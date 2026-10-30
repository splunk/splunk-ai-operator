#!/usr/bin/env python3
"""Qualify a CPU-only air-gapped LAS install and emit sanitized evidence.

The default execution path is read-only.  Replacing a LAS Pod requires both an
explicit component and an explicit disposable-cluster confirmation.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import ipaddress
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Any, Callable


DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")
HEX_SHA256_RE = re.compile(r"[0-9a-f]{64}")
SOURCE_COMMIT_RE = re.compile(r"[0-9a-f]{40}")
CAPTURE_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
PRIVATE_IDENTIFIER_RE = re.compile(
    r"(?:^|[-_.])(vpc|subnet|sg|eni|vpce|pl)-[0-9a-f]+(?:$|[-_.])|"
    r"arn:aws|(?<![0-9])[0-9]{12}(?![0-9])",
    re.IGNORECASE,
)
ECR_ACCOUNT_RE = re.compile(
    r"(?<![0-9])[0-9]{12}(?=\.dkr\.ecr(?:-fips)?\.[^/\s]+)", re.IGNORECASE
)
PRIVATE_REGISTRY_RE = re.compile(
    r"(?P<prefix>(?:docker-pullable|docker)://)?"
    r"(?P<host>(?:[0-9]{1,3}\.){3}[0-9]{1,3}|\[[0-9a-f:]+\]|localhost|"
    r"[a-z0-9.-]+\.(?:internal|local))(?::[0-9]+)?/",
    re.IGNORECASE,
)
CHECKSUM_LINE_RE = re.compile(r"^([0-9a-f]{64})[ \t]+[*]?(.+)$")
SENSITIVE_KEY_RE = re.compile(
    r"(password|passwd|secret(access)?key|accesskeyid|api[_-]?key|token|licensekey|"
    r"postgres(uri|url)|redis(uri|url)|connection[_-]?(string|url))",
    re.IGNORECASE,
)
SENSITIVE_VALUE_RES = (
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@", re.IGNORECASE),
)
FORBIDDEN_WORKLOAD_RES = (
    re.compile(r"(^|[-./_])nvidia($|[-./_])", re.IGNORECASE),
    re.compile(r"(^|[-./_])gpu($|[-./_])", re.IGNORECASE),
    re.compile(r"kuberay", re.IGNORECASE),
    re.compile(r"(^|[-./_])ray($|[-./_])", re.IGNORECASE),
    re.compile(r"ray-(head|worker)", re.IGNORECASE),
    re.compile(r"model[-_]?staging", re.IGNORECASE),
)
DEFAULT_TIMEOUT_SECONDS = 300
DEFAULT_POLL_SECONDS = 5.0
DEFAULT_NETWORK_MAX_AGE_SECONDS = 3600
NETWORK_CLOCK_SKEW_SECONDS = 300
RUNTIME_SCOPE = (
    "Runtime sub-check only. This is not final MPR-129 acceptance; fresh-install, "
    "invalid-artifact, cleanup, and reviewer evidence remain separate gates."
)


class QualificationError(RuntimeError):
    """A fail-closed qualification error with no sensitive command output."""


def _dict(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise QualificationError(f"{context} must be an object")
    return value


def _list(value: Any, context: str) -> list[Any]:
    if not isinstance(value, list):
        raise QualificationError(f"{context} must be a list")
    return value


def safe_path(root: Path, relative: str) -> Path:
    candidate = Path(relative)
    if not relative or candidate.is_absolute() or ".." in candidate.parts:
        raise QualificationError("checksum manifest contains an unsafe path")
    resolved_root = root.resolve()
    unresolved = resolved_root / candidate
    current = resolved_root
    for part in candidate.parts:
        current /= part
        if current.is_symlink():
            raise QualificationError("checksum manifest references a symbolic link")
    resolved = unresolved.resolve()
    if resolved_root not in resolved.parents:
        raise QualificationError("checksum manifest contains an unsafe path")
    return resolved


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_checksum_manifest(bundle_dir: Path) -> dict[str, Any]:
    manifest = bundle_dir / "checksums.sha256"
    if not manifest.is_file() or manifest.is_symlink():
        raise QualificationError("bundle checksums.sha256 is missing or unsafe")
    entries: list[dict[str, str]] = []
    seen: set[str] = set()
    for line_number, raw in enumerate(
        manifest.read_text(encoding="utf-8").splitlines(), 1
    ):
        if not raw.strip():
            continue
        match = CHECKSUM_LINE_RE.fullmatch(raw)
        if not match:
            raise QualificationError(f"invalid checksum manifest line {line_number}")
        expected, relative = match.groups()
        if relative in seen:
            raise QualificationError(f"duplicate checksum manifest path: {relative}")
        seen.add(relative)
        artifact = safe_path(bundle_dir, relative)
        if not artifact.is_file() or artifact.is_symlink():
            raise QualificationError(
                f"checksummed artifact is missing or unsafe: {relative}"
            )
        actual = sha256_file(artifact)
        if actual != expected:
            raise QualificationError(
                f"checksum mismatch for staged artifact: {relative}"
            )
        entries.append({"path": relative, "sha256": actual})
    if not entries:
        raise QualificationError("checksum manifest is empty")
    return {
        "manifestSha256": sha256_file(manifest),
        "artifactCount": len(entries),
        "artifacts": entries,
    }


def _load_inventory_module() -> Any:
    path = Path(__file__).with_name("build_airgap_image_inventory.py")
    spec = importlib.util.spec_from_file_location("mpr129_airgap_inventory", path)
    if spec is None or spec.loader is None:
        raise QualificationError("cannot load the offline image inventory validator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _embedded_chart_metadata(chart_path: Path) -> dict[str, str]:
    try:
        with tarfile.open(chart_path, "r:gz") as archive:
            chart_files = [
                member
                for member in archive.getmembers()
                if member.isfile() and Path(member.name).name == "Chart.yaml"
            ]
            if len(chart_files) != 1:
                raise QualificationError(
                    "embedded LAS chart must contain exactly one Chart.yaml"
                )
            stream = archive.extractfile(chart_files[0])
            if stream is None:
                raise QualificationError("embedded LAS Chart.yaml is unreadable")
            raw = stream.read().decode("utf-8")
    except (OSError, tarfile.TarError, UnicodeDecodeError):
        raise QualificationError("embedded LAS chart archive is invalid") from None

    values: dict[str, str] = {}
    for key in ("name", "version"):
        match = re.search(rf"^{key}:[ \t]*([^#\r\n]+?)[ \t]*$", raw, re.MULTILINE)
        if not match:
            raise QualificationError(f"embedded LAS chart is missing {key}")
        values[key] = match.group(1).strip().strip("\"'")
        if not values[key] or any(char.isspace() for char in values[key]):
            raise QualificationError(f"embedded LAS chart has an invalid {key}")
    values["label"] = f"{values['name']}-{values['version']}".replace("+", "_")[
        :63
    ].rstrip("-")
    return values


def validate_bundle(
    bundle_dir: Path, expected_source_commit: str
) -> tuple[dict[str, Any], dict[str, Any]]:
    if not bundle_dir.is_dir():
        raise QualificationError(f"bundle directory does not exist: {bundle_dir}")
    if not SOURCE_COMMIT_RE.fullmatch(expected_source_commit):
        raise QualificationError(
            "expected source commit must be 40 lowercase hex characters"
        )
    checksum = verify_checksum_manifest(bundle_dir)
    profile = bundle_dir / "bundle-profile.txt"
    if (
        not profile.is_file()
        or profile.is_symlink()
        or profile.read_text(encoding="utf-8").strip() != "cpuOnly"
    ):
        raise QualificationError("bundle profile is not cpuOnly")
    inventory_path = bundle_dir / "image-inventory.json"
    if not inventory_path.is_file() or inventory_path.is_symlink():
        raise QualificationError("bundle image-inventory.json is missing")
    try:
        inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
        inventory = _dict(inventory, "offline image inventory")
        distribution = inventory.get("embeddedDistribution")
        if not isinstance(distribution, dict):
            raise QualificationError(
                "image inventory must contain an embedded LAS chart distribution"
            )
        if set(distribution) != {"path", "sha256"}:
            raise QualificationError(
                "embedded LAS chart distribution must contain only path and sha256"
            )
        if (
            not isinstance(distribution.get("path"), str)
            or not distribution["path"]
            or not isinstance(distribution.get("sha256"), str)
            or not HEX_SHA256_RE.fullmatch(distribution["sha256"])
        ):
            raise QualificationError("embedded LAS chart distribution is malformed")
        _load_inventory_module().validate(
            argparse.Namespace(inventory=inventory_path, bundle_dir=bundle_dir)
        )
    except QualificationError:
        raise
    except (
        OSError,
        ValueError,
        TypeError,
        KeyError,
        AttributeError,
        json.JSONDecodeError,
    ) as exc:
        raise QualificationError(f"offline image inventory is invalid: {exc}") from None
    if inventory.get("profile") != "cpuOnly":
        raise QualificationError("image inventory profile is not cpuOnly")
    covered = {item["path"] for item in checksum["artifacts"]}
    source_commit_path = bundle_dir / "source-commit.txt"
    if not source_commit_path.is_file() or source_commit_path.is_symlink():
        raise QualificationError("bundle source-commit.txt is missing or unsafe")
    source_commit = source_commit_path.read_text(encoding="utf-8").strip()
    if not SOURCE_COMMIT_RE.fullmatch(source_commit):
        raise QualificationError("bundle source-commit.txt is not a 40-hex commit")
    if source_commit != expected_source_commit:
        raise QualificationError(
            "bundle source commit differs from the explicitly approved commit"
        )

    required = {"bundle-profile.txt", "image-inventory.json", "source-commit.txt"}
    for item in inventory.get("imageImports", []):
        if isinstance(item, dict):
            required.update(
                value for value in (item.get("archive"), item.get("imageList")) if value
            )
    distribution = inventory["embeddedDistribution"]
    required.add(distribution["path"])
    missing_coverage = sorted(required - covered)
    if missing_coverage:
        raise QualificationError(
            "checksum manifest does not cover required bundle artifacts: "
            + ", ".join(missing_coverage)
        )
    checksum["bundleContentSetSha256"] = hashlib.sha256(
        json.dumps(
            checksum["artifacts"], sort_keys=True, separators=(",", ":")
        ).encode()
    ).hexdigest()
    chart_path = safe_path(bundle_dir, distribution["path"])
    if sha256_file(chart_path) != distribution["sha256"]:
        raise QualificationError(
            "embedded LAS chart digest does not match the image inventory"
        )
    chart = _embedded_chart_metadata(chart_path)
    checksum.update(
        {
            "sourceCommit": source_commit,
            "embeddedChartName": chart["name"],
            "embeddedChartVersion": chart["version"],
            "embeddedChartLabel": chart["label"],
        }
    )
    return inventory, checksum


def validate_bundle_tarball(
    tarball: Path, expected_sha256: str, manifest_sha256: str
) -> str:
    if not HEX_SHA256_RE.fullmatch(expected_sha256):
        raise QualificationError(
            "expected bundle SHA-256 must be 64 lowercase hex characters"
        )
    if not tarball.is_file() or tarball.is_symlink():
        raise QualificationError("bundle tarball is missing or unsafe")
    actual = sha256_file(tarball)
    if actual != expected_sha256:
        raise QualificationError(
            "bundle tarball SHA-256 does not match the approved value"
        )
    try:
        with tarfile.open(tarball, "r:*") as archive:
            manifests = [
                member
                for member in archive.getmembers()
                if member.isfile() and Path(member.name).name == "checksums.sha256"
            ]
            if len(manifests) != 1:
                raise QualificationError(
                    "bundle tarball must contain exactly one checksums.sha256"
                )
            stream = archive.extractfile(manifests[0])
            if stream is None:
                raise QualificationError(
                    "bundle tarball checksum manifest is unreadable"
                )
            archived_manifest_sha = hashlib.sha256(stream.read()).hexdigest()
    except QualificationError:
        raise
    except (OSError, tarfile.TarError):
        raise QualificationError("bundle tarball is not a readable archive") from None
    if archived_manifest_sha != manifest_sha256:
        raise QualificationError(
            "extracted bundle checksum manifest differs from the approved tarball"
        )
    return actual


def load_structured_file(path: Path, description: str) -> dict[str, Any]:
    if not path.is_file():
        raise QualificationError(f"{description} does not exist: {path}")
    raw = path.read_text(encoding="utf-8")
    try:
        return _dict(json.loads(raw), description)
    except json.JSONDecodeError:
        try:
            completed = subprocess.run(
                ["yq", "eval", "-o=json", ".", str(path)],
                check=True,
                capture_output=True,
                text=True,
            )
            return _dict(json.loads(completed.stdout), description)
        except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
            raise QualificationError(
                f"cannot parse {description}; install yq or provide JSON"
            ) from None


def nested(data: dict[str, Any], *path: str, default: Any = None) -> Any:
    current: Any = data
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def configured_image(config: dict[str, Any], *path: str) -> str:
    raw = nested(config, *path)
    if not isinstance(raw, str) or not raw or raw == "null":
        raise QualificationError(
            f"deployment config is missing configured image {'.'.join(path)}"
        )
    registry = nested(config, "images", "registry", default="")
    if registry in (None, "null"):
        registry = ""
    if not isinstance(registry, str):
        raise QualificationError("deployment config images.registry must be a string")
    first, separator, _ = raw.partition("/")
    fully_qualified = bool(
        separator
        and (
            "." in first
            or ":" in first
            or first == "localhost"
            or re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", first)
        )
    )
    return raw if fully_qualified or not registry else f"{registry.rstrip('/')}/{raw}"


def configured_supporting_images(config: dict[str, Any]) -> dict[str, str]:
    required_flags = {
        "components.aiOperator": nested(config, "components", "aiOperator") is True,
        "components.splunkStandalone": nested(config, "components", "splunkStandalone")
        is True,
        "components.splunkOperator": nested(config, "components", "splunkOperator")
        is True,
        "splunk.enabled": nested(config, "splunk", "enabled") is True,
    }
    failed = [name for name, enabled in required_flags.items() if not enabled]
    if failed:
        raise QualificationError(
            "CPU-only qualification requires selected supporting components: "
            + ", ".join(failed)
        )
    return {
        "operator": configured_image(config, "images", "operator", "image"),
        "slim": configured_image(config, "images", "slim", "apiImage"),
        "splunk": configured_image(config, "images", "splunk", "image"),
        "splunkOperator": configured_image(config, "images", "splunk", "operatorImage"),
    }


def validate_deployment_config(config: dict[str, Any]) -> str:
    checks = {
        "cluster.airgap": nested(config, "cluster", "airgap") is True,
        "aiPlatform.profile": nested(config, "aiPlatform", "profile") == "cpuOnly",
        "nodes.gpuWorkers": nested(config, "nodes", "gpuWorkers") == 0,
        "storage.modelStaging.enabled": nested(
            config, "storage", "modelStaging", "enabled"
        )
        is False,
        "components.kuberay": nested(config, "components", "kuberay") is False,
        "components.nvidia": nested(config, "components", "nvidia") is False,
    }
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise QualificationError(
            "deployment config is not CPU-only air-gapped: " + ", ".join(failed)
        )
    features = _list(nested(config, "aiPlatform", "features"), "aiPlatform.features")
    names = sorted(
        str(item.get("name", "")) for item in features if isinstance(item, dict)
    )
    if names != ["agentruntime", "slim"]:
        raise QualificationError(
            "deployment config must select exactly agentruntime and slim"
        )
    agent = next(item for item in features if item.get("name") == "agentruntime")
    las = _dict(agent.get("las"), "agentruntime.las")
    image = _dict(las.get("image"), "agentruntime.las.image")
    repository, tag = image.get("repository"), image.get("tag")
    if (
        not isinstance(repository, str)
        or not repository
        or not isinstance(tag, str)
        or not tag
    ):
        raise QualificationError("deployment config is missing the LAS image reference")
    if tag in {"latest", "preview"}:
        raise QualificationError("deployment config uses a mutable LAS image tag")
    if nested(las, "tracing", "enabled", default=False) is not False:
        raise QualificationError(
            "CPU-only air-gapped qualification requires LAS tracing disabled"
        )
    if las.get("networkMode") not in (None, "airgapped"):
        raise QualificationError("deployment config LAS networkMode is not airgapped")
    return f"{repository}:{tag}"


def _bounded_destination(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        raise QualificationError(f"{context} destination is invalid")
    if value in {"0.0.0.0/0", "::/0"}:
        raise QualificationError(f"{context} permits default public egress")
    if value.startswith("pl-"):
        return value
    try:
        network = ipaddress.ip_network(value, strict=False)
    except ValueError:
        raise QualificationError(
            f"{context} destination is not a CIDR or prefix list"
        ) from None
    if not network.is_private:
        raise QualificationError(f"{context} destination is not private")
    return value


def validate_network_evidence(
    evidence: dict[str, Any],
    *,
    max_age_seconds: int = DEFAULT_NETWORK_MAX_AGE_SECONDS,
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    required = {
        "schemaVersion",
        "capturedAt",
        "source",
        "instances",
        "routes",
        "securityGroupEgress",
        "internetGatewayDefaultRoute",
        "natGatewayDefaultRoute",
        "privateDependencyReachability",
        "publicTcpReachable",
    }
    if set(evidence) != required:
        missing, extra = sorted(required - set(evidence)), sorted(
            set(evidence) - required
        )
        raise QualificationError(
            f"network evidence schema mismatch (missing={missing}, extra={extra})"
        )
    if evidence["schemaVersion"] != 1:
        raise QualificationError("unsupported network evidence schemaVersion")
    captured = evidence["capturedAt"]
    if not isinstance(captured, str):
        raise QualificationError("network evidence capturedAt is missing")
    try:
        captured_at = dt.datetime.fromisoformat(captured.replace("Z", "+00:00"))
    except ValueError:
        raise QualificationError("network evidence capturedAt is not RFC3339") from None
    if captured_at.tzinfo is None or captured_at.utcoffset() is None:
        raise QualificationError("network evidence capturedAt must include a timezone")
    current = now or dt.datetime.now(dt.timezone.utc)
    if current.tzinfo is None or current.utcoffset() is None:
        raise QualificationError("network validation clock must include a timezone")
    captured_utc = captured_at.astimezone(dt.timezone.utc)
    current_utc = current.astimezone(dt.timezone.utc)
    if captured_utc > current_utc + dt.timedelta(seconds=NETWORK_CLOCK_SKEW_SECONDS):
        raise QualificationError("network evidence capturedAt is in the future")
    if current_utc - captured_utc > dt.timedelta(seconds=max_age_seconds):
        raise QualificationError("network evidence is stale")
    source = evidence["source"]
    if (
        not isinstance(source, str)
        or not CAPTURE_ID_RE.fullmatch(source)
        or PRIVATE_IDENTIFIER_RE.search(source)
        or any(marker.search(source) for marker in SENSITIVE_VALUE_RES)
    ):
        raise QualificationError("network evidence source capture ID is invalid")
    if (
        evidence["internetGatewayDefaultRoute"] is not False
        or evidence["natGatewayDefaultRoute"] is not False
    ):
        raise QualificationError(
            "cluster-subnet evidence reports an Internet or NAT default route"
        )

    instances_out = []
    roles = set()
    for item in _list(evidence["instances"], "network evidence instances"):
        item = _dict(item, "network instance")
        if set(item) != {"role", "privateAddress", "publicAddress"}:
            raise QualificationError(
                "network instance evidence contains unsupported fields"
            )
        role = item.get("role")
        if role not in {"installer", "controller", "cpu-worker"}:
            raise QualificationError(
                "network evidence contains an unsupported instance role"
            )
        if (
            item.get("privateAddress") is not True
            or item.get("publicAddress") is not False
        ):
            raise QualificationError(f"network instance {role} is not private-only")
        roles.add(role)
        instances_out.append(dict(item))
    if not {"installer", "controller", "cpu-worker"}.issubset(roles):
        raise QualificationError(
            "network evidence does not cover installer, controller, and CPU worker"
        )

    routes_out = []
    allowed_targets = {
        "local",
        "vpc-endpoint",
        "gateway-endpoint",
        "transit-gateway",
        "other-private",
    }
    for item in _list(evidence["routes"], "network evidence routes"):
        item = _dict(item, "network route")
        if set(item) != {"destination", "targetType", "public"}:
            raise QualificationError(
                "network route evidence contains unsupported fields"
            )
        destination = _bounded_destination(item.get("destination"), "route")
        if (
            item.get("targetType") not in allowed_targets
            or item.get("public") is not False
        ):
            raise QualificationError(
                "network evidence contains a public or unsupported route"
            )
        if destination.startswith("pl-") and item.get("targetType") not in {
            "vpc-endpoint",
            "gateway-endpoint",
        }:
            raise QualificationError(
                "prefix-list route is not attached to a private endpoint target"
            )
        routes_out.append(
            {
                "destinationClass": (
                    "prefix-list" if destination.startswith("pl-") else "private-cidr"
                ),
                "targetType": item["targetType"],
                "public": False,
            }
        )
    if not routes_out:
        raise QualificationError("network evidence contains no private routes")

    egress_out = []
    for item in _list(evidence["securityGroupEgress"], "security-group egress"):
        item = _dict(item, "security-group egress entry")
        if set(item) != {"destination", "public"}:
            raise QualificationError(
                "security-group evidence contains unsupported fields"
            )
        destination = _bounded_destination(
            item.get("destination"), "security-group egress"
        )
        if item.get("public") is not False:
            raise QualificationError("security-group evidence reports public egress")
        egress_out.append(
            {
                "destinationClass": (
                    "prefix-list" if destination.startswith("pl-") else "private-cidr"
                ),
                "public": False,
            }
        )
    if not egress_out:
        raise QualificationError(
            "network evidence contains no bounded security-group egress"
        )
    dependencies = _dict(
        evidence["privateDependencyReachability"],
        "private dependency reachability",
    )
    expected_dependencies = {
        "registry",
        "objectStore",
        "postgres",
        "redis",
        "dns",
        "ssh",
    }
    if set(dependencies) != expected_dependencies or any(
        dependencies[name] is not True for name in expected_dependencies
    ):
        raise QualificationError(
            "network evidence does not prove every required private dependency reachable"
        )
    if evidence["publicTcpReachable"] is not False:
        raise QualificationError(
            "network evidence does not prove bounded public TCP is unavailable"
        )
    return {
        "schemaVersion": 1,
        "capturedAt": captured_utc.isoformat(),
        "captureId": source,
        "instances": instances_out,
        "routes": routes_out,
        "securityGroupEgress": egress_out,
        "internetGatewayDefaultRoute": False,
        "natGatewayDefaultRoute": False,
        "privateDependencyReachability": dict(sorted(dependencies.items())),
        "publicTcpReachable": False,
    }


class KubectlClient:
    def __init__(self, namespace: str):
        self.namespace = namespace

    def get(
        self,
        resource: str,
        name: str | None = None,
        *,
        selector: str | None = None,
        namespaced: bool = True,
        namespace: str | None = None,
    ) -> dict[str, Any]:
        command = ["kubectl"]
        if namespaced:
            command += ["-n", namespace or self.namespace]
        command += ["get", resource]
        if name:
            command.append(name)
        if selector:
            command += ["-l", selector]
        command += ["-o", "json"]
        try:
            completed = subprocess.run(
                command, check=True, capture_output=True, text=True
            )
            return _dict(json.loads(completed.stdout), f"kubectl get {resource}")
        except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
            raise QualificationError(f"kubectl could not read {resource}") from None

    def delete_pod(self, name: str) -> None:
        try:
            subprocess.run(
                [
                    "kubectl",
                    "-n",
                    self.namespace,
                    "delete",
                    "pod",
                    name,
                    "--wait=false",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError):
            raise QualificationError(
                f"kubectl could not delete selected Pod {name}"
            ) from None


def require_ready_condition(
    resource: dict[str, Any],
    description: str,
    *,
    require_condition_generation: bool = False,
) -> dict[str, Any]:
    metadata, status = _dict(
        resource.get("metadata"), f"{description} metadata"
    ), _dict(resource.get("status"), f"{description} status")
    generation = metadata.get("generation")
    observed_generation = status.get("observedGeneration")
    if (
        isinstance(generation, bool)
        or not isinstance(generation, int)
        or isinstance(observed_generation, bool)
        or not isinstance(observed_generation, int)
        or observed_generation < generation
    ):
        raise QualificationError(
            f"{description} has not observed its current generation"
        )
    conditions = _list(status.get("conditions", []), f"{description} conditions")
    condition = next((item for item in conditions if item.get("type") == "Ready"), None)
    if not condition or condition.get("status") != "True":
        reason = condition.get("reason", "missing") if condition else "missing"
        raise QualificationError(
            f"{description} is not Ready for its current generation ({reason})"
        )
    if "observedGeneration" not in condition:
        if require_condition_generation:
            raise QualificationError(
                f"{description} Ready condition has no observed generation"
            )
    else:
        condition_generation = condition["observedGeneration"]
        if (
            isinstance(condition_generation, bool)
            or not isinstance(condition_generation, int)
            or condition_generation < generation
        ):
            raise QualificationError(
                f"{description} Ready condition is stale or malformed"
            )
    return {
        "name": metadata.get("name"),
        "generation": generation,
        "observedGeneration": status["observedGeneration"],
        "readyReason": condition.get("reason", ""),
    }


def validate_platform_and_service(
    platform: dict[str, Any],
    service: dict[str, Any],
    expected_image: str,
    platform_name: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    platform_summary = require_ready_condition(platform, "AIPlatform")
    if nested(platform, "spec", "profile") != "cpuOnly":
        raise QualificationError("live AIPlatform profile is not cpuOnly")
    feature_names = sorted(
        item.get("name", "")
        for item in nested(platform, "spec", "features", default=[])
        if isinstance(item, dict)
    )
    if feature_names != ["agentruntime", "slim"]:
        raise QualificationError(
            "live AIPlatform does not select exactly agentruntime and slim"
        )
    service_summary = require_ready_condition(
        service,
        "Agent Runtime AIService",
        require_condition_generation=True,
    )
    if nested(service, "spec", "features", "name") != "agentruntime":
        raise QualificationError("selected AIService is not the agentruntime feature")
    if nested(service, "spec", "aiPlatformRef", "name") != platform_name:
        raise QualificationError(
            "Agent Runtime AIService references another AIPlatform"
        )
    las = _dict(
        nested(service, "spec", "features", "las"), "AIService LAS configuration"
    )
    live_image = f"{nested(las, 'image', 'repository', default='')}:{nested(las, 'image', 'tag', default='')}"
    if live_image != expected_image:
        raise QualificationError(
            "live Agent Runtime image differs from the qualified deployment config"
        )
    if las.get("networkMode") != "airgapped":
        raise QualificationError("live Agent Runtime networkMode is not airgapped")
    if nested(las, "tracing", "enabled", default=False) is not False:
        raise QualificationError("live Agent Runtime tracing is enabled")
    service_summary["image"] = live_image
    return platform_summary, service_summary


def _positive_quantity(value: Any) -> bool:
    if value in (None, 0, "0", "0m"):
        return False
    try:
        return float(value) > 0
    except (TypeError, ValueError):
        return bool(value)


def validate_nodes(
    nodes: dict[str, Any]
) -> tuple[dict[str, str], list[dict[str, Any]]]:
    items = _list(nodes.get("items"), "Kubernetes nodes")
    if len(items) < 2:
        raise QualificationError(
            "CPU-only topology requires a controller and a CPU worker"
        )
    architectures: dict[str, str] = {}
    summaries = []
    controller_count = worker_count = 0
    for node in items:
        metadata, status = _dict(node.get("metadata"), "node metadata"), _dict(
            node.get("status"), "node status"
        )
        name = metadata.get("name")
        if not isinstance(name, str) or not name:
            raise QualificationError("node is missing its name")
        labels = _dict(metadata.get("labels", {}), f"node {name} labels")
        ready = any(
            item.get("type") == "Ready" and item.get("status") == "True"
            for item in _list(status.get("conditions", []), f"node {name} conditions")
        )
        if not ready:
            raise QualificationError(f"node {name} is not Ready")
        for resource_set in (status.get("capacity", {}), status.get("allocatable", {})):
            for key, value in _dict(resource_set, f"node {name} resources").items():
                if (
                    key == "nvidia.com/gpu" or "gpu" in key.lower()
                ) and _positive_quantity(value):
                    raise QualificationError(f"node {name} advertises GPU capacity")
        addresses = _list(status.get("addresses", []), f"node {name} addresses")
        for address in addresses:
            if address.get("type") == "ExternalIP":
                raise QualificationError(f"node {name} has an ExternalIP")
            if address.get("type") == "InternalIP":
                try:
                    if not ipaddress.ip_address(address.get("address", "")).is_private:
                        raise QualificationError(
                            f"node {name} has a non-private InternalIP"
                        )
                except ValueError:
                    raise QualificationError(
                        f"node {name} has an invalid InternalIP"
                    ) from None
        node_info = _dict(status.get("nodeInfo"), f"node {name} nodeInfo")
        architecture = node_info.get("architecture") or labels.get("kubernetes.io/arch")
        os_name = node_info.get("operatingSystem") or labels.get("kubernetes.io/os")
        if not architecture or not os_name:
            raise QualificationError(f"node {name} is missing platform metadata")
        architectures[name] = f"{os_name}/{architecture}"
        is_controller = any(
            key in labels
            for key in (
                "node-role.kubernetes.io/control-plane",
                "node-role.kubernetes.io/master",
            )
        )
        if is_controller:
            controller_count += 1
            role = "controller"
        else:
            worker_count += 1
            role = "cpu-worker"
        summaries.append(
            {
                "id": f"{role}-{controller_count if is_controller else worker_count}",
                "role": role,
                "ready": True,
                "platform": architectures[name],
                "osImage": node_info.get("osImage", ""),
            }
        )
    if controller_count < 1 or worker_count < 1:
        raise QualificationError("CPU-only topology lacks a controller or CPU worker")
    return architectures, summaries


def _workload_text(item: dict[str, Any]) -> str:
    metadata = item.get("metadata", {})
    if item.get("kind") == "Pod":
        pod_spec = _dict(item.get("spec", {}), "Pod spec")
        containers = pod_spec.get("containers", [])
        init_containers = pod_spec.get("initContainers", [])
    else:
        template = nested(item, "spec", "template", default={})
        containers = nested(template, "spec", "containers", default=[])
        init_containers = nested(template, "spec", "initContainers", default=[])
    values = [str(metadata.get("name", ""))]
    for key, value in _dict(metadata.get("labels", {}), "workload labels").items():
        values.extend((str(key), str(value)))
    for container in list(containers or []) + list(init_containers or []):
        if isinstance(container, dict):
            values.extend(
                (str(container.get("name", "")), str(container.get("image", "")))
            )
    return " ".join(values)


def reject_forbidden_workloads(workloads: dict[str, Any], pods: dict[str, Any]) -> None:
    for item in _list(workloads.get("items", []), "workloads") + _list(
        pods.get("items", []), "Pods"
    ):
        text = _workload_text(item)
        if any(pattern.search(text) for pattern in FORBIDDEN_WORKLOAD_RES):
            name = nested(item, "metadata", "name", default="unknown")
            raise QualificationError(
                f"forbidden GPU/Ray/model-staging workload detected: {name}"
            )


def validate_supporting_workloads(workloads: dict[str, Any]) -> list[dict[str, Any]]:
    summaries = []
    for item in _list(workloads.get("items"), "supporting workloads"):
        kind = item.get("kind")
        metadata, spec, status = (
            _dict(item.get("metadata"), "workload metadata"),
            _dict(item.get("spec"), "workload spec"),
            _dict(item.get("status", {}), "workload status"),
        )
        name, generation = metadata.get("name"), metadata.get("generation", 1)
        if kind == "Deployment":
            desired, ready = spec.get("replicas", 1), status.get("readyReplicas", 0)
            if (
                status.get("observedGeneration", -1) < generation
                or ready < desired
                or status.get("availableReplicas", 0) < desired
            ):
                raise QualificationError(
                    f"supporting Deployment {name} is not fully Ready"
                )
        elif kind == "StatefulSet":
            desired, ready = spec.get("replicas", 1), status.get("readyReplicas", 0)
            if status.get("observedGeneration", -1) < generation or ready < desired:
                raise QualificationError(
                    f"supporting StatefulSet {name} is not fully Ready"
                )
            if desired and status.get("currentRevision") != status.get(
                "updateRevision"
            ):
                raise QualificationError(
                    f"supporting StatefulSet {name} has not completed its update"
                )
        elif kind == "DaemonSet":
            desired, ready = status.get("desiredNumberScheduled", 0), status.get(
                "numberReady", 0
            )
            if (
                status.get("observedGeneration", -1) < generation
                or ready < desired
                or status.get("updatedNumberScheduled", 0) < desired
            ):
                raise QualificationError(
                    f"supporting DaemonSet {name} is not fully Ready"
                )
        else:
            raise QualificationError(f"unexpected supporting workload kind: {kind}")
        images = [
            container.get("image", "")
            for container in nested(
                item, "spec", "template", "spec", "containers", default=[]
            )
            if isinstance(container, dict)
        ]
        summaries.append(
            {
                "kind": kind,
                "name": name,
                "desired": desired,
                "ready": ready,
                "images": images,
            }
        )
    if not summaries:
        raise QualificationError("no supporting workloads were observed")
    return summaries


def las_release_name(service_name: str) -> str:
    name = "las-" + service_name
    if len(name) <= 34:
        return name
    return name[:25] + "-" + hashlib.sha256(service_name.encode()).hexdigest()[:8]


def _fnv1a(value: str) -> str:
    result = 2166136261
    for byte in value.encode():
        result ^= byte
        result = (result * 16777619) & 0xFFFFFFFF
    return f"{result:08x}"


def agentruntime_service_name(service_name: str) -> str:
    candidate = service_name + "-svc"
    if len(candidate) <= 63:
        return candidate
    digest = _fnv1a(candidate)
    max_base = 63 - len("svc") - len(digest) - 2
    base = service_name[:max_base].rstrip("-") or service_name[:max_base]
    return f"{base}-{digest}-svc"


def validate_deployment(
    deployment: dict[str, Any],
    expected_name: str,
    expected_labels: dict[str, str] | None = None,
) -> dict[str, Any]:
    metadata, spec, status = (
        _dict(deployment.get("metadata"), "LAS Deployment metadata"),
        _dict(deployment.get("spec"), "LAS Deployment spec"),
        _dict(deployment.get("status"), "LAS Deployment status"),
    )
    if metadata.get("name") != expected_name:
        raise QualificationError(
            f"unexpected LAS Deployment name, wanted {expected_name}"
        )
    if expected_labels:
        labels = _dict(metadata.get("labels", {}), "LAS Deployment labels")
        missing_labels = {
            key: value
            for key, value in expected_labels.items()
            if key != "app.kubernetes.io/component" and labels.get(key) != value
        }
        if missing_labels:
            raise QualificationError(
                f"LAS Deployment {expected_name} does not match the embedded chart labels"
            )
        selector = _dict(
            nested(spec, "selector", "matchLabels", default={}),
            "LAS Deployment selector",
        )
        stable_selector = {
            key: expected_labels[key]
            for key in (
                "app.kubernetes.io/name",
                "app.kubernetes.io/instance",
                "app.kubernetes.io/component",
            )
        }
        if selector != stable_selector:
            raise QualificationError(
                f"LAS Deployment {expected_name} does not have the stable chart selector"
            )
    generation, desired = metadata.get("generation", 1), spec.get("replicas", 1)
    if status.get("observedGeneration", -1) < generation:
        raise QualificationError(
            f"LAS Deployment {expected_name} has a stale generation"
        )
    if (
        status.get("readyReplicas", 0) < desired
        or status.get("availableReplicas", 0) < desired
    ):
        raise QualificationError(f"LAS Deployment {expected_name} is not fully Ready")
    return {
        "name": expected_name,
        "desired": desired,
        "ready": status.get("readyReplicas", 0),
    }


def _selector_text(labels: dict[str, Any], context: str) -> str:
    if not labels or any(
        not isinstance(key, str)
        or not key
        or not isinstance(value, str)
        or not value
        or "," in key
        or "," in value
        for key, value in labels.items()
    ):
        raise QualificationError(f"{context} has an invalid or empty selector")
    return ",".join(f"{key}={labels[key]}" for key in sorted(labels))


def configured_pod_observation(
    pod: dict[str, Any],
    expected_image: str,
    architectures: dict[str, str],
    entry: dict[str, Any],
    component: str,
    expected_controller_kind: str,
    expected_controller_name: str,
) -> dict[str, Any]:
    containers = _list(
        nested(pod, "spec", "containers", default=[]), f"{component} Pod containers"
    )
    matches = [item for item in containers if item.get("image") == expected_image]
    if len(matches) != 1 or not isinstance(matches[0].get("name"), str):
        name = nested(pod, "metadata", "name", default="unknown")
        raise QualificationError(
            f"{component} Pod {name} does not use exactly one configured image"
        )
    return pod_observation(
        pod,
        matches[0]["name"],
        expected_image,
        architectures,
        entry,
        expected_controller_kind,
        expected_controller_name,
        component,
    )


def validate_configured_component(
    kube: KubectlClient,
    *,
    resource: str,
    kind: str,
    name: str,
    namespace: str,
    expected_image: str,
    architectures: dict[str, str],
    inventory: dict[str, Any],
    component: str,
) -> dict[str, Any]:
    workload = kube.get(resource, name, namespace=namespace)
    if workload.get("kind") != kind:
        raise QualificationError(f"{component} workload kind is not {kind}")
    summary = validate_supporting_workloads({"items": [workload]})[0]
    if summary["name"] != name or expected_image not in summary["images"]:
        raise QualificationError(
            f"{component} workload does not use its configured image"
        )
    selector_labels = _dict(
        nested(workload, "spec", "selector", "matchLabels", default={}),
        f"{component} selector",
    )
    selector = _selector_text(selector_labels, component)
    pods = kube.get("pods", selector=selector, namespace=namespace)
    items = _list(pods.get("items", []), f"{component} Pods")
    if len(items) != summary["desired"]:
        raise QualificationError(
            f"{component} Pod count {len(items)} does not match desired {summary['desired']}"
        )
    entry = inventory_entry(inventory, expected_image)
    expected_controller_kind = "StatefulSet" if kind == "StatefulSet" else "ReplicaSet"
    observations = [
        configured_pod_observation(
            pod,
            expected_image,
            architectures,
            entry,
            component,
            expected_controller_kind,
            name,
        )
        for pod in items
    ]
    summary.update(
        {
            "namespace": namespace,
            "image": expected_image,
            "runtimeDigests": sorted({item["digest"] for item in observations}),
        }
    )
    summary.pop("images", None)
    return summary


def validate_service_endpoint(
    service: dict[str, Any],
    endpoints: dict[str, Any],
    release: str,
    aiservice_name: str,
    aiservice_uid: str,
) -> dict[str, Any]:
    expected_selector = {
        "app.kubernetes.io/name": "langgraph-cloud",
        "app.kubernetes.io/instance": release,
        "app.kubernetes.io/component": release + "-langgraph-cloud-api-server",
    }
    metadata = _dict(service.get("metadata"), "LAS compatibility Service metadata")
    owners = _list(metadata.get("ownerReferences", []), "Service ownerReferences")
    if not any(
        owner.get("apiVersion") == "ai.splunk.com/v1"
        and owner.get("kind") == "AIService"
        and owner.get("name") == aiservice_name
        and owner.get("uid") == aiservice_uid
        and owner.get("controller") is True
        for owner in owners
    ):
        raise QualificationError(
            "LAS compatibility Service is not controlled by the selected AIService"
        )
    spec = _dict(service.get("spec"), "LAS compatibility Service spec")
    if (
        spec.get("type", "ClusterIP") != "ClusterIP"
        or spec.get("selector") != expected_selector
    ):
        raise QualificationError(
            "LAS compatibility Service does not have the stable API selector"
        )
    valid_port = any(
        port.get("name") == "http"
        and port.get("port") == 8080
        and port.get("targetPort") == 8000
        for port in _list(spec.get("ports", []), "LAS compatibility Service ports")
    )
    if not valid_port:
        raise QualificationError(
            "LAS compatibility Service does not expose 8080 -> 8000"
        )
    ready_addresses = 0
    valid_endpoint_port = False
    for subset in _list(
        endpoints.get("subsets", []), "LAS compatibility Endpoints subsets"
    ):
        ready_addresses += len(subset.get("addresses", []))
        valid_endpoint_port = valid_endpoint_port or any(
            port.get("name") == "http" and port.get("port") == 8000
            for port in subset.get("ports", [])
        )
    if ready_addresses < 1 or not valid_endpoint_port:
        raise QualificationError("LAS compatibility Service has no ready API endpoint")
    return {
        "name": nested(service, "metadata", "name"),
        "readyAddresses": ready_addresses,
        "port": 8080,
    }


def digest_from_image_id(image_id: Any) -> str:
    if not isinstance(image_id, str):
        raise QualificationError("Pod container imageID is missing")
    digests = sorted(set(DIGEST_RE.findall(image_id)))
    if len(digests) != 1:
        raise QualificationError(
            "Pod container imageID does not contain exactly one sha256 digest"
        )
    return digests[0]


def inventory_entry(inventory: dict[str, Any], image_reference: str) -> dict[str, Any]:
    matches = [
        item
        for item in inventory.get("images", [])
        if item.get("reference") == image_reference
    ]
    if len(matches) != 1:
        raise QualificationError(
            "image inventory does not contain exactly one configured LAS reference"
        )
    return matches[0]


def allowed_inventory_digests(entry: dict[str, Any], platform: str) -> set[str]:
    try:
        os_name, architecture = platform.split("/", 1)
    except ValueError:
        raise QualificationError(f"invalid node platform: {platform}") from None
    matches = [
        item
        for item in entry.get("platforms", [])
        if item.get("os") == os_name and item.get("architecture") == architecture
    ]
    identities: dict[tuple[Any, Any, Any], dict[str, Any]] = {}
    for item in matches:
        identities.setdefault(
            (
                item.get("variant"),
                item.get("digest"),
                item.get("runtimeDigest"),
            ),
            item,
        )
    if not identities:
        raise QualificationError(
            f"image inventory has no identity for node platform: {platform}"
        )
    if len(identities) != 1:
        raise QualificationError(
            f"image inventory has ambiguous identities for node platform: {platform}"
        )
    item = next(iter(identities.values()))
    allowed = {entry.get("digest"), item.get("digest"), item.get("runtimeDigest")}
    return {
        value
        for value in allowed
        if isinstance(value, str) and DIGEST_RE.fullmatch(value)
    }


def validate_pod_controller(
    metadata: dict[str, Any],
    expected_kind: str,
    expected_name: str,
    context: str,
) -> None:
    owners = _list(metadata.get("ownerReferences", []), f"{context} ownerReferences")
    controllers = [owner for owner in owners if owner.get("controller") is True]
    if len(controllers) != 1:
        raise QualificationError(
            f"{context} must have exactly one controller ownerReference"
        )
    owner = _dict(controllers[0], f"{context} controller ownerReference")
    owner_name = owner.get("name")
    if (
        owner.get("apiVersion") != "apps/v1"
        or owner.get("kind") != expected_kind
        or not isinstance(owner.get("uid"), str)
        or not owner.get("uid")
    ):
        raise QualificationError(
            f"{context} is not controlled by the expected {expected_kind}"
        )
    if expected_kind == "ReplicaSet":
        valid_name = isinstance(owner_name, str) and owner_name.startswith(
            expected_name + "-"
        )
    else:
        valid_name = owner_name == expected_name
    if not valid_name:
        raise QualificationError(
            f"{context} is not controlled by the expected {expected_kind}"
        )


def pod_observation(
    pod: dict[str, Any],
    container_name: str,
    expected_image: str,
    architectures: dict[str, str],
    entry: dict[str, Any],
    expected_controller_kind: str,
    expected_controller_name: str,
    component: str = "LAS",
) -> dict[str, Any]:
    metadata, spec, status = (
        _dict(pod.get("metadata"), "Pod metadata"),
        _dict(pod.get("spec"), "Pod spec"),
        _dict(pod.get("status"), "Pod status"),
    )
    name, uid, node = metadata.get("name"), metadata.get("uid"), spec.get("nodeName")
    if not name or not uid or not node or node not in architectures:
        raise QualificationError(
            "LAS Pod is missing name, UID, or known node assignment"
        )
    validate_pod_controller(
        metadata,
        expected_controller_kind,
        expected_controller_name,
        f"{component} Pod {name}",
    )
    if metadata.get("deletionTimestamp"):
        raise QualificationError(f"LAS Pod {name} is terminating")
    if not any(
        item.get("type") == "Ready" and item.get("status") == "True"
        for item in status.get("conditions", [])
    ):
        raise QualificationError(f"LAS Pod {name} is not Ready")
    spec_container = next(
        (
            item
            for item in spec.get("containers", [])
            if item.get("name") == container_name
        ),
        None,
    )
    container_status = next(
        (
            item
            for item in status.get("containerStatuses", [])
            if item.get("name") == container_name
        ),
        None,
    )
    if (
        not spec_container
        or not container_status
        or container_status.get("ready") is not True
    ):
        raise QualificationError(
            f"LAS Pod {name} container {container_name} is not Ready"
        )
    if spec_container.get("image") != expected_image:
        raise QualificationError(
            f"LAS Pod {name} does not use the configured image reference"
        )
    digest = digest_from_image_id(container_status.get("imageID"))
    allowed = allowed_inventory_digests(entry, architectures[node])
    if digest not in allowed:
        raise QualificationError(
            f"LAS Pod {name} image digest is not approved by the offline inventory"
        )
    return {
        "name": name,
        "uid": uid,
        "platform": architectures[node],
        "container": container_name,
        "image": expected_image,
        "imageID": container_status["imageID"],
        "digest": digest,
        "ready": True,
    }


def component_observations(
    pods: dict[str, Any],
    container_name: str,
    expected_image: str,
    architectures: dict[str, str],
    entry: dict[str, Any],
    expected_count: int,
    deployment_name: str,
) -> list[dict[str, Any]]:
    observations, failures = [], []
    for pod in _list(pods.get("items"), "LAS Pods"):
        try:
            observations.append(
                pod_observation(
                    pod,
                    container_name,
                    expected_image,
                    architectures,
                    entry,
                    "ReplicaSet",
                    deployment_name,
                )
            )
        except QualificationError as exc:
            failures.append(str(exc))
    if failures:
        raise QualificationError(
            f"invalid LAS {container_name} Pod observed: {failures[0]}"
        )
    if len(observations) != expected_count:
        raise QualificationError(
            f"LAS {container_name} Pod count {len(observations)} does not match desired {expected_count}"
        )
    return sorted(observations, key=lambda item: item["name"])


def wait_for_replacement(
    kube: KubectlClient,
    selector: str,
    container_name: str,
    expected_image: str,
    architectures: dict[str, str],
    entry: dict[str, Any],
    baseline_uids: set[str],
    previous_digest: str,
    deployment_name: str,
    timeout_seconds: int,
    poll_seconds: float,
    *,
    sleeper: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> dict[str, Any]:
    deadline = clock() + timeout_seconds
    last_problem = "replacement Pod has not appeared"
    while clock() < deadline:
        pods = kube.get("pods", selector=selector)
        for pod in pods.get("items", []):
            uid = nested(pod, "metadata", "uid")
            if not uid or uid in baseline_uids:
                continue
            try:
                observation = pod_observation(
                    pod,
                    container_name,
                    expected_image,
                    architectures,
                    entry,
                    "ReplicaSet",
                    deployment_name,
                )
            except QualificationError as exc:
                last_problem = str(exc)
                continue
            if observation["digest"] != previous_digest:
                raise QualificationError(
                    "replacement LAS Pod changed the approved runtime digest"
                )
            return observation
        sleeper(poll_seconds)
    raise QualificationError(
        f"replacement LAS Pod did not become Ready: {last_problem}"
    )


def ensure_sanitized(value: Any, path: str = "evidence") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if SENSITIVE_KEY_RE.search(str(key)):
                raise QualificationError(
                    f"refusing to write credential-shaped evidence field: {path}.{key}"
                )
            ensure_sanitized(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            ensure_sanitized(child, f"{path}[{index}]")
    elif isinstance(value, str):
        if any(pattern.search(value) for pattern in SENSITIVE_VALUE_RES):
            raise QualificationError(
                f"refusing to write credential-shaped evidence value: {path}"
            )
        if PRIVATE_REGISTRY_RE.search(value):
            raise QualificationError(
                f"refusing to write private registry address: {path}"
            )


def redact_ecr_account_ids(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: redact_ecr_account_ids(child) for key, child in value.items()}
    if isinstance(value, list):
        return [redact_ecr_account_ids(child) for child in value]
    if isinstance(value, str):
        return ECR_ACCOUNT_RE.sub("<redacted-account>", value)
    return value


def redact_private_registry_addresses(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: redact_private_registry_addresses(child)
            for key, child in value.items()
        }
    if isinstance(value, list):
        return [redact_private_registry_addresses(child) for child in value]
    if isinstance(value, str):
        return PRIVATE_REGISTRY_RE.sub(
            lambda match: f"{match.group('prefix') or ''}<redacted-registry>/",
            value,
        )
    return value


def preflight_output_paths(output_dir: Path) -> tuple[Path, Path]:
    json_path = output_dir / "mpr-129-evidence.json"
    markdown_path = output_dir / "mpr-129-evidence.md"
    if output_dir.is_symlink():
        raise QualificationError(
            "evidence output directory must not be a symbolic link"
        )
    if os.path.lexists(json_path) or os.path.lexists(markdown_path):
        raise QualificationError("refusing to overwrite existing MPR-129 evidence")
    try:
        output_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=output_dir, delete=False
        ) as stream:
            probe = Path(stream.name)
            stream.write("output preflight\n")
            stream.flush()
            os.fsync(stream.fileno())
        probe.unlink()
    except OSError:
        raise QualificationError("evidence output directory is not writable") from None
    return json_path, markdown_path


def atomic_write(path: Path, content: str) -> None:
    if os.path.lexists(path):
        raise QualificationError(
            f"refusing to overwrite existing evidence file: {path}"
        )
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=path.parent, delete=False
        ) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except OSError:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
        raise QualificationError(
            f"could not write evidence file: {path.name}"
        ) from None


def evidence_markdown(evidence: dict[str, Any]) -> str:
    replacement = evidence.get("replacement")
    lines = [
        "# MPR-129 CPU-only air-gap runtime sub-check evidence",
        "",
        f"- Result: **{evidence['result']}**",
        f"- Scope: {evidence['scope']}",
        f"- Captured: `{evidence['capturedAt']}`",
        f"- Namespace: `{evidence['namespace']}`",
        f"- AIPlatform: `{evidence['aiplatform']['name']}`",
        f"- Agent Runtime AIService: `{evidence['aiservice']['name']}`",
        f"- Bundle content-set SHA-256: `{evidence['bundle']['bundleContentSetSha256']}`",
        f"- Bundle tarball SHA-256: `{evidence['bundle']['tarballSha256']}`",
        f"- Source commit: `{evidence['bundle']['sourceCommit']}`",
        f"- Checksum manifest SHA-256: `{evidence['bundle']['manifestSha256']}`",
        f"- LAS runtime digest: `{evidence['bundle']['inventoryImageDigest']}`",
        "",
        "## Runtime Pods",
        "",
    ]
    for component in ("api", "queue"):
        for pod in evidence["las"][component]["pods"]:
            lines.append(
                f"- {component}: `{pod['name']}` UID `{pod['uid']}` digest `{pod['digest']}` Ready"
            )
    lines += ["", "## Isolation", ""]
    lines.append("- Public IPs: none reported")
    lines.append("- Cluster-subnet Internet-gateway default route: no")
    lines.append("- Cluster-subnet NAT-gateway default route: no")
    lines.append("- Security-group egress: bounded private destinations only")
    if replacement:
        lines += ["", "## Replacement", ""]
        lines.append(f"- Component: `{replacement['component']}`")
        lines.append(
            f"- Original: `{replacement['before']['name']}` UID `{replacement['before']['uid']}`"
        )
        lines.append(
            f"- Replacement: `{replacement['after']['name']}` UID `{replacement['after']['uid']}`"
        )
        lines.append(f"- Digest retained: `{replacement['after']['digest']}`")
    lines += [
        "",
        "Generated without Kubernetes Secret data or workload environment values.",
        "",
    ]
    return "\n".join(lines)


def qualify(
    args: argparse.Namespace,
    *,
    kube: KubectlClient | None = None,
    sleeper: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> dict[str, Any]:
    if args.replace_component and not args.confirm_disposable_cluster:
        raise QualificationError(
            "--replace-component requires --confirm-disposable-cluster"
        )
    if args.confirm_disposable_cluster and not args.replace_component:
        raise QualificationError(
            "--confirm-disposable-cluster is valid only with --replace-component"
        )
    json_path, markdown_path = preflight_output_paths(Path(args.output_dir))
    config = load_structured_file(Path(args.deployment_config), "deployment config")
    expected_image = validate_deployment_config(config)
    supporting_images = configured_supporting_images(config)
    inventory, checksum = validate_bundle(
        Path(args.bundle_dir), args.expected_source_commit
    )
    tarball_sha256 = validate_bundle_tarball(
        Path(args.bundle_tarball),
        args.expected_bundle_sha256,
        checksum["manifestSha256"],
    )
    configured_images = {"LAS": expected_image, **supporting_images}
    inventory_entries: dict[str, dict[str, Any]] = {}
    inventory_module = _load_inventory_module()
    target_platform = (
        inventory.get("targetPlatform")
        if inventory.get("schemaVersion") == 2
        else "linux/amd64"
    )
    for component, reference in configured_images.items():
        entry = inventory_entry(inventory, reference)
        try:
            inventory_module.enrich_image_runtime_digests(
                Path(args.bundle_dir),
                entry,
                target_platform=target_platform,
            )
        except (OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
            raise QualificationError(
                f"offline {component} runtime identity chain is invalid: {exc}"
            ) from None
        inventory_entries[component] = entry
    entry = inventory_entries["LAS"]
    network = validate_network_evidence(
        load_structured_file(Path(args.network_evidence), "network evidence"),
        max_age_seconds=args.network_max_age_seconds,
    )
    kube = kube or KubectlClient(args.namespace)

    platform = kube.get("aiplatform", args.aiplatform)
    service = kube.get("aiservice", args.aiservice)
    platform_summary, service_summary = validate_platform_and_service(
        platform, service, expected_image, args.aiplatform
    )
    aiservice_uid = nested(service, "metadata", "uid")
    if not isinstance(aiservice_uid, str) or not aiservice_uid:
        raise QualificationError("selected Agent Runtime AIService is missing its UID")
    slim_service_name = args.slim_aiservice or f"{args.aiplatform}-slim"
    slim_service = kube.get("aiservice", slim_service_name)
    slim_service_summary = require_ready_condition(slim_service, "SLIM AIService")
    if (
        nested(slim_service, "spec", "features", "name") != "slim"
        or nested(slim_service, "spec", "aiPlatformRef", "name") != args.aiplatform
    ):
        raise QualificationError(
            "selected SLIM AIService does not belong to AIPlatform"
        )
    nodes = kube.get("nodes", namespaced=False)
    architectures, node_summaries = validate_nodes(nodes)
    if set(architectures.values()) != {target_platform}:
        raise QualificationError(
            "live node platforms differ from the qualified bundle target"
        )
    workloads = kube.get("deployments,statefulsets,daemonsets")
    all_pods = kube.get("pods")
    reject_forbidden_workloads(workloads, all_pods)
    supporting = validate_supporting_workloads(workloads)
    operator_summary = validate_configured_component(
        kube,
        resource="deployment",
        kind="Deployment",
        name=args.operator_deployment,
        namespace=args.operator_namespace,
        expected_image=supporting_images["operator"],
        architectures=architectures,
        inventory=inventory,
        component="AI operator",
    )
    slim_deployment_name = (
        args.slim_deployment or f"{slim_service_name}-slim-deployment"
    )
    slim_summary = validate_configured_component(
        kube,
        resource="deployment",
        kind="Deployment",
        name=slim_deployment_name,
        namespace=args.namespace,
        expected_image=supporting_images["slim"],
        architectures=architectures,
        inventory=inventory,
        component="SLIM",
    )
    standalone_name = nested(config, "splunk", "standaloneName")
    if not isinstance(standalone_name, str) or not standalone_name:
        raise QualificationError("deployment config is missing splunk.standaloneName")
    splunk_statefulset_name = (
        args.splunk_statefulset or f"splunk-{standalone_name}-standalone"
    )
    splunk_summary = validate_configured_component(
        kube,
        resource="statefulset",
        kind="StatefulSet",
        name=splunk_statefulset_name,
        namespace=args.namespace,
        expected_image=supporting_images["splunk"],
        architectures=architectures,
        inventory=inventory,
        component="Splunk",
    )
    splunk_operator_summary = validate_configured_component(
        kube,
        resource="deployment",
        kind="Deployment",
        name=args.splunk_operator_deployment,
        namespace=args.splunk_namespace,
        expected_image=supporting_images["splunkOperator"],
        architectures=architectures,
        inventory=inventory,
        component="Splunk operator",
    )

    release = las_release_name(args.aiservice)
    component_specs = {
        "api": (release + "-langgraph-cloud-api-server", "api-server"),
        "queue": (release + "-langgraph-cloud-queue", "queue"),
    }
    las_summary: dict[str, Any] = {}
    selectors: dict[str, str] = {}
    component_pod_payloads: dict[str, dict[str, Any]] = {}
    for component, (deployment_name, container_name) in component_specs.items():
        chart_labels = {
            "app.kubernetes.io/name": "langgraph-cloud",
            "app.kubernetes.io/instance": release,
            "app.kubernetes.io/component": deployment_name,
            "app.kubernetes.io/managed-by": "Helm",
            "helm.sh/chart": checksum["embeddedChartLabel"],
        }
        selector = (
            "app.kubernetes.io/name=langgraph-cloud,"
            f"app.kubernetes.io/instance={release},"
            f"app.kubernetes.io/component={deployment_name}"
        )
        selectors[component] = selector
        deployment_summary = validate_deployment(
            kube.get("deployment", deployment_name),
            deployment_name,
            chart_labels,
        )
        pod_payload = kube.get("pods", selector=selector)
        component_pod_payloads[component] = pod_payload
        observations = component_observations(
            pod_payload,
            container_name,
            expected_image,
            architectures,
            entry,
            deployment_summary["desired"],
            deployment_name,
        )
        las_summary[component] = {
            "deployment": deployment_summary,
            "pods": observations,
        }

    service_name = agentruntime_service_name(args.aiservice)
    endpoint_summary = validate_service_endpoint(
        kube.get("service", service_name),
        kube.get("endpoints", service_name),
        release,
        args.aiservice,
        aiservice_uid,
    )

    replacement = None
    if args.replace_component:
        selected = las_summary[args.replace_component]["pods"]
        before = selected[0]
        baseline_uids = {
            nested(item, "metadata", "uid")
            for item in component_pod_payloads[args.replace_component].get("items", [])
            if nested(item, "metadata", "uid")
        }
        kube.delete_pod(before["name"])
        after = wait_for_replacement(
            kube,
            selectors[args.replace_component],
            component_specs[args.replace_component][1],
            expected_image,
            architectures,
            entry,
            baseline_uids,
            before["digest"],
            component_specs[args.replace_component][0],
            args.timeout_seconds,
            args.poll_seconds,
            sleeper=sleeper,
            clock=clock,
        )
        replacement = {
            "component": args.replace_component,
            "before": before,
            "after": after,
        }

    distribution = inventory.get("embeddedDistribution", {})
    evidence: dict[str, Any] = {
        "schemaVersion": 1,
        "result": "RUNTIME_PASS",
        "scope": RUNTIME_SCOPE,
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "namespace": args.namespace,
        "aiplatform": platform_summary,
        "aiservice": service_summary,
        "slimAIService": slim_service_summary,
        "bundle": {
            "profile": inventory.get("profile"),
            "sourceCommit": checksum["sourceCommit"],
            "tarballSha256": tarball_sha256,
            "manifestSha256": checksum["manifestSha256"],
            "bundleContentSetSha256": checksum["bundleContentSetSha256"],
            "artifactCount": checksum["artifactCount"],
            "inventoryImageDigest": entry.get("digest"),
            "inventoryPlatformDigests": [
                item.get("digest")
                for item in entry.get("platforms", [])
                if item.get("digest")
            ],
            "inventoryRuntimeDigests": [
                item.get("runtimeDigest")
                for item in entry.get("platforms", [])
                if item.get("runtimeDigest")
            ],
            "importArchives": entry.get("importArchives", []),
            "embeddedChartPath": distribution.get("path", ""),
            "embeddedChartSha256": distribution.get("sha256", ""),
            "embeddedChartName": checksum["embeddedChartName"],
            "embeddedChartVersion": checksum["embeddedChartVersion"],
        },
        "network": network,
        "nodes": node_summaries,
        "supportingWorkloads": supporting,
        "requiredSupportingComponents": {
            "operator": operator_summary,
            "slim": slim_summary,
            "splunk": splunk_summary,
            "splunkOperator": splunk_operator_summary,
        },
        "las": {**las_summary, "service": endpoint_summary},
        "replacement": replacement,
    }
    evidence = redact_ecr_account_ids(evidence)
    evidence = redact_private_registry_addresses(evidence)
    ensure_sanitized(evidence)
    atomic_write(json_path, json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    atomic_write(markdown_path, evidence_markdown(evidence))
    return evidence


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--namespace", required=True)
    result.add_argument("--aiservice", required=True)
    result.add_argument("--aiplatform", required=True)
    result.add_argument("--bundle-dir", required=True)
    result.add_argument("--bundle-tarball", required=True)
    result.add_argument("--expected-bundle-sha256", required=True)
    result.add_argument("--expected-source-commit", required=True)
    result.add_argument("--deployment-config", required=True)
    result.add_argument("--network-evidence", required=True)
    result.add_argument("--output-dir", required=True)
    result.add_argument("--operator-namespace", required=True)
    result.add_argument(
        "--operator-deployment",
        default="splunk-ai-operator-controller-manager",
    )
    result.add_argument("--slim-aiservice")
    result.add_argument("--slim-deployment")
    result.add_argument("--splunk-namespace", required=True)
    result.add_argument(
        "--splunk-operator-deployment",
        default="splunk-operator-controller-manager",
    )
    result.add_argument("--splunk-statefulset")
    result.add_argument("--replace-component", choices=("api", "queue"))
    result.add_argument(
        "--confirm-disposable-cluster",
        action="store_true",
        help="confirm that deleting exactly one selected LAS Pod is approved",
    )
    result.add_argument("--timeout-seconds", type=int, default=DEFAULT_TIMEOUT_SECONDS)
    result.add_argument("--poll-seconds", type=float, default=DEFAULT_POLL_SECONDS)
    result.add_argument(
        "--network-max-age-seconds",
        type=int,
        default=DEFAULT_NETWORK_MAX_AGE_SECONDS,
    )
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if (
        args.timeout_seconds < 1
        or args.poll_seconds <= 0
        or args.network_max_age_seconds < 1
    ):
        print(
            "ERROR: timeout, poll, and network-age intervals must be positive",
            file=sys.stderr,
        )
        return 2
    try:
        evidence = qualify(args)
    except QualificationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(
        f"RUNTIME_PASS: wrote sanitized runtime-subcheck evidence to "
        f"{Path(args.output_dir).resolve()} "
        f"(scope=runtime-only, replacement={bool(evidence['replacement'])})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
