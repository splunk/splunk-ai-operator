#!/usr/bin/env python3
"""Qualify the Launchpad product through SLIM's external HTTP caller route.

The scenario is read from stdin.  Caller and model credentials are never
printed.  Output is a bounded, sanitized JSON disposition suitable for an
acceptance record; response bodies and product output stay in memory only.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import math
import os
import re
import stat
import sys
import uuid
from dataclasses import dataclass
from typing import Any, Iterable
from urllib import error, parse, request


DEFAULT_TIMEOUT = 180
DEFAULT_MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_TOKEN_BYTES = 64 * 1024
MAX_EVENTS = 4096
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
SAFE_TENANT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$")
OPTIONAL_CALL_FIELDS = (
    "llm",
    "mcps",
    "knowledge_bases",
    "hitl_response",
    "skills",
    "structured_output",
)
JSON_TYPES = {
    "array": list,
    "boolean": bool,
    "integer": int,
    "null": type(None),
    "number": (int, float),
    "object": dict,
    "string": str,
}


class QualificationError(AssertionError):
    """A qualification failure whose message is safe to emit."""


class ScenarioError(ValueError):
    """An invalid input scenario whose message never includes input values."""


@dataclass(frozen=True)
class HTTPResult:
    status: int
    body: bytes
    content_type: str


class NoRedirect(request.HTTPRedirectHandler):
    """Do not forward a caller bearer to a redirected destination."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


def strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from strings(key)
            yield from strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from strings(item)


def value_strings(value: Any) -> Iterable[str]:
    """Yield response values without allowing an object key to satisfy a result."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from value_strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from value_strings(item)


def assert_absent(value: Any, secrets: list[str], source: str) -> None:
    serialized = "\n".join(strings(value))
    if any(secret and secret in serialized for secret in secrets):
        raise QualificationError(f"sensitive marker appeared in {source}")


def assert_body_absent(body: bytes, secrets: list[str], source: str) -> None:
    decoded = body.decode("utf-8", errors="replace")
    if any(secret and secret in decoded for secret in secrets):
        raise QualificationError(f"sensitive marker appeared in {source}")
    parsed_values: list[Any] = []
    try:
        parsed_values.append(strict_json_loads(decoded))
    except (json.JSONDecodeError, ValueError):
        for line in decoded.splitlines():
            if not line.strip():
                continue
            try:
                parsed_values.append(strict_json_loads(line))
            except (json.JSONDecodeError, ValueError):
                continue
    for value in parsed_values:
        assert_absent(value, secrets, source)


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


def validate_base_url(value: str | None) -> str:
    if not value:
        raise ScenarioError("SLIM base URL is required")
    parsed = parse.urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ScenarioError("SLIM base URL must use http or https")
    if parsed.username is not None or parsed.password is not None:
        raise ScenarioError("SLIM base URL must not contain user information")
    if parsed.query or parsed.fragment or parsed.path not in ("", "/"):
        raise ScenarioError("SLIM base URL must not contain a path, query, or fragment")
    if parsed.scheme == "http":
        try:
            loopback = ipaddress.ip_address(parsed.hostname).is_loopback
        except ValueError:
            loopback = False
        if not loopback:
            raise ScenarioError("plaintext SLIM HTTP is permitted only on a loopback address")
    return parse.urlunsplit((parsed.scheme, parsed.netloc, "", "", "")).rstrip("/")


def _read_fd(fd: int, maximum: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = os.read(fd, min(8192, maximum + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > maximum:
            raise ScenarioError("caller bearer exceeds the allowed size")
    return b"".join(chunks)


def _read_token_file(path: str) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise ScenarioError("caller bearer file could not be opened") from exc
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise ScenarioError("caller bearer file must be a regular file")
        if metadata.st_mode & 0o077:
            raise ScenarioError("caller bearer file must not be accessible by group or other users")
        return _read_fd(fd, MAX_TOKEN_BYTES)
    finally:
        os.close(fd)


def load_bearer(environ: dict[str, str] | None = None) -> str:
    env = os.environ if environ is None else environ
    sources = [
        name
        for name in ("SLIM_BEARER_TOKEN_FD", "SLIM_BEARER_TOKEN_FILE", "SLIM_BEARER_TOKEN")
        if env.get(name)
    ]
    if len(sources) != 1:
        raise ScenarioError("configure exactly one protected caller bearer source")
    source = sources[0]
    if source == "SLIM_BEARER_TOKEN_FD":
        try:
            fd = int(env[source])
        except (TypeError, ValueError) as exc:
            raise ScenarioError("caller bearer file descriptor must be an integer") from exc
        if fd < 0:
            raise ScenarioError("caller bearer file descriptor must be non-negative")
        try:
            raw = _read_fd(fd, MAX_TOKEN_BYTES)
        except OSError as exc:
            raise ScenarioError("caller bearer file descriptor could not be read") from exc
    elif source == "SLIM_BEARER_TOKEN_FILE":
        raw = _read_token_file(env[source])
    else:
        raw = env[source].encode("utf-8")
    try:
        token = raw.decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise ScenarioError("caller bearer must be UTF-8 text") from exc
    if not token or len(token.encode("utf-8")) > MAX_TOKEN_BYTES or any(char.isspace() for char in token):
        raise ScenarioError("caller bearer has an invalid format")
    return token


def _validate_shape(shape: Any, location: str) -> None:
    if not isinstance(shape, dict) or set(shape) - {"required", "types"}:
        raise ScenarioError(f"{location} expected_shape may contain only required and types")
    required = shape.get("required", [])
    types = shape.get("types", {})
    if not isinstance(required, list) or not all(isinstance(item, str) and item for item in required):
        raise ScenarioError(f"{location} expected_shape.required must contain non-empty paths")
    if not isinstance(types, dict) or not all(
        isinstance(path, str) and path and kind in JSON_TYPES for path, kind in types.items()
    ):
        raise ScenarioError(f"{location} expected_shape.types contains an unsupported entry")


def validate_scenario(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ScenarioError("stdin JSON must be an object")
    if set(value) - {"scenario_version", "sensitive_values", "cases"}:
        raise ScenarioError("stdin JSON contains unsupported top-level fields")
    if value.get("scenario_version", 1) != 1:
        raise ScenarioError("scenario_version must be 1")
    sensitive = value.get("sensitive_values", [])
    if not isinstance(sensitive, list) or not all(isinstance(item, str) and item for item in sensitive):
        raise ScenarioError("sensitive_values must contain non-empty strings")
    if len(sensitive) != len(set(sensitive)):
        raise ScenarioError("sensitive_values must not contain duplicates")
    cases = value.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ScenarioError("stdin JSON must provide non-empty cases")
    names: set[str] = set()
    call_fields = {
        "task_prompt",
        "system_prompt",
        "agent_timeout",
        "expected_text",
        "expected_shape",
        *OPTIONAL_CALL_FIELDS,
    }
    for case_index, case in enumerate(cases, start=1):
        location = f"case {case_index}"
        if not isinstance(case, dict) or set(case) - {"name", "calls"}:
            raise ScenarioError(f"{location} may contain only name and calls")
        name = case.get("name")
        if not isinstance(name, str) or not SAFE_NAME.fullmatch(name) or name in names:
            raise ScenarioError(f"{location} needs a unique safe name")
        names.add(name)
        calls = case.get("calls")
        if not isinstance(calls, list) or not calls:
            raise ScenarioError(f"{location} needs one or more calls")
        for call_index, call in enumerate(calls, start=1):
            call_location = f"{location} call {call_index}"
            if not isinstance(call, dict) or set(call) - call_fields:
                raise ScenarioError(f"{call_location} contains unsupported fields")
            if not isinstance(call.get("task_prompt"), str) or not call["task_prompt"].strip():
                raise ScenarioError(f"{call_location} needs a non-empty task_prompt")
            if "system_prompt" in call and not isinstance(call["system_prompt"], str):
                raise ScenarioError(f"{call_location} system_prompt must be a string")
            timeout = call.get("agent_timeout", DEFAULT_TIMEOUT)
            if not isinstance(timeout, int) or isinstance(timeout, bool) or not 1 <= timeout <= 600:
                raise ScenarioError(f"{call_location} agent_timeout must be between 1 and 600")
            expected_text = call.get("expected_text")
            expected_shape = call.get("expected_shape")
            if expected_text is None and expected_shape is None:
                raise ScenarioError(f"{call_location} needs expected_text or expected_shape")
            if expected_text is not None and (
                not isinstance(expected_text, str) or not expected_text.strip()
            ):
                raise ScenarioError(f"{call_location} expected_text must be non-empty")
            if expected_shape is not None:
                _validate_shape(expected_shape, call_location)
            for optional in OPTIONAL_CALL_FIELDS:
                if optional in call:
                    try:
                        json.dumps(call[optional], allow_nan=False)
                    except (TypeError, ValueError) as exc:
                        raise ScenarioError(f"{call_location} {optional} must be JSON-compatible") from exc
    return value


def read_scenario(stream=None) -> dict[str, Any]:
    source = sys.stdin if stream is None else stream
    try:
        value = strict_json_loads(source.read())
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as exc:
        raise ScenarioError("stdin did not contain valid JSON") from exc
    return validate_scenario(value)


class SlimHTTPClient:
    def __init__(
        self,
        base_url: str,
        timeout: int = DEFAULT_TIMEOUT,
        max_response_bytes: int = DEFAULT_MAX_RESPONSE_BYTES,
        opener=None,
    ):
        self.base_url = validate_base_url(base_url)
        if not isinstance(timeout, int) or not 1 <= timeout <= 600:
            raise ScenarioError("request timeout must be between 1 and 600")
        if not 4096 <= max_response_bytes <= 8 * 1024 * 1024:
            raise ScenarioError("max response bytes must be between 4096 and 8388608")
        self.timeout = timeout
        self.max_response_bytes = max_response_bytes
        self.opener = opener or request.build_opener(request.ProxyHandler({}), NoRedirect())

    def _read(self, response) -> bytes:  # noqa: ANN001
        body = response.read(self.max_response_bytes + 1)
        if len(body) > self.max_response_bytes:
            raise QualificationError("SLIM response exceeded the configured size limit")
        return body

    def request(
        self,
        method: str,
        path: str,
        *,
        token: str | None,
        request_id: str,
        payload: Any | None = None,
        raw_body: bytes | None = None,
    ) -> HTTPResult:
        if not path.startswith("/") or not SAFE_NAME.fullmatch(request_id):
            raise ScenarioError("HTTP request path or request ID is unsafe")
        if payload is not None and raw_body is not None:
            raise ScenarioError("HTTP request cannot set both payload and raw_body")
        try:
            body = raw_body if raw_body is not None else (
                None if payload is None else json.dumps(payload, allow_nan=False).encode("utf-8")
            )
        except (TypeError, ValueError) as exc:
            raise ScenarioError("HTTP payload is not JSON-compatible") from exc
        headers = {"Accept": "application/json", "request_id": request_id}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = request.Request(self.base_url + path, data=body, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=self.timeout) as response:
                response_body = self._read(response)
                return HTTPResult(
                    status=response.status,
                    body=response_body,
                    content_type=response.headers.get("Content-Type", ""),
                )
        except error.HTTPError as exc:
            response_body = self._read(exc)
            return HTTPResult(
                status=exc.code,
                body=response_body,
                content_type=exc.headers.get("Content-Type", "") if exc.headers else "",
            )
        except QualificationError:
            raise
        except (error.URLError, TimeoutError, OSError) as exc:
            raise QualificationError("SLIM HTTP transport failed") from exc


def parse_json_object(body: bytes, source: str) -> dict[str, Any]:
    try:
        value = strict_json_loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise QualificationError(f"{source} did not return valid JSON") from exc
    if not isinstance(value, dict):
        raise QualificationError(f"{source} did not return a JSON object")
    return value


def parse_ndjson(body: bytes) -> list[dict[str, Any]]:
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise QualificationError("SLIM invoke response was not UTF-8") from exc
    events: list[dict[str, Any]] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        if len(events) >= MAX_EVENTS:
            raise QualificationError("SLIM invoke response contained too many events")
        try:
            event_value = strict_json_loads(line)
        except (json.JSONDecodeError, ValueError) as exc:
            raise QualificationError("SLIM invoke response contained invalid NDJSON") from exc
        if not isinstance(event_value, dict):
            raise QualificationError("SLIM invoke response contained a non-object event")
        events.append(event_value)
    if not events:
        raise QualificationError("SLIM invoke response contained no events")
    return events


def terminal_response(events: list[dict[str, Any]]) -> Any:
    completed = [event for event in events if event.get("status") == "Completed"]
    if len(completed) != 1 or completed[0] is not events[-1]:
        raise QualificationError("SLIM invoke response lacked one final Completed event")
    terminal = completed[0]
    if terminal.get("success") is not True:
        raise QualificationError("SLIM invoke terminal event reported failure")
    if "response" not in terminal:
        raise QualificationError("SLIM invoke terminal event omitted the product response")
    return terminal["response"]


def _path_value(value: Any, path: str) -> Any:
    current = value
    for component in path.split("."):
        if not isinstance(current, dict) or component not in current:
            raise QualificationError("product response missed a required structured field")
        current = current[component]
    return current


def _structured_response(value: Any) -> Any:
    if isinstance(value, (dict, list)):
        return value
    if isinstance(value, str):
        try:
            parsed = strict_json_loads(value)
        except (json.JSONDecodeError, ValueError) as exc:
            raise QualificationError("product response was not structured JSON") from exc
        if isinstance(parsed, (dict, list)):
            return parsed
    raise QualificationError("product response was not structured JSON")


def assert_expected_shape(response_value: Any, shape: dict[str, Any]) -> None:
    structured = _structured_response(response_value)
    for path in shape.get("required", []):
        _path_value(structured, path)
    for path, expected in shape.get("types", {}).items():
        actual = _path_value(structured, path)
        if expected == "integer":
            valid = isinstance(actual, int) and not isinstance(actual, bool)
        elif expected == "number":
            valid = (
                isinstance(actual, (int, float))
                and not isinstance(actual, bool)
                and math.isfinite(actual)
            )
        else:
            valid = isinstance(actual, JSON_TYPES[expected])
        if not valid:
            raise QualificationError("product response had an unexpected structured field type")


def assert_expected(response_value: Any, call: dict[str, Any]) -> None:
    expected_text = call.get("expected_text")
    if expected_text is not None and expected_text not in "\n".join(value_strings(response_value)):
        raise QualificationError("Completed.response missed the expected product text")
    if call.get("expected_shape") is not None:
        assert_expected_shape(response_value, call["expected_shape"])


def route_root(tenant: str) -> str:
    if not SAFE_TENANT.fullmatch(tenant):
        raise ScenarioError("SLIM tenant has an unsafe format")
    return f"/{tenant}/slim-api/v1alpha1/agent/las"


def create_assistant(
    client: SlimHTTPClient,
    root: str,
    token: str,
    request_id: str,
    name: str,
    secrets: list[str],
) -> str:
    result = client.request(
        "POST",
        root,
        token=token,
        request_id=request_id,
        payload={"agent_name": name, "app_version": "mpr-44-acceptance"},
    )
    assert_body_absent(result.body, secrets, "assistant create response")
    if result.status != 201:
        raise QualificationError(f"assistant create returned HTTP {result.status}")
    body = parse_json_object(result.body, "assistant create")
    assistant_id = body.get("runtime_id")
    try:
        uuid.UUID(str(assistant_id))
    except (ValueError, TypeError, AttributeError) as exc:
        raise QualificationError("assistant create omitted a UUID runtime_id") from exc
    return str(assistant_id)


def invoke_call(
    client: SlimHTTPClient,
    root: str,
    token: str,
    request_id: str,
    assistant_id: str,
    session_id: str,
    call: dict[str, Any],
    secrets: list[str],
) -> Any:
    inner = {
        "agent_id": assistant_id,
        "session_id": session_id,
        "task_prompt": call["task_prompt"],
        "system_prompt": call.get("system_prompt", ""),
        "agent_timeout": call.get("agent_timeout", DEFAULT_TIMEOUT),
    }
    for field in OPTIONAL_CALL_FIELDS:
        if field in call:
            inner[field] = call[field]
    result = client.request(
        "POST",
        root + "/invoke",
        token=token,
        request_id=request_id,
        payload={"payload": json.dumps(inner, allow_nan=False)},
    )
    assert_body_absent(result.body, secrets, "invoke response")
    if not 200 <= result.status < 300:
        raise QualificationError(f"SLIM invoke returned HTTP {result.status}")
    media_type = result.content_type.split(";", 1)[0].strip().lower()
    if media_type != "application/x-ndjson":
        raise QualificationError("SLIM invoke returned an unexpected media type")
    events = parse_ndjson(result.body)
    assert_absent(events, secrets, "invoke events")
    response_value = terminal_response(events)
    assert_expected(response_value, call)
    assert_absent(response_value, secrets, "Completed.response")
    return response_value


def cleanup_assistant(
    client: SlimHTTPClient,
    root: str,
    token: str,
    assistant_id: str,
    secrets: list[str],
) -> None:
    first = client.request(
        "DELETE",
        root + "/" + parse.quote(assistant_id, safe=""),
        token=token,
        request_id="mpr44-cleanup",
    )
    assert_body_absent(first.body, secrets, "assistant cleanup response")
    if not 200 <= first.status < 300:
        raise QualificationError(f"assistant cleanup returned HTTP {first.status}")
    second = client.request(
        "DELETE",
        root + "/" + parse.quote(assistant_id, safe=""),
        token=token,
        request_id="mpr44-cleanup-confirm",
    )
    assert_body_absent(second.body, secrets, "assistant cleanup confirmation")
    if second.status == 404 or second.status == 204:
        return
    if not 200 <= second.status < 300:
        raise QualificationError(f"assistant cleanup confirmation returned HTTP {second.status}")
    body = parse_json_object(second.body, "assistant cleanup confirmation")
    status_value = str(body.get("status", "")).upper()
    if "NOT_FOUND" not in status_value and "NOTFOUND" not in status_value:
        raise QualificationError("assistant cleanup confirmation did not report not found")


def _cleanup_unexpected_create(
    client: SlimHTTPClient,
    root: str,
    token: str,
    result: HTTPResult,
    secrets: list[str],
) -> None:
    if not 200 <= result.status < 300:
        return
    body = parse_json_object(result.body, "unexpected authentication response")
    assistant_id = body.get("runtime_id")
    if assistant_id:
        cleanup_assistant(client, root, token, str(assistant_id), secrets)


def run_negative_checks(
    client: SlimHTTPClient,
    root: str,
    token: str,
    secrets: list[str],
) -> list[str]:
    checks: list[str] = []
    for label, supplied_token in (
        ("missing-bearer", None),
        ("malformed-bearer", "mpr44.invalid.synthetic"),
    ):
        result = client.request(
            "POST",
            root,
            token=supplied_token,
            request_id="mpr44-" + label,
            payload={"agent_name": "mpr44negative" + uuid.uuid4().hex[:8], "app_version": "mpr-44-negative"},
        )
        assert_body_absent(result.body, secrets, f"{label} response")
        if result.status not in (401, 403):
            _cleanup_unexpected_create(client, root, token, result, secrets)
            raise QualificationError(f"{label} was not denied")
        denial_body = parse_json_object(result.body, f"{label} response")
        assert_absent(denial_body, secrets, f"{label} response")
        checks.append(label + "-denied")
    malformed = client.request(
        "POST",
        root,
        token=token,
        request_id="mpr44-malformed-json",
        raw_body=b"{",
    )
    assert_body_absent(malformed.body, secrets, "malformed JSON response")
    if malformed.status not in (400, 422):
        _cleanup_unexpected_create(client, root, token, malformed, secrets)
        raise QualificationError("malformed JSON was not safely rejected")
    malformed_body = parse_json_object(malformed.body, "malformed JSON response")
    assert_absent(malformed_body, secrets, "malformed JSON response")
    checks.append("malformed-json-rejected")
    return checks


def execute(
    client: SlimHTTPClient,
    scenario: dict[str, Any],
    token: str,
    tenant: str,
) -> dict[str, Any]:
    root = route_root(tenant)
    sensitive = list(scenario.get("sensitive_values", []))
    scan_values = sensitive + [token]
    checks = run_negative_checks(client, root, token, scan_values)
    assistant_id: str | None = None
    sessions: list[dict[str, str]] = []
    primary_error: Exception | None = None
    cleanup_error: Exception | None = None
    try:
        assistant_name = "mpr44" + uuid.uuid4().hex[:12]
        assistant_id = create_assistant(
            client,
            root,
            token,
            "mpr44-create",
            assistant_name,
            scan_values,
        )
        checks.append("authenticated-assistant-create")
        for case_index, case in enumerate(scenario["cases"], start=1):
            session_id = str(uuid.uuid4())
            sessions.append({"case": case["name"], "session_id": session_id})
            for call_index, call in enumerate(case["calls"], start=1):
                invoke_call(
                    client,
                    root,
                    token,
                    f"mpr44-{case_index}-{call_index}",
                    assistant_id,
                    session_id,
                    call,
                    scan_values,
                )
                checks.append(f"{case['name']}:call-{call_index}")
            if len(case["calls"]) > 1:
                checks.append(f"{case['name']}:same-session-follow-up")
    except Exception as exc:  # preserve cleanup while main sanitizes unknown errors
        primary_error = exc
    finally:
        if assistant_id is not None:
            try:
                cleanup_assistant(client, root, token, assistant_id, scan_values)
                checks.append("assistant-delete-confirmed")
            except Exception as exc:  # report cleanup independently
                cleanup_error = exc
    if primary_error and cleanup_error:
        if isinstance(primary_error, (QualificationError, ScenarioError)):
            raise QualificationError(f"{primary_error}; assistant cleanup also failed") from primary_error
        raise QualificationError("qualification failed unexpectedly; assistant cleanup also failed") from primary_error
    if cleanup_error:
        if isinstance(cleanup_error, (QualificationError, ScenarioError)):
            raise cleanup_error
        raise QualificationError("assistant cleanup failed unexpectedly") from cleanup_error
    if primary_error:
        raise primary_error
    result = {
        "result": "PASS",
        "route": root,
        "checks": checks,
        "assistant_id": assistant_id,
        "sessions": sessions,
    }
    assert_absent(result, scan_values, "sanitized evidence")
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=os.environ.get("SLIM_BASE_URL"))
    parser.add_argument("--tenant", default=os.environ.get("SLIM_TENANT", "product-qualification"))
    parser.add_argument("--request-timeout", type=int, default=DEFAULT_TIMEOUT)
    parser.add_argument("--max-response-bytes", type=int, default=DEFAULT_MAX_RESPONSE_BYTES)
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        args = build_parser().parse_args(argv)
        scenario = read_scenario()
        token = load_bearer()
        client = SlimHTTPClient(args.base_url, args.request_timeout, args.max_response_bytes)
        result = execute(client, scenario, token, args.tenant)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (QualificationError, ScenarioError) as exc:
        print(json.dumps({"result": "FAIL", "reason": str(exc)}, sort_keys=True), file=sys.stderr)
        return 1
    except Exception:
        print(
            json.dumps({"result": "FAIL", "reason": "unexpected qualification failure"}, sort_keys=True),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
