"""Offline tests for the MPR-44 external SLIM caller-route helper."""

import importlib.util
import io
import json
import os
import pathlib
import tempfile
import threading
import unittest
import uuid
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace
from unittest.mock import patch
from urllib import error


SCRIPT = pathlib.Path(__file__).parent / "validation" / "mpr44_product_caller_acceptance.py"
MANIFEST = pathlib.Path(__file__).parent / "validation" / "mpr44-slim-candidate.yaml"
SPEC = importlib.util.spec_from_file_location("mpr44_product_caller_acceptance", SCRIPT)
mpr44 = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = mpr44
SPEC.loader.exec_module(mpr44)


class CallerRouteHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    route = "/qualification/slim-api/v1alpha1/agent/las"
    state = None

    def log_message(self, _format, *_args):
        return

    def _read(self):
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def _write(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _authorized(self):
        authorization = self.headers.get("Authorization")
        if authorization != "Bearer test-caller-token":
            self._write(401, b'{"error_message":"unauthorized"}')
            return False
        return True

    def _record(self, body):
        self.state["requests"].append(
            {
                "method": self.command,
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "request_id": self.headers.get("request_id"),
                "body": body,
            }
        )

    def do_POST(self):
        body = self._read()
        self._record(body)
        if not self._authorized():
            return
        try:
            outer = json.loads(body)
        except json.JSONDecodeError:
            self._write(422, b'{"detail":"invalid JSON"}')
            return
        if self.path == self.route:
            assistant_id = str(uuid.uuid4())
            self.state["assistants"].add(assistant_id)
            payload = json.dumps({"runtime_id": assistant_id, "status": "READY"}).encode()
            self._write(201, payload)
            return
        if self.path != self.route + "/invoke":
            self._write(404, b"{}")
            return
        try:
            inner = json.loads(outer["payload"])
        except (KeyError, TypeError, json.JSONDecodeError):
            self._write(422, b'{"detail":"invalid payload"}')
            return
        self.state["invocations"].append(inner)
        self.state["session_assistants"][inner["session_id"]] = inner["agent_id"]
        prompt = inner.get("task_prompt", "")
        if prompt == "terminal-failure":
            terminal = {"status": "Completed", "success": False, "response": "ignored"}
        elif prompt == "key-only":
            terminal = {"status": "Completed", "success": True, "response": {"expected-marker": "wrong"}}
        elif prompt == "structured":
            terminal = {
                "status": "Completed",
                "success": True,
                "response": {"answer": "ok", "meta": {"count": 1}},
            }
        elif prompt == "nan-response":
            terminal = {"status": "Completed", "success": True, "response": {"answer": float("nan")}}
        else:
            previous = self.state["sessions"].get(inner["session_id"])
            marker = previous or prompt
            self.state["sessions"][inner["session_id"]] = marker
            terminal = {"status": "Completed", "success": True, "response": marker}
        if prompt == "bad-ndjson":
            response_body = b'{"status":"Thinking"}\nnot-json\n'
        elif prompt == "oversize":
            response_body = (b"x" * 5000) + b"\n"
        else:
            response_body = (
                json.dumps({"status": "Thinking", "success": True}).encode()
                + b"\n"
                + json.dumps(terminal).encode()
                + b"\n"
            )
        if prompt == "wrong-media":
            content_type = "application/json"
        elif prompt == "evil-media":
            content_type = "text/application/x-ndjson-evil"
        else:
            content_type = "application/x-ndjson"
        self._write(200, response_body, content_type)

    def do_GET(self):
        body = self._read()
        self._record(body)
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", self.state["redirect_target"])
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self._write(200, b'{"reached":true}')

    def do_DELETE(self):
        body = self._read()
        self._record(body)
        if not self._authorized():
            return
        assistant_id = self.path.rsplit("/", 1)[-1]
        if self.state.get("fail_cleanup"):
            self._write(500, b'{"status":"FAILED"}')
        elif assistant_id in self.state["assistants"]:
            self.state["assistants"].remove(assistant_id)
            for session_id, owner in list(self.state["session_assistants"].items()):
                if owner == assistant_id:
                    self.state["sessions"].pop(session_id, None)
                    self.state["session_assistants"].pop(session_id, None)
            self._write(200, json.dumps({"status": "DELETING"}).encode())
        else:
            self._write(200, json.dumps({"status": "AGENT_NOT_FOUND"}).encode())


class MPR44CallerRouteTests(unittest.TestCase):
    def test_candidate_does_not_mount_a_kubernetes_service_account_token(self):
        manifest = MANIFEST.read_text(encoding="utf-8")
        self.assertIn(
            "automountServiceAccountToken: false",
            manifest,
        )
        self.assertIn("${MPR44_SLIM_IMAGE_AT_DIGEST}", manifest)
        self.assertIn("${MPR44_LAS_SERVICE_URL}", manifest)
        self.assertNotRegex(manifest, r"[0-9]{12}\.dkr\.ecr\.")

    def test_scenario_json_rejects_nonfinite_and_duplicate_values(self):
        for document in (
            '{"cases":[],"value":NaN}',
            '{"cases":[],"value":Infinity}',
            '{"cases":[],"cases":[]}',
        ):
            with self.subTest(document=document), self.assertRaises(mpr44.ScenarioError):
                mpr44.read_scenario(io.StringIO(document))

    def setUp(self):
        self.state = {
            "requests": [],
            "assistants": set(),
            "invocations": [],
            "sessions": {},
            "session_assistants": {},
            "fail_cleanup": False,
            "redirect_target": "",
        }
        CallerRouteHandler.state = self.state
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), CallerRouteHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"
        self.client = mpr44.SlimHTTPClient(self.base_url, timeout=2)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    @staticmethod
    def scenario(*calls):
        call_list = list(calls)
        cases = [{"name": "representative", "calls": call_list}]
        if len(call_list) == 1:
            # Focused tests retain a real recall proof instead of satisfying the
            # contract by merely duplicating one request.
            cases.append(
                {
                    "name": "session-recall-proof",
                    "calls": [
                        {
                            "task_prompt": "{{SESSION_MARKER}}",
                            "expected_text": "{{SESSION_MARKER}}",
                        },
                        {
                            "task_prompt": "recall the preceding marker",
                            "expected_text": "{{SESSION_MARKER}}",
                        },
                    ],
                }
            )
        return {
            "scenario_version": 1,
            "sensitive_values": ["secret-canary"],
            "cases": cases,
        }

    def test_full_route_owns_ids_reuses_session_and_cleans_up(self):
        scenario = self.scenario(
            {
                "task_prompt": "{{SESSION_MARKER}}",
                "system_prompt": "be concise",
                "llm": {"provider": "test", "api_key": "secret-canary"},
                "expected_text": "{{SESSION_MARKER}}",
            },
            {
                "task_prompt": "recall",
                "llm": {"provider": "test", "api_key": "secret-canary"},
                "expected_text": "{{SESSION_MARKER}}",
            },
        )
        result = mpr44.execute(self.client, mpr44.validate_scenario(scenario), "test-caller-token", "qualification")
        self.assertEqual(result["result"], "PASS")
        self.assertIn("representative:same-session-follow-up", result["checks"])
        self.assertIn("missing-bearer-denied", result["checks"])
        self.assertIn("malformed-bearer-denied", result["checks"])
        self.assertIn("malformed-json-rejected", result["checks"])
        self.assertIn("assistant-delete-confirmed", result["checks"])
        self.assertEqual(self.state["assistants"], set())
        self.assertEqual(self.state["sessions"], {})
        self.assertEqual(len(self.state["invocations"]), 2)
        first, second = self.state["invocations"]
        self.assertEqual(first["agent_id"], result["assistant_id"])
        self.assertEqual(second["agent_id"], result["assistant_id"])
        self.assertEqual(first["session_id"], second["session_id"])
        uuid.UUID(first["session_id"])
        self.assertRegex(first["task_prompt"], r"^mpr44-session-[0-9a-f]{32}$")
        self.assertNotIn(first["task_prompt"], second["task_prompt"])
        self.assertEqual(first["llm"]["api_key"], "secret-canary")
        self.assertTrue(all(request["request_id"] for request in self.state["requests"]))

    def test_http_200_terminal_failure_is_not_a_pass_and_still_cleans_up(self):
        scenario = self.scenario({"task_prompt": "terminal-failure", "expected_text": "ignored"})
        with self.assertRaisesRegex(mpr44.QualificationError, "terminal event reported failure"):
            mpr44.execute(self.client, mpr44.validate_scenario(scenario), "test-caller-token", "qualification")
        self.assertEqual(self.state["assistants"], set())
        self.assertEqual(len([item for item in self.state["requests"] if item["method"] == "DELETE"]), 2)

    def test_earlier_failure_event_cannot_be_overridden_by_later_completed(self):
        events = [
            {"status": "Error", "success": False},
            {"status": "Completed", "success": True, "response": "looks-successful"},
        ]
        with self.assertRaisesRegex(mpr44.QualificationError, "terminal failure event"):
            mpr44.terminal_response(events)

    def test_primary_and_cleanup_failures_are_both_reported(self):
        self.state["fail_cleanup"] = True
        scenario = self.scenario({"task_prompt": "terminal-failure", "expected_text": "ignored"})
        with self.assertRaisesRegex(mpr44.QualificationError, "cleanup also failed"):
            mpr44.execute(self.client, mpr44.validate_scenario(scenario), "test-caller-token", "qualification")

    def test_negative_response_must_be_valid_scannable_json(self):
        class MalformedResponse:
            status = 401
            headers = {"Content-Type": "application/json"}

            def read(self, _limit):
                return b'{"detail":"malformed"'

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return None

        class MalformedDenialOpener:
            def open(self, req, timeout):
                del timeout
                if req.headers.get("Authorization") is None:
                    return MalformedResponse()
                raise AssertionError("the malformed denial should stop the negative checks")

        client = mpr44.SlimHTTPClient(self.base_url, timeout=2, opener=MalformedDenialOpener())
        with self.assertRaisesRegex(mpr44.QualificationError, "did not return valid JSON"):
            mpr44.run_negative_checks(
                client,
                CallerRouteHandler.route,
                "test-caller-token",
                ["sécret", "test-caller-token"],
            )

    def test_expected_text_cannot_match_only_an_object_key(self):
        scenario = self.scenario({"task_prompt": "key-only", "expected_text": "expected-marker"})
        with self.assertRaisesRegex(mpr44.QualificationError, "missed the expected product text"):
            mpr44.execute(self.client, mpr44.validate_scenario(scenario), "test-caller-token", "qualification")

    def test_structured_response_shape(self):
        scenario = self.scenario(
            {
                "task_prompt": "structured",
                "expected_shape": {
                    "required": ["answer", "meta.count"],
                    "types": {"answer": "string", "meta.count": "integer"},
                },
            }
        )
        result = mpr44.execute(self.client, mpr44.validate_scenario(scenario), "test-caller-token", "qualification")
        self.assertEqual(result["result"], "PASS")

    def test_wrong_media_type_is_rejected(self):
        call = {"task_prompt": "wrong-media", "expected_text": "wrong-media"}
        assistant_id = mpr44.create_assistant(
            self.client,
            CallerRouteHandler.route,
            "test-caller-token",
            "media-create",
            "mpr44media",
            ["test-caller-token"],
        )
        try:
            with self.assertRaisesRegex(mpr44.QualificationError, "unexpected media type"):
                mpr44.invoke_call(
                    self.client,
                    CallerRouteHandler.route,
                    "test-caller-token",
                    "media-invoke",
                    assistant_id,
                    str(uuid.uuid4()),
                    call,
                    ["test-caller-token"],
                )
        finally:
            mpr44.cleanup_assistant(
                self.client, CallerRouteHandler.route, "test-caller-token", assistant_id, ["test-caller-token"]
            )

    def test_media_type_substring_and_nonstandard_nan_are_rejected(self):
        assistant_id = mpr44.create_assistant(
            self.client, CallerRouteHandler.route, "test-caller-token", "strict-create", "mpr44strict",
            ["test-caller-token"],
        )
        try:
            with self.assertRaisesRegex(mpr44.QualificationError, "unexpected media type"):
                mpr44.invoke_call(
                    self.client, CallerRouteHandler.route, "test-caller-token", "evil-media",
                    assistant_id, str(uuid.uuid4()), {"task_prompt": "evil-media", "expected_text": "x"},
                    ["test-caller-token"],
                )
            with self.assertRaisesRegex(mpr44.QualificationError, "invalid NDJSON"):
                mpr44.invoke_call(
                    self.client, CallerRouteHandler.route, "test-caller-token", "nan-response",
                    assistant_id, str(uuid.uuid4()), {
                        "task_prompt": "nan-response",
                        "expected_shape": {"types": {"answer": "number"}},
                    }, ["test-caller-token"],
                )
        finally:
            mpr44.cleanup_assistant(
                self.client, CallerRouteHandler.route, "test-caller-token", assistant_id, ["test-caller-token"]
            )

    def test_invalid_ndjson_and_oversized_response_are_rejected(self):
        assistant_id = mpr44.create_assistant(
            self.client,
            CallerRouteHandler.route,
            "test-caller-token",
            "bad-create",
            "mpr44bad",
            ["test-caller-token"],
        )
        try:
            with self.assertRaisesRegex(mpr44.QualificationError, "invalid NDJSON"):
                mpr44.invoke_call(
                    self.client, CallerRouteHandler.route, "test-caller-token", "bad-ndjson",
                    assistant_id, str(uuid.uuid4()), {"task_prompt": "bad-ndjson", "expected_text": "x"},
                    ["test-caller-token"],
                )
            small_client = mpr44.SlimHTTPClient(self.base_url, timeout=2, max_response_bytes=4096)
            with self.assertRaisesRegex(mpr44.QualificationError, "size limit"):
                mpr44.invoke_call(
                    small_client, CallerRouteHandler.route, "test-caller-token", "oversize",
                    assistant_id, str(uuid.uuid4()), {"task_prompt": "oversize", "expected_text": "x"},
                    ["test-caller-token"],
                )
        finally:
            mpr44.cleanup_assistant(
                self.client, CallerRouteHandler.route, "test-caller-token", assistant_id, ["test-caller-token"]
            )

    def test_sensitive_marker_is_rejected_without_being_in_error(self):
        with self.assertRaises(mpr44.QualificationError) as captured:
            mpr44.assert_body_absent(b'{"error":"secret-canary"}', ["secret-canary"], "error body")
        self.assertNotIn("secret-canary", str(captured.exception))
        escaped = json.dumps({"error": 'sec"ret'}).encode()
        with self.assertRaises(mpr44.QualificationError):
            mpr44.assert_body_absent(escaped, ['sec"ret'], "escaped error")
        unicode_escaped = b'{"error":"s\\u00e9cret"}'
        with self.assertRaises(mpr44.QualificationError):
            mpr44.assert_body_absent(unicode_escaped, ["s\u00e9cret"], "escaped error")
        alternate_escaped = b'{"error":"\\u0041\\/B"}'
        with self.assertRaises(mpr44.QualificationError):
            mpr44.assert_body_absent(alternate_escaped, ["A/B"], "escaped error")
        heartbeat = b'{"status":"Thinking","debug":"secret-canary"}\n'
        with self.assertRaises(mpr44.QualificationError):
            mpr44.assert_body_absent(heartbeat, ["secret-canary"], "heartbeat")

    def test_sensitive_case_name_cannot_be_emitted_as_evidence(self):
        scenario = {
            "scenario_version": 1,
            "sensitive_values": ["representative"],
            "cases": [{"name": "representative", "calls": [
                {"task_prompt": "{{SESSION_MARKER}}", "expected_text": "{{SESSION_MARKER}}"},
                {"task_prompt": "recall the preceding result", "expected_text": "{{SESSION_MARKER}}"},
            ]}],
        }
        with self.assertRaisesRegex(mpr44.QualificationError, "sanitized evidence"):
            mpr44.execute(self.client, mpr44.validate_scenario(scenario), "test-caller-token", "qualification")
        self.assertEqual(self.state["assistants"], set())

    def test_scenario_validation_rejects_unsafe_or_unchecked_cases(self):
        invalid = [
            {"scenario_version": 1, "cases": [{"name": "bad name", "calls": []}]},
            {"scenario_version": 1, "cases": [{"name": "safe", "calls": [{"task_prompt": "x"}]}]},
            {
                "scenario_version": 1,
                "cases": [{
                    "name": "empty-shape",
                    "calls": [{"task_prompt": "x", "expected_shape": {}}],
                }],
            },
            {
                "scenario_version": 1,
                "unexpected": True,
                "cases": [{"name": "safe", "calls": [{"task_prompt": "x", "expected_text": "x"}]}],
            },
        ]
        for scenario in invalid:
            with self.subTest(scenario=scenario), self.assertRaises(mpr44.ScenarioError):
                mpr44.validate_scenario(scenario)

        credential_case = {
            "scenario_version": 1,
            "cases": [{
                "name": "credential-case",
                "calls": [{
                    "task_prompt": "test",
                    "llm": {"provider": "test", "api_key": "synthetic"},
                    "expected_text": "done",
                }],
            }],
        }
        with self.assertRaisesRegex(mpr44.ScenarioError, "require sensitive_values"):
            mpr44.validate_scenario(credential_case)

        one_call = {
            "scenario_version": 1,
            "sensitive_values": ["canary"],
            "cases": [{
                "name": "one-call",
                "calls": [{"task_prompt": "test", "expected_text": "done"}],
            }],
        }
        with self.assertRaisesRegex(mpr44.ScenarioError, "same-session recall probe"):
            mpr44.validate_scenario(one_call)

        duplicate_calls = {
            "scenario_version": 1,
            "sensitive_values": ["canary"],
            "cases": [{
                "name": "duplicate",
                "calls": [
                    {"task_prompt": "same", "expected_text": "same"},
                    {"task_prompt": "same", "expected_text": "same"},
                ],
            }],
        }
        with self.assertRaisesRegex(mpr44.ScenarioError, "same-session recall probe"):
            mpr44.validate_scenario(duplicate_calls)

        stateless_constant = {
            "scenario_version": 1,
            "sensitive_values": ["canary"],
            "cases": [{
                "name": "constant",
                "calls": [
                    {"task_prompt": "first request", "expected_text": "constant-output"},
                    {"task_prompt": "second request", "expected_text": "constant-output"},
                ],
            }],
        }
        with self.assertRaisesRegex(mpr44.ScenarioError, "same-session recall probe"):
            mpr44.validate_scenario(stateless_constant)

        echoed_then_constant = {
            "scenario_version": 1,
            "sensitive_values": ["canary"],
            "cases": [{
                "name": "echoed-constant",
                "calls": [
                    {"task_prompt": "hello", "expected_text": "hello"},
                    {"task_prompt": "recall", "expected_text": "hello"},
                ],
            }],
        }
        with self.assertRaisesRegex(mpr44.ScenarioError, "same-session recall probe"):
            mpr44.validate_scenario(echoed_then_constant)

    def test_credential_values_are_derived_even_with_incomplete_canary_list(self):
        scenario = self.scenario(
            {
                "task_prompt": "test",
                "llm": {"provider": "test", "api_key": "derived-secret"},
                "expected_text": "done",
            }
        )
        scenario["sensitive_values"] = ["unrelated-canary"]
        validated = mpr44.validate_scenario(scenario)
        derived = list(mpr44.credential_values(validated))
        self.assertIn("derived-secret", derived)
        with self.assertRaisesRegex(mpr44.QualificationError, "sensitive marker"):
            mpr44.assert_absent({"response": "derived-secret"}, derived, "response")

    def test_base_url_rejects_credentials_path_query_and_fragment(self):
        invalid = (
            "ftp://example.test",
            "http://example.test",
            "https://user:pass@example.test",
            "https://example.test/path",
            "https://example.test?token=value",
            "https://example.test#fragment",
        )
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(mpr44.ScenarioError):
                mpr44.validate_base_url(value)

    def test_bearer_requires_exactly_one_protected_source(self):
        with self.assertRaisesRegex(mpr44.ScenarioError, "exactly one"):
            mpr44.load_bearer({})
        with self.assertRaisesRegex(mpr44.ScenarioError, "exactly one"):
            mpr44.load_bearer({"SLIM_BEARER_TOKEN": "one", "SLIM_BEARER_TOKEN_FILE": "/tmp/two"})
        self.assertEqual(mpr44.load_bearer({"SLIM_BEARER_TOKEN": "test-token"}), "test-token")
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as handle:
            path = handle.name
            handle.write("file-token\n")
        try:
            os.chmod(path, 0o600)
            self.assertEqual(mpr44.load_bearer({"SLIM_BEARER_TOKEN_FILE": path}), "file-token")
            os.chmod(path, 0o644)
            with self.assertRaisesRegex(mpr44.ScenarioError, "group or other"):
                mpr44.load_bearer({"SLIM_BEARER_TOKEN_FILE": path})
        finally:
            os.unlink(path)

    def test_transport_failure_is_sanitized(self):
        opener = SimpleNamespace(open=lambda *_args, **_kwargs: (_ for _ in ()).throw(error.URLError("secret")))
        client = mpr44.SlimHTTPClient("https://example.test", opener=opener)
        with self.assertRaises(mpr44.QualificationError) as captured:
            client.request("GET", "/health", token="token", request_id="health")
        self.assertEqual(str(captured.exception), "SLIM HTTP transport failed")

    def test_redirect_is_not_followed_and_bearer_is_not_forwarded(self):
        self.state["redirect_target"] = self.base_url + "/target"
        result = self.client.request(
            "GET", "/redirect", token="test-caller-token", request_id="redirect-check"
        )
        self.assertEqual(result.status, 302)
        self.assertEqual([item["path"] for item in self.state["requests"]], ["/redirect"])

    def test_unexpected_malformed_json_success_is_cleaned_up(self):
        assistant_id = str(uuid.uuid4())

        class UnexpectedSuccessClient:
            def __init__(self, mode, leak=False):
                self.mode = mode
                self.leak = leak
                self.deleted = []

            def request(self, method, path, **kwargs):
                is_unexpected = (
                    self.mode == "missing-bearer" and method == "POST" and kwargs.get("token") is None
                ) or (
                    self.mode == "malformed-json"
                    and method == "POST"
                    and kwargs.get("raw_body") == b"{"
                )
                if is_unexpected:
                    body = {"runtime_id": assistant_id}
                    if self.leak:
                        body["leak"] = "token"
                    return mpr44.HTTPResult(
                        201, json.dumps(body).encode(), "application/json"
                    )
                if method == "POST":
                    return mpr44.HTTPResult(401, b'{"error":"denied"}', "application/json")
                self.deleted.append(path)
                if len(self.deleted) == 1:
                    return mpr44.HTTPResult(200, b'{"status":"DELETING"}', "application/json")
                return mpr44.HTTPResult(200, b'{"status":"AGENT_NOT_FOUND"}', "application/json")

        cases = (
            ("malformed-json", False, "malformed JSON was not safely rejected"),
            ("malformed-json", True, "sensitive marker"),
            ("missing-bearer", True, "sensitive marker"),
        )
        for mode, leak, expected_error in cases:
            with self.subTest(mode=mode, leak=leak):
                client = UnexpectedSuccessClient(mode, leak)
                with self.assertRaisesRegex(mpr44.QualificationError, expected_error):
                    mpr44.run_negative_checks(
                        client, CallerRouteHandler.route, "token", ["token"]
                    )
                self.assertEqual(len(client.deleted), 2)

    def test_cleanup_confirmation_requires_exact_absence(self):
        class AmbiguousCleanupClient:
            def __init__(self):
                self.calls = 0

            def request(self, *_args, **_kwargs):
                self.calls += 1
                status = "DELETING" if self.calls == 1 else "AGENT_NOT_FOUND_BUT_PRESENT"
                return mpr44.HTTPResult(
                    200,
                    json.dumps({"status": status}).encode(),
                    "application/json",
                )

        with self.assertRaisesRegex(mpr44.QualificationError, "did not report not found"):
            mpr44.cleanup_assistant(
                AmbiguousCleanupClient(),
                CallerRouteHandler.route,
                "token",
                "assistant-id",
                ["token"],
            )

    def test_create_validation_failure_recovers_and_cleans_runtime_id(self):
        assistant_id = str(uuid.uuid4())

        class InvalidCreateClient:
            def __init__(self, body):
                self.body = body
                self.deleted = []

            def request(self, method, path, **_kwargs):
                if method == "POST":
                    return mpr44.HTTPResult(201, self.body, "application/json")
                self.deleted.append(path)
                status = "DELETING" if len(self.deleted) == 1 else "AGENT_NOT_FOUND"
                return mpr44.HTTPResult(
                    200, json.dumps({"status": status}).encode(), "application/json"
                )

        bodies = (
            f'{{"runtime_id":"{assistant_id}"'.encode(),
            json.dumps({"runtime_id": assistant_id, "leak": "token"}).encode(),
        )
        for body in bodies:
            with self.subTest(body=body):
                client = InvalidCreateClient(body)
                with self.assertRaises(mpr44.QualificationError):
                    mpr44.create_assistant(
                        client,
                        CallerRouteHandler.route,
                        "token",
                        "create",
                        "assistant",
                        ["token"],
                    )
                self.assertEqual(len(client.deleted), 2)

    def test_main_emits_only_sanitized_failure(self):
        scenario = self.scenario({"task_prompt": "terminal-failure", "expected_text": "secret-canary"})
        stderr = io.StringIO()
        with patch("sys.stdin", io.StringIO(json.dumps(scenario))), patch("sys.stderr", stderr), patch.dict(
            os.environ,
            {"SLIM_BASE_URL": self.base_url, "SLIM_BEARER_TOKEN": "test-caller-token"},
            clear=True,
        ):
            status = mpr44.main([])
        self.assertEqual(status, 1)
        output = stderr.getvalue()
        self.assertNotIn("secret-canary", output)
        self.assertNotIn("test-caller-token", output)


if __name__ == "__main__":
    unittest.main()
