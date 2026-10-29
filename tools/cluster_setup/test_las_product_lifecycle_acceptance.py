"""Offline safety tests for the Launchpad lifecycle qualification helper."""

import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch


SCRIPT = pathlib.Path(__file__).parents[2] / "scripts" / "las-product-lifecycle-acceptance.py"
ROTATION_SCRIPT = pathlib.Path(__file__).parents[2] / "scripts" / "las-credential-rotation-acceptance.sh"
SPEC = importlib.util.spec_from_file_location("las_product_lifecycle_acceptance", SCRIPT)
lifecycle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lifecycle)


class LifecycleAcceptanceTests(unittest.TestCase):
    def test_exact_resource_names_are_required(self):
        for value in ("", "UpperCase", "name/extra", "*", "../deployment"):
            with self.subTest(value=value), self.assertRaises(lifecycle.LifecycleError):
                lifecycle.name(value, "resource")
        self.assertEqual(lifecycle.name("launchpad-queue", "resource"), "launchpad-queue")

    def test_dependency_reference_allows_only_rollout_workloads(self):
        self.assertEqual(
            lifecycle.workload_ref("deployment/postgres", "database"),
            ("deployment", "postgres"),
        )
        self.assertEqual(
            lifecycle.workload_ref("StatefulSet/redis", "cache"),
            ("statefulset", "redis"),
        )
        for value in ("pod/postgres", "deployment", "deployment/Bad_Name"):
            with self.subTest(value=value), self.assertRaises(lifecycle.LifecycleError):
                lifecycle.workload_ref(value, "dependency")

    def test_resolved_digest_is_mandatory(self):
        digest = "sha256:" + "a" * 64
        self.assertEqual(lifecycle.require_digest(digest, "image"), digest)
        for value in ("latest", "sha256:abc", "sha256:" + "G" * 64):
            with self.subTest(value=value), self.assertRaises(lifecycle.LifecycleError):
                lifecycle.require_digest(value, "image")

    def test_cleanup_scenario_forces_thread_cleanup_without_mutating_input(self):
        original = {
            "graph_id": "agent",
            "cleanup_threads": False,
            "cases": [{"name": "positive", "cleanup": False}],
            "load_case": {"name": "load", "cleanup": False},
        }
        cleaned = lifecycle.cleanup_scenario(original)
        self.assertTrue(cleaned["cleanup_threads"])
        self.assertTrue(cleaned["cases"][0]["cleanup"])
        self.assertTrue(cleaned["load_case"]["cleanup"])
        self.assertFalse(original["cleanup_threads"])

    def test_upgrade_requires_exact_changed_pod_template_identities(self):
        unchanged = "a" * 64
        changed_api = "b" * 64
        changed_queue = "c" * 64
        hpa = {
            "min": 1,
            "max": 3,
            "cpu_target_utilization": 80,
            "scale_down": {"stabilization_window_seconds": 300},
        }
        before = {
            "api": {"revision": "1", "pod_template_sha256": unchanged},
            "queue": {"revision": "1", "pod_template_sha256": unchanged},
            "hpa": hpa,
        }
        after = {
            "api": {"revision": "2", "pod_template_sha256": changed_api},
            "queue": {"revision": "2", "pod_template_sha256": changed_queue},
            "hpa": dict(hpa),
        }
        lifecycle.validate_upgrade_transition(before, after, changed_api, changed_queue)
        revision_only = json.loads(json.dumps(after))
        revision_only["api"]["pod_template_sha256"] = unchanged
        with self.assertRaisesRegex(lifecycle.LifecycleError, "did not change the API"):
            lifecycle.validate_upgrade_transition(before, revision_only, unchanged, changed_queue)
        with self.assertRaisesRegex(lifecycle.LifecycleError, "did not match"):
            lifecycle.validate_upgrade_transition(before, after, "d" * 64, changed_queue)

    def test_deployment_snapshot_records_deterministic_template_identity(self):
        deployment = {
            "metadata": {"generation": 1, "annotations": {"deployment.kubernetes.io/revision": "1"}},
            "spec": {
                "replicas": 1,
                "template": {
                    "metadata": {"labels": {"app": "api"}},
                    "spec": {"containers": [{"name": "api", "image": "registry/api:test"}]},
                },
            },
            "status": {"observedGeneration": 1, "readyReplicas": 1, "updatedReplicas": 1, "availableReplicas": 1},
        }
        first = lifecycle.deployment_snapshot_value(deployment, "api")
        second = lifecycle.deployment_snapshot_value(json.loads(json.dumps(deployment)), "api")
        self.assertEqual(first["pod_template_sha256"], second["pod_template_sha256"])
        deployment["spec"]["template"]["spec"]["containers"][0]["image"] = "registry/api:new"
        self.assertNotEqual(
            first["pod_template_sha256"],
            lifecycle.deployment_snapshot_value(deployment, "api")["pod_template_sha256"],
        )

    def test_managed_service_access_is_required(self):
        client = lifecycle.Kubectl("ai-platform", "kubectl", 300, True)
        with patch.dict("os.environ", {"LAS_BASE_URL": "http://127.0.0.1:2024"}):
            with self.assertRaisesRegex(lifecycle.LifecycleError, "requires --api-service"):
                lifecycle.StableLASAccess(client, None, 2024, 300, True)

    def test_protocol_timeout_accounts_for_every_mode_and_case(self):
        scenario = {
            "cases": [
                {"run_modes": ["sync", "queued", "stream"]},
                {"run_modes": ["queued"]},
            ]
        }
        # 30 seconds overhead + four submissions + two queued-run polling windows.
        self.assertEqual(lifecycle.protocol_helper_timeout(scenario, 600, 180), 1950)

    def test_hpa_snapshot_verifies_cpu_bounds_and_safe_scale_down(self):
        value = {
            "spec": {
                "minReplicas": 1,
                "maxReplicas": 3,
                "scaleTargetRef": {"kind": "Deployment", "name": "launchpad-queue"},
                "metrics": [
                    {
                        "type": "Resource",
                        "resource": {
                            "name": "cpu",
                            "target": {"type": "Utilization", "averageUtilization": 80},
                        },
                    }
                ],
                "behavior": {
                    "scaleDown": {
                        "stabilizationWindowSeconds": 300,
                        "selectPolicy": "Min",
                        "policies": [{"type": "Pods", "value": 1, "periodSeconds": 60}],
                    }
                },
            },
            "status": {
                "currentReplicas": 1,
                "desiredReplicas": 1,
                "conditions": [
                    {"type": "AbleToScale", "status": "True"},
                    {"type": "ScalingActive", "status": "True"},
                ],
            },
        }
        client = SimpleNamespace(dry_run=False, get=lambda kind, resource_name: value)
        snapshot = lifecycle.hpa_snapshot(client, "launchpad-queue", "launchpad-queue", 1, 3, 80)
        self.assertEqual(snapshot["cpu_target_utilization"], 80)
        value["spec"]["metrics"][0]["resource"]["target"]["averageUtilization"] = 70
        with self.assertRaisesRegex(lifecycle.LifecycleError, "CPU target"):
            lifecycle.hpa_snapshot(client, "launchpad-queue", "launchpad-queue", 1, 3, 80)

    def test_deployment_identity_requires_live_digest_and_ready_pods(self):
        digest = "sha256:" + "a" * 64
        deployment = {
            "metadata": {
                "generation": 4,
                "annotations": {"deployment.kubernetes.io/revision": "7"},
            },
            "spec": {
                "replicas": 1,
                "selector": {"matchLabels": {"app": "launchpad-api"}},
                "template": {
                    "spec": {"containers": [{"name": "api", "image": "registry/launchpad:test"}]}
                },
            },
            "status": {
                "observedGeneration": 4,
                "readyReplicas": 1,
                "updatedReplicas": 1,
                "availableReplicas": 1,
            },
        }
        pod = {
            "status": {
                "containerStatuses": [
                    {"name": "api", "imageID": "docker-pullable://registry/launchpad@" + digest}
                ]
            }
        }
        client = SimpleNamespace(
            dry_run=False,
            get_in_namespace=lambda namespace, kind, resource_name: deployment,
            list_pods=lambda namespace, selector: [pod],
        )
        result = lifecycle.deployment_image_identity(
            client,
            "ai-platform",
            "launchpad-api",
            "registry/launchpad:test",
            digest,
            api_one=True,
        )
        self.assertEqual(result["verified_pods"], 1)
        pod["status"]["containerStatuses"][0]["imageID"] = "docker-pullable://registry/launchpad@sha256:" + "b" * 64
        with self.assertRaisesRegex(lifecycle.LifecycleError, "digest"):
            lifecycle.deployment_image_identity(
                client,
                "ai-platform",
                "launchpad-api",
                "registry/launchpad:test",
                digest,
                api_one=True,
            )

    def test_dry_run_records_exact_commands_without_mutating(self):
        client = lifecycle.Kubectl("ai-platform", "kubectl", 300, True)
        client.get("deployment", "launchpad-api")
        client.restart("deployment", "launchpad-queue")
        self.assertEqual(
            client.planned,
            [
                ["-n", "ai-platform", "get", "deployment", "launchpad-api", "-o", "json"],
                ["-n", "ai-platform", "rollout", "restart", "deployment/launchpad-queue"],
                ["-n", "ai-platform", "rollout", "status", "deployment/launchpad-queue", "--timeout=300s"],
            ],
        )

    def test_runtime_failure_never_emits_helper_stderr(self):
        failed = SimpleNamespace(returncode=1, stdout="", stderr="provider-secret-value")
        with patch.object(lifecycle.subprocess, "run", return_value=failed):
            with self.assertRaisesRegex(lifecycle.LifecycleError, "sensitive details withheld") as raised:
                lifecycle.run_helper(["protocol"], {"graph_id": "agent", "cases": [{}]}, 60)
        self.assertNotIn("provider-secret-value", str(raised.exception))

    def test_runtime_helper_does_not_inject_disposable_confirmation(self):
        passed_environment = {}

        def complete(*args, **kwargs):
            passed_environment.update(kwargs["env"])
            return SimpleNamespace(returncode=0, stdout='{"result":"PASS"}', stderr="")

        with patch.dict(os.environ, {}, clear=True), patch.object(lifecycle.subprocess, "run", side_effect=complete):
            lifecycle.run_helper(["protocol"], {"graph_id": "agent", "cases": [{}]}, 60)
        self.assertNotIn("LAS_DISPOSABLE_CLUSTER_CONFIRMED", passed_environment)

    def test_load_scale_evidence_distinguishes_observation_from_acceptance(self):
        observed = {"result": "PASS", "scale_observation": "no_cpu_scale_observed"}
        self.assertEqual(
            lifecycle.validate_load_scale_evidence(observed, "observe"),
            "OBSERVATION_ONLY_NOT_HPA_ACCEPTANCE",
        )
        with self.assertRaisesRegex(lifecycle.LifecycleError, "required HPA scale-up"):
            lifecycle.validate_load_scale_evidence(observed, "required")
        self.assertEqual(
            lifecycle.validate_load_scale_evidence({"scale_observation": "scaled"}, "required"),
            "PASS",
        )

    def test_mutation_requires_explicit_confirmation(self):
        argv = self.base_argv() + ["--restart-api"]
        stderr = io.StringIO()
        with patch.object(sys, "argv", argv), patch.dict("os.environ", {}, clear=True), patch("sys.stderr", stderr):
            self.assertEqual(lifecycle.main(), 1)
        result = json.loads(stderr.getvalue())
        self.assertIn("LAS_LIFECYCLE_MUTATIONS_CONFIRMED", result["reason"])

    def test_live_product_state_requires_both_explicit_confirmations(self):
        argv = self.base_argv() + ["--run-load"]
        stderr = io.StringIO()
        environment = {"LAS_LIFECYCLE_MUTATIONS_CONFIRMED": "true"}
        with patch.object(sys, "argv", argv), patch.dict(os.environ, environment, clear=True), patch("sys.stderr", stderr):
            self.assertEqual(lifecycle.main(), 1)
        result = json.loads(stderr.getvalue())
        self.assertIn("LAS_DISPOSABLE_CLUSTER_CONFIRMED", result["reason"])

    def test_upgrade_cli_requires_expected_post_upgrade_identities(self):
        argv = self.base_argv() + ["--upgrade-config", str(SCRIPT), "--dry-run"]
        stderr = io.StringIO()
        with patch.object(sys, "argv", argv), patch("sys.stderr", stderr):
            self.assertEqual(lifecycle.main(), 1)
        result = json.loads(stderr.getvalue())
        self.assertIn("post-upgrade API and queue", result["reason"])

    def test_rotation_rejects_invalid_secret_name_and_service_port_before_cluster_access(self):
        base_environment = {
            "PATH": os.environ.get("PATH", ""),
            "LAS_DISPOSABLE_CLUSTER_CONFIRMED": "true",
            "LAS_INITIAL_CONFIG": str(ROTATION_SCRIPT),
            "LAS_ROTATED_CONFIG": str(ROTATION_SCRIPT),
            "LAS_NAMESPACE": "ai-platform",
            "LAS_SECRET_NAMES": "auth,postgres,redis",
            "LAS_API_DEPLOYMENT": "launchpad-api",
            "LAS_QUEUE_DEPLOYMENT": "launchpad-queue",
            "LAS_QUEUE_HPA": "launchpad-queue",
            "LAS_EXPECTED_KUBE_CONTEXT": "k0s",
            "LAS_EXPECTED_NAMESPACE_UID": "uid",
            "LAS_BASE_URL": "http://127.0.0.1:2024",
            "LAS_API_SERVICE": "launchpad-api",
            "LAS_OPERATOR_NAMESPACE": "operator-system",
            "LAS_OPERATOR_DEPLOYMENT": "operator",
            "LAS_OPERATOR_IMAGE": "registry/operator:test",
            "LAS_OPERATOR_IMAGE_DIGEST": "sha256:" + "a" * 64,
            "LAS_AGENT_SERVER_IMAGE": "registry/agent:test",
            "LAS_AGENT_SERVER_DIGEST": "sha256:" + "b" * 64,
            "LAS_CHART_VERSION": "0.3.5",
            "LAS_CHART_SHA256": "c" * 64,
        }
        invalid_secret = dict(base_environment, LAS_SECRET_NAMES="auth,Bad_Name,redis")
        result = subprocess.run(
            ["bash", str(ROTATION_SCRIPT)],
            input="",
            text=True,
            capture_output=True,
            env=invalid_secret,
            timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("Secret names", result.stderr)
        invalid_port = dict(base_environment, LAS_API_SERVICE_PORT="not-a-port")
        result = subprocess.run(
            ["bash", str(ROTATION_SCRIPT)],
            input="",
            text=True,
            capture_output=True,
            env=invalid_port,
            timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("LAS_API_SERVICE_PORT", result.stderr)

    def test_dry_run_reports_known_gates_and_selected_phases(self):
        argv = self.base_argv() + ["--restart-api", "--postgres-workload", "statefulset/postgres", "--dry-run"]
        stdout = io.StringIO()
        with patch.object(sys, "argv", argv), patch("sys.stdout", stdout):
            self.assertEqual(lifecycle.main(), 0)
        result = json.loads(stdout.getvalue())
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["external_gates"]["MPR-131"], "KNOWN_FAIL")
        self.assertEqual([phase["name"] for phase in result["phases"]], ["restart_api", "recover_postgres"])
        serialized = json.dumps(result)
        self.assertNotIn("secret", serialized.lower())

    @staticmethod
    def base_argv():
        digest = "sha256:" + "a" * 64
        return [
            str(SCRIPT),
            "--namespace", "ai-platform",
            "--api-deployment", "launchpad-api",
            "--queue-deployment", "launchpad-queue",
            "--hpa", "launchpad-queue",
            "--hpa-min-replicas", "1",
            "--hpa-max-replicas", "3",
            "--hpa-cpu-target", "80",
            "--expected-context", "k0s",
            "--namespace-uid", "11111111-2222-3333-4444-555555555555",
            "--operator-namespace", "splunk-ai-operator-system",
            "--operator-deployment", "splunk-ai-operator-controller-manager",
            "--operator-image", "registry/operator:test",
            "--operator-image-digest", digest,
            "--agent-image", "registry/launchpad:test",
            "--agent-image-digest", digest,
            "--chart-version", "0.3.5-splunk.2",
            "--chart-sha256", "a" * 64,
            "--helm-release", "launchpad",
            "--helm-namespace", "ai-platform",
            "--runtime-version", "0.4.21",
            "--graph-id", "agent",
        ]


if __name__ == "__main__":
    unittest.main()
