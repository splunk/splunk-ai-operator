#!/usr/bin/env python3
"""Build and validate image metadata for a CPU-only offline AI Tier bundle."""
from __future__ import annotations
import argparse
import hashlib
import json
import re
import subprocess
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
OCI_REFERENCE_ANNOTATIONS = (
    "org.opencontainers.image.ref.name",
    "io.containerd.image.name",
)


class ReferenceNotInArchive(ValueError):
    """The selected OCI archive does not contain the requested reference."""

def image_references(path: Path) -> list[str]:
    return sorted({line.strip() for line in path.read_text(encoding="utf-8").splitlines()
                   if line.strip() and not line.lstrip().startswith("#")})


def canonical_image_reference(reference: str) -> str:
    first, separator, _ = reference.partition("/")
    if not separator:
        return f"docker.io/library/{reference}"
    if "." not in first and ":" not in first and first != "localhost":
        return f"docker.io/{reference}"
    return reference


def parse_platform(value: str) -> tuple[str, str, str | None]:
    if not isinstance(value, str):
        raise ValueError("target platform must be a string")
    parts = value.split("/")
    if len(parts) not in (2, 3) or any(not part for part in parts):
        raise ValueError("target platform must be os/architecture[/variant]")
    return parts[0], parts[1], parts[2] if len(parts) == 3 else None


def platform_matches(
    platform: dict[str, Any], target: tuple[str, str, str | None]
) -> bool:
    os_name, architecture, variant = target
    return (
        platform.get("os") == os_name
        and platform.get("architecture") == architecture
        and (platform.get("variant") or None) == variant
    )

def _raw_inspect(reference: str) -> tuple[bytes, dict[str, Any]]:
    result = subprocess.run(
        ["skopeo", "inspect", "--raw", f"docker://{reference}"],
        check=True,
        capture_output=True,
        text=True,
    )
    if not isinstance(result.stdout, str):
        raise ValueError("registry inspection returned non-text manifest data")
    raw = result.stdout.encode("utf-8").rstrip(b"\n")
    manifest = json.loads(raw)
    if not isinstance(manifest, dict):
        raise ValueError("registry inspection returned a non-object manifest")
    return raw, manifest


def _digest_reference(reference: str, digest: str) -> str:
    base = reference.split("@", 1)[0]
    prefix, separator, leaf = base.rpartition("/")
    if ":" in leaf:
        leaf = leaf.rsplit(":", 1)[0]
    repository = f"{prefix}{separator}{leaf}" if separator else leaf
    return f"{repository}@{digest}"


def _config_digest(manifest: dict[str, Any], context: str) -> str:
    config = manifest.get("config")
    digest = config.get("digest") if isinstance(config, dict) else None
    if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
        raise ValueError(f"{context} is missing a valid OCI config digest")
    return digest


def inspect_image(reference: str, target_platform: str | None = None) -> dict[str, Any]:
    try:
        target = parse_platform(target_platform) if target_platform else None
        raw, manifest = _raw_inspect(reference)
        manifest_digest = "sha256:" + hashlib.sha256(raw).hexdigest()
        platforms = []
        raw_descriptors = manifest.get("manifests")
        descriptors = raw_descriptors if isinstance(raw_descriptors, list) else []
        if target is not None and isinstance(raw_descriptors, list):
            descriptors = [
                item
                for item in descriptors
                if isinstance(item, dict)
                and isinstance(item.get("platform"), dict)
                and platform_matches(item["platform"], target)
            ]
            if len(descriptors) != 1:
                raise ValueError(
                    f"registry image {reference} does not resolve uniquely for "
                    f"{target_platform}"
                )
        for item in descriptors:
            platform = item.get("platform", {})
            if platform.get("os") and platform.get("architecture"):
                platform_digest = item.get("digest")
                if not isinstance(platform_digest, str) or not DIGEST_RE.fullmatch(
                    platform_digest
                ):
                    raise ValueError("registry platform descriptor has an invalid digest")
                _, platform_manifest = _raw_inspect(
                    _digest_reference(reference, platform_digest)
                )
                entry = {
                    "os": platform["os"],
                    "architecture": platform["architecture"],
                    "digest": platform_digest,
                    "runtimeDigest": _config_digest(
                        platform_manifest, f"platform manifest for {reference}"
                    ),
                }
                if platform.get("variant"): entry["variant"] = platform["variant"]
                platforms.append(entry)
        if not platforms:
            detail = json.loads(subprocess.run(
                ["skopeo", "inspect", f"docker://{reference}"],
                check=True, capture_output=True, text=True).stdout)
            actual = {
                "os": detail["Os"],
                "architecture": detail["Architecture"],
            }
            if detail.get("Variant"):
                actual["variant"] = detail["Variant"]
            if target is not None and not platform_matches(actual, target):
                raise ValueError(
                    f"registry image {reference} is not available for {target_platform}"
                )
            platforms = [{
                **actual,
                "digest": manifest_digest,
                "runtimeDigest": _config_digest(manifest, f"manifest for {reference}"),
            }]
        return {"reference": reference, "digest": manifest_digest,
                "platforms": platforms}
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, KeyError) as exc:
        reason = "registry inspection failed"
        if isinstance(exc, subprocess.CalledProcessError):
            detail = (exc.stderr or "").lower()
            if "unauthorized" in detail or "authentication required" in detail:
                reason = "registry authentication was rejected"
            elif "certificate" in detail or "x509" in detail or "tls" in detail:
                reason = "registry TLS trust verification failed"
        raise RuntimeError(f"{reason} for image {reference}") from exc

def mirror_reference(registry: str, reference: str) -> str | None:
    if not registry:
        return None
    first, separator, remainder = reference.partition("/")
    image_path = remainder if separator and ("." in first or ":" in first or first == "localhost") else reference
    return f"{registry.rstrip('/')}/{image_path}"

def build(args: argparse.Namespace) -> None:
    refs = image_references(args.images_file)
    if not refs: raise ValueError("image list is empty")
    imports, mapping = [], {}
    for list_path in sorted(args.image_lists_dir.glob("*.list")):
        entries = image_references(list_path)
        if not entries: continue
        archive_name = list_path.name.removesuffix(".list") + ".tar"
        if not (list_path.parent / archive_name).is_file():
            raise ValueError(f"image archive missing for import list {list_path.name}")
        archive = f"images/{archive_name}"
        imports.append({"archive": archive, "imageList": f"images/{list_path.name}"})
        for ref in entries: mapping.setdefault(ref, []).append(archive)
    if set(refs) - set(mapping): raise ValueError("image inventory contains refs without an import archive")
    images = []
    for ref in refs:
        item = inspect_image(ref, args.target_platform)
        item["importArchives"] = sorted(mapping[ref])
        item["mirrorReference"] = mirror_reference(args.mirror_registry, ref)
        low = ref.lower()
        item["role"] = "las-agent-server" if "langgraph" in low or "las-sample-agent" in low else (
            "ai-tier-operator" if "splunk-ai-operator" in low else (
            "metrics" if "metrics-server" in low or "prometheus" in low else "cluster-or-product"))
        images.append(item)
    result = {"schemaVersion":2,"profile":args.profile,
              "targetPlatform":args.target_platform,
              "generatedAt":datetime.now(timezone.utc).isoformat(),
              "imageImports":imports,"images":images}
    if args.embedded_chart:
        chart=args.embedded_chart
        result["embeddedDistribution"]={"path":f"charts/{chart.name}",
            "sha256":hashlib.sha256(chart.read_bytes()).hexdigest()}
    args.output.write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")

def safe_bundle_path(bundle: Path, relative: str) -> Path:
    path=Path(relative)
    if path.is_absolute() or ".." in path.parts: raise ValueError("inventory contains an unsafe bundle path")
    resolved=(bundle/path).resolve()
    if bundle.resolve() not in resolved.parents: raise ValueError("inventory contains an unsafe bundle path")
    return resolved


def _normalized_tar_members(archive: tarfile.TarFile) -> dict[str, tarfile.TarInfo]:
    members: dict[str, tarfile.TarInfo] = {}
    for member in archive.getmembers():
        path = Path(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("OCI archive contains an unsafe member path")
        normalized = Path(
            *[part for part in path.parts if part not in ("", ".")]
        ).as_posix()
        if not normalized or normalized in members:
            raise ValueError("OCI archive contains a duplicate or empty member path")
        members[normalized] = member
    return members


def _member_bytes(
    archive: tarfile.TarFile,
    members: dict[str, tarfile.TarInfo],
    relative: str,
) -> bytes:
    member = members.get(relative)
    if member is None or not member.isfile():
        raise ValueError(f"OCI archive is missing regular file {relative}")
    stream = archive.extractfile(member)
    if stream is None:
        raise ValueError(f"OCI archive member is unreadable: {relative}")
    return stream.read()


def _blob_bytes(
    archive: tarfile.TarFile,
    members: dict[str, tarfile.TarInfo],
    digest: str,
) -> bytes:
    if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
        raise ValueError("OCI descriptor has an invalid digest")
    raw = _member_bytes(
        archive,
        members,
        f"blobs/sha256/{digest.removeprefix('sha256:')}",
    )
    if "sha256:" + hashlib.sha256(raw).hexdigest() != digest:
        raise ValueError("OCI blob content does not match its descriptor digest")
    return raw


def _json_object(raw: bytes, context: str) -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ValueError(f"{context} is not valid JSON") from None
    if not isinstance(value, dict):
        raise ValueError(f"{context} is not a JSON object")
    return value


def _archive_runtime_platforms(
    archive_path: Path,
    reference: str,
    expected_digest: str,
    *,
    target_platform: str | None = None,
    approved_platform_digests: set[str] | None = None,
) -> list[dict[str, str]]:
    target = parse_platform(target_platform) if target_platform else None
    try:
        with tarfile.open(archive_path, "r:*") as archive:
            members = _normalized_tar_members(archive)
            index = _json_object(
                _member_bytes(archive, members, "index.json"), "OCI index.json"
            )
            matches = []
            for descriptor in index.get("manifests", []):
                if not isinstance(descriptor, dict):
                    continue
                annotations = descriptor.get("annotations", {})
                if isinstance(annotations, dict) and any(
                    isinstance(annotations.get(key), str)
                    and canonical_image_reference(annotations[key])
                    == canonical_image_reference(reference)
                    for key in OCI_REFERENCE_ANNOTATIONS
                ):
                    matches.append(descriptor)
            if not matches:
                raise ReferenceNotInArchive(
                    f"OCI archive does not contain image reference {reference}"
                )
            root_digest = matches[0].get("digest") if len(matches) == 1 else None
            approved_roots = {expected_digest}
            if approved_platform_digests:
                approved_roots.update(approved_platform_digests)
            if len(matches) != 1 or root_digest not in approved_roots:
                raise ValueError(
                    "OCI archive reference does not resolve to the approved image digest"
                )
            top = _json_object(
                _blob_bytes(archive, members, root_digest),
                "OCI image manifest",
            )
            children = top.get("manifests")
            if isinstance(children, list):
                if target is not None:
                    children = [
                        child
                        for child in children
                        if isinstance(child, dict)
                        and isinstance(child.get("platform"), dict)
                        and platform_matches(child["platform"], target)
                    ]
                    if len(children) != 1:
                        raise ValueError(
                            "OCI image index does not resolve uniquely for the target platform"
                        )
                result = []
                for child in children:
                    if not isinstance(child, dict):
                        raise ValueError("OCI image index has a malformed descriptor")
                    platform = child.get("platform", {})
                    if not isinstance(platform, dict):
                        raise ValueError("OCI platform descriptor is malformed")
                    manifest_digest = child.get("digest")
                    manifest = _json_object(
                        _blob_bytes(archive, members, manifest_digest),
                        "OCI platform manifest",
                    )
                    runtime_digest = _config_digest(
                        manifest, "OCI platform manifest"
                    )
                    config = _json_object(
                        _blob_bytes(archive, members, runtime_digest),
                        "OCI platform config",
                    )
                    descriptor_platform = (
                        platform.get("os", ""),
                        platform.get("architecture", ""),
                        platform.get("variant") or None,
                    )
                    if not platform_matches(config, descriptor_platform):
                        raise ValueError(
                            "OCI image config platform does not match its descriptor"
                        )
                    item = {
                        "os": platform.get("os", ""),
                        "architecture": platform.get("architecture", ""),
                        "manifestDigest": manifest_digest,
                        "runtimeDigest": runtime_digest,
                    }
                    if platform.get("variant"):
                        item["variant"] = platform["variant"]
                    result.append(item)
                return result
            runtime_digest = _config_digest(top, "OCI image manifest")
            config = _json_object(
                _blob_bytes(archive, members, runtime_digest),
                "OCI image config",
            )
            os_name = config.get("os")
            architecture = config.get("architecture")
            if not isinstance(os_name, str) or not os_name or not isinstance(
                architecture, str
            ) or not architecture:
                raise ValueError("OCI image config is missing its platform identity")
            if target is not None and not platform_matches(config, target):
                raise ValueError(
                    "OCI image manifest does not match the target platform"
                )
            result = {
                "os": os_name,
                "architecture": architecture,
                "manifestDigest": root_digest,
                "runtimeDigest": runtime_digest,
            }
            if config.get("variant"):
                result["variant"] = config["variant"]
            return [result]
    except (OSError, tarfile.TarError):
        raise ValueError(f"OCI archive is unreadable: {archive_path.name}") from None


def enrich_image_runtime_digests(
    bundle: Path,
    item: dict[str, Any],
    *,
    require_recorded: bool = False,
    target_platform: str | None = None,
) -> None:
    reference = item.get("reference")
    expected_digest = item.get("digest")
    platforms = item.get("platforms")
    archives = item.get("importArchives")
    if (
        not isinstance(reference, str)
        or not reference
        or not isinstance(expected_digest, str)
        or not DIGEST_RE.fullmatch(expected_digest)
        or not isinstance(platforms, list)
        or not platforms
        or not isinstance(archives, list)
        or not archives
    ):
        raise ValueError("image inventory entry cannot resolve OCI runtime digests")
    approved_platform_digests: set[str] = set()
    platforms_to_enrich = platforms
    if target_platform is not None:
        target = parse_platform(target_platform)
        selected = [
            platform
            for platform in platforms
            if isinstance(platform, dict) and platform_matches(platform, target)
        ]
        if len(selected) != 1 or (require_recorded and len(platforms) != 1):
            raise ValueError(
                "image inventory does not resolve exactly its target platform"
            )
        platforms_to_enrich = selected
        platform_digest = selected[0].get("digest")
        if isinstance(platform_digest, str) and DIGEST_RE.fullmatch(platform_digest):
            approved_platform_digests.add(platform_digest)
    observed: list[dict[str, str]] = []
    for relative in archives:
        archive_path = safe_bundle_path(bundle, relative)
        if not archive_path.is_file():
            raise ValueError(f"required image archive is missing: {archive_path.name}")
        try:
            observed.extend(
                _archive_runtime_platforms(
                    archive_path,
                    reference,
                    expected_digest,
                    target_platform=target_platform,
                    approved_platform_digests=approved_platform_digests,
                )
            )
        except ReferenceNotInArchive:
            continue
    deduplicated: dict[tuple[tuple[str, str], ...], dict[str, str]] = {}
    for value in observed:
        deduplicated.setdefault(tuple(sorted(value.items())), value)
    observed = list(deduplicated.values())
    if not observed:
        raise ValueError("approved image reference is absent from its import archives")
    for platform in platforms_to_enrich:
        if not isinstance(platform, dict):
            raise ValueError("image inventory has a malformed platform entry")
        manifest_digest = platform.get("digest")
        if manifest_digest is None and len(platforms) == 1 and len(observed) == 1:
            candidate = observed[0]
            candidates = [candidate] if (
                not candidate.get("os")
                or (
                    candidate.get("os") == platform.get("os")
                    and candidate.get("architecture") == platform.get("architecture")
                    and candidate.get("variant") == platform.get("variant")
                )
            ) else []
        else:
            candidates = [
                value
                for value in observed
                if value.get("manifestDigest") == manifest_digest
                and (
                    not value.get("os")
                    or (
                        value.get("os") == platform.get("os")
                        and value.get("architecture") == platform.get("architecture")
                        and value.get("variant") == platform.get("variant")
                    )
                )
            ]
        if len(candidates) != 1:
            raise ValueError(
                "image inventory platform does not resolve uniquely in its OCI archive"
            )
        derived = candidates[0]["runtimeDigest"]
        recorded = platform.get("runtimeDigest")
        if require_recorded and recorded is None:
            raise ValueError("schema v2 image platform is missing runtimeDigest")
        if recorded is not None and (
            not isinstance(recorded, str)
            or not DIGEST_RE.fullmatch(recorded)
            or recorded != derived
        ):
            raise ValueError(
                "recorded runtimeDigest does not match the OCI config digest"
            )
        platform["runtimeDigest"] = derived

def validate(args: argparse.Namespace) -> None:
    bundle=args.bundle_dir.resolve()
    inventory=json.loads(args.inventory.read_text(encoding="utf-8"))
    schema_version=inventory.get("schemaVersion")
    if schema_version not in (1,2): raise ValueError("unsupported image inventory schemaVersion")
    target_platform=inventory.get("targetPlatform")
    if schema_version == 2:
        parse_platform(target_platform)
    elif target_platform is not None:
        parse_platform(target_platform)
    if inventory.get("profile") not in ("cpuOnly","full"): raise ValueError("unsupported image inventory profile")
    images=inventory.get("images")
    if not isinstance(images,list) or not images: raise ValueError("image inventory has no images")
    refs=set()
    for item in images:
        if not isinstance(item,dict): raise ValueError("invalid image inventory entry")
        ref,digest,platforms=item.get("reference"),item.get("digest"),item.get("platforms")
        if not isinstance(ref,str) or not ref: raise ValueError("image inventory entry is missing its reference")
        if not isinstance(digest,str) or not DIGEST_RE.fullmatch(digest): raise ValueError(f"image inventory entry has an invalid digest: {ref}")
        if not isinstance(platforms,list) or not platforms or any(
            not isinstance(p,dict) or not p.get("os") or not p.get("architecture") for p in platforms):
            raise ValueError(f"image inventory entry is missing architecture metadata: {ref}")
        if any(
            p.get("digest") is not None and (
                not isinstance(p.get("digest"),str) or not DIGEST_RE.fullmatch(p["digest"])
            )
            for p in platforms
        ):
            raise ValueError(f"image inventory entry has an invalid platform digest: {ref}")
        if any(
            p.get("runtimeDigest") is not None and (
                not isinstance(p.get("runtimeDigest"),str)
                or not DIGEST_RE.fullmatch(p["runtimeDigest"])
            )
            for p in platforms
        ):
            raise ValueError(f"image inventory entry has an invalid runtimeDigest: {ref}")
        refs.add(ref)
    imports=inventory.get("imageImports")
    if not isinstance(imports,list) or not imports: raise ValueError("image inventory does not list image import archives")
    archives=set()
    for entry in imports:
        if not isinstance(entry,dict) or not entry.get("archive") or not entry.get("imageList"):
            raise ValueError("invalid image import mapping")
        archive=safe_bundle_path(bundle,entry["archive"]); listing=safe_bundle_path(bundle,entry["imageList"])
        if not archive.is_file(): raise ValueError(f"required image archive is missing: {archive.name}")
        if not listing.is_file(): raise ValueError(f"required image list is missing: {listing.name}")
        if not set(image_references(listing)).issubset(refs): raise ValueError(f"image inventory does not cover imports in {listing.name}")
        archives.add(entry["archive"])
    for item in images:
        mapped=item.get("importArchives")
        if not isinstance(mapped,list) or not mapped or not set(mapped).issubset(archives):
            raise ValueError(f"image has no valid import mapping: {item['reference']}")
        if schema_version == 2:
            enrich_image_runtime_digests(
                bundle,
                item,
                require_recorded=True,
                target_platform=target_platform,
            )
    distribution=inventory.get("embeddedDistribution")
    if distribution:
        chart=safe_bundle_path(bundle,distribution.get("path",""))
        if not chart.is_file(): raise ValueError("embedded LAS chart artifact is missing")
        if hashlib.sha256(chart.read_bytes()).hexdigest()!=distribution.get("sha256"):
            raise ValueError("embedded LAS chart digest does not match the inventory")

def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    cmds=parser.add_subparsers(dest="command",required=True)
    bp=cmds.add_parser("build")
    bp.add_argument("--images-file",required=True,type=Path)
    bp.add_argument("--image-lists-dir",required=True,type=Path)
    bp.add_argument("--profile",choices=("full","cpuOnly"),required=True)
    bp.add_argument("--target-platform",required=True)
    bp.add_argument("--mirror-registry",default="")
    bp.add_argument("--embedded-chart",type=Path)
    bp.add_argument("--output",required=True,type=Path)
    bp.set_defaults(func=build)
    vp=cmds.add_parser("validate")
    vp.add_argument("--inventory",required=True,type=Path)
    vp.add_argument("--bundle-dir",required=True,type=Path)
    vp.set_defaults(func=validate)
    args=parser.parse_args()
    try: args.func(args)
    except (RuntimeError,ValueError,OSError,json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}",file=sys.stderr); return 1
    return 0

if __name__=="__main__": raise SystemExit(main())
