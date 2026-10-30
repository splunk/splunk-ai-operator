import argparse, hashlib, io, json, pathlib, subprocess, tarfile, tempfile, unittest
from unittest.mock import patch
import build_airgap_image_inventory as inv

class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root=pathlib.Path(self.tmp.name)

    def make_oci_bundle(
        self,
        *,
        schema_version=1,
        runtime_value=None,
        tamper=False,
        reference="x/las:v1",
        archive_reference=None,
        single_manifest=False,
        other_platform_without_blobs=False,
        compatible_variant_without_blobs=False,
        archive_root_is_platform=False,
        config_architecture="amd64",
    ):
        bundle=self.root/f"bundle-{schema_version}-{len(list(self.root.iterdir()))}"
        (bundle/"images").mkdir(parents=True)
        config=json.dumps(
            {"os":"linux","architecture":config_architecture},
            separators=(",", ":"),
        ).encode()
        runtime_digest="sha256:"+hashlib.sha256(config).hexdigest()
        manifest=json.dumps({
            "schemaVersion":2,
            "config":{"digest":runtime_digest,"size":len(config)},
            "layers":[],
        },separators=(",", ":")).encode()
        manifest_digest="sha256:"+hashlib.sha256(manifest).hexdigest()
        manifests=[{
            "digest":manifest_digest,
            "size":len(manifest),
            "platform":{"os":"linux","architecture":"amd64"},
        }]
        if other_platform_without_blobs:
            manifests.append({
                "digest":"sha256:"+"a"*64,
                "size":123,
                "platform":{"os":"linux","architecture":"arm64","variant":"v8"},
            })
        if compatible_variant_without_blobs:
            manifests.append({
                "digest":"sha256:"+"b"*64,
                "size":124,
                "platform":{"os":"linux","architecture":"amd64","variant":"v2"},
            })
        image_index=json.dumps({
            "schemaVersion":2,
            "manifests":manifests,
        },separators=(",", ":")).encode()
        image_digest=(
            manifest_digest
            if single_manifest
            else "sha256:"+hashlib.sha256(image_index).hexdigest()
        )
        archive_digest = manifest_digest if archive_root_is_platform else image_digest
        archive_payload = manifest if archive_root_is_platform else image_index
        archive_index=json.dumps({
            "schemaVersion":2,
            "manifests":[{
                "digest":archive_digest,
                "size":len(archive_payload),
                "annotations":{"org.opencontainers.image.ref.name":archive_reference or reference},
            }],
        },separators=(",", ":")).encode()
        archive_path=bundle/"images/workload-images.tar"
        with tarfile.open(archive_path,"w") as archive:
            payloads=[("index.json",archive_index)]
            if not single_manifest and not archive_root_is_platform:
                payloads.append((
                    f"blobs/sha256/{image_digest.removeprefix('sha256:')}",
                    image_index,
                ))
            payloads.extend((
                (f"blobs/sha256/{manifest_digest.removeprefix('sha256:')}",manifest),
                (f"blobs/sha256/{runtime_digest.removeprefix('sha256:')}",b"tampered" if tamper else config),
            ))
            for name,payload in payloads:
                member=tarfile.TarInfo(name); member.size=len(payload)
                archive.addfile(member,io.BytesIO(payload))
        (bundle/"images/workload-images.list").write_text(reference+"\n")
        platform={"os":"linux","architecture":"amd64","digest":manifest_digest}
        if runtime_value is not None:
            platform["runtimeDigest"]=runtime_value
        inventory={
            "schemaVersion":schema_version,
            "profile":"cpuOnly",
            "imageImports":[{"archive":"images/workload-images.tar","imageList":"images/workload-images.list"}],
            "images":[{
                "reference":reference,
                "digest":image_digest,
                "platforms":[platform],
                "importArchives":["images/workload-images.tar"],
            }],
        }
        if schema_version == 2:
            inventory["targetPlatform"]="linux/amd64"
        inventory_path=bundle/"image-inventory.json"
        inventory_path.write_text(json.dumps(inventory))
        return bundle,inventory_path,inventory["images"][0],runtime_digest

    def test_mirror_mapping_preserves_paths_and_strips_registry_host(self):
        self.assertEqual(inv.mirror_reference("mirror.example", "ghcr.io/team/agent:v1"),
                         "mirror.example/team/agent:v1")
        self.assertEqual(inv.mirror_reference("mirror.example", "team/agent:v1"),
                         "mirror.example/team/agent:v1")

    def test_image_list_deduplicates_and_skips_comments(self):
        p=self.root/"images.list"; p.write_text("# note\nx/a:v1\nx/a:v1\n")
        self.assertEqual(inv.image_references(p),["x/a:v1"])

    @patch.object(inv.subprocess,"run")
    def test_inspect_records_digest_and_multi_platforms(self,run):
        amd_digest="sha256:"+"a"*64
        arm_digest="sha256:"+"b"*64
        amd_runtime="sha256:"+"c"*64
        arm_runtime="sha256:"+"d"*64
        raw=json.dumps({"manifests":[
            {"digest":amd_digest,"platform":{"os":"linux","architecture":"amd64"}},
            {"digest":arm_digest,"platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]})
        run.side_effect=[
            subprocess.CompletedProcess([],0,stdout=raw),
            subprocess.CompletedProcess([],0,stdout=json.dumps({"config":{"digest":amd_runtime}})),
            subprocess.CompletedProcess([],0,stdout=json.dumps({"config":{"digest":arm_runtime}})),
        ]
        result=inv.inspect_image("x/a:v1")
        self.assertEqual(result["digest"],"sha256:"+hashlib.sha256(raw.encode()).hexdigest())
        self.assertEqual([p["architecture"] for p in result["platforms"]],["amd64","arm64"])
        self.assertEqual([p["runtimeDigest"] for p in result["platforms"]],[amd_runtime,arm_runtime])

    @patch.object(inv.subprocess,"run")
    def test_inspect_records_only_selected_target_platform(self,run):
        amd_digest="sha256:"+"a"*64
        arm_digest="sha256:"+"b"*64
        amd_runtime="sha256:"+"c"*64
        raw=json.dumps({"manifests":[
            {"digest":amd_digest,"platform":{"os":"linux","architecture":"amd64"}},
            {"digest":"sha256:"+"f"*64,"platform":{"os":"linux","architecture":"amd64","variant":"v2"}},
            {"digest":arm_digest,"platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]})
        run.side_effect=[
            subprocess.CompletedProcess([],0,stdout=raw),
            subprocess.CompletedProcess([],0,stdout=json.dumps({"config":{"digest":amd_runtime}})),
        ]
        result=inv.inspect_image("x/a:v1","linux/amd64")
        self.assertEqual(result["platforms"],[{
            "os":"linux",
            "architecture":"amd64",
            "digest":amd_digest,
            "runtimeDigest":amd_runtime,
        }])

    @patch.object(inv.subprocess,"run")
    def test_inspect_records_single_manifest_runtime_digest(self,run):
        runtime_digest="sha256:"+"e"*64
        raw=json.dumps({"config":{"digest":runtime_digest},"layers":[]})
        run.side_effect=[
            subprocess.CompletedProcess([],0,stdout=raw),
            subprocess.CompletedProcess([],0,stdout=json.dumps({"Os":"linux","Architecture":"amd64"})),
        ]
        result=inv.inspect_image("x/a:v1","linux/amd64")
        self.assertEqual(result["platforms"],[{
            "os":"linux",
            "architecture":"amd64",
            "digest":result["digest"],
            "runtimeDigest":runtime_digest,
        }])

    @patch.object(inv.subprocess,"run")
    def test_registry_error_is_sanitized(self,run):
        import subprocess
        run.side_effect=subprocess.CalledProcessError(1,["skopeo"],stderr="unauthorized https://user:secret@registry")
        with self.assertRaisesRegex(RuntimeError,"authentication was rejected") as caught:
            inv.inspect_image("x/a:v1")
        self.assertNotIn("secret",str(caught.exception))

    def test_build_records_mirror_import_and_chart_hash(self):
        image_dir=self.root/"images"; image_dir.mkdir()
        (image_dir/"workload-images.list").write_text("x/las:v1\n")
        (image_dir/"workload-images.tar").write_bytes(b"archive")
        refs=self.root/"all.list"; refs.write_text("x/las:v1\n")
        chart=self.root/"las.tgz"; chart.write_bytes(b"chart")
        out=self.root/"inventory.json"
        args=argparse.Namespace(images_file=refs,image_lists_dir=image_dir,profile="cpuOnly",
            target_platform="linux/amd64",
            mirror_registry="mirror.example",embedded_chart=chart,output=out)
        with patch.object(inv,"inspect_image",return_value={"reference":"x/las:v1","digest":"sha256:"+"a"*64,
                "platforms":[{"os":"linux","architecture":"amd64"}]}):
            inv.build(args)
        result=json.loads(out.read_text()); image=result["images"][0]
        self.assertEqual(image["mirrorReference"],"mirror.example/x/las:v1")
        self.assertEqual(image["importArchives"],["images/workload-images.tar"])
        self.assertEqual(result["targetPlatform"],"linux/amd64")
        self.assertEqual(result["embeddedDistribution"]["sha256"],hashlib.sha256(b"chart").hexdigest())

    def test_validate_accepts_complete_bundle(self):
        bundle=self.root/"bundle"
        (bundle/"images").mkdir(parents=True)
        (bundle/"charts").mkdir()
        (bundle/"images/workload-images.list").write_text("x/las:v1\n")
        (bundle/"images/workload-images.tar").write_bytes(b"archive")
        (bundle/"charts/las.tgz").write_bytes(b"chart")
        data={
            "schemaVersion":1,"profile":"cpuOnly",
            "imageImports":[{"archive":"images/workload-images.tar","imageList":"images/workload-images.list"}],
            "images":[{"reference":"x/las:v1","digest":"sha256:"+"a"*64,
                       "platforms":[{"os":"linux","architecture":"amd64"}],
                       "importArchives":["images/workload-images.tar"]}],
            "embeddedDistribution":{"path":"charts/las.tgz","sha256":hashlib.sha256(b"chart").hexdigest()},
        }
        path=bundle/"image-inventory.json"; path.write_text(json.dumps(data))
        inv.validate(argparse.Namespace(inventory=path,bundle_dir=bundle))

    def test_validate_rejects_missing_archive(self):
        bundle=self.root/"bundle"; (bundle/"images").mkdir(parents=True)
        path=bundle/"image-inventory.json"
        path.write_text(json.dumps({
            "schemaVersion":1,"profile":"cpuOnly",
            "imageImports":[{"archive":"images/missing.tar","imageList":"images/missing.list"}],
            "images":[{"reference":"x/las:v1","digest":"sha256:"+"a"*64,
                       "platforms":[{"os":"linux","architecture":"amd64"}],
                       "importArchives":["images/missing.tar"]}],
        }))
        with self.assertRaisesRegex(ValueError,"archive is missing"):
            inv.validate(argparse.Namespace(inventory=path,bundle_dir=bundle))

    def test_validate_rejects_path_traversal(self):
        with self.assertRaisesRegex(ValueError,"unsafe bundle path"):
            inv.safe_bundle_path(self.root,"../escape")

    def test_legacy_inventory_derives_runtime_digest_from_oci_chain(self):
        bundle,_,item,runtime_digest=self.make_oci_bundle()
        inv.enrich_image_runtime_digests(bundle,item)
        self.assertEqual(item["platforms"][0]["runtimeDigest"],runtime_digest)

    def test_target_platform_ignores_unbundled_non_target_children(self):
        bundle,_,item,runtime_digest=self.make_oci_bundle(
            other_platform_without_blobs=True
        )
        inv.enrich_image_runtime_digests(
            bundle,item,target_platform="linux/amd64"
        )
        self.assertEqual(item["platforms"][0]["runtimeDigest"],runtime_digest)

    def test_target_platform_prefers_baseline_over_unbundled_amd64_variant(self):
        bundle,_,item,runtime_digest=self.make_oci_bundle(
            compatible_variant_without_blobs=True
        )
        inv.enrich_image_runtime_digests(
            bundle,item,target_platform="linux/amd64"
        )
        self.assertEqual(item["platforms"][0]["runtimeDigest"],runtime_digest)

    def test_legacy_multi_platform_inventory_uses_only_cpu_bundle_target(self):
        bundle,_,item,runtime_digest=self.make_oci_bundle(
            other_platform_without_blobs=True
        )
        item["platforms"].append({
            "os":"linux",
            "architecture":"arm64",
            "variant":"v8",
            "digest":"sha256:"+"a"*64,
        })
        inv.enrich_image_runtime_digests(
            bundle,item,target_platform="linux/amd64"
        )
        self.assertEqual(item["platforms"][0]["runtimeDigest"],runtime_digest)
        self.assertNotIn("runtimeDigest",item["platforms"][1])

    def test_target_platform_accepts_archive_retargeted_to_selected_manifest(self):
        bundle,_,item,runtime_digest=self.make_oci_bundle(
            other_platform_without_blobs=True,
            archive_root_is_platform=True,
        )
        inv.enrich_image_runtime_digests(
            bundle,item,target_platform="linux/amd64"
        )
        self.assertEqual(item["platforms"][0]["runtimeDigest"],runtime_digest)

    def test_platform_descriptor_must_match_verified_oci_config(self):
        bundle,_,item,_=self.make_oci_bundle(config_architecture="arm64")
        with self.assertRaisesRegex(ValueError,"config platform"):
            inv.enrich_image_runtime_digests(
                bundle,item,target_platform="linux/amd64"
            )

    def test_legacy_single_platform_without_manifest_digest_is_supported(self):
        bundle,_,item,runtime_digest=self.make_oci_bundle(single_manifest=True)
        del item["platforms"][0]["digest"]
        inv.enrich_image_runtime_digests(bundle,item)
        self.assertEqual(item["platforms"][0]["runtimeDigest"],runtime_digest)

    def test_legacy_platform_without_digest_still_matches_architecture(self):
        bundle,_,item,_=self.make_oci_bundle(single_manifest=True)
        del item["platforms"][0]["digest"]
        item["platforms"][0]["architecture"]="arm64"
        with self.assertRaisesRegex(ValueError,"does not resolve uniquely"):
            inv.enrich_image_runtime_digests(bundle,item)

    def test_canonical_docker_hub_reference_matches_archive_annotation(self):
        bundle,_,item,runtime_digest=self.make_oci_bundle(
            reference="busybox:v1",
            archive_reference="docker.io/library/busybox:v1",
        )
        inv.enrich_image_runtime_digests(bundle,item)
        self.assertEqual(item["platforms"][0]["runtimeDigest"],runtime_digest)

    def test_canonical_docker_hub_team_reference_matches_archive_annotation(self):
        bundle,_,item,runtime_digest=self.make_oci_bundle(
            reference="team/agent:v1",
            archive_reference="docker.io/team/agent:v1",
        )
        inv.enrich_image_runtime_digests(bundle,item)
        self.assertEqual(item["platforms"][0]["runtimeDigest"],runtime_digest)

    def test_identical_reference_in_two_archives_is_deduplicated(self):
        bundle,_,item,runtime_digest=self.make_oci_bundle()
        first=bundle/"images/workload-images.tar"
        second=bundle/"images/duplicate-images.tar"
        second.write_bytes(first.read_bytes())
        item["importArchives"].append("images/duplicate-images.tar")
        inv.enrich_image_runtime_digests(bundle,item)
        self.assertEqual(item["platforms"][0]["runtimeDigest"],runtime_digest)

    def test_schema_v2_requires_recorded_runtime_digest(self):
        bundle,path,_,_=self.make_oci_bundle(schema_version=2)
        with self.assertRaisesRegex(ValueError,"missing runtimeDigest"):
            inv.validate(argparse.Namespace(inventory=path,bundle_dir=bundle))

    def test_schema_v2_rejects_runtime_digest_mismatch(self):
        bundle,path,_,_=self.make_oci_bundle(
            schema_version=2,runtime_value="sha256:"+"f"*64
        )
        with self.assertRaisesRegex(ValueError,"does not match"):
            inv.validate(argparse.Namespace(inventory=path,bundle_dir=bundle))

    def test_oci_config_blob_tampering_fails_closed(self):
        bundle,_,item,_=self.make_oci_bundle(tamper=True)
        with self.assertRaisesRegex(ValueError,"blob content"):
            inv.enrich_image_runtime_digests(bundle,item)

if __name__=="__main__": unittest.main()
