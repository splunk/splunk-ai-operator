"""Offline contract tests for CPU-only air-gap runtime qualification."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import io
import json
import pathlib
import tarfile
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("validate_cpu_airgap_runtime.py")
SPEC = importlib.util.spec_from_file_location("validate_cpu_airgap_runtime", SCRIPT)
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)

OCI_CONFIG = json.dumps(
    {"architecture": "amd64", "os": "linux"}, separators=(",", ":")
).encode()
SHA_A = "sha256:" + hashlib.sha256(OCI_CONFIG).hexdigest()
OCI_PLATFORM_MANIFEST = json.dumps(
    {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": {
            "mediaType": "application/vnd.oci.image.config.v1+json",
            "digest": SHA_A,
            "size": len(OCI_CONFIG),
        },
        "layers": [],
    },
    separators=(",", ":"),
).encode()
SHA_B = "sha256:" + hashlib.sha256(OCI_PLATFORM_MANIFEST).hexdigest()
OCI_IMAGE_INDEX = json.dumps(
    {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": [
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": SHA_B,
                "size": len(OCI_PLATFORM_MANIFEST),
                "platform": {"os": "linux", "architecture": "amd64"},
            }
        ],
    },
    separators=(",", ":"),
).encode()
SHA_TOP = "sha256:" + hashlib.sha256(OCI_IMAGE_INDEX).hexdigest()


def single_manifest_fixture(identity):
    config = json.dumps(
        {
            "architecture": "amd64",
            "os": "linux",
            "config": {"Labels": {"fixture.identity": identity}},
        },
        separators=(",", ":"),
    ).encode()
    runtime_digest = "sha256:" + hashlib.sha256(config).hexdigest()
    manifest = json.dumps(
        {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": {
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "digest": runtime_digest,
                "size": len(config),
            },
            "layers": [],
        },
        separators=(",", ":"),
    ).encode()
    manifest_digest = "sha256:" + hashlib.sha256(manifest).hexdigest()
    return config, runtime_digest, manifest, manifest_digest


OCI_CONFIG_C, SHA_C, OCI_MANIFEST_C, SHA_TOP_C = single_manifest_fixture("operator")
OCI_CONFIG_D, SHA_D, OCI_MANIFEST_D, SHA_TOP_D = single_manifest_fixture("slim")
OCI_CONFIG_E, SHA_E, OCI_MANIFEST_E, SHA_TOP_E = single_manifest_fixture("splunk")
OCI_CONFIG_F, SHA_F, OCI_MANIFEST_F, SHA_TOP_F = single_manifest_fixture(
    "splunk-operator"
)
ECR_ACCOUNT = "123456789012"
ECR_REGISTRY = f"{ECR_ACCOUNT}.dkr.ecr.us-west-2.amazonaws.com"
IMAGE = f"{ECR_REGISTRY}/launchpad-agent:v1"
OPERATOR_IMAGE = f"{ECR_REGISTRY}/splunk-ai-operator:v1"
SLIM_IMAGE = f"{ECR_REGISTRY}/slim:v1"
SPLUNK_IMAGE = f"{ECR_REGISTRY}/splunk:v1"
SPLUNK_OPERATOR_IMAGE = f"{ECR_REGISTRY}/splunk-operator:v1"
SOURCE_COMMIT = "1" * 40

SUPPORTING_OCI_FIXTURES = (
    (OPERATOR_IMAGE, OCI_MANIFEST_C, SHA_TOP_C, OCI_CONFIG_C, SHA_C),
    (SLIM_IMAGE, OCI_MANIFEST_D, SHA_TOP_D, OCI_CONFIG_D, SHA_D),
    (SPLUNK_IMAGE, OCI_MANIFEST_E, SHA_TOP_E, OCI_CONFIG_E, SHA_E),
    (
        SPLUNK_OPERATOR_IMAGE,
        OCI_MANIFEST_F,
        SHA_TOP_F,
        OCI_CONFIG_F,
        SHA_F,
    ),
)


def ready_condition(generation=1):
    return [
        {
            "type": "Ready",
            "status": "True",
            "observedGeneration": generation,
            "reason": "Ready",
        }
    ]


def deployment(
    name,
    image=IMAGE,
    ready=1,
    *,
    labels=None,
    selector_labels=None,
    container="app",
):
    selector = selector_labels or labels or {"app": name}
    return {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": name,
            "generation": 1,
            "labels": dict(labels or selector),
        },
        "spec": {
            "replicas": 1,
            "selector": {"matchLabels": dict(selector)},
            "template": {
                "metadata": {"labels": dict(selector)},
                "spec": {"containers": [{"name": container, "image": image}]},
            },
        },
        "status": {
            "observedGeneration": 1,
            "readyReplicas": ready,
            "availableReplicas": ready,
        },
    }


def statefulset(name, image=SPLUNK_IMAGE, ready=1, *, labels=None):
    selector = labels or {"app": name}
    return {
        "apiVersion": "apps/v1",
        "kind": "StatefulSet",
        "metadata": {"name": name, "generation": 1, "labels": dict(selector)},
        "spec": {
            "replicas": 1,
            "selector": {"matchLabels": dict(selector)},
            "template": {
                "metadata": {"labels": dict(selector)},
                "spec": {"containers": [{"name": "splunk", "image": image}]},
            },
        },
        "status": {
            "observedGeneration": 1,
            "readyReplicas": ready,
            "currentRevision": "revision-1",
            "updateRevision": "revision-1",
        },
    }


def pod(name, uid, component, container, digest=SHA_A, ready=True, image=IMAGE):
    release = runtime.las_release_name("agent")
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": name,
            "uid": uid,
            "ownerReferences": [
                {
                    "apiVersion": "apps/v1",
                    "kind": "ReplicaSet",
                    "name": component + "-6f4d5b7c8d",
                    "uid": component + "-rs-uid",
                    "controller": True,
                }
            ],
            "labels": {
                "app.kubernetes.io/name": "langgraph-cloud",
                "app.kubernetes.io/instance": release,
                "app.kubernetes.io/component": component,
            },
        },
        "spec": {
            "nodeName": "worker",
            "containers": [{"name": container, "image": image}],
        },
        "status": {
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
            "containerStatuses": [
                {
                    "name": container,
                    "ready": ready,
                    "image": image,
                    "imageID": f"docker-pullable://{image.split(':')[0]}@{digest}",
                }
            ],
        },
    }


def configured_pod(
    name,
    uid,
    labels,
    container,
    image,
    digest,
    ready=True,
    *,
    controller_kind="ReplicaSet",
    controller_name=None,
):
    controller_name = controller_name or name.rsplit("-", 1)[0]
    owner_name = (
        controller_name
        if controller_kind == "StatefulSet"
        else controller_name + "-6f4d5b7c8d"
    )
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": name,
            "uid": uid,
            "labels": dict(labels),
            "ownerReferences": [
                {
                    "apiVersion": "apps/v1",
                    "kind": controller_kind,
                    "name": owner_name,
                    "uid": owner_name + "-uid",
                    "controller": True,
                }
            ],
        },
        "spec": {
            "nodeName": "worker",
            "containers": [{"name": container, "image": image}],
        },
        "status": {
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
            "containerStatuses": [
                {
                    "name": container,
                    "ready": ready,
                    "image": image,
                    "imageID": f"docker-pullable://{image.rsplit(':', 1)[0]}@{digest}",
                }
            ],
        },
    }


class FakeKubectl:
    def __init__(self, responses, sequences=None):
        self.responses = responses
        self.sequences = {
            key: list(values) for key, values in (sequences or {}).items()
        }
        self.deleted = []

    @staticmethod
    def key(resource, name=None, selector=None, namespaced=True, namespace=None):
        return resource, name, selector, namespaced, namespace

    def get(
        self, resource, name=None, *, selector=None, namespaced=True, namespace=None
    ):
        key = self.key(resource, name, selector, namespaced, namespace)
        if key in self.sequences:
            values = self.sequences[key]
            if len(values) > 1:
                return values.pop(0)
            return values[0]
        if key not in self.responses:
            raise AssertionError(f"unexpected kubectl get: {key}")
        return self.responses[key]

    def delete_pod(self, name):
        self.deleted.append(name)


class IncrementingClock:
    def __init__(self):
        self.value = 0

    def __call__(self):
        self.value += 1
        return self.value


class RuntimeFixture:
    def __init__(self, root: pathlib.Path, pod_digest=SHA_A, platform_digest=SHA_B):
        self.root = root
        self.bundle = root / "bundle"
        (self.bundle / "images").mkdir(parents=True)
        (self.bundle / "charts").mkdir()
        (self.bundle / "bundle-profile.txt").write_text("cpuOnly\n", encoding="utf-8")
        (self.bundle / "source-commit.txt").write_text(
            SOURCE_COMMIT + "\n", encoding="utf-8"
        )
        (self.bundle / "images/workload-images.list").write_text(
            "\n".join(
                sorted(
                    (
                        IMAGE,
                        OPERATOR_IMAGE,
                        SLIM_IMAGE,
                        SPLUNK_IMAGE,
                        SPLUNK_OPERATOR_IMAGE,
                    )
                )
            )
            + "\n",
            encoding="utf-8",
        )
        root_descriptors = [
            {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": SHA_TOP,
                "size": len(OCI_IMAGE_INDEX),
                "annotations": {"org.opencontainers.image.ref.name": IMAGE},
            }
        ]
        root_descriptors.extend(
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": manifest_digest,
                "size": len(manifest),
                "annotations": {"org.opencontainers.image.ref.name": reference},
            }
            for reference, manifest, manifest_digest, _, _ in SUPPORTING_OCI_FIXTURES
        )
        archive_index = json.dumps(
            {
                "schemaVersion": 2,
                "manifests": root_descriptors,
            },
            separators=(",", ":"),
        ).encode()
        archive_members = [
            ("index.json", archive_index),
            (f"blobs/sha256/{SHA_TOP.removeprefix('sha256:')}", OCI_IMAGE_INDEX),
            (f"blobs/sha256/{SHA_B.removeprefix('sha256:')}", OCI_PLATFORM_MANIFEST),
            (f"blobs/sha256/{SHA_A.removeprefix('sha256:')}", OCI_CONFIG),
        ]
        for _, manifest, manifest_digest, config, runtime_digest in (
            SUPPORTING_OCI_FIXTURES
        ):
            archive_members.extend(
                (
                    (
                        f"blobs/sha256/{manifest_digest.removeprefix('sha256:')}",
                        manifest,
                    ),
                    (
                        f"blobs/sha256/{runtime_digest.removeprefix('sha256:')}",
                        config,
                    ),
                )
            )
        with tarfile.open(self.bundle / "images/workload-images.tar", "w") as archive:
            for name, payload in archive_members:
                member = tarfile.TarInfo(name)
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))
        chart_buffer = io.BytesIO()
        chart_yaml = b"apiVersion: v2\nname: langgraph-cloud\nversion: 0.3.5-splunk.2\n"
        with tarfile.open(fileobj=chart_buffer, mode="w:gz") as archive:
            member = tarfile.TarInfo("langgraph-cloud/Chart.yaml")
            member.size = len(chart_yaml)
            archive.addfile(member, io.BytesIO(chart_yaml))
        (self.bundle / "charts/las.tgz").write_bytes(chart_buffer.getvalue())

        def image_entry(reference, digest, platform_digest=None):
            return {
                "reference": reference,
                "digest": digest,
                "platforms": [
                    {
                        "os": "linux",
                        "architecture": "amd64",
                        "digest": platform_digest or digest,
                    }
                ],
                "importArchives": ["images/workload-images.tar"],
            }

        inventory = {
            "schemaVersion": 1,
            "profile": "cpuOnly",
            "imageImports": [
                {
                    "archive": "images/workload-images.tar",
                    "imageList": "images/workload-images.list",
                }
            ],
            "images": [
                image_entry(IMAGE, SHA_TOP, platform_digest),
                image_entry(OPERATOR_IMAGE, SHA_TOP_C),
                image_entry(SLIM_IMAGE, SHA_TOP_D),
                image_entry(SPLUNK_IMAGE, SHA_TOP_E),
                image_entry(SPLUNK_OPERATOR_IMAGE, SHA_TOP_F),
            ],
            "embeddedDistribution": {
                "path": "charts/las.tgz",
                "sha256": hashlib.sha256(chart_buffer.getvalue()).hexdigest(),
            },
        }
        (self.bundle / "image-inventory.json").write_text(
            json.dumps(inventory), encoding="utf-8"
        )
        files = [
            "bundle-profile.txt",
            "source-commit.txt",
            "images/workload-images.list",
            "images/workload-images.tar",
            "charts/las.tgz",
            "image-inventory.json",
        ]
        manifest = "".join(
            f"{runtime.sha256_file(self.bundle / relative)}  {relative}\n"
            for relative in files
        )
        (self.bundle / "checksums.sha256").write_text(manifest, encoding="utf-8")
        self.tarball = root / "airgap-bundle.tar.gz"
        with tarfile.open(self.tarball, "w:gz") as archive:
            archive.add(self.bundle, arcname="airgap-bundle")
        self.tarball_sha256 = runtime.sha256_file(self.tarball)

        config = {
            "cluster": {"airgap": True},
            "nodes": {"gpuWorkers": 0},
            "storage": {"modelStaging": {"enabled": False}},
            "components": {
                "kuberay": False,
                "nvidia": False,
                "aiOperator": True,
                "splunkStandalone": True,
                "splunkOperator": True,
            },
            "images": {
                "registry": "",
                "operator": {"image": OPERATOR_IMAGE},
                "slim": {"apiImage": SLIM_IMAGE},
                "splunk": {
                    "image": SPLUNK_IMAGE,
                    "operatorImage": SPLUNK_OPERATOR_IMAGE,
                },
            },
            "splunk": {"enabled": True, "standaloneName": "splunk-standalone"},
            "aiPlatform": {
                "profile": "cpuOnly",
                "features": [
                    {"name": "slim"},
                    {
                        "name": "agentruntime",
                        "las": {
                            "image": {
                                "repository": IMAGE.rsplit(":", 1)[0],
                                "tag": "v1",
                            },
                            "networkMode": "airgapped",
                            "tracing": {"enabled": False},
                        },
                    },
                ],
            },
        }
        self.config = root / "config.json"
        self.config.write_text(json.dumps(config), encoding="utf-8")
        network = {
            "schemaVersion": 1,
            "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "source": "sanitized-read-only-aws-capture",
            "instances": [
                {"role": "installer", "privateAddress": True, "publicAddress": False},
                {"role": "controller", "privateAddress": True, "publicAddress": False},
                {"role": "cpu-worker", "privateAddress": True, "publicAddress": False},
            ],
            "routes": [
                {"destination": "10.0.0.0/16", "targetType": "local", "public": False},
                {
                    "destination": "pl-123456",
                    "targetType": "gateway-endpoint",
                    "public": False,
                },
            ],
            "securityGroupEgress": [{"destination": "10.0.0.0/16", "public": False}],
            "internetGatewayDefaultRoute": False,
            "natGatewayDefaultRoute": False,
            "privateDependencyReachability": {
                "registry": True,
                "objectStore": True,
                "postgres": True,
                "redis": True,
                "dns": True,
                "ssh": True,
            },
            "publicTcpReachable": False,
        }
        self.network = root / "network.json"
        self.network.write_text(json.dumps(network), encoding="utf-8")
        self.output = root / "evidence"
        self.pod_digest = pod_digest

    def rebuild_bundle_artifacts(self):
        files = [
            "bundle-profile.txt",
            "source-commit.txt",
            "images/workload-images.list",
            "images/workload-images.tar",
            "charts/las.tgz",
            "image-inventory.json",
        ]
        manifest = "".join(
            f"{runtime.sha256_file(self.bundle / relative)}  {relative}\n"
            for relative in files
        )
        (self.bundle / "checksums.sha256").write_text(manifest, encoding="utf-8")
        with tarfile.open(self.tarball, "w:gz") as archive:
            archive.add(self.bundle, arcname="airgap-bundle")
        self.tarball_sha256 = runtime.sha256_file(self.tarball)

    def args(self, replace=None, confirmed=False):
        return argparse.Namespace(
            namespace="ai-platform",
            aiservice="agent",
            aiplatform="platform",
            bundle_dir=str(self.bundle),
            bundle_tarball=str(self.tarball),
            expected_bundle_sha256=self.tarball_sha256,
            expected_source_commit=SOURCE_COMMIT,
            deployment_config=str(self.config),
            network_evidence=str(self.network),
            output_dir=str(self.output),
            operator_namespace="splunk-ai-operator-system",
            operator_deployment="splunk-ai-operator-controller-manager",
            slim_aiservice=None,
            slim_deployment=None,
            splunk_namespace="splunk-operator",
            splunk_operator_deployment="splunk-operator-controller-manager",
            splunk_statefulset=None,
            replace_component=replace,
            confirm_disposable_cluster=confirmed,
            timeout_seconds=5,
            poll_seconds=0.01,
            network_max_age_seconds=3600,
        )

    def kube(self, sequences=None):
        release = runtime.las_release_name("agent")
        api_name = release + "-langgraph-cloud-api-server"
        queue_name = release + "-langgraph-cloud-queue"
        api_pod = pod("api-1", "api-old", api_name, "api-server", self.pod_digest)
        queue_pod = pod("queue-1", "queue-old", queue_name, "queue", self.pod_digest)
        platform = {
            "metadata": {"name": "platform", "generation": 1},
            "spec": {
                "profile": "cpuOnly",
                "features": [{"name": "slim"}, {"name": "agentruntime"}],
            },
            "status": {"observedGeneration": 1, "conditions": ready_condition()},
        }
        service = {
            "metadata": {"name": "agent", "uid": "agent-uid", "generation": 1},
            "spec": {
                "aiPlatformRef": {"name": "platform"},
                "features": {
                    "name": "agentruntime",
                    "las": {
                        "image": {"repository": IMAGE.rsplit(":", 1)[0], "tag": "v1"},
                        "networkMode": "airgapped",
                        "tracing": {"enabled": False},
                    },
                },
            },
            "status": {"observedGeneration": 1, "conditions": ready_condition()},
        }
        slim_service = {
            "metadata": {"name": "platform-slim", "uid": "slim-uid", "generation": 1},
            "spec": {
                "aiPlatformRef": {"name": "platform"},
                "features": {"name": "slim"},
            },
            "status": {"observedGeneration": 1, "conditions": ready_condition()},
        }
        nodes = {
            "items": [
                {
                    "metadata": {
                        "name": "controller",
                        "labels": {
                            "node-role.kubernetes.io/control-plane": "",
                            "kubernetes.io/arch": "amd64",
                        },
                    },
                    "status": {
                        "conditions": [{"type": "Ready", "status": "True"}],
                        "capacity": {"cpu": "4"},
                        "allocatable": {"cpu": "4"},
                        "addresses": [{"type": "InternalIP", "address": "10.0.0.10"}],
                        "nodeInfo": {
                            "architecture": "amd64",
                            "operatingSystem": "linux",
                            "osImage": "RHEL",
                        },
                    },
                },
                {
                    "metadata": {
                        "name": "worker",
                        "labels": {"kubernetes.io/arch": "amd64"},
                    },
                    "status": {
                        "conditions": [{"type": "Ready", "status": "True"}],
                        "capacity": {"cpu": "8"},
                        "allocatable": {"cpu": "8"},
                        "addresses": [{"type": "InternalIP", "address": "10.0.0.11"}],
                        "nodeInfo": {
                            "architecture": "amd64",
                            "operatingSystem": "linux",
                            "osImage": "RHEL",
                        },
                    },
                },
            ]
        }
        chart_base_labels = {
            "app.kubernetes.io/name": "langgraph-cloud",
            "app.kubernetes.io/instance": release,
            "app.kubernetes.io/managed-by": "Helm",
            "helm.sh/chart": "langgraph-cloud-0.3.5-splunk.2",
        }
        api_selector_labels = {
            "app.kubernetes.io/name": "langgraph-cloud",
            "app.kubernetes.io/instance": release,
            "app.kubernetes.io/component": api_name,
        }
        queue_selector_labels = {
            "app.kubernetes.io/name": "langgraph-cloud",
            "app.kubernetes.io/instance": release,
            "app.kubernetes.io/component": queue_name,
        }
        api_deployment = deployment(
            api_name,
            labels={**chart_base_labels, "app.kubernetes.io/component": api_name},
            selector_labels=api_selector_labels,
            container="api-server",
        )
        queue_deployment = deployment(
            queue_name,
            labels={**chart_base_labels, "app.kubernetes.io/component": queue_name},
            selector_labels=queue_selector_labels,
            container="queue",
        )
        slim_labels = {"app": "platform-slim", "component": "platform-slim"}
        slim = deployment(
            "platform-slim-slim-deployment",
            SLIM_IMAGE,
            labels=slim_labels,
            container="platform-slim",
        )
        splunk_labels = {
            "app.kubernetes.io/instance": "splunk-splunk-standalone-standalone"
        }
        splunk = statefulset(
            "splunk-splunk-standalone-standalone", labels=splunk_labels
        )
        workloads = {"items": [api_deployment, queue_deployment, slim, splunk]}
        operator_labels = {
            "app.kubernetes.io/name": "splunk-ai-operator",
            "control-plane": "controller-manager",
        }
        operator = deployment(
            "splunk-ai-operator-controller-manager",
            OPERATOR_IMAGE,
            labels=operator_labels,
            container="manager",
        )
        operator_pod = configured_pod(
            "operator-1",
            "operator-uid",
            operator_labels,
            "manager",
            OPERATOR_IMAGE,
            SHA_C,
            controller_name="splunk-ai-operator-controller-manager",
        )
        slim_pod = configured_pod(
            "slim-1",
            "slim-pod-uid",
            slim_labels,
            "platform-slim",
            SLIM_IMAGE,
            SHA_D,
            controller_name="platform-slim-slim-deployment",
        )
        splunk_pod = configured_pod(
            "splunk-0",
            "splunk-pod-uid",
            splunk_labels,
            "splunk",
            SPLUNK_IMAGE,
            SHA_E,
            controller_kind="StatefulSet",
            controller_name="splunk-splunk-standalone-standalone",
        )
        splunk_operator_labels = {"control-plane": "controller-manager"}
        splunk_operator = deployment(
            "splunk-operator-controller-manager",
            SPLUNK_OPERATOR_IMAGE,
            labels=splunk_operator_labels,
            container="manager",
        )
        splunk_operator_pod = configured_pod(
            "splunk-operator-1",
            "splunk-operator-uid",
            splunk_operator_labels,
            "manager",
            SPLUNK_OPERATOR_IMAGE,
            SHA_F,
            controller_name="splunk-operator-controller-manager",
        )
        compatibility = {
            "metadata": {
                "name": "agent-svc",
                "ownerReferences": [
                    {
                        "apiVersion": "ai.splunk.com/v1",
                        "kind": "AIService",
                        "name": "agent",
                        "uid": "agent-uid",
                        "controller": True,
                    }
                ],
            },
            "spec": {
                "type": "ClusterIP",
                "selector": {
                    "app.kubernetes.io/name": "langgraph-cloud",
                    "app.kubernetes.io/instance": release,
                    "app.kubernetes.io/component": api_name,
                },
                "ports": [{"name": "http", "port": 8080, "targetPort": 8000}],
            },
        }
        endpoints = {
            "subsets": [
                {
                    "addresses": [{"ip": "10.1.0.5"}],
                    "ports": [{"name": "http", "port": 8000}],
                }
            ]
        }
        api_selector = (
            "app.kubernetes.io/name=langgraph-cloud,"
            f"app.kubernetes.io/instance={release},app.kubernetes.io/component={api_name}"
        )
        queue_selector = (
            "app.kubernetes.io/name=langgraph-cloud,"
            f"app.kubernetes.io/instance={release},app.kubernetes.io/component={queue_name}"
        )
        responses = {
            FakeKubectl.key("aiplatform", "platform"): platform,
            FakeKubectl.key("aiservice", "agent"): service,
            FakeKubectl.key("aiservice", "platform-slim"): slim_service,
            FakeKubectl.key("nodes", namespaced=False): nodes,
            FakeKubectl.key("deployments,statefulsets,daemonsets"): workloads,
            FakeKubectl.key("pods"): {"items": [api_pod, queue_pod]},
            FakeKubectl.key("deployment", api_name): api_deployment,
            FakeKubectl.key("deployment", queue_name): queue_deployment,
            FakeKubectl.key("pods", selector=api_selector): {"items": [api_pod]},
            FakeKubectl.key("pods", selector=queue_selector): {"items": [queue_pod]},
            FakeKubectl.key("service", "agent-svc"): compatibility,
            FakeKubectl.key("endpoints", "agent-svc"): endpoints,
            FakeKubectl.key(
                "deployment",
                "splunk-ai-operator-controller-manager",
                namespace="splunk-ai-operator-system",
            ): operator,
            FakeKubectl.key(
                "pods",
                selector="app.kubernetes.io/name=splunk-ai-operator,control-plane=controller-manager",
                namespace="splunk-ai-operator-system",
            ): {"items": [operator_pod]},
            FakeKubectl.key(
                "deployment", "platform-slim-slim-deployment", namespace="ai-platform"
            ): slim,
            FakeKubectl.key(
                "pods",
                selector="app=platform-slim,component=platform-slim",
                namespace="ai-platform",
            ): {"items": [slim_pod]},
            FakeKubectl.key(
                "statefulset",
                "splunk-splunk-standalone-standalone",
                namespace="ai-platform",
            ): splunk,
            FakeKubectl.key(
                "pods",
                selector="app.kubernetes.io/instance=splunk-splunk-standalone-standalone",
                namespace="ai-platform",
            ): {"items": [splunk_pod]},
            FakeKubectl.key(
                "deployment",
                "splunk-operator-controller-manager",
                namespace="splunk-operator",
            ): splunk_operator,
            FakeKubectl.key(
                "pods",
                selector="control-plane=controller-manager",
                namespace="splunk-operator",
            ): {"items": [splunk_operator_pod]},
        }
        return FakeKubectl(responses, sequences), api_selector, queue_selector


class CPUAirgapRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.fixture = RuntimeFixture(pathlib.Path(self.temporary.name))

    def test_read_only_qualification_accepts_top_level_digest_and_writes_sanitized_evidence(
        self,
    ):
        kube, _, _ = self.fixture.kube()
        evidence = runtime.qualify(self.fixture.args(), kube=kube)
        self.assertEqual(evidence["result"], "RUNTIME_PASS")
        self.assertIn("not final MPR-129 acceptance", evidence["scope"])
        self.assertIsNone(evidence["replacement"])
        self.assertEqual(kube.deleted, [])
        self.assertTrue((self.fixture.output / "mpr-129-evidence.json").is_file())
        markdown = (self.fixture.output / "mpr-129-evidence.md").read_text()
        self.assertIn("CPU-only air-gap runtime sub-check", markdown)
        serialized = json.dumps(evidence).lower()
        self.assertNotIn("password", serialized)
        self.assertNotIn("connection_url", serialized)
        self.assertNotIn("10.0.0.0/16", serialized)
        self.assertNotIn("pl-123456", serialized)
        self.assertNotIn('"node": "worker"', serialized)
        self.assertNotIn(ECR_ACCOUNT, serialized)
        self.assertIn(
            "<redacted-account>.dkr.ecr.us-west-2.amazonaws.com/launchpad-agent:v1",
            serialized,
        )
        self.assertIn(SHA_A, serialized)
        self.assertEqual(evidence["bundle"]["inventoryRuntimeDigests"], [SHA_A])
        self.assertEqual(
            evidence["requiredSupportingComponents"]["operator"]["runtimeDigests"],
            [SHA_C],
        )
        self.assertEqual(
            evidence["requiredSupportingComponents"]["slim"]["runtimeDigests"],
            [SHA_D],
        )
        self.assertEqual(
            evidence["requiredSupportingComponents"]["splunk"]["runtimeDigests"],
            [SHA_E],
        )
        self.assertEqual(
            evidence["requiredSupportingComponents"]["splunkOperator"][
                "runtimeDigests"
            ],
            [SHA_F],
        )
        written_json = (self.fixture.output / "mpr-129-evidence.json").read_text()
        self.assertNotIn(ECR_ACCOUNT, written_json)
        self.assertNotIn(ECR_ACCOUNT, markdown)

    def test_supporting_inventory_digest_must_resolve_in_oci_archive(self):
        inventory_path = self.fixture.bundle / "image-inventory.json"
        inventory = json.loads(inventory_path.read_text())
        operator = next(
            item
            for item in inventory["images"]
            if item["reference"] == OPERATOR_IMAGE
        )
        mismatched_digest = "sha256:" + "9" * 64
        operator["digest"] = mismatched_digest
        operator["platforms"][0]["digest"] = mismatched_digest
        inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
        self.fixture.rebuild_bundle_artifacts()
        kube, _, _ = self.fixture.kube()
        with self.assertRaisesRegex(
            runtime.QualificationError,
            "offline operator runtime identity chain is invalid",
        ):
            runtime.qualify(self.fixture.args(), kube=kube)

    def test_legacy_multi_platform_inventory_qualifies_amd64_archive(self):
        inventory_path = self.fixture.bundle / "image-inventory.json"
        inventory = json.loads(inventory_path.read_text())
        for item in inventory["images"]:
            item["platforms"].append(
                {
                    "os": "linux",
                    "architecture": "arm64",
                    "variant": "v8",
                    "digest": "sha256:" + "8" * 64,
                }
            )
        inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
        self.fixture.rebuild_bundle_artifacts()
        kube, _, _ = self.fixture.kube()
        evidence = runtime.qualify(self.fixture.args(), kube=kube)
        self.assertEqual(evidence["result"], "RUNTIME_PASS")
        self.assertEqual(evidence["bundle"]["inventoryRuntimeDigests"], [SHA_A])

    def test_legacy_unbundled_node_platform_is_rejected(self):
        inventory_path = self.fixture.bundle / "image-inventory.json"
        inventory = json.loads(inventory_path.read_text())
        for item in inventory["images"]:
            item["platforms"].append(
                {
                    "os": "linux",
                    "architecture": "arm64",
                    "variant": "v8",
                    "digest": "sha256:" + "8" * 64,
                }
            )
        inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
        self.fixture.rebuild_bundle_artifacts()
        kube, _, _ = self.fixture.kube()
        worker = kube.responses[FakeKubectl.key("nodes", namespaced=False)]["items"][1]
        worker["metadata"]["labels"]["kubernetes.io/arch"] = "arm64"
        worker["status"]["nodeInfo"]["architecture"] = "arm64"
        with self.assertRaisesRegex(
            runtime.QualificationError,
            "node platforms differ from the qualified bundle target",
        ):
            runtime.qualify(self.fixture.args(), kube=kube)

    def test_platform_specific_digest_is_accepted_for_multi_arch_inventory(self):
        second = pathlib.Path(self.temporary.name) / "platform-digest"
        fixture = RuntimeFixture(second, pod_digest=SHA_B, platform_digest=SHA_B)
        kube, _, _ = fixture.kube()
        evidence = runtime.qualify(fixture.args(), kube=kube)
        self.assertEqual(evidence["las"]["api"]["pods"][0]["digest"], SHA_B)

    def test_unapproved_runtime_digest_fails_closed(self):
        second = pathlib.Path(self.temporary.name) / "bad-digest"
        fixture = RuntimeFixture(second, pod_digest="sha256:" + "c" * 64)
        kube, _, _ = fixture.kube()
        with self.assertRaisesRegex(runtime.QualificationError, "not approved"):
            runtime.qualify(fixture.args(), kube=kube)

    def test_mixed_approved_and_unapproved_las_pods_fail_closed(self):
        kube, api_selector, _ = self.fixture.kube()
        release = runtime.las_release_name("agent")
        bad = pod(
            "api-bad",
            "api-bad-uid",
            release + "-langgraph-cloud-api-server",
            "api-server",
            SHA_E,
        )
        kube.responses[FakeKubectl.key("pods", selector=api_selector)]["items"].append(
            bad
        )
        with self.assertRaisesRegex(runtime.QualificationError, "invalid LAS"):
            runtime.qualify(self.fixture.args(), kube=kube)

    def test_orphan_las_pod_is_rejected_before_evidence_or_deletion(self):
        kube, _, queue_selector = self.fixture.kube()
        queue_pod = kube.responses[FakeKubectl.key("pods", selector=queue_selector)][
            "items"
        ][0]
        queue_pod["metadata"]["ownerReferences"] = []
        with self.assertRaisesRegex(
            runtime.QualificationError, "controller ownerReference"
        ):
            runtime.qualify(
                self.fixture.args(replace="queue", confirmed=True), kube=kube
            )
        self.assertEqual(kube.deleted, [])
        self.assertFalse((self.fixture.output / "mpr-129-evidence.json").exists())

    def test_replacement_requires_separate_disposable_cluster_confirmation(self):
        kube, _, _ = self.fixture.kube()
        with self.assertRaisesRegex(runtime.QualificationError, "confirm-disposable"):
            runtime.qualify(
                self.fixture.args(replace="queue", confirmed=False), kube=kube
            )
        self.assertEqual(kube.deleted, [])

    def test_replacement_requires_new_ready_uid_and_same_digest(self):
        kube, _, queue_selector = self.fixture.kube()
        release = runtime.las_release_name("agent")
        new_pod = pod(
            "queue-2", "queue-new", release + "-langgraph-cloud-queue", "queue", SHA_A
        )
        initial = kube.responses[FakeKubectl.key("pods", selector=queue_selector)]
        kube.sequences[FakeKubectl.key("pods", selector=queue_selector)] = [
            initial,
            {"items": [new_pod]},
        ]
        evidence = runtime.qualify(
            self.fixture.args(replace="queue", confirmed=True),
            kube=kube,
            sleeper=lambda _: None,
            clock=IncrementingClock(),
        )
        self.assertEqual(kube.deleted, ["queue-1"])
        self.assertEqual(evidence["replacement"]["before"]["uid"], "queue-old")
        self.assertEqual(evidence["replacement"]["after"]["uid"], "queue-new")
        self.assertEqual(evidence["replacement"]["after"]["digest"], SHA_A)

    def test_replacement_digest_change_is_rejected(self):
        kube, _, queue_selector = self.fixture.kube()
        release = runtime.las_release_name("agent")
        entry = runtime.inventory_entry(
            json.loads((self.fixture.bundle / "image-inventory.json").read_text()),
            IMAGE,
        )
        entry["platforms"].append(
            {"os": "linux", "architecture": "amd64", "digest": SHA_B}
        )
        new_pod = pod(
            "queue-2", "queue-new", release + "-langgraph-cloud-queue", "queue", SHA_B
        )
        kube.sequences[FakeKubectl.key("pods", selector=queue_selector)] = [
            {"items": [new_pod]}
        ]
        with self.assertRaisesRegex(runtime.QualificationError, "changed"):
            runtime.wait_for_replacement(
                kube,
                queue_selector,
                "queue",
                IMAGE,
                {"worker": "linux/amd64"},
                entry,
                {"queue-old"},
                SHA_A,
                release + "-langgraph-cloud-queue",
                5,
                0.01,
                sleeper=lambda _: None,
                clock=IncrementingClock(),
            )

    def test_replacement_old_uid_or_unready_pod_times_out(self):
        kube, _, queue_selector = self.fixture.kube()
        release = runtime.las_release_name("agent")
        old = pod(
            "queue-1", "queue-old", release + "-langgraph-cloud-queue", "queue", SHA_A
        )
        unready = pod(
            "queue-2",
            "queue-new",
            release + "-langgraph-cloud-queue",
            "queue",
            SHA_A,
            ready=False,
        )
        kube.sequences[FakeKubectl.key("pods", selector=queue_selector)] = [
            {"items": [old, unready]}
        ]
        entry = runtime.inventory_entry(
            json.loads((self.fixture.bundle / "image-inventory.json").read_text()),
            IMAGE,
        )
        with self.assertRaisesRegex(runtime.QualificationError, "did not become Ready"):
            runtime.wait_for_replacement(
                kube,
                queue_selector,
                "queue",
                IMAGE,
                {"worker": "linux/amd64"},
                entry,
                {"queue-old"},
                SHA_A,
                release + "-langgraph-cloud-queue",
                3,
                0.01,
                sleeper=lambda _: None,
                clock=IncrementingClock(),
            )

    def test_gpu_node_and_forbidden_workloads_are_rejected(self):
        kube, _, _ = self.fixture.kube()
        nodes = kube.responses[FakeKubectl.key("nodes", namespaced=False)]
        nodes["items"][1]["status"]["allocatable"]["nvidia.com/gpu"] = "1"
        with self.assertRaisesRegex(runtime.QualificationError, "GPU capacity"):
            runtime.validate_nodes(nodes)
        bad = deployment("kuberay-operator", "registry.internal/kuberay:v1")
        with self.assertRaisesRegex(runtime.QualificationError, "forbidden"):
            runtime.reject_forbidden_workloads({"items": [bad]}, {"items": []})
        bad_pod = pod(
            "model-staging-1",
            "bad",
            "model-staging",
            "worker",
            SHA_A,
            image="registry.internal/model-staging:v1",
        )
        with self.assertRaisesRegex(runtime.QualificationError, "forbidden"):
            runtime.reject_forbidden_workloads({"items": []}, {"items": [bad_pod]})

    def test_stale_aiservice_generation_is_rejected(self):
        kube, _, _ = self.fixture.kube()
        service = kube.responses[FakeKubectl.key("aiservice", "agent")]
        service["metadata"]["generation"] = 2
        with self.assertRaisesRegex(runtime.QualificationError, "current generation"):
            runtime.qualify(self.fixture.args(), kube=kube)

    def test_live_platform_and_slim_ready_shape_without_condition_generation(self):
        kube, _, _ = self.fixture.kube()
        platform = kube.responses[FakeKubectl.key("aiplatform", "platform")]
        slim = kube.responses[FakeKubectl.key("aiservice", "platform-slim")]
        del platform["status"]["conditions"][0]["observedGeneration"]
        del slim["status"]["conditions"][0]["observedGeneration"]

        evidence = runtime.qualify(self.fixture.args(), kube=kube)

        self.assertEqual(evidence["aiplatform"]["observedGeneration"], 1)
        self.assertEqual(evidence["slimAIService"]["observedGeneration"], 1)

    def test_agentruntime_ready_condition_requires_generation(self):
        kube, _, _ = self.fixture.kube()
        service = kube.responses[FakeKubectl.key("aiservice", "agent")]
        del service["status"]["conditions"][0]["observedGeneration"]

        with self.assertRaisesRegex(
            runtime.QualificationError, "Ready condition has no observed generation"
        ):
            runtime.qualify(self.fixture.args(), kube=kube)

    def test_present_ready_condition_generation_must_be_current_integer(self):
        resource = {
            "metadata": {"name": "platform", "generation": 2},
            "status": {
                "observedGeneration": 2,
                "conditions": [
                    {
                        "type": "Ready",
                        "status": "True",
                        "reason": "AllReconciled",
                        "observedGeneration": 2,
                    }
                ],
            },
        }
        for value in (1, None, "2", True):
            with self.subTest(value=value):
                resource["status"]["conditions"][0]["observedGeneration"] = value
                with self.assertRaisesRegex(
                    runtime.QualificationError, "stale or malformed"
                ):
                    runtime.require_ready_condition(resource, "AIPlatform")

    def test_runtime_digest_is_allowed_without_platform_manifest_digest(self):
        entry = {
            "digest": SHA_TOP,
            "platforms": [
                {
                    "os": "linux",
                    "architecture": "amd64",
                    "runtimeDigest": SHA_A,
                }
            ],
        }
        self.assertIn(
            SHA_A, runtime.allowed_inventory_digests(entry, "linux/amd64")
        )

    def test_multiple_variants_for_one_node_platform_fail_closed(self):
        entry = {
            "digest": SHA_TOP,
            "platforms": [
                {
                    "os": "linux",
                    "architecture": "arm64",
                    "variant": "v8",
                    "digest": SHA_A,
                },
                {
                    "os": "linux",
                    "architecture": "arm64",
                    "variant": "v9",
                    "digest": SHA_B,
                },
            ],
        }
        with self.assertRaisesRegex(runtime.QualificationError, "ambiguous identities"):
            runtime.allowed_inventory_digests(entry, "linux/arm64")

    def test_missing_platform_identity_fails_closed(self):
        entry = {
            "digest": SHA_TOP,
            "platforms": [
                {
                    "os": "linux",
                    "architecture": "amd64",
                    "digest": SHA_B,
                    "runtimeDigest": SHA_A,
                }
            ],
        }
        with self.assertRaisesRegex(runtime.QualificationError, "no identity"):
            runtime.allowed_inventory_digests(entry, "linux/arm64")

    def test_same_variant_with_conflicting_digests_fails_closed(self):
        entry = {
            "digest": SHA_TOP,
            "platforms": [
                {
                    "os": "linux",
                    "architecture": "arm64",
                    "variant": "v8",
                    "digest": SHA_A,
                    "runtimeDigest": SHA_C,
                },
                {
                    "os": "linux",
                    "architecture": "arm64",
                    "variant": "v8",
                    "digest": SHA_B,
                    "runtimeDigest": SHA_D,
                },
            ],
        }
        with self.assertRaisesRegex(runtime.QualificationError, "ambiguous identities"):
            runtime.allowed_inventory_digests(entry, "linux/arm64")

    def test_unready_las_deployment_is_rejected(self):
        kube, _, _ = self.fixture.kube()
        release = runtime.las_release_name("agent")
        api_name = release + "-langgraph-cloud-api-server"
        kube.responses[FakeKubectl.key("deployment", api_name)]["status"][
            "readyReplicas"
        ] = 0
        with self.assertRaisesRegex(runtime.QualificationError, "not fully Ready"):
            runtime.qualify(self.fixture.args(), kube=kube)

    def test_network_evidence_rejects_public_and_default_routes(self):
        evidence = json.loads(self.fixture.network.read_text())
        evidence["routes"].append(
            {"destination": "0.0.0.0/0", "targetType": "other-private", "public": False}
        )
        with self.assertRaisesRegex(
            runtime.QualificationError, "default public egress"
        ):
            runtime.validate_network_evidence(evidence)

    def test_network_evidence_requires_fresh_zoned_connectivity_capture(self):
        evidence = json.loads(self.fixture.network.read_text())
        evidence["capturedAt"] = "2026-10-29T10:00:00"
        with self.assertRaisesRegex(runtime.QualificationError, "timezone"):
            runtime.validate_network_evidence(evidence)

        evidence = json.loads(self.fixture.network.read_text())
        evidence["capturedAt"] = "2026-10-29T10:00:00+00:00"
        with self.assertRaisesRegex(runtime.QualificationError, "stale"):
            runtime.validate_network_evidence(
                evidence,
                max_age_seconds=60,
                now=dt.datetime(2026, 10, 29, 11, 0, tzinfo=dt.timezone.utc),
            )

        evidence = json.loads(self.fixture.network.read_text())
        evidence["privateDependencyReachability"]["postgres"] = False
        with self.assertRaisesRegex(runtime.QualificationError, "private dependency"):
            runtime.validate_network_evidence(evidence)

        evidence = json.loads(self.fixture.network.read_text())
        evidence["source"] = "vpc-1234abcd"
        with self.assertRaisesRegex(runtime.QualificationError, "capture ID"):
            runtime.validate_network_evidence(evidence)
        evidence = json.loads(self.fixture.network.read_text())
        evidence["natGatewayDefaultRoute"] = True
        with self.assertRaisesRegex(
            runtime.QualificationError, "Internet or NAT default route"
        ):
            runtime.validate_network_evidence(evidence)

    def test_bundle_checksum_and_missing_archive_fail(self):
        (self.fixture.bundle / "charts/las.tgz").write_bytes(b"tampered")
        with self.assertRaisesRegex(runtime.QualificationError, "checksum mismatch"):
            runtime.validate_bundle(self.fixture.bundle, SOURCE_COMMIT)
        second = pathlib.Path(self.temporary.name) / "missing"
        fixture = RuntimeFixture(second)
        (fixture.bundle / "images/workload-images.tar").unlink()
        with self.assertRaisesRegex(runtime.QualificationError, "missing"):
            runtime.validate_bundle(fixture.bundle, SOURCE_COMMIT)

    def test_bundle_rejects_checksum_gaps_and_symlinks(self):
        manifest = self.fixture.bundle / "checksums.sha256"
        lines = [
            line
            for line in manifest.read_text().splitlines()
            if not line.endswith("  image-inventory.json")
        ]
        manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(runtime.QualificationError, "does not cover"):
            runtime.validate_bundle(self.fixture.bundle, SOURCE_COMMIT)
        second = pathlib.Path(self.temporary.name) / "symlink"
        fixture = RuntimeFixture(second)
        target = fixture.bundle / "images/workload-images.tar"
        replacement = fixture.bundle / "images/archive-real.tar"
        target.rename(replacement)
        target.symlink_to(replacement.name)
        with self.assertRaisesRegex(runtime.QualificationError, "symbolic link"):
            runtime.validate_bundle(fixture.bundle, SOURCE_COMMIT)

    def test_bundle_requires_chart_source_commit_and_approved_tarball(self):
        inventory_path = self.fixture.bundle / "image-inventory.json"
        old_digest = runtime.sha256_file(inventory_path)
        inventory = json.loads(inventory_path.read_text())
        inventory.pop("embeddedDistribution")
        inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
        manifest = self.fixture.bundle / "checksums.sha256"
        manifest.write_text(
            manifest.read_text().replace(
                old_digest + "  image-inventory.json",
                runtime.sha256_file(inventory_path) + "  image-inventory.json",
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(runtime.QualificationError, "embedded LAS chart"):
            runtime.validate_bundle(self.fixture.bundle, SOURCE_COMMIT)

        second = pathlib.Path(self.temporary.name) / "source-mismatch"
        fixture = RuntimeFixture(second)
        with self.assertRaisesRegex(runtime.QualificationError, "approved commit"):
            runtime.validate_bundle(fixture.bundle, "2" * 40)

        malformed_root = pathlib.Path(self.temporary.name) / "malformed-inventory"
        malformed = RuntimeFixture(malformed_root)
        inventory_path = malformed.bundle / "image-inventory.json"
        old_digest = runtime.sha256_file(inventory_path)
        inventory = json.loads(inventory_path.read_text())
        inventory["embeddedDistribution"] = "not-an-object"
        inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
        manifest = malformed.bundle / "checksums.sha256"
        manifest.write_text(
            manifest.read_text().replace(
                old_digest + "  image-inventory.json",
                runtime.sha256_file(inventory_path) + "  image-inventory.json",
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(runtime.QualificationError, "embedded LAS chart"):
            runtime.validate_bundle(malformed.bundle, SOURCE_COMMIT)

        kube, _, _ = fixture.kube()
        args = fixture.args()
        args.expected_bundle_sha256 = "0" * 64
        with self.assertRaisesRegex(runtime.QualificationError, "approved value"):
            runtime.qualify(args, kube=kube)
        self.assertEqual(kube.deleted, [])

    def test_chart_labels_service_owner_and_supporting_image_are_enforced(self):
        kube, _, _ = self.fixture.kube()
        release = runtime.las_release_name("agent")
        api_name = release + "-langgraph-cloud-api-server"
        kube.responses[FakeKubectl.key("deployment", api_name)]["metadata"]["labels"][
            "helm.sh/chart"
        ] = "wrong-chart"
        with self.assertRaisesRegex(
            runtime.QualificationError, "embedded chart labels"
        ):
            runtime.qualify(self.fixture.args(), kube=kube)

        second = pathlib.Path(self.temporary.name) / "bad-owner"
        fixture = RuntimeFixture(second)
        kube, _, _ = fixture.kube()
        kube.responses[FakeKubectl.key("service", "agent-svc")]["metadata"][
            "ownerReferences"
        ] = []
        with self.assertRaisesRegex(runtime.QualificationError, "not controlled"):
            runtime.qualify(fixture.args(), kube=kube)

        third = pathlib.Path(self.temporary.name) / "bad-support"
        fixture = RuntimeFixture(third)
        kube, _, _ = fixture.kube()
        operator = kube.responses[
            FakeKubectl.key(
                "deployment",
                "splunk-ai-operator-controller-manager",
                namespace="splunk-ai-operator-system",
            )
        ]
        operator["spec"]["template"]["spec"]["containers"][0]["image"] = IMAGE
        with self.assertRaisesRegex(runtime.QualificationError, "configured image"):
            runtime.qualify(fixture.args(), kube=kube)

    def test_evidence_redaction_rejects_credential_keys_and_values(self):
        with self.assertRaisesRegex(
            runtime.QualificationError, "credential-shaped.*field"
        ):
            runtime.ensure_sanitized({"api_key": "canary"})
        with self.assertRaisesRegex(
            runtime.QualificationError, "credential-shaped.*value"
        ):
            runtime.ensure_sanitized({"value": "https://user:pass@example.test"})

    def test_evidence_redacts_private_registry_addresses(self):
        evidence = {
            "image": "10.0.0.5:5000/team/launchpad:v1",
            "imageID": (
                "docker-pullable://registry.internal/team/launchpad@sha256:"
                + "a" * 64
            ),
            "public": "docker.io/library/postgres:16",
            "ecr": "658391232643.dkr.ecr.us-west-2.amazonaws.com/team/image:v1",
        }
        redacted = runtime.redact_ecr_account_ids(evidence)
        redacted = runtime.redact_private_registry_addresses(redacted)

        self.assertEqual(
            redacted["image"], "<redacted-registry>/team/launchpad:v1"
        )
        self.assertEqual(
            redacted["imageID"],
            "docker-pullable://<redacted-registry>/team/launchpad@sha256:"
            + "a" * 64,
        )
        self.assertEqual(redacted["public"], "docker.io/library/postgres:16")
        self.assertEqual(
            redacted["ecr"],
            "<redacted-account>.dkr.ecr.us-west-2.amazonaws.com/team/image:v1",
        )
        runtime.ensure_sanitized(redacted)
        with self.assertRaisesRegex(
            runtime.QualificationError, "private registry address"
        ):
            runtime.ensure_sanitized(
                {"image": "docker-pullable://10.0.0.5:5000/team/image:v1"}
            )

    def test_existing_evidence_prevents_replacement_before_pod_deletion(self):
        self.fixture.output.mkdir()
        existing = self.fixture.output / "mpr-129-evidence.md"
        existing.write_text("keep me", encoding="utf-8")
        kube, _, _ = self.fixture.kube()
        with self.assertRaisesRegex(runtime.QualificationError, "overwrite"):
            runtime.qualify(
                self.fixture.args(replace="queue", confirmed=True), kube=kube
            )
        self.assertEqual(existing.read_text(encoding="utf-8"), "keep me")
        self.assertFalse((self.fixture.output / "mpr-129-evidence.json").exists())
        self.assertEqual(kube.deleted, [])

    def test_service_name_matches_long_name_contract(self):
        name = "a" * 70
        self.assertEqual(
            runtime.agentruntime_service_name(name),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-562feef4-svc",
        )
        self.assertEqual(
            runtime.las_release_name(name), "las-aaaaaaaaaaaaaaaaaaaaa-6bd5e503"
        )


if __name__ == "__main__":
    unittest.main()
