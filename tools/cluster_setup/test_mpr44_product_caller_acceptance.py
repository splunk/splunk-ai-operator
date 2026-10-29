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
        return {
            "scenario_version": 1,
            "sensitive_values": ["secret-canary"],
            "cases": [{"name": "representative", "calls": list(calls)}],
        }

    def test_full_route_owns_ids_reuses_session_and_cleans_up(self):
        scenario = self.scenario(
            {
                "task_prompt": "expected-marker",
                "system_prompt": "be concise",
                "llm": {"provider": "test", "api_key": "secret-canary"},
                "expected_text": "expected-marker",
            },
            {
                "task_prompt": "recall",
                "llm": {"provider": "test", "api_key": "secret-canary"},
                "expected_text": "expected-marker",
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
        self.assertEqual(first["llm"]["api_key"], "secret-canary")
        self.assertTrue(all(request["request_id"] for request in self.state["requests"]))

    def test_http_200_terminal_failure_is_not_a_pass_and_still_cleans_up(self):
        scenario = self.scenario({"task_prompt": "terminal-failure", "expected_text": "ignored"})
        with self.assertRaisesRegex(mpr44.QualificationError, "terminal event reported failure"):
            mpr44.execute(self.client, mpr44.validate_scenario(scenario), "test-caller-token", "qualification")
        self.assertEqual(self.state["assistants"], set())
        self.assertEqual(len([item for item in self.state["requests"] if item["method"] == "DELETE"]), 2)

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
                return b'{"detail":"s\\u00e9cret"'

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
        heartbeat = b'{"status":"Thinking","debug":"secret-canary"}\n'
        with self.assertRaises(mpr44.QualificationError):
            mpr44.assert_body_absent(heartbeat, ["secret-canary"], "heartbeat")

    def test_sensitive_case_name_cannot_be_emitted_as_evidence(self):
        scenario = {
            "scenario_version": 1,
            "sensitive_values": ["representative"],
            "cases": [{"name": "representative", "calls": [
                {"task_prompt": "safe-result", "expected_text": "safe-result"}
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
                "unexpected": True,
                "cases": [{"name": "safe", "calls": [{"task_prompt": "x", "expected_text": "x"}]}],
            },
        ]
        for scenario in invalid:
            with self.subTest(scenario=scenario), self.assertRaises(mpr44.ScenarioError):
                mpr44.validate_scenario(scenario)

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
            def __init__(self):
                self.deleted = []

            def request(self, method, path, **kwargs):
                if method == "POST" and kwargs.get("raw_body") == b"{":
                    return mpr44.HTTPResult(
                        201, json.dumps({"runtime_id": assistant_id}).encode(), "application/json"
                    )
                if method == "POST":
                    return mpr44.HTTPResult(401, b'{"error":"denied"}', "application/json")
                self.deleted.append(path)
                if len(self.deleted) == 1:
                    return mpr44.HTTPResult(200, b'{"status":"DELETING"}', "application/json")
                return mpr44.HTTPResult(200, b'{"status":"AGENT_NOT_FOUND"}', "application/json")

        client = UnexpectedSuccessClient()
        with self.assertRaisesRegex(mpr44.QualificationError, "malformed JSON was not safely rejected"):
            mpr44.run_negative_checks(client, CallerRouteHandler.route, "token", ["token"])
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
