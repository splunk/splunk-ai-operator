"""Offline safety tests for the Launchpad lifecycle qualification helper."""

import importlib.util
import base64
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

    def test_dependency_binding_requires_exact_service_endpoint_and_workload_refs(self):
        encoded = base64.b64encode(
            b"postgresql://user:password@postgres.ai-platform.svc:5432/db"
        ).decode()
        objects = {
            ("statefulset", "postgres"): {
                "spec": {
                    "selector": {"matchLabels": {"app": "postgres"}},
                    "template": {"metadata": {"labels": {"app": "postgres"}}},
                }
            },
            ("service", "postgres"): {
                "metadata": {"uid": "service-uid"},
                "spec": {"selector": {"app": "postgres"}},
            },
            ("secret", "postgres-connection"): {
                "data": {"postgres_connection_url": encoded}
            },
        }
        deployment = {
            "spec": {
                "template": {
                    "spec": {
                        "containers": [{
                            "image": "registry/launchpad:test",
                            "env": [{
                                "valueFrom": {
                                    "secretKeyRef": {
                                        "name": "postgres-connection",
                                        "key": "postgres_connection_url",
                                    }
                                }
                            }]
                        }]
                    }
                }
            }
        }
        objects[("deployment", "api")] = deployment
        objects[("deployment", "queue")] = deployment

        class FakeKubectl:
            dry_run = False

            def get(self, kind, resource_name):
                return objects[(kind, resource_name)]

        result = lifecycle.dependency_binding(
            FakeKubectl(), "ai-platform", "statefulset", "postgres",
            "postgres", "service-uid", "postgres-connection",
            "postgres_connection_url", "api", "queue", "registry/launchpad:test",
        )
        self.assertTrue(result["endpoint_reference_bound"])

        objects[("service", "postgres")]["spec"]["selector"] = {"app": "unrelated"}
        with self.assertRaisesRegex(lifecycle.LifecycleError, "selector"):
            lifecycle.dependency_binding(
                FakeKubectl(), "ai-platform", "statefulset", "postgres",
                "postgres", "service-uid", "postgres-connection",
                "postgres_connection_url", "api", "queue", "registry/launchpad:test",
            )

        objects[("service", "postgres")]["spec"]["selector"] = {"app": "postgres"}
        objects[("statefulset", "postgres")]["spec"]["selector"]["matchExpressions"] = [
            {"key": "tier", "operator": "Exists"}
        ]
        with self.assertRaisesRegex(lifecycle.LifecycleError, "matchExpressions"):
            lifecycle.dependency_binding(
                FakeKubectl(), "ai-platform", "statefulset", "postgres",
                "postgres", "service-uid", "postgres-connection",
                "postgres_connection_url", "api", "queue", "registry/launchpad:test",
            )
        objects[("statefulset", "postgres")]["spec"]["selector"]["matchExpressions"] = []
        with self.assertRaisesRegex(lifecycle.LifecycleError, "matchExpressions"):
            lifecycle.dependency_binding(
                FakeKubectl(), "ai-platform", "statefulset", "postgres",
                "postgres", "service-uid", "postgres-connection",
                "postgres_connection_url", "api", "queue", "registry/launchpad:test",
            )
        del objects[("statefulset", "postgres")]["spec"]["selector"]["matchExpressions"]

        sidecar_only = json.loads(json.dumps(deployment))
        sidecar_only["spec"]["template"]["spec"]["containers"] = [
            {"image": "registry/launchpad:test"},
            {
                "image": "registry/sidecar:test",
                "envFrom": [{"secretRef": {"name": "postgres-connection"}}],
            },
        ]
        objects[("deployment", "api")] = sidecar_only
        with self.assertRaisesRegex(lifecycle.LifecycleError, "agent container"):
            lifecycle.dependency_binding(
                FakeKubectl(), "ai-platform", "statefulset", "postgres",
                "postgres", "service-uid", "postgres-connection",
                "postgres_connection_url", "api", "queue", "registry/launchpad:test",
            )

    def test_agent_secret_volume_requires_agent_mount_and_exact_exposed_key(self):
        pod_spec = {
            "volumes": [{
                "name": "connection",
                "secret": {
                    "secretName": "postgres-connection",
                    "items": [{"key": "other", "path": "other-url"}],
                },
            }]
        }
        container = {
            "image": "registry/launchpad:test",
            "volumeMounts": [{"name": "connection", "mountPath": "/connection"}],
        }
        self.assertFalse(
            lifecycle._agent_container_references_secret_key(
                pod_spec, container, "postgres-connection", "postgres_connection_url"
            )
        )

        pod_spec["volumes"][0]["secret"]["items"] = [{
            "key": "postgres_connection_url",
            "path": "database-url",
        }]
        container["volumeMounts"][0]["subPath"] = "other-url"
        self.assertFalse(
            lifecycle._agent_container_references_secret_key(
                pod_spec, container, "postgres-connection", "postgres_connection_url"
            )
        )
        container["volumeMounts"][0]["subPath"] = "database-url"
        self.assertTrue(
            lifecycle._agent_container_references_secret_key(
                pod_spec, container, "postgres-connection", "postgres_connection_url"
            )
        )

        container["volumeMounts"] = []
        self.assertFalse(
            lifecycle._agent_container_references_secret_key(
                pod_spec, container, "postgres-connection", "postgres_connection_url"
            )
        )

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

        for unsafe_url in (
            "http://user@127.0.0.1:2024",
            "http://127.0.0.1:2024/unexpected",
            "http://127.0.0.1:2024?target=other",
        ):
            with self.subTest(url=unsafe_url), patch.dict(
                "os.environ", {"LAS_BASE_URL": unsafe_url}, clear=True
            ), self.assertRaises(lifecycle.LifecycleError):
                lifecycle.StableLASAccess(client, "launchpad-api", 2024, 300, True)

    def test_helm_identity_binds_exact_chart_name_and_version(self):
        good = SimpleNamespace(
            stdout=json.dumps(
                [{"name": "launchpad", "chart": "langgraph-cloud-0.3.5", "status": "deployed"}]
            )
        )
        with patch.object(lifecycle.subprocess, "run", return_value=good):
            result = lifecycle.helm_release_identity(
                "helm", "ai-platform", "launchpad", "langgraph-cloud", "0.3.5", 30, False
            )
        self.assertEqual(result["chart"], "langgraph-cloud-0.3.5")
        wrong_name = SimpleNamespace(
            stdout=json.dumps(
                [{"name": "launchpad", "chart": "other-chart-0.3.5", "status": "deployed"}]
            )
        )
        with patch.object(lifecycle.subprocess, "run", return_value=wrong_name), self.assertRaisesRegex(
            lifecycle.LifecycleError, "chart version"
        ):
            lifecycle.helm_release_identity(
                "helm", "ai-platform", "launchpad", "langgraph-cloud", "0.3.5", 30, False
            )

    def test_upgrade_rechecks_cluster_scope_immediately_after_installer(self):
        source = SCRIPT.read_text(encoding="utf-8")
        installer_call = source.index("run_installer(args.installer")
        scope_check = source.index("verify_cluster_scope()", installer_call)
        rollout = source.index("kubectl.rollout_status(api)", installer_call)
        self.assertLess(scope_check, rollout)

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

    def test_api_service_identity_binds_uid_selector_and_endpoint_pods(self):
        digest = "sha256:" + "a" * 64
        deployment = {
            "spec": {
                "selector": {"matchLabels": {"app": "launchpad-api"}},
                "template": {
                    "spec": {
                        "containers": [{
                            "name": "api",
                            "image": "registry/launchpad:test",
                            "ports": [{"name": "http", "containerPort": 2024}],
                        }]
                    }
                },
            }
        }
        service = {
            "metadata": {"uid": "service-uid"},
            "spec": {
                "selector": {"app": "launchpad-api"},
                "ports": [{"port": 2024, "targetPort": "http"}],
            },
        }
        pod = {
            "metadata": {"name": "api-1", "uid": "pod-uid"},
            "status": {
                "containerStatuses": [{
                    "name": "api",
                    "imageID": f"registry/launchpad@{digest}",
                }]
            },
        }
        endpoint_slice = {
            "metadata": {
                "labels": {"kubernetes.io/service-name": "launchpad-api"},
                "ownerReferences": [{
                    "kind": "Service",
                    "name": "launchpad-api",
                    "uid": "service-uid",
                }],
            },
            "ports": [{"name": "http", "port": 2024}],
            "endpoints": [{
                "conditions": {"ready": True},
                "targetRef": {
                    "kind": "Pod",
                    "namespace": "ai-platform",
                    "name": "api-1",
                    "uid": "pod-uid",
                },
            }]
        }

        class FakeKubectl:
            dry_run = False

            def get_in_namespace(self, namespace, kind, resource_name):
                return service if kind == "service" else deployment

            def list_pods(self, namespace, selector):
                return [pod]

            def list_endpoint_slices(self, namespace, service_name):
                return [endpoint_slice]

        result = lifecycle.api_service_identity(
            FakeKubectl(), "ai-platform", "launchpad-api", "service-uid",
            2024, "api", "registry/launchpad:test", digest,
        )
        self.assertEqual(result["verified_endpoints"], 1)
        self.assertEqual(result["target_port"], 2024)

        endpoint_slice["endpoints"][0]["targetRef"]["uid"] = "other-pod"
        with self.assertRaisesRegex(lifecycle.LifecycleError, "did not match"):
            lifecycle.api_service_identity(
                FakeKubectl(), "ai-platform", "launchpad-api", "service-uid",
                2024, "api", "registry/launchpad:test", digest,
            )

        endpoint_slice["endpoints"][0]["targetRef"]["uid"] = "pod-uid"
        endpoint_slice["metadata"]["ownerReferences"][0]["uid"] = "replaced-service"
        with self.assertRaisesRegex(lifecycle.LifecycleError, "owned by"):
            lifecycle.api_service_identity(
                FakeKubectl(), "ai-platform", "launchpad-api", "service-uid",
                2024, "api", "registry/launchpad:test", digest,
            )

        endpoint_slice["metadata"]["ownerReferences"][0]["uid"] = "service-uid"
        pod["status"]["containerStatuses"][0]["imageID"] = (
            "registry/launchpad@sha256:" + "b" * 64
        )
        with self.assertRaisesRegex(lifecycle.LifecycleError, "attested image digest"):
            lifecycle.api_service_identity(
                FakeKubectl(), "ai-platform", "launchpad-api", "service-uid",
                2024, "api", "registry/launchpad:test", digest,
            )

        pod["status"]["containerStatuses"][0]["imageID"] = f"registry/launchpad@{digest}"
        service["spec"]["ports"][0]["targetPort"] = "sidecar"
        with self.assertRaisesRegex(lifecycle.LifecycleError, "targetPort"):
            lifecycle.api_service_identity(
                FakeKubectl(), "ai-platform", "launchpad-api", "service-uid",
                2024, "api", "registry/launchpad:test", digest,
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

        observation = SimpleNamespace(
            returncode=0,
            stdout='{"result":"OBSERVATION"}',
            stderr="",
        )
        with patch.object(lifecycle.subprocess, "run", return_value=observation):
            with self.assertRaisesRegex(lifecycle.LifecycleError, "expected result"):
                lifecycle.run_helper(["product-load"], {}, 60)
            self.assertEqual(
                lifecycle.run_helper(
                    ["product-load"], {}, 60, {"OBSERVATION"}
                )["result"],
                "OBSERVATION",
            )

    def test_load_scale_evidence_distinguishes_observation_from_acceptance(self):
        observed = {"result": "OBSERVATION", "scale_observation": "no_cpu_scale_observed"}
        self.assertEqual(
            lifecycle.validate_load_scale_evidence(observed, "observe"),
            "OBSERVATION_ONLY_NOT_HPA_ACCEPTANCE",
        )
        with self.assertRaisesRegex(lifecycle.LifecycleError, "required HPA scale-up"):
            lifecycle.validate_load_scale_evidence(observed, "required")
        self.assertEqual(
            lifecycle.validate_load_scale_evidence(
                {"result": "OBSERVATION", "scale_observation": "cpu_scale_pass"},
                "required",
            ),
            "PASS",
        )

    def test_product_load_helper_receives_the_attested_kube_context(self):
        command = lifecycle.product_load_helper_args(
            "ai-platform",
            "launchpad-queue",
            "launchpad-queue",
            "launchpad-api",
            "approved-k0s-context",
            4,
            "required",
            600,
            180,
        )
        self.assertEqual(
            command[command.index("--expected-context") + 1],
            "approved-k0s-context",
        )

    def test_mutation_requires_explicit_confirmation(self):
        argv = self.base_argv() + ["--restart-api", "--run-protocol"]
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
        self.assertIn("pre-upgrade image/digest", result["reason"])

    def test_live_lifecycle_phase_requires_product_protocol(self):
        argv = self.base_argv() + ["--restart-api"]
        stderr = io.StringIO()
        environment = {"LAS_LIFECYCLE_MUTATIONS_CONFIRMED": "true"}
        with patch.object(sys, "argv", argv), patch.dict(
            os.environ, environment, clear=True
        ), patch("sys.stderr", stderr):
            self.assertEqual(lifecycle.main(), 1)
        result = json.loads(stderr.getvalue())
        self.assertIn("requires --run-protocol", result["reason"])

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
            "LAS_API_SERVICE_UID": "service-uid",
            "LAS_OPERATOR_NAMESPACE": "operator-system",
            "LAS_OPERATOR_DEPLOYMENT": "operator",
            "LAS_OPERATOR_IMAGE": "registry/operator:test",
            "LAS_OPERATOR_IMAGE_DIGEST": "sha256:" + "a" * 64,
            "LAS_AGENT_SERVER_IMAGE": "registry/agent:test",
            "LAS_AGENT_SERVER_DIGEST": "sha256:" + "b" * 64,
            "LAS_CHART_NAME": "langgraph-cloud",
            "LAS_CHART_VERSION": "0.3.5",
            "LAS_CHART_SHA256": "c" * 64,
            "LAS_HELM_RELEASE": "launchpad",
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
        unsafe_url = dict(
            base_environment,
            LAS_BASE_URL="http://user@127.0.0.1:2024/unexpected?target=other",
            KUBECTL="printf",
            HELM="printf",
        )
        result = subprocess.run(
            ["bash", str(ROTATION_SCRIPT)],
            input="{}",
            text=True,
            capture_output=True,
            env=unsafe_url,
            timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("uncredentialed HTTP loopback URL", result.stderr)

    def test_dry_run_reports_known_gates_and_selected_phases(self):
        argv = self.base_argv() + [
            "--restart-api",
            "--postgres-workload", "statefulset/postgres",
            "--postgres-service", "postgres",
            "--postgres-service-uid", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "--postgres-secret", "postgres-connection",
            "--dry-run",
        ]
        stdout = io.StringIO()
        with patch.object(sys, "argv", argv), patch("sys.stdout", stdout):
            self.assertEqual(lifecycle.main(), 0)
        result = json.loads(stdout.getvalue())
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["external_gates"]["MPR-131"], "KNOWN_FAIL")
        self.assertIn("RERUN REQUIRED", result["external_gates"]["MPR-44_EXTERNAL_SLIM_EDGE"])
        self.assertEqual([phase["name"] for phase in result["phases"]], ["restart_api", "recover_postgres"])
        serialized = json.dumps(result)
        self.assertNotIn("postgresql://", serialized.lower())
        self.assertNotIn("user:password", serialized.lower())

    def test_external_caller_gate_requires_exact_recorded_digest(self):
        digest = "sha256:" + "a" * 64
        stdout = io.StringIO()
        argv = self.base_argv() + [
            "--recorded-mpr44-agent-digest", digest,
            "--dry-run",
        ]
        with patch.object(sys, "argv", argv), patch("sys.stdout", stdout):
            self.assertEqual(lifecycle.main(), 0)
        result = json.loads(stdout.getvalue())
        self.assertEqual(
            result["external_gates"]["MPR-44_EXTERNAL_SLIM_EDGE"],
            "DIGEST_MATCH_ONLY; EXTERNAL CALLER RESULT NOT INGESTED",
        )
        self.assertNotIn("PASS", result["external_gates"]["MPR-44_EXTERNAL_SLIM_EDGE"])

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
            "--chart-name", "langgraph-cloud",
            "--chart-version", "0.3.5-splunk.2",
            "--chart-sha256", "a" * 64,
            "--helm-release", "launchpad",
            "--helm-namespace", "ai-platform",
            "--runtime-version", "0.4.21",
            "--graph-id", "agent",
        ]


if __name__ == "__main__":
    unittest.main()
