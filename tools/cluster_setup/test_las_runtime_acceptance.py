"""Offline contract tests for the LAS runtime qualification helpers."""

import asyncio
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import types
import unittest
import urllib.error
from io import BytesIO
from types import SimpleNamespace
from unittest.mock import patch


SCRIPT = pathlib.Path(__file__).parents[2] / "scripts" / "las-runtime-acceptance.py"
RESTART_SCRIPT = pathlib.Path(__file__).parents[2] / "scripts" / "las-restart-persistence-acceptance.sh"
ROTATION_SCRIPT = pathlib.Path(__file__).parents[2] / "scripts" / "las-credential-rotation-acceptance.sh"
SPEC = importlib.util.spec_from_file_location("las_runtime_acceptance", SCRIPT)
las = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(las)

PRODUCT_SCRIPT = pathlib.Path(__file__).parent / "validation" / "aip5410_product_route_acceptance.py"
PRODUCT_SPEC = importlib.util.spec_from_file_location("aip5410_product_route_acceptance", PRODUCT_SCRIPT)
product = importlib.util.module_from_spec(PRODUCT_SPEC)
PRODUCT_SPEC.loader.exec_module(product)


class FakeClient:
    def __init__(self, payload):
        self.payload = payload

    def request(self, method, path):
        return 200, __import__("json").dumps(self.payload).encode(), "application/json"


class PersistenceClient:
    def __init__(self, state, history_pages, api_key=""):
        self.state = state
        self.history_pages = list(history_pages)
        self.history_requests = []
        self.api_key = api_key

    def request(self, method, path, payload=None):
        if method == "GET" and path.endswith("/state"):
            return 200, json.dumps(self.state).encode(), "application/json"
        if method == "POST" and path.endswith("/history"):
            self.history_requests.append(payload)
            if not self.history_pages:
                raise AssertionError("unexpected checkpoint history page request")
            page = self.history_pages.pop(0)
            return 200, json.dumps(page).encode(), "application/json"
        raise AssertionError(f"unexpected request: {method} {path}")


class ProductProtocolClient:
    def __init__(self, mode="sync", failure_status=None):
        self.mode = mode
        self.failure_status = failure_status
        self.payloads = []
        self.deleted = []
        self.marker = None

    def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
        if method == "POST" and path == "/threads":
            return 201, b'{"thread_id":"thread-1"}', "application/json"
        if method == "DELETE":
            self.deleted.append(path)
            return 204, b"", "application/json"
        if method == "GET" and path == "/threads/thread-1":
            return 404, b"", "application/json"
        if method == "POST" and "/runs" in path:
            self.payloads.append(payload)
            if self.failure_status is not None:
                return self.failure_status, b"", "application/json"
            self.marker = next(value for value in las.strings(payload["input"]) if value.startswith("marker-"))
            if path.endswith("/wait"):
                return 200, json.dumps({"response": self.marker}).encode(), "application/json"
            if path.endswith("/stream"):
                body = (
                    'event: metadata\ndata: {"run_id":"run-1"}\n\n'
                    f'event: values\ndata: {{"response":"{self.marker}"}}\n\n'
                    'event: updates\ndata: {"status":"success"}\n\n'
                ).encode()
                return 200, body, "text/event-stream"
            return 201, b'{"run_id":"run-1"}', "application/json"
        if method == "GET" and path.endswith("/state"):
            return 200, json.dumps({"values": {"response": self.marker}}).encode(), "application/json"
        if method == "GET" and "/runs/" in path:
            return 200, b'{"status":"success"}', "application/json"
        raise AssertionError(f"unexpected request: {method} {path}")


class ActiveProductClient(ProductProtocolClient):
    def __init__(self, run_status="running"):
        super().__init__()
        self.run_status = run_status

    def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
        if method == "POST" and "/runs" in path:
            self.payloads.append(payload)
            candidate = next(
                value for value in las.strings(payload["input"]) if "mpr-qualification-" in value
            )
            self.marker = candidate.split("mpr-qualification-", 1)[1]
            self.marker = "mpr-qualification-" + self.marker[:32]
            return 201, b'{"run_id":"run-1"}', "application/json"
        if method == "GET" and "/runs/" in path:
            return 200, json.dumps({"status": self.run_status}).encode(), "application/json"
        return super().request(method, path, payload, accept, allow_http_error)


class LASRuntimeAcceptanceTests(unittest.TestCase):
    def test_runtime_strict_json_rejects_nonfinite_and_duplicate_values(self):
        for document in ('{"value": NaN}', '{"value": Infinity}', '{"value":1,"value":2}'):
            with self.subTest(document=document), self.assertRaises(ValueError):
                las.strict_json_loads(document)

    def test_graph_response_does_not_accept_echoed_user_input(self):
        snapshot = {
            "values": {
                "messages": [
                    {"role": "user", "content": "expected-marker"},
                    {"role": "assistant", "content": "actual-output"},
                ]
            }
        }
        self.assertNotIn("expected-marker", las.graph_response_strings(snapshot))
        self.assertIn("actual-output", las.graph_response_strings(snapshot))
        self.assertEqual(
            las.graph_response_strings(snapshot, ["messages"]),
            ["actual-output"],
        )

    def test_graph_response_does_not_accept_nested_transport_envelopes(self):
        for key in ("input", "context", "request", "metadata", "checkpoint", "config"):
            with self.subTest(key=key):
                snapshot = {"values": {key: {"response": "submitted-marker"}}}
                self.assertNotIn(
                    "submitted-marker", las.graph_response_strings(snapshot)
                )

    def test_response_paths_cannot_reenable_input_or_metadata_matching(self):
        base = {
            "name": "unsafe-path",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["sync"],
        }
        for path in ("request", "input.response", "metadata.answer"):
            with self.subTest(path=path), self.assertRaisesRegex(
                las.AcceptanceError, "safe dotted paths"
            ):
                las.run_protocol_case(
                    ProductProtocolClient(),
                    "agent",
                    dict(base, expected_response_paths=[path]),
                    30,
                )

        echoed = dict(base, expected_response_paths=["echo.response"])
        with self.assertRaisesRegex(
            las.AcceptanceError, "already present in submitted input/context"
        ):
            las.run_protocol_case(ProductProtocolClient(), "agent", echoed, 30)

        class CustomOutputClient(ProductProtocolClient):
            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "POST" and path.endswith("/wait"):
                    self.payloads.append(payload)
                    self.marker = next(
                        value for value in las.strings(payload["input"]) if value.startswith("marker-")
                    )
                    return 200, b'{"final":{"text":"generated-output"}}', "application/json"
                return super().request(method, path, payload, accept, allow_http_error)

        custom = dict(
            base,
            expected_response_values=["generated-output"],
            expected_response_paths=["final.text"],
        )
        checks = las.run_protocol_case(CustomOutputClient(), "agent", custom, 30)
        self.assertEqual(checks[0]["result"], "PASS")

    def test_sensitive_scan_decodes_alternate_json_escapes(self):
        with self.assertRaisesRegex(las.AcceptanceError, "sensitive marker"):
            las.assert_sensitive_absent(
                br'{"token":"\u0041\/B"}', ["A/B"], "escaped response"
            )

    def test_restart_wrapper_disables_xtrace_before_reading_scenario(self):
        source = RESTART_SCRIPT.read_text(encoding="utf-8")
        service_binding = source[
            source.index("verify_api_service_binding()") : source.index("verify_helm_identity()")
        ]
        self.assertLess(source.index("set +x"), source.index('scenario="$(cat)"'))
        self.assertIn('"service/${LAS_API_SERVICE}"', source)
        self.assertIn("expected.replace(placeholder, marker)", source)
        self.assertIn("LAS_EXPECTED_NAMESPACE_UID", source)
        self.assertIn("contains_marker(expected, placeholder)", source)
        self.assertLess(
            source.index("qualification_threads_cleanup=deleted:"),
            source.index("las_restart_persistence=PASS"),
        )
        self.assertGreater(
            source.index('queue_before="$(deployment_revision "$LAS_QUEUE_DEPLOYMENT")"'),
            source.index("active_run_queue_replacement=NOT_RUN"),
        )
        self.assertIn("qualification_thread_cleanup=FAIL", source)
        self.assertIn("cleanup_failed != 0 && original_status == 0", source)
        self.assertIn("identity_verification=PASS", source)
        self.assertIn("EXPECTED_CONTAINER_NAMES", source)
        self.assertIn("EXPECTED_CHART_NAME", source)
        self.assertIn("LAS_API_SERVICE_UID", source)
        self.assertIn('service.get("metadata", {}).get("uid")', service_binding)
        self.assertIn('service.get("spec", {}).get("selector") != selector', service_binding)
        self.assertIn('service_ports[0].get("targetPort", expected_port)', service_binding)
        self.assertIn('port.get("containerPort") == target_port', service_binding)
        self.assertIn('port.get("name") == target_port', service_binding)
        self.assertIn('resolved_port not in {', service_binding)
        self.assertIn('endpoint_slice.get("ports", [])', service_binding)
        self.assertIn('uid not in pod_uids', service_binding)
        self.assertIn('ready_targets.issubset(ready_pod_uids)', service_binding)
        self.assertLess(
            source.index("verify_api_service_binding || return 1"),
            source.index('port-forward \\\n    "service/${LAS_API_SERVICE}"'),
        )
        self.assertGreaterEqual(source.count("--scenario-stdin"), 3)
        self.assertIn("kubectl_scoped", source)
        self.assertIn("verify_cluster_scope || return 1", source)
        self.assertLess(
            source.index("verify_stack_identity ||"),
            source.index("start_port_forward\nresult="),
        )
        api_restart = source.index('restart_and_wait "$LAS_API_DEPLOYMENT"')
        self.assertLess(
            source.index("verify_stack_identity ||", api_restart),
            source.index('check_states api_restart'),
        )
        initial_history = source.index("check_history_persistence initial")
        self.assertLess(initial_history, api_restart)
        self.assertLess(
            source.index("check_history_persistence api_restart", api_restart),
            source.index('restart_and_wait "$LAS_QUEUE_DEPLOYMENT"'),
        )
        self.assertGreater(
            source.index("check_history_persistence queue_restart"),
            source.index('restart_and_wait "$LAS_QUEUE_DEPLOYMENT"'),
        )
        self.assertIn('python3 "$QUALIFIER" persistence --scenario-stdin', source)
        self.assertIn("history_rows.append([thread_id, marker, name, mode])", source)

    def test_rotation_wrapper_proves_data_change_and_preserves_hpa(self):
        source = ROTATION_SCRIPT.read_text(encoding="utf-8")
        service_binding = source[
            source.index("verify_api_service_binding()") : source.index("verify_secret_references()")
        ]
        self.assertLess(source.index("set +x"), source.index('scenario="$(cat)"'))
        self.assertIn("secret_key_hash", source)
        self.assertIn("langgraph_cloud_license_key", source)
        self.assertIn("postgres_connection_url", source)
        self.assertIn("redis_connection_url", source)
        self.assertIn('encoded_value = value.get(key)', source)
        self.assertNotIn('json.dumps(value, sort_keys=True', source)
        self.assertIn('kubectl_scoped', source)
        self.assertIn('--kube-context "$LAS_EXPECTED_KUBE_CONTEXT"', source)
        self.assertIn("initial_hashes", source)
        self.assertIn("queue_hpa_ownership_preserved=PASS", source)
        self.assertIn("product_protocol_before_rotation", source)
        self.assertIn("refresh_las_access", source)
        self.assertIn('LAS_API_SERVICE LAS_API_SERVICE_UID\n', source)
        self.assertIn('kill -0 "$PORT_FORWARD_PID"', source)
        self.assertIn('case["cleanup"] = True', source)
        self.assertIn("ProxyHandler({})", source)
        self.assertIn("managed_secret_workload_references=PASS", source)
        self.assertIn("live_helm_release_identity=PASS", source)
        self.assertIn("EXPECTED_CONTAINER_NAMES", source)
        self.assertIn("EXPECTED_CHART_NAME", source)
        self.assertIn('service.get("metadata", {}).get("uid")', service_binding)
        self.assertIn('service.get("spec", {}).get("selector") != selector', service_binding)
        self.assertIn('service_ports[0].get("targetPort", expected_port)', service_binding)
        self.assertIn('port.get("containerPort") == target_port', service_binding)
        self.assertIn('port.get("name") == target_port', service_binding)
        self.assertIn('resolved_port not in {', service_binding)
        self.assertIn('endpoint_slice.get("ports", [])', service_binding)
        self.assertIn('uid not in pod_uids', service_binding)
        self.assertIn('ready_targets.issubset(ready_pod_uids)', service_binding)
        self.assertIn('container.get("image") == os.environ["EXPECTED_IMAGE"]', source)
        secret_check = source[source.index("verify_secret_references()") : source.index("verify_helm_identity()")]
        self.assertIn("def exposes_key(items, mount, secret_key):", secret_check)
        self.assertIn('mount.get("subPathExpr") is not None', secret_check)
        self.assertIn('sub_path = mount.get("subPath")', secret_check)
        self.assertIn("sub_path is None or sub_path == key_path", secret_check)
        self.assertIn("references_secret_key(pod, container, name, key)", secret_check)
        self.assertNotIn('initContainers', secret_check)
        embedded_start = secret_check.index("python3 -c '") + len("python3 -c '")
        embedded = secret_check[embedded_start : secret_check.rindex("\n'")]
        base_mount = {"name": "credentials", "mountPath": "/var/run/credentials"}
        pod_spec = {
            "containers": [{
                "name": "agent",
                "image": "agent-image",
                "volumeMounts": [dict(base_mount, subPath="unrelated")],
            }],
            "volumes": [{
                "name": "credentials",
                "secret": {
                    "secretName": "auth-secret",
                    "items": [{"key": "license-key", "path": "license"}],
                },
            }],
        }
        deployments = {
            "items": [
                {"metadata": {"name": name}, "spec": {"template": {"spec": pod_spec}}}
                for name in ("api", "queue")
            ]
        }
        env = {
            "EXPECTED_SECRET_NAMES": "auth-secret",
            "EXPECTED_SECRET_KEYS": "license-key",
            "EXPECTED_IMAGE": "agent-image",
            "EXPECTED_DEPLOYMENTS": "api,queue",
        }
        hidden_key = subprocess.run(
            [sys.executable, "-c", embedded],
            input=json.dumps(deployments),
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        self.assertNotEqual(hidden_key.returncode, 0)
        for deployment in deployments["items"]:
            deployment["spec"]["template"]["spec"]["containers"][0]["volumeMounts"][0][
                "subPath"
            ] = "license"
        exposed_key = subprocess.run(
            [sys.executable, "-c", embedded],
            input=json.dumps(deployments),
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        self.assertEqual(exposed_key.returncode, 0, exposed_key.stderr)
        self.assertLess(
            source.index("phase=verify_initial_immutable_identity"),
            source.index("phase=product_before_rotation"),
        )
        self.assertLess(
            source.index("phase=verify_operator_before_initial_secret_install"),
            source.index("phase=install_initial"),
        )
        initial_verify = source.index("phase=verify_initial_immutable_identity")
        initial_refresh = source.index("refresh_las_access", initial_verify)
        self.assertLess(initial_verify, initial_refresh)
        rotated_verify = source.index("phase=verify_rotated_immutable_identity")
        rotated_refresh = source.index("refresh_las_access", rotated_verify)
        self.assertLess(rotated_verify, rotated_refresh)
        initial_install = source.index('install_config "$LAS_INITIAL_CONFIG"')
        self.assertLess(
            source.index("verify_cluster_scope", initial_install),
            source.index('wait_rollout "$LAS_API_DEPLOYMENT"', initial_install),
        )
        rotated_install = source.index('install_config "$LAS_ROTATED_CONFIG"')
        self.assertLess(
            source.index("verify_cluster_scope", rotated_install),
            source.index("changed=0", rotated_install),
        )

    def test_persistence_marker_must_be_inside_graph_values(self):
        marker = "run-marker"
        client = FakeClient({"values": {"response": "completed"}, "metadata": {"marker": marker}})
        with self.assertRaisesRegex(las.AcceptanceError, "graph state values"):
            las.assert_state(client, "thread", [marker], [])

    def test_persisted_marker_under_values_passes(self):
        marker = "run-marker"
        client = FakeClient({"values": {"response": f"persisted {marker}"}, "metadata": {}})
        las.assert_state(client, "thread", [marker], [])

    def test_sensitive_markers_are_rejected_from_state_values(self):
        client = FakeClient({"values": {"response": "secret-value"}})
        with self.assertRaisesRegex(las.AcceptanceError, "sensitive marker"):
            las.assert_state(client, "thread", [], ["secret-value"])

    def test_persistence_requires_marker_in_current_state_and_history_graph_values(self):
        marker = "known-non-secret-marker"
        history = [{
            "values": {"response": f"persisted {marker}"},
            "checkpoint": {"checkpoint_id": "checkpoint-1"},
        }]
        client = PersistenceClient(
            {"values": {"response": f"current {marker}"}}, [history]
        )
        state, count = las.assert_persistence(client, "thread", [marker], [])
        self.assertEqual(state["values"]["response"], f"current {marker}")
        self.assertEqual(count, 1)

        history_only = PersistenceClient(
            {"values": {"response": "other"}}, [history]
        )
        with self.assertRaisesRegex(las.AcceptanceError, "graph state values"):
            las.assert_persistence(history_only, "thread", [marker], [])
        self.assertEqual(history_only.history_requests, [])

        metadata_only = PersistenceClient(
            {"values": {"response": marker}},
            [[{
                "values": {"response": "other"},
                "metadata": {"marker": marker},
                "checkpoint": {"checkpoint_id": "checkpoint-1"},
            }]],
        )
        with self.assertRaisesRegex(las.AcceptanceError, "history graph values"):
            las.assert_persistence(metadata_only, "thread", [marker], [])

    def test_checkpoint_history_paginates_to_exhaustion_with_supported_cursor(self):
        marker = "known-history-marker"
        first_page = [
            {
                "values": {"response": "old"},
                "checkpoint": {"checkpoint_id": "checkpoint-3"},
            },
            {
                "values": {"response": "older"},
                "checkpoint": {"checkpoint_id": "checkpoint-2"},
            },
        ]
        second_page = [{
            "values": {"response": marker},
            "checkpoint": {"checkpoint_id": "checkpoint-1"},
        }]
        client = PersistenceClient({}, [first_page, second_page])
        count = las.assert_checkpoint_history(
            client, "thread", [marker], [], page_size=2, max_snapshots=4
        )
        self.assertEqual(count, 3)
        self.assertEqual(client.history_requests[0], {"limit": 2})
        self.assertEqual(
            client.history_requests[1],
            {"limit": 2, "before": {"checkpoint_id": "checkpoint-2"}},
        )

    def test_checkpoint_history_scans_credentials_on_every_page(self):
        first_page = [
            {
                "values": {"response": "known-history-marker"},
                "checkpoint": {"checkpoint_id": "checkpoint-2"},
            },
            {
                "values": {"response": "older"},
                "checkpoint": {"checkpoint_id": "checkpoint-1"},
            },
        ]
        leaked_page = [{
            "values": {"response": "oldest"},
            "metadata": {"api_key": "credential-canary"},
            "checkpoint": {"checkpoint_id": "checkpoint-0"},
        }]
        client = PersistenceClient(
            {}, [first_page, leaked_page], api_key="credential-canary"
        )
        with self.assertRaisesRegex(las.AcceptanceError, "checkpoint history"):
            las.assert_checkpoint_history(
                client,
                "thread",
                ["known-history-marker"],
                [],
                page_size=2,
                max_snapshots=4,
            )
        self.assertEqual(len(client.history_requests), 2)

    def test_checkpoint_history_fails_closed_at_snapshot_bound(self):
        first_page = [
            {
                "values": {"response": "known-history-marker"},
                "checkpoint": {"checkpoint_id": "checkpoint-2"},
            },
            {
                "values": {"response": "older"},
                "checkpoint": {"checkpoint_id": "checkpoint-1"},
            },
        ]
        overflow = [{
            "values": {"response": "oldest"},
            "checkpoint": {"checkpoint_id": "checkpoint-0"},
        }]
        client = PersistenceClient({}, [first_page, overflow])
        with self.assertRaisesRegex(las.AcceptanceError, "bounded snapshot limit"):
            las.assert_checkpoint_history(
                client,
                "thread",
                ["known-history-marker"],
                [],
                page_size=2,
                max_snapshots=2,
            )
        self.assertEqual(client.history_requests[-1]["limit"], 1)

    def test_persistence_command_emits_only_sanitized_summary(self):
        marker = "known-non-secret-marker"
        client = PersistenceClient(
            {"values": {"response": marker}},
            [[{
                "values": {"response": marker},
                "checkpoint": {"checkpoint_id": "checkpoint-1"},
            }]],
        )
        scenario = {"sensitive_values": ["credential-canary"]}
        output = io.StringIO()
        with (
            patch.object(las, "LASClient", return_value=client),
            patch("sys.stdin", io.StringIO(json.dumps(scenario))),
            patch("sys.stdout", output),
        ):
            las.persistence_command(
                SimpleNamespace(
                    request_timeout=5,
                    scenario_stdin=True,
                    thread_id="thread-1",
                    expected_value=marker,
                )
            )
        rendered = output.getvalue()
        self.assertNotIn(marker, rendered)
        self.assertNotIn("credential-canary", rendered)
        self.assertEqual(
            json.loads(rendered),
            {
                "result": "PASS",
                "check": "persisted_graph_state_and_checkpoint_history",
                "thread_id": "thread-1",
                "checkpoint_count": 1,
            },
        )

    def test_sse_parser_checks_data_lines_only(self):
        self.assertTrue(las.sse_has_data(b"event: values\ndata: {\"response\":\"expected\"}\n\n", ["expected"], []))
        self.assertFalse(las.sse_has_data(b"event: values\ndata: {\"response\":\"other\"}\n\n", ["expected"], []))

    def test_sse_parser_rejects_sensitive_values(self):
        with self.assertRaisesRegex(las.AcceptanceError, "sensitive marker"):
            las.sse_has_data(b"data: secret-value\n\n", [], ["secret-value"])

    def test_product_input_uses_context_marker_without_injecting_fixture_request(self):
        client = ProductProtocolClient()
        case = {
            "name": "launchpad-sync",
            "input": {
                "messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}],
                "system_prompt": "answer briefly",
            },
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["sync"],
            "cleanup": True,
        }
        checks = las.run_protocol_case(client, "agent", case, 30)
        self.assertNotIn("request", client.payloads[0]["input"])
        self.assertEqual(client.payloads[0]["context"]["llm_config"]["model"], "test-model")
        self.assertEqual(checks[0]["terminal_status"], "success")
        self.assertRegex(checks[0]["marker"], r"^aip-qualification-[0-9a-f]{32}$")
        self.assertTrue(checks[0]["thread_cleaned"])
        self.assertEqual(client.deleted, ["/threads/thread-1"])

    def test_expected_http_failure_passes_and_is_cleaned(self):
        client = ProductProtocolClient(failure_status=422)
        case = {
            "name": "missing-context",
            "input": {"messages": [], "system_prompt": "test"},
            "expected_state_values": [],
            "run_modes": ["sync"],
            "expected_outcome": "failure",
            "expected_http_statuses": [422],
            "cleanup": True,
        }
        checks = las.run_protocol_case(client, "agent", case, 30)
        self.assertEqual(checks[0]["terminal_status"], "http_error")
        self.assertEqual(checks[0]["http_status"], 422)
        self.assertEqual(client.deleted, ["/threads/thread-1"])

    def test_failure_contract_rejects_success_statuses(self):
        base = {
            "name": "invalid-failure-contract",
            "input": {"request": "invalid"},
            "expected_state_values": [],
            "expected_response_values": [],
            "run_modes": ["sync"],
            "expected_outcome": "failure",
        }
        with self.assertRaisesRegex(las.AcceptanceError, "only 4xx/5xx"):
            las.run_protocol_case(
                ProductProtocolClient(),
                "agent",
                dict(base, expected_http_statuses=[204]),
                30,
            )
        with self.assertRaisesRegex(las.AcceptanceError, "only failed terminal"):
            las.run_protocol_case(
                ProductProtocolClient(),
                "agent",
                dict(base, expected_run_statuses=["success"]),
                30,
            )

    def test_sse_terminal_contract_cannot_invert_or_omit_completion(self):
        base = {
            "name": "invalid-sse-contract",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["stream"],
            "expected_sse_event_sequence": ["metadata", "values", "updates"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "require a success terminal"):
            las.run_protocol_case(
                ProductProtocolClient(),
                "agent",
                dict(
                    base,
                    expected_sse_terminal_event="updates",
                    expected_sse_terminal_status="error",
                ),
                30,
            )
        with self.assertRaisesRegex(las.AcceptanceError, "requires a non-empty"):
            las.run_protocol_case(
                ProductProtocolClient(),
                "agent",
                dict(base, expected_sse_completion="terminal_event"),
                30,
            )

    def test_queued_success_requires_expected_graph_output(self):
        class EchoOnlyState(ProductProtocolClient):
            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "GET" and path.endswith("/state"):
                    body = {
                        "values": {
                            "messages": [{"role": "user", "content": self.marker}]
                        }
                    }
                    return 200, json.dumps(body).encode(), "application/json"
                return super().request(method, path, payload, accept, allow_http_error)

        case = {
            "name": "echo-only",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["queued"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "queued graph output omitted"):
            las.run_protocol_case(EchoOnlyState(), "agent", case, 30)

    def test_sse_sequence_and_terminal_status_are_enforced(self):
        client = ProductProtocolClient(mode="stream")
        case = {
            "name": "launchpad-stream",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["stream"],
            "expected_sse_event_sequence": ["metadata", "values", "updates"],
            "expected_sse_terminal_event": "updates",
            "expected_sse_terminal_status": "success",
            "cleanup": True,
        }
        checks = las.run_protocol_case(client, "agent", case, 30)
        self.assertEqual(checks[0]["sse_events"], ["metadata", "values", "updates"])
        self.assertEqual(checks[0]["terminal_status"], "success")

    def test_sse_can_use_versioned_eof_after_values_contract(self):
        class EofStreamClient(ProductProtocolClient):
            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "POST" and path.endswith("/stream"):
                    self.payloads.append(payload)
                    self.marker = next(
                        value for value in las.strings(payload["input"]) if value.startswith("marker-")
                    )
                    body = (
                        'event: metadata\ndata: {"run_id":"run-1"}\n\n'
                        f'event: values\ndata: {{"response":"{self.marker}"}}\n\n'
                    ).encode()
                    return 200, body, "text/event-stream"
                return super().request(method, path, payload, accept, allow_http_error)

        case = {
            "name": "launchpad-stream-eof",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["stream"],
            "expected_sse_event_sequence": ["metadata", "values"],
            "expected_sse_completion": "eof_after_expected_values",
        }
        checks = las.run_protocol_case(EofStreamClient(), "agent", case, 30)
        self.assertEqual(checks[0]["sse_events"], ["metadata", "values"])
        self.assertEqual(checks[0]["terminal_status"], "success")
        self.assertEqual(checks[0]["run_id"], "run-1")

    def test_derived_credential_is_scanned_when_explicit_list_is_incomplete(self):
        class LeakingCredentialClient(ProductProtocolClient):
            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "POST" and path.endswith("/wait"):
                    return 200, b'{"response":"derived-secret"}', "application/json"
                return super().request(method, path, payload, accept, allow_http_error)

        case = {
            "name": "derived-secret",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {
                "llm_config": {"model": "test-model", "api_key": "derived-secret"}
            },
            "sensitive_values": ["unrelated-canary"],
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["sync"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "sensitive marker"):
            las.run_protocol_case(LeakingCredentialClient(), "agent", case, 30)

    def test_direct_credential_context_requires_declared_canary(self):
        case = {
            "name": "missing-canary",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {
                "llm_config": {"model": "test-model", "api_key": "derived-secret"}
            },
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["sync"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "requires sensitive_values"):
            las.run_protocol_case(ProductProtocolClient(), "agent", case, 30)

    def test_runtime_api_key_is_always_in_the_scan_set(self):
        class LeakingAPIKeyClient(ProductProtocolClient):
            api_key = "runtime-api-secret"

            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "POST" and path.endswith("/wait"):
                    return 200, b'{"response":"runtime-api-secret"}', "application/json"
                return super().request(method, path, payload, accept, allow_http_error)

        case = {
            "name": "api-key-scan",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["sync"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "sensitive marker"):
            las.run_protocol_case(LeakingAPIKeyClient(), "agent", case, 30)

    def test_thread_create_response_is_scanned_before_any_product_run(self):
        class LeakingCreateClient(ProductProtocolClient):
            api_key = "runtime-api-secret"

            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "POST" and path == "/threads":
                    return (
                        201,
                        b'{"thread_id":"thread-1","leak":"runtime-api-secret"}',
                        "application/json",
                    )
                return super().request(method, path, payload, accept, allow_http_error)

        case = {
            "name": "create-scan",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["sync"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "thread creation response"):
            client = LeakingCreateClient()
            las.run_protocol_case(client, "agent", case, 30)
        self.assertEqual(client.deleted, ["/threads/thread-1"])

    def test_malformed_thread_create_cleans_one_recoverable_identifier(self):
        class MalformedCreateClient(ProductProtocolClient):
            def __init__(self, body):
                super().__init__()
                self.body = body

            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "POST" and path == "/threads":
                    return 202, self.body, "application/json"
                if method == "GET" and path == "/threads/thread-recovered":
                    return 404, b"", "application/json"
                return super().request(method, path, payload, accept, allow_http_error)

        for body in (
            b'{"thread_id":"thread-recovered"',
            b'{"thread_id":"thread-recovered","thread_id":"thread-recovered"}',
        ):
            with self.subTest(body=body):
                client = MalformedCreateClient(body)
                with self.assertRaises(las.AcceptanceError):
                    las.create_thread(client)
                self.assertEqual(client.deleted, ["/threads/thread-recovered"])

    def test_ambiguous_thread_create_does_not_delete_an_identifier(self):
        class AmbiguousCreateClient(ProductProtocolClient):
            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "POST" and path == "/threads":
                    return 201, b'{"thread_id":"thread-1","nested":{"thread_id":"thread-2"}', "application/json"
                return super().request(method, path, payload, accept, allow_http_error)

        client = AmbiguousCreateClient()
        with self.assertRaisesRegex(las.AcceptanceError, "invalid JSON"):
            las.create_thread(client)
        self.assertEqual(client.deleted, [])

    def test_cleanup_runs_when_product_assertion_fails(self):
        client = ProductProtocolClient()
        case = {
            "name": "bad-expectation",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["different-{{RUN_MARKER}}"],
            "expected_response_values": ["different-{{RUN_MARKER}}"],
            "run_modes": ["sync"],
            "cleanup": True,
        }
        with self.assertRaisesRegex(las.AcceptanceError, "expected result"):
            las.run_protocol_case(client, "agent", case, 30)
        self.assertEqual(client.deleted, ["/threads/thread-1"])

    def test_later_mode_failure_cleans_previously_retained_threads(self):
        class SecondModeFailure(ProductProtocolClient):
            def __init__(self):
                super().__init__()
                self.thread_count = 0

            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "POST" and path == "/threads":
                    self.thread_count += 1
                    return 201, json.dumps({"thread_id": f"thread-{self.thread_count}"}).encode(), "application/json"
                if method == "POST" and path.endswith("/runs"):
                    return 500, b"", "application/json"
                if method == "GET" and path in ("/threads/thread-1", "/threads/thread-2"):
                    return 404, b"", "application/json"
                return super().request(method, path, payload, accept, allow_http_error)

        client = SecondModeFailure()
        case = {
            "name": "later-mode-failure",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["sync", "queued"],
            "cleanup": False,
        }
        with self.assertRaisesRegex(las.AcceptanceError, "queued run returned"):
            las.run_protocol_case(client, "agent", case, 30)
        self.assertCountEqual(client.deleted, ["/threads/thread-1", "/threads/thread-2"])

    def test_success_requires_marker_in_request_and_expected_state(self):
        missing_request_marker = {
            "name": "missing-request-marker",
            "input": {"messages": [{"role": "user", "content": "constant"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["{{RUN_MARKER}}"],
            "run_modes": ["sync"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "send the marker placeholder"):
            las.run_protocol_case(ProductProtocolClient(), "agent", missing_request_marker, 30)

        missing_expected_marker = {
            "name": "missing-expected-marker",
            "input": {"messages": [{"role": "user", "content": "{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["constant"],
            "run_modes": ["sync"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "expected_state_values"):
            las.run_protocol_case(ProductProtocolClient(), "agent", missing_expected_marker, 30)

    def test_direct_protocol_defaults_to_cleanup(self):
        client = ProductProtocolClient()
        case = {
            "name": "default-cleanup",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["sync"],
        }
        checks = las.run_protocol_case(client, "agent", case, 30)
        self.assertTrue(checks[0]["thread_cleaned"])
        self.assertEqual(client.deleted, ["/threads/thread-1"])

    def test_success_case_rejects_empty_response_expectation(self):
        case = {
            "name": "unchecked-success",
            "input": {"request": "marker"},
            "expected_state_values": ["marker"],
            "expected_response_values": [],
            "run_modes": ["sync"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "non-empty expected_response_values"):
            las.run_protocol_case(ProductProtocolClient(), "agent", case, 30)

    def test_active_product_run_uses_synthetic_marker_and_can_be_verified(self):
        scenario = {
            "graph_id": "agent",
            "sensitive_values": ["fake-secret-canary"],
            "active_run_case": {
                "name": "active-product",
                "input": {"messages": [{"role": "user", "content": "hold {{RUN_MARKER}}"}]},
                "context": {"llm_config": {"api_key": "fake-secret-canary"}},
                "expected_state_values": ["{{RUN_MARKER}}"],
            },
        }
        submit_client = ActiveProductClient("running")
        submit_output = io.StringIO()
        submit_args = SimpleNamespace(running_timeout=30, request_timeout=30)
        with patch.object(las, "LASClient", return_value=submit_client), patch(
            "sys.stdin", io.StringIO(json.dumps(scenario))
        ), patch("sys.stdout", submit_output):
            las.submit_product_active_command(submit_args)
        submitted = json.loads(submit_output.getvalue())
        self.assertRegex(submitted["marker"], r"^mpr-qualification-[0-9a-f]{32}$")
        self.assertNotIn("fake-secret-canary", submit_output.getvalue())

        verify_client = ActiveProductClient("success")
        verify_client.marker = submitted["marker"]
        verify_output = io.StringIO()
        verify_args = SimpleNamespace(
            thread_id=submitted["thread_id"],
            run_id=submitted["run_id"],
            marker=submitted["marker"],
            run_timeout=30,
            request_timeout=30,
            cleanup=True,
        )
        with patch.object(las, "LASClient", return_value=verify_client), patch(
            "sys.stdin", io.StringIO(json.dumps(scenario))
        ), patch("sys.stdout", verify_output):
            las.verify_product_active_command(verify_args)
        verified = json.loads(verify_output.getvalue())
        self.assertEqual(verified["terminal_status"], "success")
        self.assertTrue(verified["thread_cleaned"])
        self.assertEqual(verify_client.deleted, ["/threads/thread-1"])

    def test_active_product_paths_derive_credentials_when_canary_list_is_incomplete(self):
        scenario = {
            "graph_id": "agent",
            "sensitive_values": ["unrelated-canary"],
            "active_run_case": {
                "name": "active-product",
                "input": {"messages": [{"role": "user", "content": "hold {{RUN_MARKER}}"}]},
                "context": {"llm_config": {"api_key": "derived-secret"}},
                "expected_state_values": ["{{RUN_MARKER}}"],
            },
        }

        class SubmitLeakClient(ActiveProductClient):
            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "POST" and path.endswith("/runs"):
                    return 201, b'{"run_id":"run-1","leak":"derived-secret"}', "application/json"
                return super().request(method, path, payload, accept, allow_http_error)

        with patch.object(las, "LASClient", return_value=SubmitLeakClient()), patch(
            "sys.stdin", io.StringIO(json.dumps(scenario))
        ), self.assertRaisesRegex(las.AcceptanceError, "sensitive marker"):
            las.submit_product_active_command(
                SimpleNamespace(running_timeout=30, request_timeout=30)
            )

        class VerifyLeakClient(ActiveProductClient):
            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "GET" and "/runs/" in path:
                    return 200, b'{"status":"success","leak":"derived-secret"}', "application/json"
                return super().request(method, path, payload, accept, allow_http_error)

        marker = "mpr-qualification-" + "a" * 32
        verify_args = SimpleNamespace(
            thread_id="thread-1",
            run_id="run-1",
            marker=marker,
            run_timeout=30,
            request_timeout=30,
            cleanup=True,
        )
        with patch.object(las, "LASClient", return_value=VerifyLeakClient()), patch(
            "sys.stdin", io.StringIO(json.dumps(scenario))
        ), self.assertRaisesRegex(las.AcceptanceError, "sensitive marker"):
            las.verify_product_active_command(verify_args)

    def test_delete_thread_command_rejects_unsafe_identifier(self):
        with self.assertRaisesRegex(las.AcceptanceError, "safe runtime identifier"):
            las.delete_thread_command(SimpleNamespace(thread_id="id\nsecret", request_timeout=30))

    def test_thread_cleanup_waits_for_confirmed_absence(self):
        class EventuallyDeleted:
            def __init__(self):
                self.reads = 0

            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "DELETE":
                    return 202, b"", "application/json"
                self.reads += 1
                return (200 if self.reads == 1 else 404), b"", "application/json"

        client = EventuallyDeleted()
        with patch.object(las.time, "sleep"):
            las.delete_thread(client, "thread-1")
        self.assertEqual(client.reads, 2)

    def test_thread_cleanup_scans_delete_and_confirmation_bodies(self):
        class CleanupLeak:
            def __init__(self, leak_on):
                self.leak_on = leak_on
                self.reads = 0

            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "DELETE":
                    body = b'{"leak":"credential-value"}' if self.leak_on == "delete" else b"{}"
                    return 202, body, "application/json"
                self.reads += 1
                body = (
                    b'{"leak":"credential-value"}'
                    if self.leak_on == "get" and self.reads == 1
                    else b"{}"
                )
                return (200 if self.reads == 1 else 404), body, "application/json"

        for leak_on in ("delete", "get"):
            with self.subTest(leak_on=leak_on):
                client = CleanupLeak(leak_on)
                with patch.object(las.time, "sleep"), self.assertRaisesRegex(
                    las.AcceptanceError, "sensitive marker"
                ):
                    las.delete_thread(client, "thread-1", ["credential-value"])
                self.assertEqual(client.reads, 2)

    def test_health_command_scans_runtime_api_key(self):
        class HealthLeak:
            api_key = "runtime-api-secret"

            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                return 200, b'{"ok":true,"leak":"runtime-api-secret"}', "application/json"

        with patch.object(las, "LASClient", return_value=HealthLeak()), self.assertRaisesRegex(
            las.AcceptanceError, "sensitive marker"
        ):
            las.health_command(SimpleNamespace(request_timeout=5))

    def test_sse_eof_run_id_must_come_from_consistent_metadata(self):
        values_only = b'event: values\ndata: {"run_id":"run-1","response":"ok"}\n\n'
        with self.assertRaisesRegex(las.AcceptanceError, "omitted a run ID"):
            las.sse_run_id(values_only, [])

        conflicting = (
            b'event: metadata\ndata: {"run_id":"run-1"}\n\n'
            b'event: metadata\ndata: {"run_id":"run-2"}\n\n'
        )
        with self.assertRaisesRegex(las.AcceptanceError, "conflicting run IDs"):
            las.sse_run_id(conflicting, [])

    def test_nested_status_cannot_satisfy_terminal_contract(self):
        body = (
            b'event: values\ndata: {"response":"expected"}\n\n'
            b'event: updates\ndata: {"node":{"status":"success"}}\n\n'
        )
        with self.assertRaisesRegex(las.AcceptanceError, "unexpected status"):
            las.assert_sse(
                body,
                ["expected"],
                [],
                ["values", "updates"],
                "updates",
                "success",
            )
        self.assertIsNone(las.authoritative_status({"input": {"status": "error"}}))

        contradictory = (
            b'event: values\ndata: {"response":"expected"}\n\n'
            b'event: updates\ndata: {"status":"error"}\n\n'
            b'event: updates\ndata: {"status":"success"}\n\n'
        )
        with self.assertRaisesRegex(las.AcceptanceError, "failed terminal status"):
            las.assert_sse(
                contradictory,
                ["expected"],
                [],
                ["values", "updates"],
                "updates",
                "success",
            )

        class FailedSyncClient(ProductProtocolClient):
            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "POST" and path.endswith("/wait"):
                    self.payloads.append(payload)
                    marker = next(
                        value for value in las.strings(payload["input"])
                        if value.startswith("marker-")
                    )
                    return (
                        200,
                        json.dumps({"status": "error", "response": marker}).encode(),
                        "application/json",
                    )
                return super().request(method, path, payload, accept, allow_http_error)

        success_case = {
            "name": "contradictory-sync-success",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "expected_response_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["sync"],
        }
        client = FailedSyncClient()
        with self.assertRaisesRegex(las.AcceptanceError, "failed terminal status"):
            las.run_protocol_case(client, "agent", success_case, 30)
        self.assertEqual(client.deleted, ["/threads/thread-1"])

        class NestedFailureClient(ProductProtocolClient):
            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "POST" and path.endswith("/wait"):
                    return 200, b'{"input":{"status":"error"}}', "application/json"
                return super().request(method, path, payload, accept, allow_http_error)

        failure_case = {
            "name": "nested-status-failure",
            "input": {"request": "invalid"},
            "expected_state_values": [],
            "expected_response_values": [],
            "run_modes": ["sync"],
            "expected_outcome": "failure",
            "expected_run_statuses": ["error"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "unexpectedly succeeded"):
            las.run_protocol_case(NestedFailureClient(), "agent", failure_case, 30)

    def test_protocol_failure_cleans_prior_per_case_retained_thread(self):
        class CleanupClient:
            api_key = ""

            def __init__(self):
                self.deleted = []

            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "GET" and path == "/ok":
                    return 200, b'{"ok":true}', "application/json"
                if method == "DELETE":
                    self.deleted.append(path)
                    return 204, b"", "application/json"
                if method == "GET" and path == "/threads/retained-1":
                    return 404, b"", "application/json"
                raise AssertionError((method, path))

        scenario = {
            "graph_id": "agent",
            "cleanup_threads": True,
            "cases": [
                {"name": "retained", "input": {}, "cleanup": False},
                {"name": "fails", "input": {}},
            ],
        }
        retained = [{
            "case": "retained",
            "mode": "sync",
            "thread_id": "retained-1",
            "thread_cleaned": False,
            "marker": "aip-qualification-" + "a" * 32,
        }]
        client = CleanupClient()
        with patch.object(las, "LASClient", return_value=client), patch.object(
            las,
            "run_protocol_case",
            side_effect=[retained, las.AcceptanceError("later case failed")],
        ), patch("sys.stdin", io.StringIO(json.dumps(scenario))), self.assertRaisesRegex(
            las.AcceptanceError, "later case failed"
        ):
            las.protocol_command(SimpleNamespace(request_timeout=5, run_timeout=5))
        self.assertEqual(client.deleted, ["/threads/retained-1"])

    def test_post_completion_observation_captures_delayed_hpa_sample(self):
        args = SimpleNamespace(
            namespace="ns",
            hpa="queue-hpa",
            deployment="queue",
            api_deployment="api",
            expected_context="approved-context",
            sample_interval=1,
        )
        observation = {
            "current": 2,
            "desired": 2,
            "deployment_replicas": 2,
            "cpu_average_utilization": 95,
            "cpu_target_utilization": 80,
        }
        samples = []
        with patch.object(las.time, "monotonic", side_effect=[0, 0, 0.5, 1.1]), patch.object(
            las.time, "sleep"
        ), patch.object(las, "hpa_observation", return_value=observation), patch.object(
            las, "deployment_replicas", return_value={"desired": 1, "ready": 1}
        ):
            las.observe_hpa_after_completion(args, 0, samples, 1)
        self.assertEqual(samples[0]["desired"], 2)
        self.assertEqual(samples[0]["ready"], 2)

    def test_product_load_records_no_cpu_scale_observed(self):
        scenario = {
            "graph_id": "agent",
            "case": {
                "name": "load",
                "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
                "context": {"llm_config": {"model": "test-model"}},
                "expected_state_values": ["marker-{{RUN_MARKER}}"],
            },
        }
        observation = {
            "min": 1,
            "max": 3,
            "desired": 1,
            "current": 1,
            "cpu_metrics_present": True,
            "cpu_average_utilization": 10,
            "cpu_target_utilization": 80,
            "deployment_replicas": 1,
        }
        args = SimpleNamespace(
            workers=2,
            timeout=30,
            request_timeout=30,
            sample_interval=1,
            namespace="ns",
            hpa="queue-hpa",
            deployment="queue",
            api_deployment="api",
            expected_context="approved-context",
            run_mode="queued",
            scale_expectation="observe",
        )
        run_result = [{"case": "load", "mode": "queued", "duration_seconds": 0.1}]
        output = io.StringIO()
        with patch.dict("os.environ", {"LAS_DISPOSABLE_CLUSTER_CONFIRMED": "true", "LAS_BASE_URL": "http://127.0.0.1:2024"}), \
             patch.object(las, "read_scenario", return_value=scenario), \
             patch.object(las, "hpa_observation", return_value=observation) as hpa, \
             patch.object(las, "deployment_replicas", return_value={"desired": 1, "ready": 1}) as deployment, \
             patch.object(las, "run_protocol_case", return_value=run_result), \
             patch("sys.stdout", output):
            las.product_load_command(args)
        result = json.loads(output.getvalue())
        self.assertEqual(result["result"], "OBSERVATION")
        self.assertEqual(
            result["acceptance_scope"],
            "requires_identity_bound_lifecycle_orchestrator",
        )
        self.assertEqual(result["scale_observation"], "no_cpu_scale_observed")
        self.assertEqual(result["cpu_scale_evidence"], "OBSERVATION")
        self.assertFalse(result["cpu_trigger_observed"])
        self.assertEqual(result["completed_runs"], 2)
        self.assertEqual(result["api_replicas"], 1)
        self.assertTrue(all(call.args[-1] == "approved-context" for call in hpa.call_args_list))
        self.assertTrue(all(call.args[-1] == "approved-context" for call in deployment.call_args_list))

    def test_product_load_cannot_claim_required_cpu_scale_from_replicas_alone(self):
        scenario = {
            "graph_id": "agent",
            "case": {
                "name": "load",
                "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
                "context": {"llm_config": {"model": "test-model"}},
                "expected_state_values": ["marker-{{RUN_MARKER}}"],
            },
        }
        baseline = {
            "min": 1,
            "max": 3,
            "desired": 1,
            "current": 1,
            "cpu_metrics_present": True,
            "cpu_average_utilization": 20,
            "cpu_target_utilization": 80,
            "deployment_replicas": 1,
        }
        replica_growth = dict(
            baseline,
            desired=2,
            current=2,
            deployment_replicas=2,
            cpu_average_utilization=50,
        )
        args = SimpleNamespace(
            workers=1,
            timeout=30,
            request_timeout=30,
            sample_interval=1,
            post_completion_observation=0,
            namespace="ns",
            hpa="queue-hpa",
            deployment="queue",
            api_deployment="api",
            expected_context="approved-context",
            run_mode="queued",
            scale_expectation="required",
        )
        run_result = [{"case": "load", "mode": "queued", "duration_seconds": 0.1}]
        with patch.dict(
            "os.environ",
            {
                "LAS_DISPOSABLE_CLUSTER_CONFIRMED": "true",
                "LAS_BASE_URL": "http://127.0.0.1:2024",
            },
        ), patch.object(las, "read_scenario", return_value=scenario), patch.object(
            las, "hpa_observation", side_effect=[baseline, replica_growth]
        ), patch.object(
            las, "deployment_replicas", return_value={"desired": 1, "ready": 1}
        ), patch.object(
            las, "run_protocol_case", return_value=run_result
        ), self.assertRaisesRegex(
            las.AcceptanceError, "causal HPA CPU evidence"
        ):
            las.product_load_command(args)

    def test_product_load_rejects_expected_failure_case(self):
        scenario = {
            "graph_id": "agent",
            "case": {
                "name": "negative-load",
                "input": {"messages": [{"role": "user", "content": "{{RUN_MARKER}}"}]},
                "context": {"llm_config": {"model": "test-model"}},
                "expected_state_values": [],
                "expected_outcome": "failure",
            },
        }
        args = SimpleNamespace(
            workers=1,
            timeout=30,
            request_timeout=30,
            sample_interval=1,
            post_completion_observation=0,
        )
        with patch.dict("os.environ", {"LAS_DISPOSABLE_CLUSTER_CONFIRMED": "true"}), patch.object(
            las, "read_scenario", return_value=scenario
        ), patch.object(las, "hpa_observation") as hpa:
            with self.assertRaisesRegex(las.AcceptanceError, "successful product case"):
                las.product_load_command(args)
        hpa.assert_not_called()

    def test_client_rejects_url_userinfo_and_query(self):
        for url in ("https://user:pass@example.test", "https://example.test?token=value"):
            with self.subTest(url=url), self.assertRaises(las.AcceptanceError):
                las.LASClient(url, 2)

    def test_client_allows_plaintext_only_for_loopback_and_disables_redirects_and_proxies(self):
        for url in ("http://example.test", "http://10.0.0.8:2024"):
            with self.subTest(url=url), self.assertRaisesRegex(
                las.AcceptanceError, "loopback"
            ):
                las.LASClient(url, 2)

        for url in ("http://127.0.0.1:2024", "http://[::1]:2024", "https://example.test"):
            with self.subTest(url=url):
                client = las.LASClient(url, 2)
                proxies = [
                    handler.proxies
                    for handler in client.opener.handlers
                    if isinstance(handler, __import__("urllib.request").request.ProxyHandler)
                ]
                # An empty ProxyHandler contributes no protocol handler; the
                # important property is that build_opener did not install its
                # environment-derived default ProxyHandler.
                self.assertEqual(proxies, [])
                self.assertTrue(
                    any(isinstance(handler, las._RejectRedirects) for handler in client.opener.handlers)
                )

        with self.assertRaisesRegex(las.AcceptanceError, "redirects"):
            las._RejectRedirects().redirect_request(None, None, 302, "Found", {}, "https://other")

    def test_http_error_body_is_bounded_and_scanned_without_being_printed(self):
        client = las.LASClient("http://127.0.0.1:2024", 2)
        secret = "line\né"
        error_body = json.dumps({"error": secret}).encode()
        error = urllib.error.HTTPError(
            client.base_url + "/runs", 422, "failure", None, BytesIO(error_body)
        )
        client.opener = SimpleNamespace(open=lambda *_args, **_kwargs: (_ for _ in ()).throw(error))
        status, body, _ = client.request("POST", "/runs", {}, allow_http_error=True)
        self.assertEqual(status, 422)
        with self.assertRaisesRegex(las.AcceptanceError, "sensitive marker") as caught:
            las.assert_sensitive_absent(body, [secret], "HTTP error response")
        self.assertNotIn(secret, str(caught.exception))

        oversized = urllib.error.HTTPError(
            client.base_url + "/runs", 422, "failure", None, BytesIO(b"12345")
        )
        client.opener = SimpleNamespace(open=lambda *_args, **_kwargs: (_ for _ in ()).throw(oversized))
        with patch.object(las, "MAX_BODY", 4), self.assertRaisesRegex(
            las.AcceptanceError, "size limit"
        ):
            client.request("POST", "/runs", {}, allow_http_error=True)

    def test_response_assertions_exclude_metadata_and_sse_requires_terminal_contract(self):
        self.assertEqual(
            las.graph_response_strings(
                {"values": {"answer": "state-value"}, "metadata": {"answer": "metadata-value"}}
            ),
            ["state-value"],
        )
        with self.assertRaisesRegex(las.AcceptanceError, "omitted expected data"):
            las.assert_sse(
                b'event: metadata\ndata: {"marker":"metadata-only"}\n\n'
                b'event: updates\ndata: {"status":"success"}\n\n',
                ["metadata-only"],
                [],
            )

        case = {
            "name": "unverified-stream",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["marker-{{RUN_MARKER}}"],
            "run_modes": ["stream"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "terminal_event or eof_after_expected_values"):
            las.run_protocol_case(ProductProtocolClient(), "agent", case, 30)

    def test_failed_case_reports_cleanup_failure(self):
        class CleanupFailureClient(ProductProtocolClient):
            def request(self, method, path, payload=None, accept="application/json", allow_http_error=False):
                if method == "DELETE":
                    return 500, b"", "application/json"
                return super().request(method, path, payload, accept, allow_http_error)

        case = {
            "name": "cleanup-failure",
            "input": {"messages": [{"role": "user", "content": "marker-{{RUN_MARKER}}"}]},
            "context": {"llm_config": {"model": "test-model"}},
            "expected_state_values": ["other-{{RUN_MARKER}}"],
            "run_modes": ["sync"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "cleanup also failed"):
            las.run_protocol_case(CleanupFailureClient(), "agent", case, 30)

    def test_case_names_are_safe_to_emit(self):
        bad_runtime = {
            "name": "case\nsecret-value",
            "input": {"request": "test"},
            "expected_state_values": ["test"],
        }
        with self.assertRaisesRegex(las.AcceptanceError, "safe name"):
            las.run_protocol_case(ProductProtocolClient(), "agent", bad_runtime, 30)
        bad_product = {
            "cases": [{"name": "case with spaces", "calls": [{"task_prompt": "test", "expected_text": "done"}]}]
        }
        with self.assertRaisesRegex(product.ScenarioError, "safe name"):
            product.validate_scenario(bad_product)

    def test_hpa_observation_rejects_a_different_scale_target(self):
        hpa = {"spec": {"scaleTargetRef": {"kind": "Deployment", "name": "other-queue"}}}
        with patch.object(las, "kubectl_json", return_value=hpa) as get:
            with self.assertRaisesRegex(las.AcceptanceError, "scale target"):
                las.hpa_observation("ns", "queue-hpa", "expected-queue")
        self.assertEqual(get.call_count, 1)

    def test_hpa_observation_accepts_the_requested_deployment_target(self):
        hpa = {
            "spec": {"scaleTargetRef": {"kind": "Deployment", "name": "queue"}, "minReplicas": 1, "maxReplicas": 3},
            "status": {"currentReplicas": 1, "desiredReplicas": 1, "currentMetrics": [{"type": "Resource", "resource": {"name": "cpu"}}]},
        }
        deployment = {"status": {"readyReplicas": 1}}
        with patch.object(las, "kubectl_json", side_effect=[hpa, deployment]):
            observation = las.hpa_observation("ns", "queue-hpa", "queue")
        self.assertEqual(observation["deployment_replicas"], 1)
        stable = {
            "min": 1,
            "max": 3,
            "current": 1,
            "desired": 1,
            "deployment_replicas": 1,
        }
        self.assertEqual(las.require_stable_hpa_baseline(stable), 1)
        for unstable in (
            dict(stable, desired=2),
            dict(stable, deployment_replicas=2),
            dict(stable, current=0, desired=0, deployment_replicas=0),
        ):
            with self.subTest(unstable=unstable), self.assertRaisesRegex(
                las.AcceptanceError, "baseline"
            ):
                las.require_stable_hpa_baseline(unstable)

    def test_scale_waits_for_a_ready_replica_after_runs_finish(self):
        class CompletedFuture:
            def done(self):
                return True

            def result(self):
                return None

        observations = iter([
            {"current": 2, "desired": 2, "deployment_replicas": 1, "cpu_average_utilization": 90, "cpu_target_utilization": 80},
            {"current": 2, "desired": 2, "deployment_replicas": 2, "cpu_average_utilization": 70, "cpu_target_utilization": 80},
        ])
        with patch.object(las.time, "monotonic", return_value=0), patch.object(las.time, "sleep"):
            peak_hpa, peak_ready, _, peak_cpu = las.wait_for_ready_scale_up(
                lambda: next(observations), [CompletedFuture()], 1, 1, 30
            )
        self.assertEqual((peak_hpa, peak_ready), (2, 2))
        self.assertEqual(peak_cpu, 90)

    def test_desired_replicas_without_ready_worker_does_not_pass_scale_up(self):
        class CompletedFuture:
            def done(self):
                return True

            def result(self):
                return None

        with patch.object(las.time, "monotonic", side_effect=[0, 0, 0, 2]), patch.object(las.time, "sleep"):
            with self.assertRaisesRegex(las.AcceptanceError, "ready worker"):
                las.wait_for_ready_scale_up(
                    lambda: {"current": 2, "desired": 2, "deployment_replicas": 1, "cpu_average_utilization": 90, "cpu_target_utilization": 80},
                    [CompletedFuture()], 1, 1, 1,
                )

    def test_ready_replica_growth_without_cpu_trigger_is_only_observation(self):
        class CompletedFuture:
            def done(self):
                return True

            def result(self):
                return None

        observation = {
            "current": 2,
            "desired": 2,
            "deployment_replicas": 2,
            "cpu_average_utilization": 50,
            "cpu_target_utilization": 80,
        }
        with patch.object(las.time, "monotonic", side_effect=[0, 0, 0, 2]), patch.object(
            las.time, "sleep"
        ):
            with self.assertRaisesRegex(las.AcceptanceError, "causal CPU evidence"):
                las.wait_for_ready_scale_up(
                    lambda: observation, [CompletedFuture()], 1, 1, 1
                )

    def test_kubectl_json_pins_the_expected_context(self):
        completed = SimpleNamespace(stdout="{}")
        with patch("subprocess.run", return_value=completed) as run:
            las.kubectl_json("ns", "deployment", "queue", "approved-context")
        command = run.call_args.args[0]
        self.assertEqual(command[1:3], ["--context", "approved-context"])

    def test_product_result_requires_nonempty_expected_text(self):
        for expected in (None, "", "   "):
            with self.subTest(expected=expected), self.assertRaisesRegex(AssertionError, "non-empty"):
                product.assert_expected_result([], expected, "product case")

    def test_product_result_requires_completed_caller_response(self):
        for event in (
            {"status": "Thinking", "response": "expected output"},
            {"status": "Completed", "result": "expected output"},
            {"status": "Completed", "message": "expected output"},
            {"status": "Completed", "success": False, "response": "expected output"},
        ):
            with self.subTest(event=event), self.assertRaises(product.QualificationError):
                product.assert_expected_result([event], "expected output", "product case")
        product.assert_expected_result(
            [{"status": "Completed", "success": True, "response": "the expected output"}],
            "expected output",
            "product case",
        )
        contradictory = (
            [
                {"status": "Error", "success": False},
                {"status": "Completed", "success": True, "response": "expected output"},
            ],
            [
                {"status": "Completed", "success": True, "response": "expected output"},
                {"status": "Completed", "success": True, "response": "expected output"},
            ],
            [
                {"status": "Completed", "success": True, "response": "expected output"},
                {"status": "Thinking"},
            ],
        )
        for events in contradictory:
            with self.subTest(events=events), self.assertRaises(product.QualificationError):
                product.assert_expected_result(events, "expected output", "product case")

    def test_product_scenario_keeps_mpr131_as_known_failure(self):
        base = {
            "cases": [{"name": "positive", "calls": [{"task_prompt": "test", "expected_text": "done"}]}]
        }
        cases, secrets = product.validate_scenario(base)
        self.assertEqual((len(cases), secrets), (1, []))
        base["external_gates"] = {"MPR-131": "PASS"}
        with self.assertRaisesRegex(product.ScenarioError, "KNOWN_FAIL"):
            product.validate_scenario(base)

        credential_case = {
            "cases": [{
                "name": "credential-case",
                "calls": [{
                    "task_prompt": "test",
                    "llm": {"provider": "test", "api_key": "synthetic"},
                    "expected_text": "done",
                }],
            }]
        }
        with self.assertRaisesRegex(product.ScenarioError, "require sensitive_values"):
            product.validate_scenario(credential_case)

        credential_case["sensitive_values"] = ["unrelated-canary"]
        credential_case["cases"][0]["check_state"] = False
        with self.assertRaisesRegex(product.ScenarioError, "cannot disable state checks"):
            product.validate_scenario(credential_case)
        del credential_case["cases"][0]["check_state"]
        _, derived = product.validate_scenario(credential_case)
        self.assertIn("synthetic", derived)

    def test_product_structured_shape_supports_native_and_json_responses(self):
        shape = {"required": ["answer", "meta.count"], "types": {"answer": "string", "meta.count": "integer"}}
        native = [{"status": "Completed", "success": True, "response": {"answer": "ok", "meta": {"count": 1}}}]
        encoded = [{"status": "Completed", "success": True, "response": '{"answer":"ok","meta":{"count":1}}'}]
        product.assert_expected_shape(native, shape, "native")
        product.assert_expected_shape(encoded, shape, "encoded")
        with self.assertRaisesRegex(product.QualificationError, "structured response shape"):
            product.assert_expected_shape(
                [{"status": "Completed", "success": True, "response": {"answer": "ok", "meta": {"count": True}}}],
                shape,
                "wrong type",
            )

    def test_product_expected_failure_is_sanitized_and_classified(self):
        expectation = product.normalize_expectation(
            {
                "expect": {
                    "outcome": "failure",
                    "http_status": [400, 422],
                    "error_category": "validation",
                    "owner": "product",
                }
            },
            "negative",
        )
        actual, category = product.assert_expected_outcome(
            200,
            [{"status": "Completed", "success": False, "http_error_code": "422"}],
            expectation,
            "negative",
        )
        self.assertEqual((actual, category), ("failure", "validation"))

    def test_product_malformed_raw_payload_requires_the_http_caller_route(self):
        invalid = {
            "cases": [{
                "name": "malformed-json",
                "calls": [{
                    "raw_payload": "{",
                    "expect": {
                        "outcome": "failure",
                        "http_status": 422,
                        "error_category": "validation",
                        "owner": "caller",
                    },
                }],
                "check_state": False,
            }]
        }
        with self.assertRaisesRegex(product.ScenarioError, "unsupported fields"):
            product.validate_scenario(invalid)

    def test_product_negative_case_can_require_empty_state(self):
        scenario = {
            "cases": [{
                "name": "invalid-dependency",
                "calls": [{
                    "task_prompt": "test",
                    "expect": {
                        "outcome": "failure",
                        "error_category": "dependency",
                        "owner": "dependency",
                    },
                }],
                "expect_empty_state": True,
            }]
        }
        cases, _ = product.validate_scenario(scenario)
        self.assertTrue(cases[0]["expect_empty_state"])
        scenario["cases"][0]["check_state"] = False
        with self.assertRaisesRegex(product.ScenarioError, "cannot disable state checks"):
            product.validate_scenario(scenario)

    def test_product_empty_state_recognizes_default_containers_and_rejects_values(self):
        self.assertTrue(product.state_is_effectively_empty({}))
        self.assertTrue(product.state_is_effectively_empty({"messages": [], "metadata": {}}))
        self.assertFalse(product.state_is_effectively_empty({"messages": [{"content": "written"}]}))

    def test_product_not_found_is_only_empty_for_http_404(self):
        missing = RuntimeError("not found")
        missing.status_code = 404
        other = RuntimeError("failure")
        other.status_code = 500
        self.assertTrue(product.is_not_found(missing))
        self.assertFalse(product.is_not_found(other))

    def test_product_expected_failure_accepts_missing_thread_as_empty_state(self):
        config = {
            "cases": [{
                "name": "rejected-before-thread",
                "calls": [{
                    "task_prompt": "invalid request",
                    "expect": {
                        "outcome": "failure",
                        "http_status": 422,
                        "error_category": "validation",
                        "owner": "caller",
                    },
                }],
                "expect_empty_state": True,
            }],
        }

        async def create_agent(_tenant, _payload, _request):
            return SimpleNamespace(status_code=201, body=b'{"runtime_id":"assistant-id"}')

        assistant_delete_count = 0

        async def delete_agent(_tenant, _assistant_id, _request):
            nonlocal assistant_delete_count
            assistant_delete_count += 1
            status = "DELETING" if assistant_delete_count == 1 else "AGENT_NOT_FOUND"
            return SimpleNamespace(
                status_code=200,
                body=json.dumps({"status": status}).encode(),
            )

        async def invoke(_tenant, _payload, _request_id):
            return 200, [{"status": "Error", "success": False, "http_error_code": 422}], {}

        async def get_state(_thread_id):
            missing = RuntimeError("not found")
            missing.status_code = 404
            raise missing

        deleted_thread_ids = []

        async def delete_thread(thread_id):
            deleted_thread_ids.append(thread_id)

        modules = {}
        for module_name in (
            "slim_api", "slim_api.models", "slim_api.models.aws", "slim_api.routers",
            "slim_api.routers.las_agent", "slim_api.util", "slim_api.util.las_client",
            "slim_api.util.las_utils",
        ):
            modules[module_name] = types.ModuleType(module_name)
            parent, _, child = module_name.rpartition(".")
            if parent:
                setattr(modules[parent], child, modules[module_name])
        modules["slim_api.models.aws"].CreateAgentPayload = lambda **kwargs: SimpleNamespace(**kwargs)
        modules["slim_api.routers.las_agent"].create_agent = create_agent
        modules["slim_api.routers.las_agent"].delete_agent = delete_agent
        modules["slim_api.util.las_client"].get_las_client = lambda: SimpleNamespace(
            threads=SimpleNamespace(get_state=get_state, delete=delete_thread)
        )
        modules["slim_api.util.las_utils"].get_proper_thread_id = (
            lambda tenant, session_id: f"mapped:{tenant}:{session_id}"
        )
        output = io.StringIO()
        with patch.dict(sys.modules, modules), patch.object(product, "invoke", invoke), patch(
            "sys.stdin", io.StringIO(json.dumps(config))
        ), patch("sys.stdout", output):
            asyncio.run(product.main())
        result = json.loads(output.getvalue())
        self.assertIn("rejected-before-thread:empty-state", result["checks"])
        self.assertEqual(result["case_results"][0]["transport_http_status"], 200)
        self.assertEqual(result["case_results"][0]["reported_error_status"], 422)
        self.assertEqual(len(deleted_thread_ids), 1)
        self.assertTrue(deleted_thread_ids[0].startswith("mapped:product-qualification:"))

    def test_product_create_failures_cleanup_when_runtime_id_is_recoverable(self):
        config = {
            "cases": [{
                "name": "mock",
                "calls": [{"task_prompt": "test", "expected_text": "done"}],
            }]
        }

        for status_code, malformed, expected in (
            (201, False, RuntimeError),
            (201, True, product.QualificationError),
            (200, False, product.QualificationError),
            (202, False, product.QualificationError),
        ):
            with self.subTest(status_code=status_code, malformed_create_response=malformed):
                deleted = []

                async def create_agent(_tenant, _payload, _request):
                    body = (
                        b'{"runtime_id":"assistant-id"'
                        if malformed
                        else b'{"runtime_id":"assistant-id"}'
                    )
                    return SimpleNamespace(status_code=status_code, body=body)

                async def delete_agent(_tenant, assistant_id, _request):
                    deleted.append(assistant_id)
                    status = "DELETING" if len(deleted) == 1 else "AGENT_NOT_FOUND"
                    return SimpleNamespace(
                        status_code=200,
                        body=json.dumps({"status": status}).encode(),
                    )

                def get_las_client():
                    raise RuntimeError("client construction failed")

                modules = {}
                for module_name in (
                    "slim_api", "slim_api.models", "slim_api.models.aws", "slim_api.routers",
                    "slim_api.routers.las_agent", "slim_api.util", "slim_api.util.las_client",
                    "slim_api.util.las_utils",
                ):
                    modules[module_name] = types.ModuleType(module_name)
                    parent, _, child = module_name.rpartition(".")
                    if parent:
                        setattr(modules[parent], child, modules[module_name])
                modules["slim_api.models.aws"].CreateAgentPayload = (
                    lambda **kwargs: SimpleNamespace(**kwargs)
                )
                modules["slim_api.routers.las_agent"].create_agent = create_agent
                modules["slim_api.routers.las_agent"].delete_agent = delete_agent
                modules["slim_api.util.las_client"].get_las_client = get_las_client
                modules["slim_api.util.las_utils"].get_proper_thread_id = lambda *_args: "thread"

                with patch.dict(sys.modules, modules), patch(
                    "sys.stdin", io.StringIO(json.dumps(config))
                ), self.assertRaises(expected):
                    asyncio.run(product.main())
                self.assertEqual(deleted, ["assistant-id", "assistant-id"])

    def test_product_create_recovery_is_unique_and_cleanup_failure_is_fatal(self):
        self.assertIsNone(
            product.recover_created_assistant_id(
                b'{"runtime_id":"assistant-one","other":{"runtime_id":"assistant-two"}}'
            )
        )

        config = {
            "sensitive_values": ["create-leak"],
            "cases": [{
                "name": "mock",
                "calls": [{"task_prompt": "test", "expected_text": "done"}],
            }],
        }

        async def create_agent(_tenant, _payload, _request):
            return SimpleNamespace(
                status_code=201,
                body=b'{"runtime_id":"assistant-id","leak":"create-leak"}',
            )

        async def delete_agent(_tenant, _assistant_id, _request):
            return SimpleNamespace(status_code=500, body=b'{}')

        modules = {}
        for module_name in (
            "slim_api", "slim_api.models", "slim_api.models.aws", "slim_api.routers",
            "slim_api.routers.las_agent", "slim_api.util", "slim_api.util.las_client",
            "slim_api.util.las_utils",
        ):
            modules[module_name] = types.ModuleType(module_name)
            parent, _, child = module_name.rpartition(".")
            if parent:
                setattr(modules[parent], child, modules[module_name])
        modules["slim_api.models.aws"].CreateAgentPayload = (
            lambda **kwargs: SimpleNamespace(**kwargs)
        )
        modules["slim_api.routers.las_agent"].create_agent = create_agent
        modules["slim_api.routers.las_agent"].delete_agent = delete_agent
        modules["slim_api.util.las_client"].get_las_client = lambda: None
        modules["slim_api.util.las_utils"].get_proper_thread_id = lambda *_args: "thread"

        with patch.dict(sys.modules, modules), patch(
            "sys.stdin", io.StringIO(json.dumps(config))
        ), self.assertRaisesRegex(
            product.QualificationError,
            "assistant create validation failed and cleanup also failed",
        ):
            asyncio.run(product.main())

    def test_product_state_keys_and_empty_shapes_cannot_prove_acceptance(self):
        marker = "state-marker"
        self.assertNotIn(marker, list(product.value_strings({marker: "unrelated"})))
        with self.assertRaisesRegex(product.ScenarioError, "assert at least one"):
            product.normalize_expectation(
                {"expect": {"outcome": "success", "shape": {}}},
                "empty shape",
            )
        with self.assertRaisesRegex(product.QualificationError, "did not assert"):
            product.assert_expected_shape([], {}, "empty shape")

    def test_product_router_value_error_is_not_fabricated_as_validation(self):
        class Payload:
            def __init__(self, **kwargs):
                self.payload = kwargs["payload"]

        async def invoke_agent(*_args, **_kwargs):
            raise ValueError("internal router bug with sensitive details")

        modules = {}
        for name in (
            "slim_api", "slim_api.models", "slim_api.models.aws", "slim_api.routers",
            "slim_api.routers.las_agent",
        ):
            modules[name] = types.ModuleType(name)
            parent, _, child = name.rpartition(".")
            if parent:
                setattr(modules[parent], child, modules[name])
        modules["slim_api.models.aws"].InvokeAgentPayload = Payload
        modules["slim_api.routers.las_agent"].invoke_agent = invoke_agent
        with patch.dict(sys.modules, modules):
            with self.assertRaises(ValueError):
                asyncio.run(product.invoke("tenant", {"task": "test"}, "request"))

    def test_product_payload_forwards_both_supported_structured_field_names(self):
        call = {
            "task_prompt": "test",
            "structured_output": {"fields": {"answer": {"type": "string"}}},
            "structured_response": {"type": "object"},
        }
        payload = product.build_payload(call, "assistant", "session")
        self.assertEqual(payload["structured_output"], call["structured_output"])
        self.assertEqual(payload["structured_response"], call["structured_response"])

    def test_product_raw_payload_cannot_override_harness_owned_identifiers(self):
        for field in ("agent_id", "session_id"):
            scenario = {
                "cases": [{
                    "name": "owned-id",
                    "calls": [{
                        "payload": {field: "unowned-resource", "task_prompt": "test"},
                        "expected_text": "done",
                    }],
                }]
            }
            with self.subTest(field=field), self.assertRaisesRegex(
                product.ScenarioError, "harness-owned"
            ):
                product.validate_scenario(scenario)

        # Defensive construction still overwrites the values if a caller
        # bypasses scenario validation.
        payload = product.build_payload(
            {"payload": {"agent_id": "other", "session_id": "other", "task_prompt": "test"}},
            "owned-agent",
            "owned-session",
        )
        self.assertEqual(payload["agent_id"], "owned-agent")
        self.assertEqual(payload["session_id"], "owned-session")

    def test_product_strict_json_rejects_nonfinite_and_duplicate_values(self):
        for document in ('{"value": NaN}', '{"value": Infinity}', '{"value":1,"value":2}'):
            with self.subTest(document=document), self.assertRaises(ValueError):
                product.strict_json_loads(document)

        shape = {"required": ["value"], "types": {"value": "number"}}
        with self.assertRaisesRegex(product.QualificationError, "structured response shape"):
            product.assert_expected_shape(
                [{"status": "Completed", "success": True, "response": {"value": float("nan")}}],
                shape,
                "finite-number",
            )

    def test_product_collect_enforces_bounded_valid_ndjson(self):
        class Response:
            status_code = 200

            def __init__(self, chunks):
                async def body():
                    for chunk in chunks:
                        yield chunk

                self.body_iterator = body()

        status, events = asyncio.run(
            product.collect(Response([b'{"status":"Comp', b'leted"}\n']))
        )
        self.assertEqual((status, events), (200, [{"status": "Completed"}]))

        unicode_event = '{"response":"caf\u00e9"}\n'.encode("utf-8")
        split_at = unicode_event.index(b"\xc3") + 1
        _, events = asyncio.run(
            product.collect(Response([unicode_event[:split_at], unicode_event[split_at:]]))
        )
        self.assertEqual(events, [{"response": "caf\u00e9"}])

        with self.assertRaisesRegex(product.QualificationError, "invalid NDJSON"):
            asyncio.run(product.collect(Response([b'{"status":'])))

        with patch.object(product, "MAX_CALLER_RESPONSE_BYTES", 4):
            with self.assertRaisesRegex(product.QualificationError, "bounded evidence"):
                asyncio.run(product.collect(Response([b"12345"])))

        with patch.object(product, "MAX_CALLER_EVENTS", 1):
            with self.assertRaisesRegex(product.QualificationError, "bounded event"):
                asyncio.run(product.collect(Response([b"{}\n{}\n"])))

    def test_product_router_exception_reads_sdk_response_status(self):
        class Payload:
            def __init__(self, **kwargs):
                self.payload = kwargs["payload"]

        class SDKError(RuntimeError):
            def __init__(self):
                super().__init__("sensitive SDK detail")
                self.response = SimpleNamespace(status_code=404)

        async def invoke_agent(*_args, **_kwargs):
            raise SDKError()

        modules = {}
        for name in (
            "slim_api", "slim_api.models", "slim_api.models.aws", "slim_api.routers",
            "slim_api.routers.las_agent",
        ):
            modules[name] = types.ModuleType(name)
            parent, _, child = name.rpartition(".")
            if parent:
                setattr(modules[parent], child, modules[name])
        modules["slim_api.models.aws"].InvokeAgentPayload = Payload
        modules["slim_api.routers.las_agent"].invoke_agent = invoke_agent
        with patch.dict(sys.modules, modules):
            status, events, captured = asyncio.run(
                product.invoke("tenant", {"task": "test"}, "request")
            )
        self.assertEqual(status, 404)
        self.assertEqual(product.classify_error(status, events), "not_found")
        self.assertNotIn("sensitive SDK detail", json.dumps(captured))

    def test_known_gate_does_not_waive_canary_assertion(self):
        self.assertEqual(product.EXTERNAL_GATES[0]["status"], "KNOWN_FAIL")
        with self.assertRaisesRegex(product.QualificationError, "sensitive marker"):
            product.assert_absent({"run": {"kwargs": "fake-canary"}}, ["fake-canary"], "run list")
        with self.assertRaisesRegex(product.QualificationError, "sensitive marker"):
            product.assert_absent(
                {"log": r"s\u00e9cret"}, ["sécret"], "escaped log"
            )
        self.assertFalse(
            product.assistant_delete_reports_absent(
                SimpleNamespace(
                    status_code=200,
                    body=b'{"status":"AGENT_NOT_FOUND_BUT_PRESENT"}',
                )
            )
        )
        with self.assertRaisesRegex(product.QualificationError, "sensitive marker"):
            product.assert_delete_response_absent(
                SimpleNamespace(
                    status_code=200,
                    body=b'{"status":"AGENT_NOT_FOUND","leak":"fake-canary"}',
                ),
                ["fake-canary"],
                "cleanup",
            )

    def test_product_case_uses_valid_name_mapped_thread_and_retains_redaction_gate(self):
        config = {
            "sensitive_values": ["test-canary"],
            "cases": [{
                "name": "mock",
                "calls": [{
                    "task_prompt": "test",
                    "llm": {"provider": "test", "api_key": "test-canary"},
                    "expected_text": "expected output",
                }],
            }],
        }

        for leak_surface in (None, "state", "history", "delete", "cleanup-state"):
            with self.subTest(leak_surface=leak_surface):
                created_names = []
                invoked_payloads = []
                state_ids = []
                history_ids = []
                deleted_ids = []
                deleted_thread_ids = []
                cleanup_observations = 0

                async def create_agent(tenant, payload, request):
                    created_names.append(payload.agent_name)
                    return SimpleNamespace(status_code=201, body=b'{"runtime_id":"assistant-id"}')

                async def delete_agent(tenant, assistant_id, request):
                    deleted_ids.append(assistant_id)
                    status = "DELETING" if len(deleted_ids) == 1 else "AGENT_NOT_FOUND"
                    return SimpleNamespace(
                        status_code=200,
                        body=json.dumps({"status": status}).encode(),
                    )

                async def invoke(tenant, payload, request_id):
                    invoked_payloads.append(payload)
                    return 200, [{"status": "Completed", "success": True, "response": "expected output"}], {}

                async def get_state(thread_id):
                    nonlocal cleanup_observations
                    state_ids.append(thread_id)
                    if thread_id in deleted_thread_ids:
                        if leak_surface == "cleanup-state" and cleanup_observations == 0:
                            cleanup_observations += 1
                            return {
                                "values": {},
                                "metadata": {"llm_config": {"api_key": "test-canary"}},
                            }
                        missing = RuntimeError("not found")
                        missing.status_code = 404
                        raise missing
                    state = {"values": {"messages": [{"content": "expected output"}]}}
                    if leak_surface == "state":
                        state["metadata"] = {"llm_config": {"api_key": "test-canary"}}
                    return state

                async def all_checkpoints(client, thread_id):
                    history_ids.append(thread_id)
                    value = "test-canary" if leak_surface == "history" else "redacted"
                    return [{"metadata": {"llm_config": {"api_key": value}}}]

                async def delete_thread(thread_id):
                    deleted_thread_ids.append(thread_id)
                    if leak_surface == "delete":
                        return {"status": "DELETING", "leak": "test-canary"}
                    return {"status": "DELETING"}

                modules = {}
                for name in (
                    "slim_api", "slim_api.models", "slim_api.models.aws", "slim_api.routers",
                    "slim_api.routers.las_agent", "slim_api.util", "slim_api.util.las_client",
                    "slim_api.util.las_utils",
                ):
                    modules[name] = types.ModuleType(name)
                    parent, _, child = name.rpartition(".")
                    if parent:
                        setattr(modules[parent], child, modules[name])
                modules["slim_api.models.aws"].CreateAgentPayload = lambda **kwargs: SimpleNamespace(**kwargs)
                modules["slim_api.routers.las_agent"].create_agent = create_agent
                modules["slim_api.routers.las_agent"].delete_agent = delete_agent
                modules["slim_api.util.las_client"].get_las_client = lambda: SimpleNamespace(
                    threads=SimpleNamespace(get_state=get_state, delete=delete_thread)
                )
                modules["slim_api.util.las_utils"].get_proper_thread_id = (
                    lambda tenant, session_id: f"mapped:{tenant}:{session_id}"
                )

                output = io.StringIO()
                async def no_sleep(_delay):
                    return None

                with patch.dict(sys.modules, modules), patch.object(product, "invoke", invoke), patch.object(
                    product, "all_checkpoints", all_checkpoints
                ), patch.object(product.asyncio, "sleep", no_sleep), patch(
                    "sys.stdin", io.StringIO(json.dumps(config))
                ), patch("sys.stdout", output):
                    if leak_surface:
                        expected_source = {
                            "state": "graph state",
                            "history": "checkpoint history",
                            "delete": "thread cleanup evidence",
                            "cleanup-state": "thread cleanup evidence",
                        }[leak_surface]
                        with self.assertRaisesRegex(AssertionError, expected_source):
                            asyncio.run(product.main())
                    else:
                        asyncio.run(product.main())

                self.assertRegex(created_names[0], r"^aip5410[A-Za-z0-9]+$")
                self.assertEqual(invoked_payloads[0]["agent_id"], "assistant-id")
                expected_thread = f"mapped:product-qualification:{invoked_payloads[0]['session_id']}"
                expected_state_reads = 3 if leak_surface == "cleanup-state" else 2
                self.assertEqual(state_ids, [expected_thread] * expected_state_reads)
                self.assertEqual(
                    history_ids,
                    [] if leak_surface == "state" else [expected_thread],
                )
                self.assertEqual(deleted_ids, ["assistant-id", "assistant-id"])
                self.assertEqual(deleted_thread_ids, [expected_thread])
                if leak_surface is None:
                    result = json.loads(output.getvalue())
                    self.assertEqual(result["result"], "PASS")
                    self.assertEqual(result["route"], "in-pod-slim-router")
                    case_result = result["case_results"][0]
                    self.assertEqual(case_result["route"], "in-pod-slim-router")
                    self.assertRegex(case_result["request_id"], r"^aip5410-[0-9a-f]+-0-0$")
                    self.assertEqual(case_result["session_id"], invoked_payloads[0]["session_id"])
                    self.assertEqual(case_result["thread_id"], expected_thread)


if __name__ == "__main__":
    unittest.main()
