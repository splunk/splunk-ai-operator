#!/usr/bin/env python3
"""Run bounded, sanitized Launchpad lifecycle qualification phases.

Product scenarios are accepted only on stdin and are forwarded to the runtime
qualification helper without being written or printed. Kubernetes Secret data
is never read. Mutating phases require LAS_LIFECYCLE_MUTATIONS_CONFIRMED=true.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


DNS_NAME = re.compile(r"^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
WORKLOAD_KINDS = {"deployment", "statefulset"}
RUNTIME_HELPER = pathlib.Path(__file__).with_name("las-runtime-acceptance.py")


class LifecycleError(RuntimeError):
    pass


def name(value: str, label: str) -> str:
    if not isinstance(value, str) or not DNS_NAME.fullmatch(value):
        raise LifecycleError(f"{label} must be an exact Kubernetes DNS name")
    return value


def workload_ref(value: str, label: str) -> tuple[str, str]:
    try:
        kind, resource_name = value.split("/", 1)
    except ValueError:
        raise LifecycleError(f"{label} must use kind/name") from None
    kind = kind.lower()
    if kind not in WORKLOAD_KINDS:
        raise LifecycleError(f"{label} kind must be Deployment or StatefulSet")
    return kind, name(resource_name, label)


def require_digest(value: str, label: str) -> str:
    if not SHA256.fullmatch(value):
        raise LifecycleError(f"{label} must be a resolved sha256 digest")
    return value


def require_sha256_hex(value: str, label: str) -> str:
    if not SHA256_HEX.fullmatch(value):
        raise LifecycleError(f"{label} must be a 64-character lowercase sha256 value")
    return value


def safe_text(value: str, label: str) -> str:
    if not value or "\n" in value or "\r" in value:
        raise LifecycleError(f"{label} must be a non-empty single-line value")
    return value


def value_sha256(value: Any) -> str:
    """Return a deterministic, non-secret identity for a JSON-compatible value."""
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


class Kubectl:
    def __init__(self, namespace: str, binary: str, timeout: int, dry_run: bool):
        self.namespace = name(namespace, "namespace")
        self.binary = binary
        self.timeout = timeout
        self.dry_run = dry_run
        self.planned: list[list[str]] = []

    def _run(self, args: list[str], *, mutate: bool = False) -> str:
        command = [self.binary, "-n", self.namespace, *args]
        if self.dry_run:
            self.planned.append(command[1:])
            return ""
        if mutate and os.environ.get("LAS_LIFECYCLE_MUTATIONS_CONFIRMED") != "true":
            raise LifecycleError("set LAS_LIFECYCLE_MUTATIONS_CONFIRMED=true for selected mutation phases")
        try:
            completed = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
                timeout=self.timeout,
            )
        except (OSError, subprocess.SubprocessError):
            raise LifecycleError("a bounded kubectl operation failed; inspect cluster events separately") from None
        return completed.stdout

    def _run_global(self, args: list[str]) -> str:
        command = [self.binary, *args]
        if self.dry_run:
            self.planned.append(command[1:])
            return ""
        try:
            completed = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
                timeout=self.timeout,
            )
        except (OSError, subprocess.SubprocessError):
            raise LifecycleError("a bounded kubectl identity operation failed") from None
        return completed.stdout

    def get(self, kind: str, resource_name: str) -> dict[str, Any]:
        resource_name = name(resource_name, kind)
        raw = self._run(["get", kind, resource_name, "-o", "json"])
        if self.dry_run:
            return {}
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            raise LifecycleError(f"kubectl returned invalid JSON for {kind}") from None
        if not isinstance(value, dict):
            raise LifecycleError(f"kubectl returned an invalid {kind} object")
        return value

    def get_in_namespace(self, namespace: str, kind: str, resource_name: str) -> dict[str, Any]:
        namespace = name(namespace, "namespace")
        resource_name = name(resource_name, kind)
        if namespace == self.namespace:
            return self.get(kind, resource_name)
        raw = self._run_global(["-n", namespace, "get", kind, resource_name, "-o", "json"])
        if self.dry_run:
            return {}
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            raise LifecycleError(f"kubectl returned invalid JSON for {kind}") from None
        if not isinstance(value, dict):
            raise LifecycleError(f"kubectl returned an invalid {kind} object")
        return value

    def get_namespace(self) -> dict[str, Any]:
        raw = self._run_global(["get", "namespace", self.namespace, "-o", "json"])
        if self.dry_run:
            return {}
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            raise LifecycleError("kubectl returned invalid namespace JSON") from None
        if not isinstance(value, dict):
            raise LifecycleError("kubectl returned an invalid namespace object")
        return value

    def current_context(self) -> str:
        if self.dry_run:
            self._run_global(["config", "current-context"])
            return ""
        return self._run_global(["config", "current-context"]).strip()

    def list_pods(self, namespace: str, selector: str) -> list[dict[str, Any]]:
        if not selector or not re.fullmatch(r"[A-Za-z0-9_.\-/=,]+", selector):
            raise LifecycleError("Deployment selector cannot be represented safely")
        raw = self._run_global(
            ["-n", name(namespace, "namespace"), "get", "pods", "-l", selector, "-o", "json"]
        )
        if self.dry_run:
            return []
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            raise LifecycleError("kubectl returned invalid Pod-list JSON") from None
        items = value.get("items") if isinstance(value, dict) else None
        if not isinstance(items, list):
            raise LifecycleError("kubectl returned an invalid Pod list")
        return [item for item in items if isinstance(item, dict)]

    def restart(self, kind: str, resource_name: str) -> None:
        kind, resource_name = workload_ref(f"{kind}/{resource_name}", "workload")
        self._run(["rollout", "restart", f"{kind}/{resource_name}"], mutate=True)
        self._run(
            ["rollout", "status", f"{kind}/{resource_name}", f"--timeout={self.timeout}s"],
            mutate=True,
        )

    def rollout_status(self, deployment: str) -> None:
        deployment = name(deployment, "Deployment")
        self._run(
            ["rollout", "status", f"deployment/{deployment}", f"--timeout={self.timeout}s"],
            mutate=True,
        )


class StableLASAccess:
    """Own the Service port-forward that binds protocol evidence to this cluster."""

    def __init__(
        self,
        kubectl: Kubectl,
        service: str | None,
        service_port: int,
        timeout: int,
        dry_run: bool,
    ):
        self.kubectl = kubectl
        if not service:
            raise LifecycleError(
                "product qualification requires --api-service so protocol traffic is bound to the verified cluster"
            )
        self.service = name(service, "LAS API Service")
        self.service_port = service_port
        self.timeout = timeout
        self.dry_run = dry_run
        self.process: subprocess.Popen[str] | None = None
        self.base_url = os.environ.get("LAS_BASE_URL", "")
        parsed = urllib.parse.urlsplit(self.base_url)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise LifecycleError("LAS_BASE_URL must be an http(s) URL")
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise LifecycleError("LAS_BASE_URL cannot contain credentials, query, or fragment")
        if parsed.hostname not in ("127.0.0.1", "localhost", "::1") or parsed.port is None:
            raise LifecycleError("script-managed port-forward requires a loopback LAS_BASE_URL with a port")
        if parsed.scheme != "http":
            raise LifecycleError("script-managed port-forward requires an http LAS_BASE_URL")
        self.local_port = parsed.port

    def close(self) -> None:
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            self.process = None

    def _healthy(self) -> bool:
        request = urllib.request.Request(self.base_url.rstrip("/") + "/ok")
        api_key = os.environ.get("LAS_API_KEY")
        if api_key:
            request.add_header("X-Api-Key", api_key)
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                body = response.read(65537)
                if response.status != 200 or len(body) > 65536:
                    return False
                value = json.loads(body)
                return isinstance(value, dict) and value.get("ok") is True
        except (OSError, urllib.error.URLError, ValueError, json.JSONDecodeError):
            return False

    def refresh(self) -> None:
        if self.dry_run:
            self.kubectl.planned.append(
                [
                    "-n",
                    self.kubectl.namespace,
                    "port-forward",
                    f"service/{self.service}",
                    f"{self.local_port}:{self.service_port}",
                ]
            )
            return
        self.close()
        try:
            self.process = subprocess.Popen(
                [
                    self.kubectl.binary,
                    "-n",
                    self.kubectl.namespace,
                    "port-forward",
                    f"service/{self.service}",
                    f"{self.local_port}:{self.service_port}",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
            )
        except OSError:
            raise LifecycleError("could not start the bounded LAS Service port-forward") from None
        deadline = time.monotonic() + min(self.timeout, 60)
        while time.monotonic() < deadline:
            if self.process is not None and self.process.poll() is not None:
                raise LifecycleError("LAS Service port-forward exited before becoming ready")
            if self._healthy():
                if self.process is None or self.process.poll() is not None:
                    raise LifecycleError("LAS Service port-forward exited during its health check")
                return
            time.sleep(1)
        raise LifecycleError(
            "the managed LAS Service port-forward did not become healthy"
        )


def selector_for_deployment(value: dict[str, Any]) -> str:
    labels = value.get("spec", {}).get("selector", {}).get("matchLabels")
    if not isinstance(labels, dict) or not labels:
        raise LifecycleError("Deployment has no exact matchLabels selector")
    parts = []
    for key, item in sorted(labels.items()):
        if not isinstance(key, str) or not isinstance(item, str):
            raise LifecycleError("Deployment selector labels must be strings")
        part = f"{key}={item}"
        if not re.fullmatch(r"[A-Za-z0-9_.\-/=]+", part):
            raise LifecycleError("Deployment selector cannot be represented safely")
        parts.append(part)
    return ",".join(parts)


def assert_ready(snapshot: dict[str, Any], *, api_one: bool = False) -> None:
    desired = snapshot.get("desired")
    if not isinstance(desired, int) or desired < 1:
        raise LifecycleError("workload has no positive desired replica count")
    if api_one and desired != 1:
        raise LifecycleError("LAS API Deployment must remain at exactly one replica")
    if any(snapshot.get(field) != desired for field in ("ready", "updated", "available")):
        raise LifecycleError("workload is not fully ready, updated, and available")
    generation = snapshot.get("generation")
    observed = snapshot.get("observed_generation")
    if isinstance(generation, int) and observed != generation:
        raise LifecycleError("workload controller has not observed the current generation")


def deployment_image_identity(
    kubectl: Kubectl,
    namespace: str,
    deployment: str,
    expected_image: str,
    expected_digest: str,
    *,
    api_one: bool = False,
) -> dict[str, Any]:
    value = kubectl.get_in_namespace(namespace, "deployment", deployment)
    if kubectl.dry_run:
        return {
            "namespace": namespace,
            "deployment": deployment,
            "expected_image": expected_image,
            "expected_digest": expected_digest,
            "dry_run": True,
        }
    snapshot = deployment_snapshot_value(value, deployment)
    assert_ready(snapshot, api_one=api_one)
    containers = value.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
    matching_names = {
        item.get("name")
        for item in containers
        if isinstance(item, dict) and item.get("image") == expected_image and isinstance(item.get("name"), str)
    }
    if not matching_names:
        raise LifecycleError("configured Deployment image does not match the declared identity")
    pods = kubectl.list_pods(namespace, selector_for_deployment(value))
    if not pods:
        raise LifecycleError("no Pods were found for identity verification")
    resolved = []
    for pod in pods:
        statuses = pod.get("status", {}).get("containerStatuses", [])
        matching = [
            item
            for item in statuses
            if isinstance(item, dict) and item.get("name") in matching_names
        ]
        if not matching:
            raise LifecycleError("a selected Pod omitted the expected container identity")
        for item in matching:
            image_id = item.get("imageID")
            if not isinstance(image_id, str) or expected_digest not in image_id:
                raise LifecycleError("resolved Pod image digest does not match the declared identity")
            resolved.append(image_id)
    return {
        "namespace": namespace,
        "deployment": deployment,
        "configured_image": expected_image,
        "resolved_digest": expected_digest,
        "verified_pods": len(pods),
        "verified_containers": len(resolved),
    }


def helm_release_identity(
    binary: str,
    namespace: str,
    release: str,
    chart_version: str,
    timeout: int,
    dry_run: bool,
) -> dict[str, Any]:
    namespace = name(namespace, "Helm namespace")
    release = name(release, "Helm release")
    if dry_run:
        return {"namespace": namespace, "release": release, "chart_version": chart_version, "dry_run": True}
    try:
        completed = subprocess.run(
            [binary, "list", "--namespace", namespace, "--filter", f"^{release}$", "--output", "json"],
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        values = json.loads(completed.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        raise LifecycleError("could not verify the Helm release identity") from None
    if not isinstance(values, list) or len(values) != 1 or values[0].get("name") != release:
        raise LifecycleError("exact Helm release identity was not found")
    chart = values[0].get("chart")
    if not isinstance(chart, str) or not chart.endswith("-" + chart_version):
        raise LifecycleError("live Helm chart version does not match the declared identity")
    if values[0].get("status") != "deployed":
        raise LifecycleError("Helm release is not deployed")
    return {
        "namespace": namespace,
        "release": release,
        "chart": chart,
        "status": "deployed",
    }


def deployment_snapshot_value(value: dict[str, Any], deployment: str) -> dict[str, Any]:
    metadata = value.get("metadata", {})
    spec = value.get("spec", {})
    status = value.get("status", {})
    template = spec.get("template", {})
    if not isinstance(template, dict) or not template:
        raise LifecycleError("Deployment has no Pod template identity")
    containers = template.get("spec", {}).get("containers", [])
    return {
        "name": deployment,
        "generation": metadata.get("generation"),
        "observed_generation": status.get("observedGeneration"),
        "revision": metadata.get("annotations", {}).get("deployment.kubernetes.io/revision"),
        "desired": spec.get("replicas", 1),
        "ready": status.get("readyReplicas", 0),
        "updated": status.get("updatedReplicas", 0),
        "available": status.get("availableReplicas", 0),
        "images": [item.get("image") for item in containers if isinstance(item, dict)],
        "pod_template_sha256": value_sha256(template),
    }


def deployment_snapshot(kubectl: Kubectl, deployment: str, *, require_ready: bool = True, api_one: bool = False) -> dict[str, Any]:
    value = kubectl.get("deployment", deployment)
    if kubectl.dry_run:
        return {"name": deployment, "dry_run": True}
    snapshot = deployment_snapshot_value(value, deployment)
    if require_ready:
        assert_ready(snapshot, api_one=api_one)
    return snapshot


def workload_snapshot(kubectl: Kubectl, kind: str, resource_name: str) -> dict[str, Any]:
    if kind == "deployment":
        return deployment_snapshot(kubectl, resource_name)
    value = kubectl.get(kind, resource_name)
    if kubectl.dry_run:
        return {"kind": kind, "name": resource_name, "dry_run": True}
    status = value.get("status", {})
    snapshot = {
        "kind": kind,
        "name": resource_name,
        "generation": value.get("metadata", {}).get("generation"),
        "observed_generation": status.get("observedGeneration"),
        "revision": status.get("updateRevision"),
        "desired": value.get("spec", {}).get("replicas", 1),
        "ready": status.get("readyReplicas", 0),
        "updated": status.get("updatedReplicas", 0),
        "available": status.get("availableReplicas", status.get("readyReplicas", 0)),
    }
    assert_ready(snapshot)
    return snapshot


def hpa_snapshot(
    kubectl: Kubectl,
    hpa_name: str,
    queue_deployment: str,
    expected_min: int,
    expected_max: int,
    expected_cpu: int,
) -> dict[str, Any]:
    value = kubectl.get("hpa", hpa_name)
    if kubectl.dry_run:
        return {"name": hpa_name, "dry_run": True}
    spec = value.get("spec", {})
    target = spec.get("scaleTargetRef", {})
    if target.get("kind") != "Deployment" or target.get("name") != queue_deployment:
        raise LifecycleError("HPA does not target the selected queue Deployment")
    status = value.get("status", {})
    if spec.get("minReplicas", 1) != expected_min or spec.get("maxReplicas") != expected_max:
        raise LifecycleError("HPA replica bounds do not match the expected configuration")
    cpu_metrics = [
        metric
        for metric in spec.get("metrics", [])
        if isinstance(metric, dict)
        and metric.get("type") == "Resource"
        and metric.get("resource", {}).get("name") == "cpu"
    ]
    if len(cpu_metrics) != 1:
        raise LifecycleError("HPA must contain exactly one CPU resource metric")
    cpu_target = cpu_metrics[0].get("resource", {}).get("target", {}).get("averageUtilization")
    if cpu_target != expected_cpu:
        raise LifecycleError("HPA CPU target does not match the expected configuration")
    scale_down = spec.get("behavior", {}).get("scaleDown", {})
    policies = scale_down.get("policies", [])
    expected_policy = {"type": "Pods", "value": 1, "periodSeconds": 60}
    if (
        scale_down.get("stabilizationWindowSeconds") != 300
        or scale_down.get("selectPolicy") != "Min"
        or policies != [expected_policy]
    ):
        raise LifecycleError("HPA scale-down behavior does not match the safe rollout policy")
    current = status.get("currentReplicas")
    desired = status.get("desiredReplicas")
    if not all(isinstance(item, int) and expected_min <= item <= expected_max for item in (current, desired)):
        raise LifecycleError("HPA replica status is unavailable or outside the configured bounds")
    conditions = {
        item.get("type"): item.get("status")
        for item in status.get("conditions", [])
        if isinstance(item, dict)
    }
    if conditions.get("AbleToScale") != "True" or conditions.get("ScalingActive") != "True":
        raise LifecycleError("HPA is not able to scale with an active metric")
    return {
        "name": hpa_name,
        "min": spec.get("minReplicas", 1),
        "max": spec.get("maxReplicas"),
        "current": current,
        "desired": desired,
        "cpu_target_utilization": cpu_target,
        "scale_down": {
            "stabilization_window_seconds": 300,
            "select_policy": "Min",
            "policies": policies,
        },
        "conditions": [
            {
                "type": condition.get("type"),
                "status": condition.get("status"),
                "reason": condition.get("reason"),
            }
            for condition in status.get("conditions", [])
            if isinstance(condition, dict)
        ],
    }


def read_scenario(required: bool) -> dict[str, Any] | None:
    if not required:
        return None
    try:
        value = json.load(sys.stdin)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise LifecycleError("stdin must contain one valid product scenario") from None
    if not isinstance(value, dict) or not value.get("graph_id") or not value.get("cases"):
        raise LifecycleError("product scenario needs graph_id and non-empty cases")
    return value


def cleanup_scenario(scenario: dict[str, Any]) -> dict[str, Any]:
    """Return an in-memory copy that guarantees ordinary test threads are deleted."""
    value = json.loads(json.dumps(scenario, separators=(",", ":")))
    value["cleanup_threads"] = True
    for case in value.get("cases", []):
        if isinstance(case, dict):
            case["cleanup"] = True
    if isinstance(value.get("load_case"), dict):
        value["load_case"]["cleanup"] = True
    return value


def protocol_helper_timeout(scenario: dict[str, Any], phase_timeout: int, request_timeout: int) -> int:
    """Bound the sequential sync/queued/stream work for every scenario case."""
    total = 30
    for case in scenario.get("cases", []):
        if not isinstance(case, dict):
            raise LifecycleError("product scenario cases must be objects")
        modes = case.get("run_modes", ["sync", "queued", "stream"])
        if not isinstance(modes, list) or not modes or set(modes) - {"sync", "queued", "stream"}:
            raise LifecycleError("scenario run_modes may contain sync, queued, and stream")
        for mode in modes:
            # Every submission can consume the request timeout. A queued run can
            # then consume the complete run/phase timeout while it is polled.
            total += request_timeout
            if mode == "queued":
                total += phase_timeout
    return total


def run_helper(command: list[str], scenario: dict[str, Any], timeout: int) -> dict[str, Any]:
    environment = os.environ.copy()
    try:
        completed = subprocess.run(
            [sys.executable, str(RUNTIME_HELPER), *command],
            input=json.dumps(scenario, separators=(",", ":")),
            capture_output=True,
            text=True,
            timeout=timeout,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError):
        raise LifecycleError("runtime qualification helper failed") from None
    if completed.returncode != 0:
        raise LifecycleError("runtime qualification phase failed; sensitive details withheld")
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError:
        raise LifecycleError("runtime qualification helper returned invalid evidence") from None
    if not isinstance(value, dict) or value.get("result") != "PASS":
        raise LifecycleError("runtime qualification helper did not report PASS")
    return value


def validate_load_scale_evidence(result: dict[str, Any], expectation: str) -> str:
    """Classify HPA evidence without treating an observation-only run as acceptance."""
    observation = result.get("scale_observation")
    if expectation == "required":
        if observation != "scaled":
            raise LifecycleError("required HPA scale-up was not present in product-load evidence")
        return "PASS"
    if expectation == "none":
        if observation != "no_cpu_scale_observed":
            raise LifecycleError("product load scaled although scale expectation was none")
        return "NOT_APPLICABLE"
    if expectation == "observe":
        return "OBSERVATION_ONLY_NOT_HPA_ACCEPTANCE"
    raise LifecycleError("unsupported product-load scale expectation")


def validate_upgrade_transition(
    before: dict[str, Any],
    after: dict[str, Any],
    expected_api_template_sha256: str,
    expected_queue_template_sha256: str,
) -> None:
    """Bind an installer rollout to exact intended post-upgrade workload identities."""
    for role, expected in (
        ("api", expected_api_template_sha256),
        ("queue", expected_queue_template_sha256),
    ):
        before_workload = before.get(role, {})
        after_workload = after.get(role, {})
        if before_workload.get("revision") == after_workload.get("revision"):
            raise LifecycleError(f"supported upgrade did not advance the {role.upper()} Deployment revision")
        old_identity = before_workload.get("pod_template_sha256")
        new_identity = after_workload.get("pod_template_sha256")
        if not old_identity or old_identity == new_identity:
            raise LifecycleError(f"supported upgrade did not change the {role.upper()} Pod template identity")
        if new_identity != expected:
            raise LifecycleError(f"post-upgrade {role.upper()} Pod template identity did not match the declared value")
    if any(
        before.get("hpa", {}).get(key) != after.get("hpa", {}).get(key)
        for key in ("min", "max", "cpu_target_utilization", "scale_down")
    ):
        raise LifecycleError("supported upgrade changed the verified HPA policy")


def run_installer(installer: str, config: str, timeout: int) -> None:
    installer_path = pathlib.Path(installer)
    config_path = pathlib.Path(config)
    if not installer_path.is_file() or not os.access(installer_path, os.X_OK):
        raise LifecycleError("installer must be an executable file")
    if not config_path.is_file() or not os.access(config_path, os.R_OK):
        raise LifecycleError("upgrade config must be a readable file")
    environment = os.environ.copy()
    environment.update({"AUTO_APPROVE": "true", "CONFIG_FILE": str(config_path)})
    try:
        subprocess.run(
            [str(installer_path), "install", "--silent"],
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError):
        raise LifecycleError("supported installer upgrade failed; output withheld") from None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--api-deployment", required=True)
    parser.add_argument("--queue-deployment", required=True)
    parser.add_argument("--hpa", required=True)
    parser.add_argument("--hpa-min-replicas", type=int, required=True)
    parser.add_argument("--hpa-max-replicas", type=int, required=True)
    parser.add_argument("--hpa-cpu-target", type=int, required=True)
    parser.add_argument("--expected-context", required=True)
    parser.add_argument("--namespace-uid", required=True)
    parser.add_argument("--operator-namespace", required=True)
    parser.add_argument("--operator-deployment", required=True)
    parser.add_argument("--operator-image", required=True)
    parser.add_argument("--operator-image-digest", required=True)
    parser.add_argument("--agent-image", required=True)
    parser.add_argument("--agent-image-digest", required=True)
    parser.add_argument("--chart-version", required=True)
    parser.add_argument("--chart-sha256", required=True)
    parser.add_argument("--helm-release", required=True)
    parser.add_argument("--helm-namespace", required=True)
    parser.add_argument("--helm", default=os.environ.get("HELM", "helm"))
    parser.add_argument("--runtime-version", required=True)
    parser.add_argument("--graph-id", required=True)
    parser.add_argument("--run-protocol", action="store_true")
    parser.add_argument("--run-load", action="store_true")
    parser.add_argument("--restart-api", action="store_true")
    parser.add_argument("--restart-queue", action="store_true")
    parser.add_argument("--postgres-workload")
    parser.add_argument("--redis-workload")
    parser.add_argument("--upgrade-config")
    parser.add_argument("--post-upgrade-api-template-sha256")
    parser.add_argument("--post-upgrade-queue-template-sha256")
    parser.add_argument("--api-service")
    parser.add_argument("--api-service-port", type=int, default=2024)
    parser.add_argument(
        "--installer",
        default=str(pathlib.Path(__file__).parents[1] / "tools" / "cluster_setup" / "k0s_cluster_with_stack.sh"),
    )
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument(
        "--load-scale-expectation",
        choices=("required", "observe", "none"),
        default="required",
        help="required by default; 'observe' produces observation-only evidence, not HPA acceptance",
    )
    parser.add_argument("--phase-timeout", type=int, default=600)
    parser.add_argument("--request-timeout", type=int, default=180)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--kubectl", default=os.environ.get("KUBECTL", "kubectl"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    access: StableLASAccess | None = None
    try:
        namespace = name(args.namespace, "namespace")
        api = name(args.api_deployment, "API Deployment")
        queue = name(args.queue_deployment, "queue Deployment")
        hpa = name(args.hpa, "HPA")
        operator_namespace = name(args.operator_namespace, "operator namespace")
        operator_deployment = name(args.operator_deployment, "operator Deployment")
        helm_namespace = name(args.helm_namespace, "Helm namespace")
        helm_release = name(args.helm_release, "Helm release")
        require_digest(args.operator_image_digest, "operator image digest")
        require_digest(args.agent_image_digest, "agent image digest")
        require_sha256_hex(args.chart_sha256, "chart sha256")
        safe_text(args.operator_image, "operator image")
        safe_text(args.agent_image, "agent image")
        safe_text(args.chart_version, "chart version")
        safe_text(args.runtime_version, "runtime version")
        safe_text(args.graph_id, "graph ID")
        safe_text(args.expected_context, "expected Kubernetes context")
        safe_text(args.namespace_uid, "namespace UID")
        if not 1 <= args.workers <= 8:
            raise LifecycleError("workers must be between 1 and 8")
        if not 30 <= args.phase_timeout <= 900:
            raise LifecycleError("phase-timeout must be between 30 and 900 seconds")
        if not 1 <= args.request_timeout <= args.phase_timeout:
            raise LifecycleError("request-timeout must be positive and no greater than phase-timeout")
        if not 1 <= args.hpa_min_replicas <= args.hpa_max_replicas:
            raise LifecycleError("HPA replica bounds must be positive and ordered")
        if not 1 <= args.hpa_cpu_target <= 100:
            raise LifecycleError("HPA CPU target must be between 1 and 100")
        if not 1 <= args.api_service_port <= 65535:
            raise LifecycleError("API Service port must be between 1 and 65535")

        if args.upgrade_config:
            if not args.post_upgrade_api_template_sha256 or not args.post_upgrade_queue_template_sha256:
                raise LifecycleError(
                    "--upgrade-config requires exact post-upgrade API and queue Pod template sha256 values"
                )
            require_sha256_hex(args.post_upgrade_api_template_sha256, "post-upgrade API Pod template sha256")
            require_sha256_hex(args.post_upgrade_queue_template_sha256, "post-upgrade queue Pod template sha256")

        selected_mutation = any(
            (
                args.run_protocol,
                args.run_load,
                args.restart_api,
                args.restart_queue,
                args.postgres_workload,
                args.redis_workload,
                args.upgrade_config,
            )
        )
        if selected_mutation and not args.dry_run and os.environ.get("LAS_LIFECYCLE_MUTATIONS_CONFIRMED") != "true":
            raise LifecycleError("set LAS_LIFECYCLE_MUTATIONS_CONFIRMED=true for selected mutation phases")
        if (args.run_protocol or args.run_load) and not args.dry_run:
            if os.environ.get("LAS_DISPOSABLE_CLUSTER_CONFIRMED") != "true":
                raise LifecycleError(
                    "set LAS_DISPOSABLE_CLUSTER_CONFIRMED=true for live product state creation"
                )

        scenario = read_scenario(args.run_protocol or args.run_load)
        if scenario is not None and scenario.get("graph_id") != args.graph_id:
            raise LifecycleError("scenario graph_id does not match the recorded graph identity")
        if scenario is not None:
            scenario = cleanup_scenario(scenario)
            if not args.api_service:
                raise LifecycleError(
                    "--api-service is required for protocol/load qualification so traffic uses the verified cluster"
                )
        if args.run_load and scenario is not None:
            load_case = scenario.get("load_case")
            if not isinstance(load_case, dict):
                raise LifecycleError("--run-load requires an explicit load_case in the scenario")
            if load_case.get("expected_outcome", "success") != "success":
                raise LifecycleError("load_case must expect a successful product run")

        kubectl = Kubectl(namespace, args.kubectl, args.phase_timeout, args.dry_run)
        actual_context = kubectl.current_context()
        namespace_object = kubectl.get_namespace()
        actual_namespace_uid = namespace_object.get("metadata", {}).get("uid") if not args.dry_run else ""
        if not args.dry_run and actual_context != args.expected_context:
            raise LifecycleError("current Kubernetes context does not match --expected-context")
        if not args.dry_run and actual_namespace_uid != args.namespace_uid:
            raise LifecycleError("namespace UID does not match --namespace-uid")

        access = StableLASAccess(
            kubectl,
            args.api_service,
            args.api_service_port,
            args.phase_timeout,
            args.dry_run,
        ) if scenario is not None else None
        if access is not None:
            access.refresh()

        def hpa_state() -> dict[str, Any]:
            return hpa_snapshot(
                kubectl,
                hpa,
                queue,
                args.hpa_min_replicas,
                args.hpa_max_replicas,
                args.hpa_cpu_target,
            )

        def stack_snapshot() -> dict[str, Any]:
            snapshot = {
                "api": deployment_snapshot(kubectl, api, api_one=True),
                "queue": deployment_snapshot(kubectl, queue),
                "hpa": hpa_state(),
            }
            if not args.dry_run and (
                snapshot["queue"].get("desired") != snapshot["hpa"].get("current")
                or snapshot["queue"].get("desired") != snapshot["hpa"].get("desired")
            ):
                raise LifecycleError("queue Deployment and HPA replica status are not stable")
            return snapshot

        def live_identity() -> dict[str, Any]:
            return {
                "operator": deployment_image_identity(
                    kubectl,
                    operator_namespace,
                    operator_deployment,
                    args.operator_image,
                    args.operator_image_digest,
                ),
                "api": deployment_image_identity(
                    kubectl,
                    namespace,
                    api,
                    args.agent_image,
                    args.agent_image_digest,
                    api_one=True,
                ),
                "queue": deployment_image_identity(
                    kubectl,
                    namespace,
                    queue,
                    args.agent_image,
                    args.agent_image_digest,
                ),
                "helm": helm_release_identity(
                    args.helm,
                    helm_namespace,
                    helm_release,
                    args.chart_version,
                    args.phase_timeout,
                    args.dry_run,
                ),
            }

        before_stack = stack_snapshot()
        evidence: dict[str, Any] = {
            "result": "PASS",
            "identity": {
                "declared": {
                    "operator_image": args.operator_image,
                    "operator_image_digest": args.operator_image_digest,
                    "agent_image": args.agent_image,
                    "agent_image_digest": args.agent_image_digest,
                    "chart_version": args.chart_version,
                    "chart_sha256": args.chart_sha256,
                    "runtime_version": args.runtime_version,
                    "graph_id": args.graph_id,
                },
                "chart_archive_digest_scope": "declared embedded archive; live release version is independently verified",
                "kubernetes": {
                    "expected_context": args.expected_context,
                    "namespace": namespace,
                    "namespace_uid": args.namespace_uid,
                },
            },
            "external_gates": {
                "MPR-131": "KNOWN_FAIL",
                "MPR-44_EXTERNAL_SLIM_EDGE": "PASS_ON_RECORDED_IMMUTABLE_DIGESTS",
                "INSTALLED_AITK_CALLER_ORIGIN": "NOT_RUN",
                "MPR-48": "REQUIRED_FOR_TIMEOUT_CANCELLATION_ACCEPTANCE",
                "in_flight_replacement": "NOT_CLAIMED_BY_THIS_ORCHESTRATOR",
                "host_podman_dependency_recovery": "NOT_RUN; ONLY EXPLICIT KUBERNETES WORKLOAD REFERENCES ARE SUPPORTED",
            },
            "before": before_stack,
            "phases": [],
        }

        def protocol_phase(phase_name: str) -> dict[str, Any]:
            started = time.monotonic()
            result = run_helper(
                [
                    "protocol",
                    "--request-timeout", str(args.request_timeout),
                    "--run-timeout", str(args.phase_timeout),
                ],
                scenario,
                protocol_helper_timeout(scenario, args.phase_timeout, args.request_timeout),
            )
            return {"name": phase_name, "duration_seconds": round(time.monotonic() - started, 3), "evidence": result}

        if args.run_protocol and scenario is not None and not args.dry_run:
            evidence["phases"].append(protocol_phase("product_protocol_before_lifecycle"))

        if args.run_load and scenario is not None and not args.dry_run:
            started = time.monotonic()
            load_case = scenario.get("load_case")
            # The scenario was validated before any cluster access.
            assert isinstance(load_case, dict)
            load_scenario = {
                "graph_id": scenario["graph_id"],
                "case": load_case,
                "sensitive_values": scenario.get("sensitive_values", []),
                "cleanup_threads": True,
            }
            result = run_helper(
                [
                    "product-load",
                    "--namespace", namespace,
                    "--hpa", hpa,
                    "--deployment", queue,
                    "--api-deployment", api,
                    "--workers", str(args.workers),
                    "--scale-expectation", args.load_scale_expectation,
                    "--timeout", str(args.phase_timeout),
                    "--request-timeout", str(args.request_timeout),
                ],
                load_scenario,
                args.phase_timeout + args.request_timeout,
            )
            evidence["phases"].append(
                {
                    "name": "representative_load",
                    "duration_seconds": round(time.monotonic() - started, 3),
                    "scale_expectation": args.load_scale_expectation,
                    "hpa_scale_acceptance": validate_load_scale_evidence(
                        result, args.load_scale_expectation
                    ),
                    "evidence": result,
                }
            )

        if args.upgrade_config:
            if args.dry_run:
                evidence["phases"].append({"name": "supported_installer_upgrade", "dry_run": True})
            else:
                before = stack_snapshot()
                run_installer(args.installer, args.upgrade_config, args.phase_timeout)
                kubectl.rollout_status(api)
                kubectl.rollout_status(queue)
                if access is not None:
                    access.refresh()
                after = stack_snapshot()
                validate_upgrade_transition(
                    before,
                    after,
                    args.post_upgrade_api_template_sha256,
                    args.post_upgrade_queue_template_sha256,
                )
                phase = {"name": "supported_installer_upgrade", "before": before, "after": after}
                if args.run_protocol and scenario is not None:
                    phase["verification"] = protocol_phase("post_upgrade_product_protocol")
                evidence["phases"].append(phase)

        for phase_name, kind, resource_name in (
            ("restart_api", "deployment", api if args.restart_api else None),
            ("restart_queue", "deployment", queue if args.restart_queue else None),
        ):
            if resource_name:
                before = workload_snapshot(kubectl, kind, resource_name)
                kubectl.restart(kind, resource_name)
                if phase_name == "restart_api" and access is not None:
                    access.refresh()
                after = workload_snapshot(kubectl, kind, resource_name)
                if not args.dry_run and before.get("revision") == after.get("revision"):
                    raise LifecycleError(f"{phase_name} did not advance the workload revision")
                phase = {"name": phase_name, "before": before, "after": after}
                if args.run_protocol and scenario is not None and not args.dry_run:
                    phase["verification"] = protocol_phase(f"post_{phase_name}_product_protocol")
                evidence["phases"].append(phase)

        for phase_name, reference in (
            ("recover_postgres", args.postgres_workload),
            ("recover_redis", args.redis_workload),
        ):
            if reference:
                kind, resource_name = workload_ref(reference, phase_name)
                before = workload_snapshot(kubectl, kind, resource_name)
                kubectl.restart(kind, resource_name)
                after = workload_snapshot(kubectl, kind, resource_name)
                if not args.dry_run and before.get("revision") == after.get("revision"):
                    raise LifecycleError(f"{phase_name} did not advance the workload revision")
                phase = {"name": phase_name, "before": before, "after": after}
                if args.run_protocol and scenario is not None and not args.dry_run:
                    phase["verification"] = protocol_phase(f"post_{phase_name}_product_protocol")
                evidence["phases"].append(phase)

        evidence["after"] = stack_snapshot()
        evidence["identity"]["verified_live"] = live_identity()
        if args.dry_run:
            evidence["dry_run"] = True
            evidence["planned_kubectl"] = kubectl.planned
        print(json.dumps(evidence, sort_keys=True))
        return 0
    except LifecycleError as exc:
        print(json.dumps({"result": "FAIL", "reason": str(exc)}, sort_keys=True), file=sys.stderr)
        return 1
    finally:
        if access is not None:
            access.close()


if __name__ == "__main__":
    raise SystemExit(main())
