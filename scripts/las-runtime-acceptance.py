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
CHECKPOINT_HISTORY_PAGE_SIZE = 100
MAX_CHECKPOINT_HISTORY_SNAPSHOTS = 1000
THREAD_CLEANUP_TIMEOUT = 15.0
THREAD_CLEANUP_INTERVAL = 0.25
TERMINAL = {"success", "error", "failed", "cancelled", "timeout"}
FAILURE_TERMINAL = TERMINAL - {"success"}
SAFE_CASE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
SAFE_RUNTIME_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
SYNTHETIC_MARKER = re.compile(r"^mpr-qualification-[0-9a-f]{32}$")
CREDENTIAL_KEY = re.compile(
    r"(?:authorization|api[_-]?key|access[_-]?(?:key|token)|secret|token|password|credential|role[_-]?arn|private[_-]?key)",
    re.IGNORECASE,
)
FORBIDDEN_RESPONSE_PATH_COMPONENTS = {
    "checkpoint",
    "config",
    "context",
    "input",
    "metadata",
    "parent_config",
    "request",
}
SAFE_PATH_COMPONENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")


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
        if (
            parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
            or parsed.path not in ("", "/")
        ):
            raise AcceptanceError("LAS_BASE_URL cannot contain credentials, path, query, or fragment")
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


def credential_values(value: Any):
    """Yield string credentials from recognized config fields without logging them."""
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(key, str) and CREDENTIAL_KEY.search(key):
                yield from (candidate for candidate in strings(item) if candidate)
            else:
                yield from credential_values(item)
    elif isinstance(value, list):
        for item in value:
            yield from credential_values(item)


def _json_unescaped_values(text: str):
    """Yield parsed/JSON-unescaped text so alternate escapes cannot hide a secret."""
    candidates = [text]
    candidates.extend(
        line[5:].lstrip() if line.startswith("data:") else line
        for line in text.splitlines()
        if line.strip()
    )
    for candidate in candidates:
        try:
            parsed = strict_json_loads(candidate)
        except (json.JSONDecodeError, ValueError):
            parsed = None
        if parsed is not None:
            yield from strings(parsed)

        current = candidate
        for _ in range(3):
            wrapped = (
                '"'
                + current.replace('"', r'\"')
                .replace("\n", r"\n")
                .replace("\r", r"\r")
                .replace("\t", r"\t")
                + '"'
            )
            try:
                decoded = json.loads(wrapped)
            except (json.JSONDecodeError, ValueError):
                break
            if not isinstance(decoded, str) or decoded == current:
                break
            yield decoded
            current = decoded


def assert_sensitive_absent(value: bytes | str, sensitive: list[str], location: str) -> None:
    text = value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
    decoded_values = [text, *_json_unescaped_values(text)]
    if any(
        secret
        and any(
            secret in candidate
            or any(variant in candidate for variant in _sensitive_variants(secret))
            for candidate in decoded_values
        )
        for secret in sensitive
    ):
        raise AcceptanceError(f"sensitive marker appeared in {location}")


def _dotted_value(value: Any, path: str) -> Any:
    current = value
    for component in path.split("."):
        if not isinstance(current, dict) or component not in current:
            raise AcceptanceError("expected_response_paths referenced a missing graph output")
        current = current[component]
    return current


def _known_output_strings(value: Any):
    """Yield output values without allowing echoed user input to satisfy a check."""
    if not isinstance(value, dict):
        yield from strings(value)
        return
    handled: set[str] = set()
    messages = value.get("messages")
    if isinstance(messages, list):
        handled.add("messages")
        for message in messages:
            if not isinstance(message, dict):
                continue
            role = str(message.get("role") or message.get("type") or "").lower()
            if role in {"ai", "assistant"}:
                yield from strings(message.get("content"))
                yield from strings(message.get("additional_kwargs"))
    for key in (
        "answer",
        "response",
        "result",
        "output",
        "structured_response",
        "structured_output",
    ):
        if key in value:
            handled.add(key)
            yield from strings(value[key])
    # LangGraph update events are often nested under a node name. Recurse only
    # into object containers; never treat arbitrary scalar state/input fields
    # as product output.
    for key, item in value.items():
        if key in handled or key in FORBIDDEN_RESPONSE_PATH_COMPONENTS:
            continue
        if isinstance(item, dict):
            yield from _known_output_strings(item)


def graph_response_strings(value: Any, response_paths: list[str] | None = None) -> list[str]:
    """Extract declared/known graph output while excluding input and metadata."""
    if isinstance(value, dict) and isinstance(value.get("values"), (dict, list)):
        target = value["values"]
    else:
        target = value
    if response_paths:
        output: list[str] = []
        for path in response_paths:
            selected = _dotted_value(target, path)
            if path.split(".")[-1] == "messages":
                output.extend(_known_output_strings({"messages": selected}))
            else:
                output.extend(strings(selected))
        return output
    return list(_known_output_strings(target))


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


def recover_thread_id(body: bytes) -> str | None:
    """Recover exactly one safe thread_id for cleanup after create validation."""
    matches = {
        match.decode("ascii")
        for match in re.findall(
            rb'"thread_id"\s*:\s*"([A-Za-z0-9][A-Za-z0-9._:-]{0,127})"',
            body,
        )
    }
    if len(matches) != 1:
        return None
    candidate = next(iter(matches))
    return candidate if SAFE_RUNTIME_ID.fullmatch(candidate) else None


def create_thread(client: LASClient, sensitive: list[str] | None = None) -> str:
    status, body, _ = client.request("POST", "/threads", {})
    scan_values = list(sensitive or [])
    api_key = getattr(client, "api_key", "")
    if api_key:
        scan_values.append(api_key)
    scan_values = list(dict.fromkeys(scan_values))
    # A successful-but-malformed response may still have created a durable
    # thread.  Recover only one unambiguous, safe identifier and clean it up
    # before reporting the validation failure.
    cleanup_id = recover_thread_id(body) if 200 <= status < 300 else None
    try:
        assert_sensitive_absent(body, scan_values, "thread creation response")
        result = json_body(body)
        thread_id = result.get("thread_id") if isinstance(result, dict) else None
        if (
            status not in (200, 201)
            or not isinstance(thread_id, str)
            or not SAFE_RUNTIME_ID.fullmatch(thread_id)
        ):
            raise AcceptanceError("thread creation failed")
        return thread_id
    except AcceptanceError as original_error:
        if cleanup_id is not None:
            try:
                delete_thread(client, cleanup_id, scan_values)
            except AcceptanceError:
                raise AcceptanceError(
                    "thread creation validation failed and cleanup also failed"
                ) from original_error
        raise


def delete_thread(
    client: LASClient, thread_id: str, sensitive: list[str] | None = None
) -> None:
    scan_values = list(sensitive or [])
    api_key = getattr(client, "api_key", "")
    if api_key:
        scan_values.append(api_key)
    scan_values = list(dict.fromkeys(scan_values))
    status, body, _ = client.request(
        "DELETE", f"/threads/{path_segment(thread_id)}", allow_http_error=True
    )
    scan_failed = False
    try:
        assert_sensitive_absent(body, scan_values, "thread cleanup response")
    except AcceptanceError:
        scan_failed = True
    if status not in (200, 202, 204, 404):
        raise AcceptanceError("thread cleanup failed")
    if status == 404:
        if scan_failed:
            raise AcceptanceError("sensitive marker appeared during thread cleanup")
        return
    deadline = time.monotonic() + THREAD_CLEANUP_TIMEOUT
    while time.monotonic() < deadline:
        status, body, _ = client.request(
            "GET", f"/threads/{path_segment(thread_id)}", allow_http_error=True
        )
        try:
            assert_sensitive_absent(body, scan_values, "thread cleanup confirmation")
        except AcceptanceError:
            scan_failed = True
        if status == 404:
            if scan_failed:
                raise AcceptanceError("sensitive marker appeared during thread cleanup")
            return
        if status != 200:
            raise AcceptanceError("thread cleanup confirmation failed")
        time.sleep(THREAD_CLEANUP_INTERVAL)
    raise AcceptanceError("thread cleanup was not confirmed before timeout")


def assert_state(
    client: LASClient,
    thread_id: str,
    expected: list[str],
    sensitive: list[str] | None = None,
):
    scan_values = list(sensitive or [])
    api_key = getattr(client, "api_key", "")
    if api_key:
        scan_values.append(api_key)
    status, body, _ = client.request("GET", f"/threads/{path_segment(thread_id)}/state")
    assert_sensitive_absent(
        body, list(dict.fromkeys(scan_values)), "persisted thread state"
    )
    result = json_body(body)
    if status != 200 or not isinstance(result, dict) or not isinstance(result.get("values"), (dict, list)):
        raise AcceptanceError("thread state response omitted graph values")
    state_values = list(strings(result["values"]))
    for item in expected:
        if not any(item in value for value in state_values):
            raise AcceptanceError("expected value was not persisted under graph state values")
    return result


def assert_checkpoint_history(
    client: LASClient,
    thread_id: str,
    expected: list[str],
    sensitive: list[str] | None = None,
    page_size: int = CHECKPOINT_HISTORY_PAGE_SIZE,
    max_snapshots: int = MAX_CHECKPOINT_HISTORY_SNAPSHOTS,
) -> int:
    """Scan complete supported history within a hard snapshot bound."""
    if (
        not isinstance(page_size, int)
        or isinstance(page_size, bool)
        or page_size < 1
        or not isinstance(max_snapshots, int)
        or isinstance(max_snapshots, bool)
        or max_snapshots < 1
    ):
        raise AcceptanceError("checkpoint history bounds must be positive integers")
    if not isinstance(expected, list) or not all(
        isinstance(item, str) and item for item in expected
    ):
        raise AcceptanceError("checkpoint history expected values must be non-empty strings")

    scan_values = list(sensitive or [])
    api_key = getattr(client, "api_key", "")
    if api_key:
        scan_values.append(api_key)
    scan_values = list(dict.fromkeys(scan_values))

    missing_expected = set(expected)
    before: dict[str, Any] | None = None
    seen_cursors: set[str] = set()
    snapshot_count = 0
    while True:
        # Request one item beyond the remaining allowance so oversized
        # histories fail closed without reading an unbounded number of pages.
        limit = min(page_size, max_snapshots - snapshot_count + 1)
        payload: dict[str, Any] = {"limit": limit}
        if before is not None:
            payload["before"] = before
        status, body, _ = client.request(
            "POST",
            f"/threads/{path_segment(thread_id)}/history",
            payload,
        )
        assert_sensitive_absent(body, scan_values, "checkpoint history")
        page = json_body(body)
        if status != 200 or not isinstance(page, list):
            raise AcceptanceError("checkpoint history response was not a snapshot list")
        if len(page) > limit:
            raise AcceptanceError("checkpoint history response exceeded its requested page size")
        if snapshot_count + len(page) > max_snapshots:
            raise AcceptanceError("checkpoint history exceeded the bounded snapshot limit")

        for snapshot in page:
            if not isinstance(snapshot, dict) or not isinstance(
                snapshot.get("values"), (dict, list)
            ):
                raise AcceptanceError("checkpoint history snapshot omitted graph values")
            snapshot_values = list(strings(snapshot["values"]))
            missing_expected = {
                item
                for item in missing_expected
                if not any(item in value for value in snapshot_values)
            }
        snapshot_count += len(page)

        if len(page) < limit:
            break
        checkpoint = page[-1].get("checkpoint")
        checkpoint_id = (
            checkpoint.get("checkpoint_id") if isinstance(checkpoint, dict) else None
        )
        if (
            not isinstance(checkpoint_id, str)
            or not checkpoint_id
            or checkpoint_id in seen_cursors
        ):
            raise AcceptanceError("checkpoint history pagination did not advance")
        seen_cursors.add(checkpoint_id)
        before = checkpoint

    if snapshot_count == 0:
        raise AcceptanceError("checkpoint history contained no snapshots")
    if missing_expected:
        raise AcceptanceError(
            "expected value was not persisted under checkpoint history graph values"
        )
    return snapshot_count


def assert_persistence(
    client: LASClient,
    thread_id: str,
    expected: list[str],
    sensitive: list[str] | None = None,
) -> tuple[dict[str, Any], int]:
    state = assert_state(client, thread_id, expected, sensitive)
    snapshot_count = assert_checkpoint_history(
        client, thread_id, expected, sensitive
    )
    return state, snapshot_count


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


def authoritative_status(value: Any) -> str | None:
    """Read only the authoritative top-level run/event status field."""
    if not isinstance(value, dict):
        return None
    status = value.get("status")
    return status.lower() if isinstance(status, str) else None


def nested_string_field(value: Any, field: str) -> str | None:
    if isinstance(value, dict):
        candidate = value.get(field)
        if isinstance(candidate, str) and candidate:
            return candidate
        for item in value.values():
            found = nested_string_field(item, field)
            if found is not None:
                return found
    elif isinstance(value, list):
        for item in value:
            found = nested_string_field(item, field)
            if found is not None:
                return found
    return None


def sse_run_id(body: bytes, sensitive: list[str]) -> str:
    run_ids: set[str] = set()
    for event in parse_sse(body, sensitive):
        if event["event"].lower() != "metadata":
            continue
        try:
            value = strict_json_loads(event["data"])
        except (json.JSONDecodeError, ValueError):
            continue
        run_id = nested_string_field(value, "run_id")
        if run_id:
            run_ids.add(run_id)
    if len(run_ids) > 1:
        raise AcceptanceError("SSE metadata contained conflicting run IDs")
    if run_ids:
        return next(iter(run_ids))
    raise AcceptanceError("SSE EOF completion omitted a run ID for terminal verification")


def assert_sse(
    body: bytes,
    expected_values: list[str],
    sensitive: list[str],
    expected_sequence: list[str] | None = None,
    terminal_event: str | None = None,
    terminal_status: str | None = None,
    response_paths: list[str] | None = None,
    completion: str | None = None,
    success_expected: bool = False,
) -> list[str]:
    events = parse_sse(body, sensitive)
    if not events:
        raise AcceptanceError("SSE stream contained no data events")
    # Metadata is transport/checkpoint context, not graph output. It must not
    # satisfy the product response assertion.
    graph_output: list[str] = []
    observed_statuses: list[str] = []
    for event in events:
        try:
            event_value = strict_json_loads(event["data"])
        except (json.JSONDecodeError, ValueError):
            continue
        event_status = authoritative_status(event_value)
        if event_status is not None:
            observed_statuses.append(event_status)
        if event["event"].lower() == "metadata":
            continue
        graph_output.extend(graph_response_strings(event_value, response_paths))
    if (success_expected or terminal_status == "success") and any(
        status in FAILURE_TERMINAL for status in observed_statuses
    ):
        raise AcceptanceError("SSE stream contained a failed terminal status")
    joined = "\n".join(graph_output)
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
        if authoritative_status(terminal_payload) != terminal_status:
            raise AcceptanceError("SSE terminal event had an unexpected status")
    elif completion == "eof_after_expected_values":
        if not expected_sequence or expected_sequence[-1].lower() == "metadata":
            raise AcceptanceError("SSE EOF completion needs an output event sequence")
        if event_names[-1] != expected_sequence[-1]:
            raise AcceptanceError("SSE stream did not end after the expected output event")
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
    sensitive_values = list(sensitive or [])
    api_key = getattr(client, "api_key", "")
    if api_key:
        sensitive_values.append(api_key)
    sensitive_values = list(dict.fromkeys(sensitive_values))
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
    expected_response_paths = case.get("expected_response_paths", [])
    sensitive = case.get("sensitive_values", [])
    modes = case.get("run_modes", ["sync", "queued", "stream"])
    expected_outcome = case.get("expected_outcome", "success")
    expected_http_statuses = case.get("expected_http_statuses", list(range(400, 500)))
    expected_run_statuses = case.get("expected_run_statuses", ["error", "failed", "cancelled", "timeout"])
    expected_sse_sequence = case.get("expected_sse_event_sequence", [])
    expected_sse_terminal_event = case.get("expected_sse_terminal_event")
    expected_sse_terminal_status = case.get("expected_sse_terminal_status")
    expected_sse_completion = case.get("expected_sse_completion")
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
    if not isinstance(expected_response_paths, list) or not all(
        isinstance(path, str)
        and path
        and all(SAFE_PATH_COMPONENT.fullmatch(component) for component in path.split("."))
        and not FORBIDDEN_RESPONSE_PATH_COMPONENTS.intersection(path.split("."))
        for path in expected_response_paths
    ):
        raise AcceptanceError(
            "expected_response_paths must be safe dotted paths and cannot select input/context/metadata"
        )
    if not isinstance(sensitive, list) or not all(isinstance(v, str) for v in sensitive):
        raise AcceptanceError("sensitive_values must be a string list")
    if not isinstance(modes, list) or not modes or set(modes) - {"sync", "queued", "stream"}:
        raise AcceptanceError("run_modes may contain sync, queued, and stream")
    if expected_outcome not in ("success", "failure"):
        raise AcceptanceError("expected_outcome must be success or failure")
    if not isinstance(expected_http_statuses, list) or not all(
        isinstance(value, int) and not isinstance(value, bool) and 400 <= value <= 599
        for value in expected_http_statuses
    ):
        raise AcceptanceError("expected_http_statuses must contain only 4xx/5xx statuses")
    if not isinstance(expected_run_statuses, list) or not expected_run_statuses or not all(
        isinstance(value, str) and value in FAILURE_TERMINAL
        for value in expected_run_statuses
    ):
        raise AcceptanceError("expected_run_statuses must contain only failed terminal statuses")
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
    if expected_sse_completion not in (None, "terminal_event", "eof_after_expected_values"):
        raise AcceptanceError(
            "expected_sse_completion must be terminal_event or eof_after_expected_values"
        )
    if expected_sse_terminal_status is not None:
        if expected_sse_completion not in (None, "terminal_event"):
            raise AcceptanceError("terminal SSE status conflicts with expected_sse_completion")
        expected_sse_completion = "terminal_event"
        if expected_outcome == "success" and expected_sse_terminal_status != "success":
            raise AcceptanceError("successful SSE cases require a success terminal status")
        if (
            expected_outcome == "failure"
            and expected_sse_terminal_status not in expected_run_statuses
        ):
            raise AcceptanceError(
                "failure SSE terminal status must be an allowed failed run status"
            )
    if expected_sse_completion == "terminal_event" and (
        not expected_sse_terminal_event or expected_sse_terminal_status is None
    ):
        raise AcceptanceError(
            "terminal_event completion requires a non-empty terminal event and status"
        )
    if expected_outcome == "success" and "stream" in modes and expected_sse_completion is None:
        raise AcceptanceError(
            "successful stream cases must declare terminal_event or eof_after_expected_values completion"
        )
    if expected_sse_completion == "eof_after_expected_values" and not expected_sse_sequence:
        raise AcceptanceError("eof_after_expected_values requires expected_sse_event_sequence")
    if not isinstance(placeholder, str) or not placeholder:
        raise AcceptanceError("marker_placeholder must be a non-empty string")
    if not isinstance(cleanup, bool):
        raise AcceptanceError("cleanup must be true or false")
    if not isinstance(run_options, dict) or set(run_options) & {"assistant_id", "input"}:
        raise AcceptanceError("run_options must be an object and cannot replace assistant_id or input")
    if context is not None and not isinstance(context, dict):
        raise AcceptanceError("context must be an object")
    if list(
        credential_values(
            {"input": run_input, "context": context, "run_options": run_options}
        )
    ) and not sensitive:
        raise AcceptanceError(
            "credential-bearing input/context requires sensitive_values canaries"
        )
    sensitive = list(
        dict.fromkeys(
            [
                *sensitive,
                *(
                    [getattr(client, "api_key", "")]
                    if getattr(client, "api_key", "")
                    else []
                ),
            ]
        )
    )

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
    retained_thread_ids: list[str] = []
    retained_thread_sensitive: dict[str, list[str]] = {}
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
        payload = {"assistant_id": graph_id, "input": input_copy}
        if context is not None:
            payload["context"] = substitute_marker(context, marker, placeholder)
        payload.update(substitute_marker(run_options, marker, placeholder))
        if expected_response_paths:
            submitted_values = list(
                strings(
                    {
                        "input": input_copy,
                        "context": payload.get("context"),
                        "run_options": {
                            key: value
                            for key, value in payload.items()
                            if key not in {"assistant_id", "input", "context"}
                        },
                    }
                )
            )
            if any(
                expected_value in submitted
                for expected_value in case_expected_response
                for submitted in submitted_values
            ):
                raise AcceptanceError(
                    "explicit response paths cannot prove a value already present in submitted input/context"
                )
        case_sensitive = list(
            dict.fromkeys([*case_sensitive, *credential_values(payload)])
        )
        thread_id = create_thread(client, case_sensitive)
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
                    result_status = authoritative_status(result)
                    output = "\n".join(
                        graph_response_strings(result, expected_response_paths)
                    )
                    if expected_outcome == "failure":
                        terminal_status = result_status
                        if terminal_status not in expected_run_statuses:
                            raise AcceptanceError("synchronous run unexpectedly succeeded")
                    elif result_status in FAILURE_TERMINAL:
                        raise AcceptanceError("synchronous run returned a failed terminal status")
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
                        expected_response_paths,
                        expected_sse_completion,
                        expected_outcome == "success",
                    )
                    if expected_outcome == "failure":
                        parsed = parse_sse(body, case_sensitive)
                        try:
                            terminal_payload = strict_json_loads(parsed[-1]["data"])
                        except (json.JSONDecodeError, ValueError):
                            terminal_payload = None
                        terminal_status = authoritative_status(terminal_payload)
                        if terminal_status not in expected_run_statuses:
                            raise AcceptanceError("streaming run unexpectedly succeeded")
                    else:
                        if expected_sse_completion == "eof_after_expected_values":
                            run_id = sse_run_id(body, case_sensitive)
                            terminal_status = wait_for_run(
                                client,
                                thread_id,
                                run_id,
                                timeout,
                                {"success"},
                                case_sensitive,
                            )
                        else:
                            terminal_status = expected_sse_terminal_status

            if expected_outcome == "success":
                state = assert_state(client, thread_id, case_expected, case_sensitive)
                if mode == "queued":
                    queued_output = "\n".join(
                        graph_response_strings(state, expected_response_paths)
                    )
                    if not all(item in queued_output for item in case_expected_response):
                        raise AcceptanceError("queued graph output omitted an expected result")
        except Exception as original_error:
            # A failed case is never useful persistence evidence. Clean it even
            # when successful cases are intentionally retained for restart
            # verification so a partially submitted credential-bearing run is
            # not orphaned.
            cleanup_failed = False
            for cleanup_thread_id in dict.fromkeys([thread_id, *retained_thread_ids]):
                try:
                    cleanup_sensitive = (
                        case_sensitive
                        if cleanup_thread_id == thread_id
                        else retained_thread_sensitive.get(cleanup_thread_id, [])
                    )
                    delete_thread(client, cleanup_thread_id, cleanup_sensitive)
                except AcceptanceError:
                    cleanup_failed = True
            if cleanup_failed:
                raise AcceptanceError(
                    "qualification case failed and cleanup also failed for one or more threads"
                ) from original_error
            raise

        if cleanup:
            delete_thread(client, thread_id, case_sensitive)
        else:
            retained_thread_ids.append(thread_id)
            retained_thread_sensitive[thread_id] = case_sensitive
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


def scenario_sensitive_values(scenario: dict[str, Any]) -> list[str]:
    """Resolve configured canaries and credential values without returning them."""
    resolved: list[str] = []
    top_level = scenario.get("sensitive_values", [])
    if not isinstance(top_level, list) or not all(
        isinstance(value, str) for value in top_level
    ):
        raise AcceptanceError("scenario sensitive_values must be a string list")
    resolved.extend(top_level)
    candidates: list[Any] = []
    cases = scenario.get("cases", [])
    if cases is not None:
        if not isinstance(cases, list):
            raise AcceptanceError("scenario cases must be a list")
        candidates.extend(cases)
    for key in ("case", "active_run_case"):
        if scenario.get(key) is not None:
            candidates.append(scenario[key])
    for case in candidates:
        if not isinstance(case, dict):
            raise AcceptanceError("scenario cases must be objects")
        case_sensitive = case.get("sensitive_values", [])
        if not isinstance(case_sensitive, list) or not all(
            isinstance(value, str) for value in case_sensitive
        ):
            raise AcceptanceError("case sensitive_values must be a string list")
        resolved.extend(case_sensitive)
        resolved.extend(credential_values(case))
    return list(dict.fromkeys(value for value in resolved if value))


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
    health_sensitive = list(
        dict.fromkeys(
            [*scenario_sensitive, *([client.api_key] if client.api_key else [])]
        )
    )
    health_status, health_body, _ = client.request("GET", "/ok")
    assert_sensitive_absent(health_body, health_sensitive, "Agent Server health response")
    health = json_body(health_body)
    if health_status != 200 or not isinstance(health, dict) or health.get("ok") is not True:
        raise AcceptanceError("Agent Server health check failed")
    all_checks = []
    cleanup_sensitive_by_thread: dict[str, list[str]] = {}
    try:
        for case in cases:
            if not isinstance(case, dict):
                raise AcceptanceError("scenario cases must be objects")
            case_copy = dict(case)
            case_sensitive = case_copy.get("sensitive_values", [])
            if not isinstance(case_sensitive, list):
                raise AcceptanceError("case sensitive_values must be a string list")
            declared_sensitive = scenario_sensitive + case_sensitive
            if list(credential_values(case_copy)) and not declared_sensitive:
                raise AcceptanceError(
                    "credential-bearing input/context requires sensitive_values canaries"
                )
            case_copy["sensitive_values"] = list(
                dict.fromkeys(
                    [
                        *declared_sensitive,
                        *([client.api_key] if client.api_key else []),
                    ]
                )
            )
            case_checks = run_protocol_case(
                client, graph_id, case_copy, args.run_timeout, cleanup_threads
            )
            all_checks.extend(case_checks)
            for check in case_checks:
                thread_id = check.get("thread_id")
                marker = check.get("marker")
                if not isinstance(thread_id, str) or not isinstance(marker, str):
                    continue
                placeholder = case_copy.get("marker_placeholder", "{{RUN_MARKER}}")
                credential_source = substitute_marker(
                    {
                        "input": case_copy.get("input"),
                        "context": case_copy.get("context"),
                        "run_options": case_copy.get("run_options", {}),
                    },
                    marker,
                    placeholder,
                )
                cleanup_sensitive_by_thread[thread_id] = list(
                    dict.fromkeys(
                        [
                            *substitute_marker(
                                case_copy.get("sensitive_values", []), marker, placeholder
                            ),
                            *credential_values(credential_source),
                        ]
                    )
                )
    except Exception as original_error:
        cleanup_failed = False
        retained_thread_ids = {
            check.get("thread_id")
            for check in all_checks
            if check.get("thread_cleaned") is False
        }
        for thread_id in retained_thread_ids:
            if isinstance(thread_id, str) and thread_id:
                try:
                    delete_thread(
                        client,
                        thread_id,
                        cleanup_sensitive_by_thread.get(thread_id, scenario_sensitive),
                    )
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
    sensitive = scenario_sensitive_values(read_scenario()) if args.scenario_stdin else []
    assert_state(client, args.thread_id, [args.expected_value], sensitive)
    print(json.dumps({"result": "PASS", "check": "persisted_graph_state", "thread_id": args.thread_id}, sort_keys=True))


def persistence_command(args):
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    sensitive = scenario_sensitive_values(read_scenario()) if args.scenario_stdin else []
    _, snapshot_count = assert_persistence(
        client, args.thread_id, [args.expected_value], sensitive
    )
    print(
        json.dumps(
            {
                "result": "PASS",
                "check": "persisted_graph_state_and_checkpoint_history",
                "thread_id": args.thread_id,
                "checkpoint_count": snapshot_count,
            },
            sort_keys=True,
        )
    )


def health_command(args):
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    status, body, _ = client.request("GET", "/ok")
    api_key = getattr(client, "api_key", "")
    assert_sensitive_absent(
        body, [api_key] if api_key else [], "Agent Server health response"
    )
    health = json_body(body)
    if status != 200 or not isinstance(health, dict) or health.get("ok") is not True:
        raise AcceptanceError("Agent Server health check failed")
    print(json.dumps({"result": "PASS", "check": "agent_server_health"}, sort_keys=True))


def delete_thread_command(args):
    if not SAFE_RUNTIME_ID.fullmatch(args.thread_id):
        raise AcceptanceError("thread-id must be a safe runtime identifier")
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    sensitive = scenario_sensitive_values(read_scenario()) if args.scenario_stdin else []
    delete_thread(client, args.thread_id, sensitive)
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
    sensitive = scenario_sensitive + case_sensitive
    if list(
        credential_values(
            {"input": run_input, "context": context, "run_options": run_options}
        )
    ) and not sensitive:
        raise AcceptanceError(
            "credential-bearing active_run_case requires sensitive_values canaries"
        )
    return graph_id, case, sensitive, placeholder


def submit_product_active_command(args):
    if not 10 <= args.running_timeout <= 300 or args.request_timeout <= 0:
        raise AcceptanceError("running-timeout must be 10..300 and request-timeout must be positive")
    scenario = read_scenario()
    graph_id, case, sensitive, placeholder = _active_product_case(scenario)
    marker = f"mpr-qualification-{uuid.uuid4().hex}"
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    thread_id: str | None = None
    resolved_sensitive: list[str] = []
    try:
        payload = {
            "assistant_id": graph_id,
            "input": substitute_marker(case["input"], marker, placeholder),
        }
        if case.get("context") is not None:
            payload["context"] = substitute_marker(case["context"], marker, placeholder)
        payload.update(substitute_marker(case.get("run_options", {}), marker, placeholder))
        resolved_sensitive = list(
            dict.fromkeys(
                [
                    *substitute_marker(sensitive, marker, placeholder),
                    *credential_values(payload),
                    *([getattr(client, "api_key", "")] if getattr(client, "api_key", "") else []),
                ]
            )
        )
        thread_id = create_thread(client, resolved_sensitive)
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
        if thread_id is not None:
            try:
                delete_thread(client, thread_id, resolved_sensitive)
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
    expected = substitute_marker(case["expected_state_values"], args.marker, placeholder)
    client = LASClient(os.environ.get("LAS_BASE_URL", ""), args.request_timeout)
    credential_payload = {
        "input": substitute_marker(case["input"], args.marker, placeholder),
        "context": substitute_marker(case.get("context"), args.marker, placeholder),
        "run_options": substitute_marker(case.get("run_options", {}), args.marker, placeholder),
    }
    resolved_sensitive = list(
        dict.fromkeys(
            [
                *substitute_marker(sensitive, args.marker, placeholder),
                *credential_values(credential_payload),
                *([getattr(client, "api_key", "")] if getattr(client, "api_key", "") else []),
            ]
        )
    )
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
        delete_thread(client, args.thread_id, resolved_sensitive)
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


def kubectl_json(
    namespace: str, resource: str, name: str, expected_context: str | None = None
):
    import subprocess

    if expected_context is not None and (
        not expected_context or "\n" in expected_context or "\r" in expected_context
    ):
        raise AcceptanceError("expected Kubernetes context must be a safe non-empty value")
    context_args = ["--context", expected_context] if expected_context else []
    try:
        raw = subprocess.run(
            [
                os.environ.get("KUBECTL", "kubectl"),
                *context_args,
                "-n",
                namespace,
                "get",
                resource,
                name,
                "-o",
                "json",
            ],
            check=True, capture_output=True, text=True, timeout=20,
        ).stdout
        return json.loads(raw)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        raise AcceptanceError(f"could not read Kubernetes {resource} {name}") from None


def hpa_observation(
    namespace: str,
    hpa_name: str,
    deployment_name: str,
    expected_context: str | None = None,
):
    hpa = kubectl_json(namespace, "hpa", hpa_name, expected_context)
    spec = hpa.get("spec", {})
    target = spec.get("scaleTargetRef", {})
    if target.get("kind") != "Deployment" or target.get("name") != deployment_name:
        raise AcceptanceError("HPA scale target does not match the supplied queue Deployment")
    deployment = kubectl_json(namespace, "deployment", deployment_name, expected_context)
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
    """Wait for causal CPU evidence plus HPA and ready-worker scale-up."""
    deadline = time.monotonic() + timeout
    peak_hpa = starting_replicas
    peak_ready = starting_ready
    peak_cpu = None
    cpu_trigger_observed = False
    last = None
    while time.monotonic() < deadline:
        for future in futures:
            if future.done():
                future.result()
        last = observe()
        peak_hpa = max(peak_hpa, last["current"] or 0, last["desired"] or 0)
        peak_ready = max(peak_ready, last["deployment_replicas"] or 0)
        cpu_average = last.get("cpu_average_utilization")
        cpu_target = last.get("cpu_target_utilization")
        if isinstance(cpu_average, (int, float)) and not isinstance(cpu_average, bool):
            peak_cpu = cpu_average if peak_cpu is None else max(peak_cpu, cpu_average)
        if (
            isinstance(cpu_average, (int, float))
            and not isinstance(cpu_average, bool)
            and isinstance(cpu_target, (int, float))
            and not isinstance(cpu_target, bool)
            and cpu_target > 0
            and cpu_average >= cpu_target
        ):
            cpu_trigger_observed = True
        if (
            all(future.done() for future in futures)
            and peak_hpa > starting_replicas
            and peak_ready > starting_ready
            and cpu_trigger_observed
        ):
            return peak_hpa, peak_ready, last, peak_cpu
        time.sleep(min(5, max(0, deadline - time.monotonic())))
    for future in futures:
        if not future.done():
            raise AcceptanceError("bounded LAS runs did not complete before scale-up timeout")
        future.result()
    raise AcceptanceError(
        "queue HPA did not provide causal CPU evidence and add a ready worker "
        "before scale-up timeout"
    )


def deployment_replicas(
    namespace: str, name: str, expected_context: str | None = None
):
    deployment = kubectl_json(namespace, "deployment", name, expected_context)
    return {
        "desired": deployment.get("spec", {}).get("replicas", 1),
        "ready": deployment.get("status", {}).get("readyReplicas", 0),
    }


def require_stable_hpa_baseline(observation: dict[str, Any]) -> int:
    """Reject a pre-existing scale event before attributing growth to this run."""
    current = observation.get("current")
    desired = observation.get("desired")
    ready = observation.get("deployment_replicas")
    minimum = observation.get("min")
    maximum = observation.get("max")
    replicas = (current, desired, ready, minimum, maximum)
    if any(not isinstance(value, int) or isinstance(value, bool) for value in replicas):
        raise AcceptanceError("queue HPA baseline did not expose integer replica counts")
    if not minimum <= current <= maximum:
        raise AcceptanceError("queue HPA baseline was outside its configured bounds")
    if current != desired or current != ready:
        raise AcceptanceError(
            "queue HPA baseline was not stable before qualification work started"
        )
    return current


def observe_hpa_after_completion(args, started: float, samples: list[dict[str, Any]], seconds: float):
    """Append bounded post-run HPA samples so delayed decisions are visible."""
    deadline = time.monotonic() + seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(args.sample_interval, remaining))
        observation = hpa_observation(
            args.namespace, args.hpa, args.deployment, args.expected_context
        )
        api_now = deployment_replicas(
            args.namespace, args.api_deployment, args.expected_context
        )
        if api_now["desired"] != 1:
            raise AcceptanceError("LAS API Deployment replica count changed after product load")
        samples.append(
            {
                "elapsed_seconds": round(time.monotonic() - started, 3),
                "current": observation["current"],
                "desired": observation["desired"],
                "ready": observation["deployment_replicas"],
                "cpu_average_utilization": observation["cpu_average_utilization"],
                "cpu_target_utilization": observation["cpu_target_utilization"],
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
    before = hpa_observation(
        args.namespace, args.hpa, args.deployment, args.expected_context
    )
    api_before = deployment_replicas(
        args.namespace, args.api_deployment, args.expected_context
    )
    if api_before["desired"] != 1:
        raise AcceptanceError("LAS API Deployment is not configured for one replica")
    if before["max"] is None or before["max"] < before["min"]:
        raise AcceptanceError("HPA did not provide valid minimum and maximum bounds")
    require_stable_hpa_baseline(before)
    if not before["cpu_metrics_present"]:
        raise AcceptanceError("HPA has no current CPU metrics")
    if (
        not isinstance(before["cpu_target_utilization"], (int, float))
        or isinstance(before["cpu_target_utilization"], bool)
        or before["cpu_target_utilization"] <= 0
    ):
        raise AcceptanceError("HPA has no valid CPU utilization target")
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
            observation = hpa_observation(
                args.namespace, args.hpa, args.deployment, args.expected_context
            )
            api_now = deployment_replicas(
                args.namespace, args.api_deployment, args.expected_context
            )
            if api_now["desired"] != 1:
                raise AcceptanceError("LAS API Deployment replica count changed during product load")
            samples.append(
                {
                    "elapsed_seconds": round(time.monotonic() - started, 3),
                    "current": observation["current"],
                    "desired": observation["desired"],
                    "ready": observation["deployment_replicas"],
                    "cpu_average_utilization": observation["cpu_average_utilization"],
                    "cpu_target_utilization": observation["cpu_target_utilization"],
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
    cpu_trigger_observed = any(
        isinstance(sample.get("cpu_average_utilization"), (int, float))
        and not isinstance(sample.get("cpu_average_utilization"), bool)
        and isinstance(sample.get("cpu_target_utilization"), (int, float))
        and not isinstance(sample.get("cpu_target_utilization"), bool)
        and sample["cpu_target_utilization"] > 0
        and sample["cpu_average_utilization"] >= sample["cpu_target_utilization"]
        for sample in samples
    )
    cpu_scale_pass = scaled and cpu_trigger_observed
    if args.scale_expectation == "required" and not cpu_scale_pass:
        raise AcceptanceError(
            "representative product load did not produce both causal HPA CPU "
            "evidence and replica scale-up"
        )
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
    if cpu_scale_pass:
        scale_observation = "cpu_scale_pass"
    elif scaled:
        scale_observation = "replica_scale_observed_without_cpu_evidence"
    elif cpu_trigger_observed:
        scale_observation = "cpu_trigger_observed_without_replica_scale"
    else:
        scale_observation = "no_cpu_scale_observed"
    print(
        json.dumps(
            {
                "result": "OBSERVATION",
                "acceptance_scope": "requires_identity_bound_lifecycle_orchestrator",
                "check": "representative_product_load",
                "scale_observation": scale_observation,
                "cpu_scale_evidence": "OBSERVATION",
                "cpu_trigger_observed": cpu_trigger_observed,
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
    before = hpa_observation(
        args.namespace, args.hpa, args.deployment, args.expected_context
    )
    api_before = deployment_replicas(
        args.namespace, args.api_deployment, args.expected_context
    )
    if api_before["desired"] != 1:
        raise AcceptanceError("LAS API Deployment is not configured for one replica")
    if before["max"] is None or before["max"] < before["min"]:
        raise AcceptanceError("HPA did not provide valid minimum and maximum bounds")
    require_stable_hpa_baseline(before)
    if before["current"] is not None and before["current"] >= before["max"]:
        raise AcceptanceError("start below the HPA maximum to qualify scale-up")
    if not before["cpu_metrics_present"]:
        raise AcceptanceError("HPA has no current CPU metrics")
    if (
        not isinstance(before["cpu_target_utilization"], (int, float))
        or isinstance(before["cpu_target_utilization"], bool)
        or before["cpu_target_utilization"] <= 0
    ):
        raise AcceptanceError("HPA has no valid CPU utilization target")
    if args.workers > before["max"] * 4:
        raise AcceptanceError("workload exceeds the bounded worker-to-HPA ratio")

    def execute(index: int):
        name = f"scale-{index + 1}"
        marker = f"aip5411-{uuid.uuid4().hex}"
        case = {"name": name, "input": {"request": marker, "cpu_seconds": args.cpu_seconds}, "expected_state_values": [marker], "run_modes": ["sync"], "cleanup": True}
        return run_protocol_case(client, args.graph_id, case, args.timeout)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(execute, index) for index in range(args.workers)]
        peak_hpa, peak_ready, last, peak_cpu = wait_for_ready_scale_up(
            lambda: hpa_observation(
                args.namespace, args.hpa, args.deployment, args.expected_context
            ),
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
        last = hpa_observation(
            args.namespace, args.hpa, args.deployment, args.expected_context
        )
        api_now = deployment_replicas(
            args.namespace, args.api_deployment, args.expected_context
        )
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
    print(json.dumps({"result": "OBSERVATION", "acceptance_scope": "requires_identity_bound_lifecycle_orchestrator", "check": "queue_scale_up_cap_downscale_floor_api_fixed", "workers": args.workers, "peak_replicas": peak_hpa, "peak_ready_workers": peak_ready, "hpa_min": last["min"], "hpa_max": last["max"], "ready_workers": last["deployment_replicas"], "api_replicas": api_now["desired"], "cpu_metrics_present": last["cpu_metrics_present"], "peak_cpu_average_utilization": peak_cpu, "cpu_target_utilization": last["cpu_target_utilization"], "cpu_scale_evidence": "OBSERVATION"}, sort_keys=True))


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
    state.add_argument("--scenario-stdin", action="store_true")
    state.set_defaults(func=state_command)
    persistence = subparsers.add_parser(
        "persistence",
        help="verify a marker in current graph state and complete bounded checkpoint history",
    )
    persistence.add_argument("--thread-id", required=True)
    persistence.add_argument("--expected-value", required=True)
    persistence.add_argument("--request-timeout", type=float, default=45)
    persistence.add_argument("--scenario-stdin", action="store_true")
    persistence.set_defaults(func=persistence_command)
    health = subparsers.add_parser("health", help="verify the Agent Server health endpoint")
    health.add_argument("--request-timeout", type=float, default=10)
    health.set_defaults(func=health_command)
    cleanup = subparsers.add_parser("delete-thread", help="delete one exact qualification thread")
    cleanup.add_argument("--thread-id", required=True)
    cleanup.add_argument("--request-timeout", type=float, default=45)
    cleanup.add_argument("--scenario-stdin", action="store_true")
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
    product_load.add_argument("--expected-context", required=True)
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
    scale.add_argument("--expected-context", required=True)
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
