#!/usr/bin/env python3
"""Run sanitized LAS protocol and queue scaling acceptance checks.

Scenario data is read from stdin so product context need not be stored in a
file or command argument. Response bodies and request values are never printed.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import ipaddress
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any


MAX_BODY = 8 * 1024 * 1024
TERMINAL = {"success", "error", "failed", "cancelled", "timeout"}
SAFE_CASE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
SAFE_RUNTIME_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
SYNTHETIC_MARKER = re.compile(r"^mpr-qualification-[0-9a-f]{32}$")


class AcceptanceError(RuntimeError):
    pass


def _reject_json_constant(_value: str) -> None:
    raise ValueError("non-standard JSON constant")


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON object key")
        value[key] = item
    return value


def strict_json_loads(value: str | bytes) -> Any:
    return json.loads(
        value,
        parse_constant=_reject_json_constant,
        object_pairs_hook=_unique_json_object,
    )


def strict_json_load(stream: Any) -> Any:
    return json.load(
        stream,
        parse_constant=_reject_json_constant,
        object_pairs_hook=_unique_json_object,
    )


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    """Do not forward an API key to a redirect target."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise AcceptanceError("LAS redirects are not allowed")


def _is_loopback(hostname: str) -> bool:
    if hostname.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


class LASClient:
    def __init__(self, base_url: str, timeout: float):
        parsed = urllib.parse.urlsplit(base_url)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise AcceptanceError("LAS_BASE_URL must be an http(s) URL")
        if parsed.scheme == "http" and not _is_loopback(parsed.hostname):
            raise AcceptanceError("LAS_BASE_URL may use plaintext HTTP only for a loopback host")
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise AcceptanceError("LAS_BASE_URL cannot contain credentials, query, or fragment")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.api_key = os.environ.get("LAS_API_KEY", "")
        # Qualification requests must not inherit workstation proxy settings,
        # and redirects must never be allowed to forward the API key.
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            _RejectRedirects(),
        )

    def request(
        self,
        method: str,
        path: str,
        payload: Any = None,
        accept: str = "application/json",
        allow_http_error: bool = False,
    ):
        data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
        headers = {"Accept": accept}
        if data is not None:
            headers["Content-Type"] = "application/json"
        if self.api_key:
            headers["X-Api-Key"] = self.api_key
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                body = response.read(MAX_BODY + 1)
                if len(body) > MAX_BODY:
                    raise AcceptanceError("LAS response exceeded the size limit")
                return response.status, body, response.headers.get_content_type()
        except urllib.error.HTTPError as exc:
            body = exc.read(MAX_BODY + 1)
            if len(body) > MAX_BODY:
                exc.close()
                raise AcceptanceError("LAS error response exceeded the size limit") from None
            if allow_http_error:
                content_type = exc.headers.get_content_type() if exc.headers else "application/octet-stream"
                exc.close()
                # The body is returned only to the in-memory redaction checks;
                # callers never print it.
                return exc.code, body, content_type
            exc.close()
            raise AcceptanceError(f"LAS returned HTTP {exc.code}") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise AcceptanceError("LAS request failed or timed out") from None


def json_body(body: bytes) -> Any:
    try:
        return strict_json_loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        raise AcceptanceError("LAS returned an invalid JSON response") from None


def strings(value: Any):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def _sensitive_variants(secret: str) -> set[str]:
    """Return literal and JSON-escaped forms without exposing them in errors."""
    if not secret:
        return set()
    return {
        secret,
        json.dumps(secret, ensure_ascii=True)[1:-1],
        json.dumps(secret, ensure_ascii=False)[1:-1],
    }


def assert_sensitive_absent(value: bytes | str, sensitive: list[str], location: str) -> None:
    text = value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
    if any(variant and variant in text for secret in sensitive for variant in _sensitive_variants(secret)):
        raise AcceptanceError(f"sensitive marker appeared in {location}")


def graph_response_strings(value: Any) -> list[str]:
    """Extract graph output while excluding transport/checkpoint metadata."""
    if isinstance(value, dict) and isinstance(value.get("values"), (dict, list)):
        target = value["values"]
    elif isinstance(value, dict):
        metadata_keys = {
            "metadata",
            "checkpoint",
            "parent_config",
            "config",
            "created_at",
            "tasks",
            "interrupts",
        }
        target = {key: item for key, item in value.items() if key not in metadata_keys}
    else:
        target = value
    return list(strings(target))


def path_segment(value: str) -> str:
    return urllib.parse.quote(value, safe="")


def substitute_marker(value: Any, marker: str, placeholder: str) -> Any:
    if isinstance(value, str):
        return value.replace(placeholder, marker)
    if isinstance(value, dict):
        return {key: substitute_marker(item, marker, placeholder) for key, item in value.items()}
    if isinstance(value, list):
        return [substitute_marker(item, marker, placeholder) for item in value]
    return value


def contains_marker_placeholder(value: Any, placeholder: str) -> bool:
    return any(placeholder in item for item in strings(value))


def create_thread(client: LASClient) -> str:
    status, body, _ = client.request("POST", "/threads", {})
    result = json_body(body)
    thread_id = result.get("thread_id") if isinstance(result, dict) else None
    if status not in (200, 201) or not isinstance(thread_id, str) or not thread_id:
        raise AcceptanceError("thread creation failed")
    return thread_id


def delete_thread(client: LASClient, thread_id: str) -> None:
    status, _, _ = client.request(
        "DELETE", f"/threads/{path_segment(thread_id)}", allow_http_error=True
    )
    if status not in (200, 202, 204, 404):
        raise AcceptanceError("thread cleanup failed")


def assert_state(client: LASClient, thread_id: str, expected: list[str], sensitive: list[str]):
    status, body, _ = client.request("GET", f"/threads/{path_segment(thread_id)}/state")
    assert_sensitive_absent(body, sensitive, "persisted thread state")
    result = json_body(body)
    if status != 200 or not isinstance(result, dict) or not isinstance(result.get("values"), (dict, list)):
        raise AcceptanceError("thread state response omitted graph values")
    state_values = list(strings(result["values"]))
    for item in expected:
        if not any(item in value for value in state_values):
            raise AcceptanceError("expected value was not persisted under graph state values")


def parse_sse(body: bytes, sensitive: list[str]) -> list[dict[str, str]]:
    if not body:
        return []
    text = body.decode("utf-8", errors="replace")
    events = []
    event_name = "message"
    data_lines = []

    def append_event() -> None:
        nonlocal event_name, data_lines
        if data_lines:
            data = "\n".join(data_lines)
            assert_sensitive_absent(data, sensitive, "SSE output")
            events.append({"event": event_name, "data": data})
        event_name = "message"
        data_lines = []

    for line in text.splitlines():
        if not line:
            append_event()
        elif line.startswith("event:"):
            event_name = line[6:].strip() or "message"
            assert_sensitive_absent(event_name, sensitive, "SSE output")
        elif line.startswith("data:"):
            data_lines.append(line[5:].lstrip())
    append_event()
    return events


def ordered_subsequence(actual: list[str], expected: list[str]) -> bool:
    cursor = iter(actual)
    return all(any(item == wanted for item in cursor) for wanted in expected)


def nested_status(value: Any) -> str | None:
    if isinstance(value, dict):
        status = value.get("status")
        if isinstance(status, str):
            return status
        for item in value.values():
            found = nested_status(item)
            if found is not None:
                return found
    elif isinstance(value, list):
        for item in value:
            found = nested_status(item)
            if found is not None:
                return found
    return None


def assert_sse(
    body: bytes,
    expected_values: list[str],
    sensitive: list[str],
    expected_sequence: list[str] | None = None,
    terminal_event: str | None = None,
    terminal_status: str | None = None,
) -> list[str]:
    events = parse_sse(body, sensitive)
    if not events:
        raise AcceptanceError("SSE stream contained no data events")
    # Metadata is transport/checkpoint context, not graph output. It must not
    # satisfy the product response assertion.
    graph_events = [event for event in events if event["event"].lower() != "metadata"]
    joined = "\n".join(event["data"] for event in graph_events)
    if not all(marker in joined for marker in expected_values):
        raise AcceptanceError("SSE stream omitted expected data")
    event_names = [event["event"] for event in events]
    if expected_sequence and not ordered_subsequence(event_names, expected_sequence):
        raise AcceptanceError("SSE event order did not match the expected sequence")
    if terminal_event and event_names[-1] != terminal_event:
        raise AcceptanceError("SSE stream omitted the expected terminal event")
    if terminal_status:
        try:
            terminal_payload = strict_json_loads(events[-1]["data"])
        except (json.JSONDecodeError, ValueError):
            raise AcceptanceError("SSE terminal event did not contain JSON") from None
        if nested_status(terminal_payload) != terminal_status:
            raise AcceptanceError("SSE terminal event had an unexpected status")
    return event_names


def sse_has_data(body: bytes, expected: list[str], sensitive: list[str]) -> bool:
    try:
        assert_sse(body, expected, sensitive)
    except AcceptanceError as exc:
        if str(exc) in ("SSE stream contained no data events", "SSE stream omitted expected data"):
            return False
        raise
    return True


def wait_for_run(
    client: LASClient,
    thread_id: str,
    run_id: str,
    timeout: float,
    accepted_statuses: set[str] | None = None,
    sensitive: list[str] | None = None,
) -> str:
    accepted = accepted_statuses or {"success"}
    sensitive_values = sensitive or []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status, body, _ = client.request(
            "GET", f"/threads/{path_segment(thread_id)}/runs/{path_segment(run_id)}"
        )
        assert_sensitive_absent(body, sensitive_values, "queued run status")
        run = json_body(body)
        run_status = run.get("status") if isinstance(run, dict) else None
        if run_status in TERMINAL:
            if run_status not in accepted:
                raise AcceptanceError(f"queued run ended in {run_status}")
            return run_status
        time.sleep(2)
    raise AcceptanceError("queued run did not reach a terminal state before timeout")


def run_protocol_case(
    client: LASClient,
    graph_id: str,
    case: dict[str, Any],
    timeout: float,
    cleanup_default: bool = True,
):
    name = case.get("name")
    run_input = case.get("input")
    expected = case.get("expected_state_values", [])
    expected_response = case.get("expected_response_values", expected)
    sensitive = case.get("sensitive_values", [])
    modes = case.get("run_modes", ["sync", "queued", "stream"])
    expected_outcome = case.get("expected_outcome", "success")
    expected_http_statuses = case.get("expected_http_statuses", list(range(400, 500)))
    expected_run_statuses = case.get("expected_run_statuses", ["error", "failed", "cancelled", "timeout"])
    expected_sse_sequence = case.get("expected_sse_event_sequence", [])
    expected_sse_terminal_event = case.get("expected_sse_terminal_event")
    expected_sse_terminal_status = case.get("expected_sse_terminal_status")
    placeholder = case.get("marker_placeholder", "{{RUN_MARKER}}")
    cleanup = case.get("cleanup", cleanup_default)
    run_options = case.get("run_options", {})
    context = case.get("context")
    if not isinstance(name, str) or not SAFE_CASE_NAME.fullmatch(name) or not isinstance(run_input, dict):
        raise AcceptanceError("each case needs a safe name and object input")
    if not isinstance(expected, list) or not all(isinstance(v, str) for v in expected):
        raise AcceptanceError("expected_state_values must be a string list")
    if expected_outcome == "success" and (not expected or not all(expected)):
        raise AcceptanceError("expected_state_values must include at least one non-empty persisted marker")
    if not isinstance(expected_response, list) or not all(isinstance(v, str) and v for v in expected_response):
        raise AcceptanceError("expected_response_values must be a string list")
    if expected_outcome == "success" and not expected_response:
        raise AcceptanceError("successful cases need non-empty expected_response_values")
    if not isinstance(sensitive, list) or not all(isinstance(v, str) for v in sensitive):
        raise AcceptanceError("sensitive_values must be a string list")
    if not isinstance(modes, list) or not modes or set(modes) - {"sync", "queued", "stream"}:
        raise AcceptanceError("run_modes may contain sync, queued, and stream")
    if expected_outcome not in ("success", "failure"):
        raise AcceptanceError("expected_outcome must be success or failure")
    if not isinstance(expected_http_statuses, list) or not all(
        isinstance(value, int) and 100 <= value <= 599 for value in expected_http_statuses
    ):
        raise AcceptanceError("expected_http_statuses must be a list of HTTP statuses")
    if not isinstance(expected_run_statuses, list) or not expected_run_statuses or not all(
        isinstance(value, str) and value in TERMINAL for value in expected_run_statuses
    ):
        raise AcceptanceError("expected_run_statuses must contain terminal run statuses")
    if not isinstance(expected_sse_sequence, list) or not all(
        isinstance(value, str) and value for value in expected_sse_sequence
    ):
        raise AcceptanceError("expected_sse_event_sequence must be a string list")
    if expected_sse_terminal_event is not None and not isinstance(expected_sse_terminal_event, str):
        raise AcceptanceError("expected_sse_terminal_event must be a string")
    if expected_sse_terminal_status is not None and expected_sse_terminal_status not in TERMINAL:
        raise AcceptanceError("expected_sse_terminal_status must be a terminal run status")
    if (expected_sse_terminal_event is None) != (expected_sse_terminal_status is None):
        raise AcceptanceError(
            "expected_sse_terminal_event and expected_sse_terminal_status must be supplied together"
        )
    if expected_outcome == "success" and "stream" in modes and expected_sse_terminal_status is None:
        raise AcceptanceError("successful stream cases must declare an explicit terminal event and status")
    if not isinstance(placeholder, str) or not placeholder:
        raise AcceptanceError("marker_placeholder must be a non-empty string")
    if not isinstance(cleanup, bool):
        raise AcceptanceError("cleanup must be true or false")
    if not isinstance(run_options, dict) or set(run_options) & {"assistant_id", "input"}:
        raise AcceptanceError("run_options must be an object and cannot replace assistant_id or input")
    if context is not None and not isinstance(context, dict):
        raise AcceptanceError("context must be an object")

    inject_request_marker = case.get("inject_request_marker")
    if inject_request_marker is None:
        # Keep the deterministic fixture behavior, but infer product-shaped cases
        # from explicit context or a marker placeholder and do not add an extra
        # field to their strict input schema.
        product_input = any(key in run_input for key in ("messages", "system_prompt"))
        inject_request_marker = (
            context is None
            and not product_input
            and not contains_marker_placeholder(run_input, placeholder)
        )
    if not isinstance(inject_request_marker, bool):
        raise AcceptanceError("inject_request_marker must be true or false")
    if expected_outcome == "success":
        request_has_marker = contains_marker_placeholder(
            {"input": run_input, "context": context},
            placeholder,
        )
        helper_injects_marker = inject_request_marker and "request" not in run_input
        if not request_has_marker and not helper_injects_marker:
            raise AcceptanceError(
                "successful cases must send the marker placeholder in input/context"
            )
        if not contains_marker_placeholder(expected, placeholder):
            raise AcceptanceError(
                "successful cases must include the marker placeholder in expected_state_values"
            )

    checks = []
    for mode in modes:
        marker = f"aip-qualification-{uuid.uuid4().hex}"
        input_copy = substitute_marker(run_input, marker, placeholder)
        case_expected = substitute_marker(expected, marker, placeholder)
        case_expected_response = substitute_marker(expected_response, marker, placeholder)
        case_sensitive = substitute_marker(sensitive, marker, placeholder)
        # Backwards-compatible deterministic fixture behavior is opt-out. A
        # strict product schema uses context or a marker placeholder and is not
        # given an unexpected `request` field.
        if inject_request_marker:
            input_copy.setdefault("request", marker)
        thread_id = create_thread(client)
        payload = {"assistant_id": graph_id, "input": input_copy}
        if context is not None:
            payload["context"] = substitute_marker(context, marker, placeholder)
        payload.update(substitute_marker(run_options, marker, placeholder))
        thread_path = path_segment(thread_id)
        started = time.monotonic()
        status = None
        run_id = None
        terminal_status = None
        sse_events = []
        try:
            if mode == "sync":
                status, body, _ = client.request(
                    "POST",
                    f"/threads/{thread_path}/runs/wait",
                    payload,
                    allow_http_error=expected_outcome == "failure",
                )
                assert_sensitive_absent(body, case_sensitive, "synchronous response")
                if status != 200:
                    if expected_outcome == "failure" and status in expected_http_statuses:
                        terminal_status = "http_error"
                    else:
                        raise AcceptanceError("synchronous run returned an unexpected HTTP status")
                else:
                    result = json_body(body)
                    output = "\n".join(graph_response_strings(result))
                    if expected_outcome == "failure":
                        terminal_status = nested_status(result)
                        if terminal_status not in expected_run_statuses:
                            raise AcceptanceError("synchronous run unexpectedly succeeded")
                    elif not all(item in output for item in case_expected_response):
                        raise AcceptanceError("synchronous response omitted an expected result")
            elif mode == "queued":
                status, body, _ = client.request(
                    "POST",
                    f"/threads/{thread_path}/runs",
                    payload,
                    allow_http_error=expected_outcome == "failure",
                )
                assert_sensitive_absent(body, case_sensitive, "queued response")
                if status not in (200, 201, 202):
                    if expected_outcome == "failure" and status in expected_http_statuses:
                        terminal_status = "http_error"
                    else:
                        raise AcceptanceError("queued run returned an unexpected HTTP status")
                else:
                    result = json_body(body)
                    run_id = result.get("run_id") if isinstance(result, dict) else None
                    if status not in (200, 201, 202) or not isinstance(run_id, str) or not run_id:
                        raise AcceptanceError("queued run did not return a run ID")
                    accepted = set(expected_run_statuses) if expected_outcome == "failure" else {"success"}
                    terminal_status = wait_for_run(
                        client, thread_id, run_id, timeout, accepted, case_sensitive
                    )
            else:
                status, body, content_type = client.request(
                    "POST",
                    f"/threads/{thread_path}/runs/stream",
                    payload,
                    "text/event-stream",
                    allow_http_error=expected_outcome == "failure",
                )
                assert_sensitive_absent(body, case_sensitive, "streaming response")
                if status != 200:
                    if expected_outcome == "failure" and status in expected_http_statuses:
                        terminal_status = "http_error"
                    else:
                        raise AcceptanceError("run stream returned an unexpected HTTP response")
                else:
                    if content_type != "text/event-stream":
                        raise AcceptanceError("run stream returned an unexpected HTTP response")
                    sse_events = assert_sse(
                        body,
                        case_expected_response if expected_outcome == "success" else [],
                        case_sensitive,
                        expected_sse_sequence,
                        expected_sse_terminal_event,
                        expected_sse_terminal_status,
                    )
                    if expected_outcome == "failure":
                        parsed = parse_sse(body, case_sensitive)
                        try:
                            terminal_payload = strict_json_loads(parsed[-1]["data"])
                        except (json.JSONDecodeError, ValueError):
                            terminal_payload = None
                        terminal_status = nested_status(terminal_payload)
                        if terminal_status not in expected_run_statuses:
                            raise AcceptanceError("streaming run unexpectedly succeeded")
                    else:
                        terminal_status = expected_sse_terminal_status

            if expected_outcome == "success":
                assert_state(client, thread_id, case_expected, case_sensitive)
        except Exception as original_error:
            # A failed case is never useful persistence evidence. Clean it even
            # when successful cases are intentionally retained for restart
            # verification so a partially submitted credential-bearing run is
            # not orphaned.
            try:
                delete_thread(client, thread_id)
            except AcceptanceError:
                raise AcceptanceError(
                    "qualification case failed and its thread cleanup also failed"
                ) from original_error
            raise

        if cleanup:
            delete_thread(client, thread_id)
        check = {
            "case": name,
            "mode": mode,
            "thread_id": thread_id,
            "result": "PASS",
            "expected_outcome": expected_outcome,
            "http_status": status,
            "terminal_status": terminal_status or "success",
            "duration_seconds": round(time.monotonic() - started, 3),
            "thread_cleaned": cleanup,
            # This is generated by the helper and contains no scenario value.
            # Restart tooling uses it to resolve {{RUN_MARKER}} without
            # returning the request, context, response, or expected value.
            "marker": marker,
        }
        if run_id:
            check["run_id"] = run_id
        if sse_events:
            check["sse_events"] = sse_events
        checks.append(check)
    return checks


def read_scenario() -> dict[str, Any]:
    try:
        scenario = strict_json_load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
        raise AcceptanceError("scenario stdin must contain valid JSON") from None
    if not isinstance(scenario, dict):
        raise AcceptanceError("scenario must be a JSON object")
    return scenario


def protocol_command(args):
    scenario = read_scenario()
    graph_id = scenario.get("graph_id")
    cases = scenario.get("cases")
    cleanup_threads = scenario.get("cleanup_threads", True)
    scenario_sensitive = scenario.get("sensitive_values", [])
    if not isinstance(graph_id, str) or not graph_id or not isinstance(cases, list) or not cases:
        raise AcceptanceError("scenario needs graph_id and at least one case")
    if not isinstance(cleanup_threads, bool):
        raise AcceptanceError("cleanup_threads must be true or false")
    if not isinstance(scenario_sensitive, list) or not all(
        isinstance(value, str) for value in scenario_sensitive
    ):
        raise AcceptanceError("scenario sensitive_values must be a string list")
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    health_status, health_body, _ = client.request("GET", "/ok")
    health = json_body(health_body)
    if health_status != 200 or not isinstance(health, dict) or health.get("ok") is not True:
        raise AcceptanceError("Agent Server health check failed")
    all_checks = []
    try:
        for case in cases:
            if not isinstance(case, dict):
                raise AcceptanceError("scenario cases must be objects")
            case_copy = dict(case)
            case_sensitive = case_copy.get("sensitive_values", [])
            if not isinstance(case_sensitive, list):
                raise AcceptanceError("case sensitive_values must be a string list")
            case_copy["sensitive_values"] = scenario_sensitive + case_sensitive
            all_checks.extend(
                run_protocol_case(client, graph_id, case_copy, args.run_timeout, cleanup_threads)
            )
    except Exception as original_error:
        cleanup_failed = False
        if not cleanup_threads:
            for thread_id in {check.get("thread_id") for check in all_checks}:
                if isinstance(thread_id, str) and thread_id:
                    try:
                        delete_thread(client, thread_id)
                    except AcceptanceError:
                        cleanup_failed = True
        if cleanup_failed:
            raise AcceptanceError(
                "protocol failed and one or more retained threads could not be cleaned up"
            ) from original_error
        raise
    print(json.dumps({"result": "PASS", "checks": all_checks}, sort_keys=True))


def state_command(args):
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    assert_state(client, args.thread_id, [args.expected_value], [])
    print(json.dumps({"result": "PASS", "check": "persisted_graph_state", "thread_id": args.thread_id}, sort_keys=True))


def health_command(args):
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    status, body, _ = client.request("GET", "/ok")
    health = json_body(body)
    if status != 200 or not isinstance(health, dict) or health.get("ok") is not True:
        raise AcceptanceError("Agent Server health check failed")
    print(json.dumps({"result": "PASS", "check": "agent_server_health"}, sort_keys=True))


def delete_thread_command(args):
    if not SAFE_RUNTIME_ID.fullmatch(args.thread_id):
        raise AcceptanceError("thread-id must be a safe runtime identifier")
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    delete_thread(client, args.thread_id)
    print(
        json.dumps(
            {"result": "PASS", "check": "thread_cleanup", "thread_id": args.thread_id},
            sort_keys=True,
        )
    )


def _active_product_case(scenario: dict[str, Any]):
    graph_id = scenario.get("graph_id")
    case = scenario.get("active_run_case")
    scenario_sensitive = scenario.get("sensitive_values", [])
    if not isinstance(graph_id, str) or not graph_id or not isinstance(case, dict):
        raise AcceptanceError("active product scenario needs graph_id and active_run_case")
    if not isinstance(scenario_sensitive, list) or not all(
        isinstance(value, str) for value in scenario_sensitive
    ):
        raise AcceptanceError("scenario sensitive_values must be a string list")
    name = case.get("name")
    run_input = case.get("input")
    context = case.get("context")
    run_options = case.get("run_options", {})
    expected = case.get("expected_state_values")
    case_sensitive = case.get("sensitive_values", [])
    placeholder = case.get("marker_placeholder", "{{RUN_MARKER}}")
    if not isinstance(name, str) or not SAFE_CASE_NAME.fullmatch(name):
        raise AcceptanceError("active_run_case needs a safe name")
    if not isinstance(run_input, dict):
        raise AcceptanceError("active_run_case input must be an object")
    if context is not None and not isinstance(context, dict):
        raise AcceptanceError("active_run_case context must be an object")
    if not isinstance(run_options, dict) or set(run_options) & {"assistant_id", "input"}:
        raise AcceptanceError("active_run_case run_options cannot replace assistant_id or input")
    if not isinstance(expected, list) or not expected or not all(
        isinstance(value, str) and value for value in expected
    ):
        raise AcceptanceError("active_run_case needs non-empty expected_state_values")
    if not isinstance(case_sensitive, list) or not all(
        isinstance(value, str) for value in case_sensitive
    ):
        raise AcceptanceError("active_run_case sensitive_values must be a string list")
    if not isinstance(placeholder, str) or not placeholder:
        raise AcceptanceError("active_run_case marker_placeholder must be non-empty")
    if not contains_marker_placeholder(expected, placeholder) or not contains_marker_placeholder(
        {"input": run_input, "context": context, "run_options": run_options}, placeholder
    ):
        raise AcceptanceError(
            "active_run_case must use its marker placeholder in input/context and expected state"
        )
    return graph_id, case, scenario_sensitive + case_sensitive, placeholder


def submit_product_active_command(args):
    if not 10 <= args.running_timeout <= 300 or args.request_timeout <= 0:
        raise AcceptanceError("running-timeout must be 10..300 and request-timeout must be positive")
    scenario = read_scenario()
    graph_id, case, sensitive, placeholder = _active_product_case(scenario)
    marker = f"mpr-qualification-{uuid.uuid4().hex}"
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    thread_id = create_thread(client)
    try:
        payload = {
            "assistant_id": graph_id,
            "input": substitute_marker(case["input"], marker, placeholder),
        }
        if case.get("context") is not None:
            payload["context"] = substitute_marker(case["context"], marker, placeholder)
        payload.update(substitute_marker(case.get("run_options", {}), marker, placeholder))
        resolved_sensitive = substitute_marker(sensitive, marker, placeholder)
        status, body, _ = client.request(
            "POST", f"/threads/{path_segment(thread_id)}/runs", payload
        )
        assert_sensitive_absent(body, resolved_sensitive, "queued response")
        result = json_body(body)
        run_id = result.get("run_id") if isinstance(result, dict) else None
        if status not in (200, 201, 202) or not isinstance(run_id, str) or not run_id:
            raise AcceptanceError("active product submission did not return a run ID")
        deadline = time.monotonic() + args.running_timeout
        while time.monotonic() < deadline:
            _, body, _ = client.request(
                "GET", f"/threads/{path_segment(thread_id)}/runs/{path_segment(run_id)}"
            )
            assert_sensitive_absent(body, resolved_sensitive, "active run status")
            run = json_body(body)
            run_status = run.get("status") if isinstance(run, dict) else None
            if run_status == "running":
                print(
                    json.dumps(
                        {
                            "result": "PASS",
                            "check": "active_product_run_submitted",
                            "case": case["name"],
                            "thread_id": thread_id,
                            "run_id": run_id,
                            "marker": marker,
                        },
                        sort_keys=True,
                    )
                )
                return
            if run_status in TERMINAL:
                raise AcceptanceError("active product run finished before replacement began")
            time.sleep(1)
        raise AcceptanceError("active product run did not enter running state before timeout")
    except Exception as original_error:
        try:
            delete_thread(client, thread_id)
        except AcceptanceError:
            raise AcceptanceError(
                "active product submission failed and its thread cleanup also failed"
            ) from original_error
        raise


def verify_product_active_command(args):
    if (
        not SAFE_RUNTIME_ID.fullmatch(args.thread_id)
        or not SAFE_RUNTIME_ID.fullmatch(args.run_id)
        or not SYNTHETIC_MARKER.fullmatch(args.marker)
    ):
        raise AcceptanceError("active run identifiers or marker are invalid")
    scenario = read_scenario()
    _, case, sensitive, placeholder = _active_product_case(scenario)
    resolved_sensitive = substitute_marker(sensitive, args.marker, placeholder)
    expected = substitute_marker(case["expected_state_values"], args.marker, placeholder)
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    terminal = wait_for_run(
        client,
        args.thread_id,
        args.run_id,
        args.run_timeout,
        {"success"},
        resolved_sensitive,
    )
    assert_state(client, args.thread_id, expected, resolved_sensitive)
    if args.cleanup:
        delete_thread(client, args.thread_id)
    print(
        json.dumps(
            {
                "result": "PASS",
                "check": "active_product_run_survived_replacement",
                "case": case["name"],
                "thread_id": args.thread_id,
                "run_id": args.run_id,
                "terminal_status": terminal,
                "thread_cleaned": args.cleanup,
            },
            sort_keys=True,
        )
    )


def submit_active_command(args):
    if not 1 <= args.cpu_seconds <= 15 or not 10 <= args.running_timeout <= 180:
        raise AcceptanceError("active run cpu-seconds must be 1..15 and running-timeout 10..180")
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    marker = f"aip5411-active-{uuid.uuid4().hex}"
    thread_id = create_thread(client)
    payload = {"assistant_id": args.graph_id, "input": {"request": marker, "cpu_seconds": args.cpu_seconds}}
    status, body, _ = client.request("POST", f"/threads/{path_segment(thread_id)}/runs", payload)
    result = json_body(body)
    run_id = result.get("run_id") if isinstance(result, dict) else None
    if status not in (200, 201, 202) or not isinstance(run_id, str) or not run_id:
        raise AcceptanceError("active-run submission did not return a run ID")
    deadline = time.monotonic() + args.running_timeout
    while time.monotonic() < deadline:
        _, body, _ = client.request("GET", f"/threads/{path_segment(thread_id)}/runs/{path_segment(run_id)}")
        run = json_body(body)
        run_status = run.get("status") if isinstance(run, dict) else None
        if run_status == "running":
            print(json.dumps({"result": "PASS", "check": "active_run_submitted", "thread_id": thread_id, "run_id": run_id, "marker": marker}, sort_keys=True))
            return
        if run_status in TERMINAL:
            raise AcceptanceError("active run finished before queue replacement began")
        time.sleep(1)
    raise AcceptanceError("run did not enter running state before timeout")


def verify_run_command(args):
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    wait_for_run(client, args.thread_id, args.run_id, args.run_timeout)
    assert_state(client, args.thread_id, [args.expected_marker], [])
    if args.cleanup:
        delete_thread(client, args.thread_id)
    print(json.dumps({"result": "PASS", "check": "active_run_survived_queue_replacement", "thread_id": args.thread_id, "run_id": args.run_id, "thread_cleaned": args.cleanup}, sort_keys=True))


def kubectl_json(namespace: str, resource: str, name: str):
    import subprocess

    try:
        raw = subprocess.run(
            [os.environ.get("KUBECTL", "kubectl"), "-n", namespace, "get", resource, name, "-o", "json"],
            check=True, capture_output=True, text=True, timeout=20,
        ).stdout
        return json.loads(raw)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        raise AcceptanceError(f"could not read Kubernetes {resource} {name}") from None


def hpa_observation(namespace: str, hpa_name: str, deployment_name: str):
    hpa = kubectl_json(namespace, "hpa", hpa_name)
    spec = hpa.get("spec", {})
    target = spec.get("scaleTargetRef", {})
    if target.get("kind") != "Deployment" or target.get("name") != deployment_name:
        raise AcceptanceError("HPA scale target does not match the supplied queue Deployment")
    deployment = kubectl_json(namespace, "deployment", deployment_name)
    status = hpa.get("status", {})
    current_metrics = status.get("currentMetrics", [])
    cpu_metrics = [m for m in current_metrics if m.get("type") == "Resource" and m.get("resource", {}).get("name") == "cpu"]
    target_metrics = spec.get("metrics", [])
    cpu_targets = [m for m in target_metrics if m.get("type") == "Resource" and m.get("resource", {}).get("name") == "cpu"]
    cpu_average = None
    if cpu_metrics:
        current = cpu_metrics[0].get("resource", {}).get("current", {})
        cpu_average = current.get("averageUtilization")
    return {
        "min": spec.get("minReplicas", 1),
        "max": spec.get("maxReplicas"),
        "desired": status.get("desiredReplicas"),
        "current": status.get("currentReplicas"),
        "cpu_metrics_present": bool(cpu_metrics),
        "cpu_average_utilization": cpu_average,
        "cpu_target_utilization": (
            cpu_targets[0].get("resource", {}).get("target", {}).get("averageUtilization")
            if cpu_targets
            else None
        ),
        "deployment_replicas": deployment.get("status", {}).get("readyReplicas", 0),
    }


def wait_for_ready_scale_up(observe, futures, starting_replicas: int, starting_ready: int, timeout: int):
    """Wait for both the HPA and ready worker count to rise, even after runs end."""
    deadline = time.monotonic() + timeout
    peak_hpa = starting_replicas
    peak_ready = starting_ready
    last = None
    while time.monotonic() < deadline:
        for future in futures:
            if future.done():
                future.result()
        last = observe()
        peak_hpa = max(peak_hpa, last["current"] or 0, last["desired"] or 0)
        peak_ready = max(peak_ready, last["deployment_replicas"] or 0)
        if all(future.done() for future in futures) and peak_hpa > starting_replicas and peak_ready > starting_ready:
            return peak_hpa, peak_ready, last
        time.sleep(min(5, max(0, deadline - time.monotonic())))
    for future in futures:
        if not future.done():
            raise AcceptanceError("bounded LAS runs did not complete before scale-up timeout")
        future.result()
    raise AcceptanceError("queue HPA did not add a ready worker before scale-up timeout")


def deployment_replicas(namespace: str, name: str):
    deployment = kubectl_json(namespace, "deployment", name)
    return {
        "desired": deployment.get("spec", {}).get("replicas", 1),
        "ready": deployment.get("status", {}).get("readyReplicas", 0),
    }


def observe_hpa_after_completion(args, started: float, samples: list[dict[str, Any]], seconds: float):
    """Append bounded post-run HPA samples so delayed decisions are visible."""
    deadline = time.monotonic() + seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(args.sample_interval, remaining))
        observation = hpa_observation(args.namespace, args.hpa, args.deployment)
        api_now = deployment_replicas(args.namespace, args.api_deployment)
        if api_now["desired"] != 1:
            raise AcceptanceError("LAS API Deployment replica count changed after product load")
        samples.append(
            {
                "elapsed_seconds": round(time.monotonic() - started, 3),
                "current": observation["current"],
                "desired": observation["desired"],
                "ready": observation["deployment_replicas"],
                "cpu_average_utilization": observation["cpu_average_utilization"],
            }
        )


def product_load_command(args):
    if os.environ.get("LAS_DISPOSABLE_CLUSTER_CONFIRMED") != "true":
        raise AcceptanceError("set LAS_DISPOSABLE_CLUSTER_CONFIRMED=true only for a disposable cluster")
    if args.workers < 1 or args.workers > 8:
        raise AcceptanceError("workers must be 1..8")
    if args.timeout < 30 or args.timeout > 900:
        raise AcceptanceError("timeout must be 30..900 seconds")
    post_completion_observation = getattr(args, "post_completion_observation", 0)
    if args.request_timeout <= 0 or args.sample_interval < 1 or args.sample_interval > 30:
        raise AcceptanceError("request-timeout must be positive and sample-interval must be 1..30 seconds")
    if post_completion_observation < 0 or post_completion_observation > 120:
        raise AcceptanceError("post-completion-observation must be 0..120 seconds")
    scenario = read_scenario()
    graph_id = scenario.get("graph_id")
    case = scenario.get("case")
    if not isinstance(graph_id, str) or not graph_id or not isinstance(case, dict):
        raise AcceptanceError("product-load scenario needs graph_id and one case object")
    scenario_sensitive = scenario.get("sensitive_values", [])
    if not isinstance(scenario_sensitive, list) or not all(
        isinstance(value, str) for value in scenario_sensitive
    ):
        raise AcceptanceError("scenario sensitive_values must be a string list")
    cleanup_threads = scenario.get("cleanup_threads", True)
    if not isinstance(cleanup_threads, bool):
        raise AcceptanceError("cleanup_threads must be true or false")

    base_case = dict(case)
    if base_case.get("expected_outcome", "success") != "success":
        raise AcceptanceError("product-load requires a successful product case")

    client = LASClient(os.environ.get("LAS_BASE_URL", ""), min(args.request_timeout, args.timeout))
    before = hpa_observation(args.namespace, args.hpa, args.deployment)
    api_before = deployment_replicas(args.namespace, args.api_deployment)
    if api_before["desired"] != 1:
        raise AcceptanceError("LAS API Deployment is not configured for one replica")
    if before["max"] is None or before["max"] < before["min"]:
        raise AcceptanceError("HPA did not provide valid minimum and maximum bounds")
    if not before["cpu_metrics_present"]:
        raise AcceptanceError("HPA has no current CPU metrics")
    if before["current"] is None or before["deployment_replicas"] < before["current"]:
        raise AcceptanceError("queue HPA baseline does not have all current replicas ready")
    if args.workers > before["max"] * 4:
        raise AcceptanceError("workload exceeds the bounded worker-to-HPA ratio")

    case_sensitive = base_case.get("sensitive_values", [])
    if not isinstance(case_sensitive, list):
        raise AcceptanceError("case sensitive_values must be a string list")
    base_case["sensitive_values"] = scenario_sensitive + case_sensitive
    base_case["run_modes"] = [args.run_mode]
    base_case["cleanup"] = cleanup_threads

    def execute(index: int):
        worker_case = dict(base_case)
        base_name = str(base_case.get("name", "product-load"))[:70]
        worker_case["name"] = f"{base_name}-{index + 1}"
        return run_protocol_case(client, graph_id, worker_case, args.timeout, cleanup_threads)

    started = time.monotonic()
    samples = []
    results = []
    processed = set()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(execute, index) for index in range(args.workers)]
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            observation = hpa_observation(args.namespace, args.hpa, args.deployment)
            api_now = deployment_replicas(args.namespace, args.api_deployment)
            if api_now["desired"] != 1:
                raise AcceptanceError("LAS API Deployment replica count changed during product load")
            samples.append(
                {
                    "elapsed_seconds": round(time.monotonic() - started, 3),
                    "current": observation["current"],
                    "desired": observation["desired"],
                    "ready": observation["deployment_replicas"],
                    "cpu_average_utilization": observation["cpu_average_utilization"],
                }
            )
            for index, future in enumerate(futures):
                if future.done() and index not in processed:
                    results.extend(future.result())
                    processed.add(index)
            if len(processed) == len(futures):
                break
            time.sleep(min(args.sample_interval, max(0, deadline - time.monotonic())))
        if len(processed) != len(futures):
            for future in futures:
                future.cancel()
            raise AcceptanceError("representative product load did not finish before timeout")

    # HPA decisions can lag behind short product calls and metrics collection.
    # Continue observing for a bounded window after all futures complete so a
    # delayed scale decision is represented in evidence rather than missed.
    observe_hpa_after_completion(args, started, samples, post_completion_observation)

    peak_current = max([before["current"] or 0] + [sample["current"] or 0 for sample in samples])
    peak_desired = max([before["desired"] or 0] + [sample["desired"] or 0 for sample in samples])
    peak_ready = max(
        [before["deployment_replicas"] or 0] + [sample["ready"] or 0 for sample in samples]
    )
    if max(peak_current, peak_desired, peak_ready) > before["max"]:
        raise AcceptanceError("observed queue replicas exceeded the HPA maximum")
    scaled = (
        peak_current > (before["current"] or 0)
        or peak_desired > (before["desired"] or 0)
        or peak_ready > (before["deployment_replicas"] or 0)
    )
    if args.scale_expectation == "required" and not scaled:
        raise AcceptanceError("representative product load did not trigger CPU scale-up")
    if args.scale_expectation == "none" and scaled:
        raise AcceptanceError("representative product load unexpectedly triggered CPU scale-up")
    durations = [check["duration_seconds"] for check in results]
    ordered_durations = sorted(durations)

    def percentile(fraction: float) -> float:
        index = max(0, min(len(ordered_durations) - 1, math.ceil(len(ordered_durations) * fraction) - 1))
        return ordered_durations[index]

    cpu_samples = [
        sample["cpu_average_utilization"]
        for sample in samples
        if isinstance(sample["cpu_average_utilization"], (int, float))
    ]
    print(
        json.dumps(
            {
                "result": "PASS",
                "check": "representative_product_load",
                "scale_observation": "scaled" if scaled else "no_cpu_scale_observed",
                "workers": args.workers,
                "completed_runs": len(results),
                "duration_seconds": round(time.monotonic() - started, 3),
                "run_duration_min_seconds": min(durations),
                "run_duration_p50_seconds": percentile(0.50),
                "run_duration_p95_seconds": percentile(0.95),
                "run_duration_max_seconds": max(durations),
                "run_duration_average_seconds": round(sum(durations) / len(durations), 3),
                "failed_runs": 0,
                "hpa_min": before["min"],
                "hpa_max": before["max"],
                "starting_replicas": before["current"],
                "peak_current_replicas": peak_current,
                "peak_desired_replicas": peak_desired,
                "peak_ready_workers": peak_ready,
                "peak_cpu_average_utilization": max(cpu_samples) if cpu_samples else None,
                "cpu_target_utilization": before["cpu_target_utilization"],
                "api_replicas": api_before["desired"],
                "queue_backlog": "not_exposed_by_agent_server_api",
                "worker_attribution": "requires_sanitized_queue_log_or_runtime_correlation",
                "samples": len(samples),
                "post_completion_observation_seconds": post_completion_observation,
                "checks": results,
            },
            sort_keys=True,
        )
    )


def scale_command(args):
    if os.environ.get("LAS_DISPOSABLE_CLUSTER_CONFIRMED") != "true":
        raise AcceptanceError("set LAS_DISPOSABLE_CLUSTER_CONFIRMED=true only for a disposable cluster")
    if args.workers < 1 or args.workers > 8 or not 1 <= args.cpu_seconds <= 15:
        raise AcceptanceError("workers must be 1..8 and cpu_seconds must be 1..15")
    if args.timeout < 30 or args.timeout > 900 or args.downscale_timeout < 300 or args.downscale_timeout > 1200:
        raise AcceptanceError("timeout must be 30..900 and downscale-timeout 300..1200 seconds")
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), min(args.timeout, 60))
    before = hpa_observation(args.namespace, args.hpa, args.deployment)
    api_before = deployment_replicas(args.namespace, args.api_deployment)
    if api_before["desired"] != 1:
        raise AcceptanceError("LAS API Deployment is not configured for one replica")
    if before["max"] is None or before["max"] < before["min"]:
        raise AcceptanceError("HPA did not provide valid minimum and maximum bounds")
    if before["current"] is not None and before["current"] >= before["max"]:
        raise AcceptanceError("start below the HPA maximum to qualify scale-up")
    if not before["cpu_metrics_present"]:
        raise AcceptanceError("HPA has no current CPU metrics")
    if before["current"] is None or before["deployment_replicas"] < before["current"]:
        raise AcceptanceError("queue HPA baseline does not have all current replicas ready")
    if before["deployment_replicas"] < before["min"]:
        raise AcceptanceError("queue Deployment is below its ready worker floor before the test")
    if args.workers > before["max"] * 4:
        raise AcceptanceError("workload exceeds the bounded worker-to-HPA ratio")

    def execute(index: int):
        name = f"scale-{index + 1}"
        marker = f"aip5411-{uuid.uuid4().hex}"
        case = {"name": name, "input": {"request": marker, "cpu_seconds": args.cpu_seconds}, "expected_state_values": [marker], "run_modes": ["sync"], "cleanup": True}
        return run_protocol_case(client, args.graph_id, case, args.timeout)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(execute, index) for index in range(args.workers)]
        peak_hpa, peak_ready, last = wait_for_ready_scale_up(
            lambda: hpa_observation(args.namespace, args.hpa, args.deployment),
            futures,
            before["current"],
            before["deployment_replicas"],
            args.timeout,
        )
        for future in futures:
            future.result()
    if peak_hpa <= before["current"]:
        raise AcceptanceError("queue HPA did not scale above its starting replica count")
    if peak_hpa > last["max"] or peak_ready > last["max"]:
        raise AcceptanceError("observed queue replicas exceeded the HPA maximum")

    downscale_deadline = time.monotonic() + args.downscale_timeout
    while time.monotonic() < downscale_deadline:
        last = hpa_observation(args.namespace, args.hpa, args.deployment)
        api_now = deployment_replicas(args.namespace, args.api_deployment)
        if api_now["desired"] != 1:
            raise AcceptanceError("LAS API Deployment replica count changed during queue scaling")
        if (
            last["current"] == last["min"]
            and last["desired"] == last["min"]
            and last["deployment_replicas"] >= last["min"]
        ):
            break
        time.sleep(10)
    if last["current"] != last["min"] or last["desired"] != last["min"]:
        raise AcceptanceError("queue HPA did not return to its minimum before downscale timeout")
    if last["deployment_replicas"] < last["min"]:
        raise AcceptanceError("queue Deployment did not restore its HPA minimum ready workers")
    print(json.dumps({"result": "PASS", "check": "queue_scale_up_cap_downscale_floor_api_fixed", "workers": args.workers, "peak_replicas": peak_hpa, "peak_ready_workers": peak_ready, "hpa_min": last["min"], "hpa_max": last["max"], "ready_workers": last["deployment_replicas"], "api_replicas": api_now["desired"], "cpu_metrics_present": last["cpu_metrics_present"], "cpu_target_utilization": last["cpu_target_utilization"]}, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    protocol = subparsers.add_parser("protocol", help="validate synchronous, queued, SSE, and state flows")
    protocol.add_argument("--request-timeout", type=float, default=45)
    protocol.add_argument("--run-timeout", type=float, default=300)
    protocol.set_defaults(func=protocol_command)
    state = subparsers.add_parser("state", help="verify a marker exists under persisted graph values")
    state.add_argument("--thread-id", required=True)
    state.add_argument("--expected-value", required=True)
    state.add_argument("--request-timeout", type=float, default=45)
    state.set_defaults(func=state_command)
    health = subparsers.add_parser("health", help="verify the Agent Server health endpoint")
    health.add_argument("--request-timeout", type=float, default=10)
    health.set_defaults(func=health_command)
    cleanup = subparsers.add_parser("delete-thread", help="delete one exact qualification thread")
    cleanup.add_argument("--thread-id", required=True)
    cleanup.add_argument("--request-timeout", type=float, default=45)
    cleanup.set_defaults(func=delete_thread_command)
    active = subparsers.add_parser("submit-active", help="start a bounded active queue run for replacement testing")
    active.add_argument("--graph-id", default="contract_fixture")
    active.add_argument("--cpu-seconds", type=int, default=15)
    active.add_argument("--running-timeout", type=int, default=45)
    active.add_argument("--request-timeout", type=float, default=45)
    active.set_defaults(func=submit_active_command)
    verify = subparsers.add_parser("verify-run", help="verify an active run completed and persisted its marker")
    verify.add_argument("--thread-id", required=True)
    verify.add_argument("--run-id", required=True)
    verify.add_argument("--expected-marker", required=True)
    verify.add_argument("--run-timeout", type=float, default=300)
    verify.add_argument("--request-timeout", type=float, default=45)
    verify.add_argument("--cleanup", action="store_true")
    verify.set_defaults(func=verify_run_command)
    product_active = subparsers.add_parser(
        "submit-product-active",
        help="read active_run_case from stdin and wait until its queued run is active",
    )
    product_active.add_argument("--running-timeout", type=int, default=90)
    product_active.add_argument("--request-timeout", type=float, default=45)
    product_active.set_defaults(func=submit_product_active_command)
    product_verify = subparsers.add_parser(
        "verify-product-active",
        help="read active_run_case from stdin and verify the exact run after replacement",
    )
    product_verify.add_argument("--thread-id", required=True)
    product_verify.add_argument("--run-id", required=True)
    product_verify.add_argument("--marker", required=True)
    product_verify.add_argument("--run-timeout", type=float, default=300)
    product_verify.add_argument("--request-timeout", type=float, default=45)
    product_verify.add_argument("--cleanup", action="store_true")
    product_verify.set_defaults(func=verify_product_active_command)
    product_load = subparsers.add_parser(
        "product-load", help="run representative product input and observe queue HPA behavior"
    )
    product_load.add_argument("--namespace", required=True)
    product_load.add_argument("--hpa", required=True)
    product_load.add_argument("--deployment", required=True)
    product_load.add_argument("--api-deployment", required=True)
    product_load.add_argument("--workers", type=int, default=4)
    product_load.add_argument("--run-mode", choices=("sync", "queued"), default="queued")
    product_load.add_argument(
        "--scale-expectation", choices=("observe", "required", "none"), default="observe"
    )
    product_load.add_argument("--timeout", type=int, default=300)
    product_load.add_argument("--request-timeout", type=float, default=60)
    product_load.add_argument("--sample-interval", type=float, default=5)
    product_load.add_argument(
        "--post-completion-observation",
        type=float,
        default=30,
        help="bounded HPA observation window after all product calls finish",
    )
    product_load.set_defaults(func=product_load_command)
    scale = subparsers.add_parser("scale", help="submit bounded queue CPU load and read HPA observations")
    scale.add_argument("--namespace", required=True)
    scale.add_argument("--hpa", required=True)
    scale.add_argument("--deployment", required=True)
    scale.add_argument("--api-deployment", required=True)
    scale.add_argument("--graph-id", default="contract_fixture")
    scale.add_argument("--workers", type=int, default=4)
    scale.add_argument("--cpu-seconds", type=int, default=10)
    scale.add_argument("--timeout", type=int, default=300)
    scale.add_argument("--downscale-timeout", type=int, default=600)
    scale.set_defaults(func=scale_command)
    args = parser.parse_args()
    try:
        args.func(args)
    except AcceptanceError as exc:
        print(json.dumps({"result": "FAIL", "reason": str(exc)}, sort_keys=True), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
