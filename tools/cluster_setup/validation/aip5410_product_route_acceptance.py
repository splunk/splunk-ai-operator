"""Config-driven SLIM caller-route checks for approved product graph cases.

Run inside the SLIM Pod and pipe a trusted case JSON document to stdin. Input
may contain credentials and is never logged, printed, or written by this tool.
The caller must supply approved product graph expectations; this harness does
not invent product fixtures or expected answers.
"""

import asyncio
import contextlib
import io
import json
import logging
import math
import re
import sys
import time
import uuid
from types import SimpleNamespace
from typing import Any, Optional


ALLOWED_OWNERS = {"product", "caller", "platform", "dependency"}
ALLOWED_ERROR_CATEGORIES = {
    "authentication",
    "authorization",
    "cancelled",
    "dependency",
    "not_found",
    "platform",
    "timeout",
    "validation",
}
PRIMITIVE_TYPES = {
    "array": list,
    "boolean": bool,
    "integer": int,
    "null": type(None),
    "number": (int, float),
    "object": dict,
    "string": str,
}
FORWARDED_FIELDS = (
    "llm",
    "mcps",
    "knowledge_bases",
    "hitl_response",
    "structured_output",
    "structured_response",
)
EXTERNAL_GATES = [
    {
        "issue": "MPR-131",
        "status": "KNOWN_FAIL",
        "scope": "run-list credential exposure; credential canary assertions remain enforced",
    }
]
SAFE_CASE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
MAX_CALLER_RESPONSE_BYTES = 1024 * 1024
MAX_CALLER_EVENTS = 1000
OWNED_PAYLOAD_FIELDS = {"agent_id", "session_id"}
ROUTE = "in-pod-slim-router"


class QualificationError(AssertionError):
    """Failure whose message is intentionally safe to include in evidence."""


class ScenarioError(ValueError):
    """Invalid scenario whose message never includes scenario values."""


def _reject_json_constant(_value: str) -> None:
    raise ValueError("non-finite JSON number")


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def strict_json_loads(value: Any) -> Any:
    """Parse standards-compliant JSON without duplicate keys or NaN/Infinity."""
    return json.loads(
        value,
        parse_constant=_reject_json_constant,
        object_pairs_hook=_unique_json_object,
    )


def exception_http_status(exc: Exception) -> Optional[int]:
    status = getattr(exc, "status_code", None)
    if status is None:
        status = getattr(getattr(exc, "response", None), "status_code", None)
    return status if isinstance(status, int) and 100 <= status <= 599 else None


def jsonable(value: Any) -> Any:
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json")
    if hasattr(value, "dict"):
        return value.dict()
    if isinstance(value, dict):
        return {key: jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [jsonable(item) for item in value]
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    return vars(value) if hasattr(value, "__dict__") else str(value)


def strings(value: Any):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from strings(key)
            yield from strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from strings(item)


def state_is_effectively_empty(value: Any) -> bool:
    """Treat only structurally empty/default graph containers as no side effect."""
    if value is None:
        return True
    if isinstance(value, dict):
        return all(state_is_effectively_empty(item) for item in value.values())
    if isinstance(value, list):
        return all(state_is_effectively_empty(item) for item in value)
    return False


def is_not_found(exc: Exception) -> bool:
    return exception_http_status(exc) == 404


def assert_absent(value: Any, secrets: list[str], source: str):
    serialized = "\n".join(strings(value))
    if any(secret and secret in serialized for secret in secrets):
        raise QualificationError(f"sensitive marker appeared in {source}")


def _validate_shape(shape: Any, location: str) -> None:
    if not isinstance(shape, dict) or set(shape) - {"required", "types"}:
        raise ScenarioError(f"{location} shape may contain only required and types")
    required = shape.get("required", [])
    types = shape.get("types", {})
    if not isinstance(required, list) or not all(isinstance(path, str) and path for path in required):
        raise ScenarioError(f"{location} shape.required must be a list of non-empty paths")
    if not isinstance(types, dict) or not all(
        isinstance(path, str) and path and kind in PRIMITIVE_TYPES for path, kind in types.items()
    ):
        raise ScenarioError(f"{location} shape.types must map non-empty paths to supported types")


def _normalize_http_statuses(value: Any, location: str) -> Optional[list[int]]:
    if value is None:
        return None
    statuses = [value] if isinstance(value, int) and not isinstance(value, bool) else value
    if not isinstance(statuses, list) or not statuses or not all(
        isinstance(status, int) and not isinstance(status, bool) and 100 <= status <= 599
        for status in statuses
    ):
        raise ScenarioError(f"{location} http_status must contain valid HTTP status codes")
    return statuses


def normalize_expectation(call: dict[str, Any], location: str) -> dict[str, Any]:
    raw = call.get("expect")
    if raw is None:
        raw = {"outcome": "success", "text": call.get("expected_text")}
    if not isinstance(raw, dict):
        raise ScenarioError(f"{location} expect must be an object")
    allowed = {"outcome", "text", "shape", "http_status", "error_category", "owner", "state_text"}
    if set(raw) - allowed:
        raise ScenarioError(f"{location} expect contains unsupported fields")
    outcome = raw.get("outcome", "success")
    if outcome not in ("success", "failure"):
        raise ScenarioError(f"{location} expect.outcome must be success or failure")
    result = dict(raw)
    result["outcome"] = outcome
    if outcome == "success":
        text = result.get("text")
        shape = result.get("shape")
        if text is not None and (not isinstance(text, str) or not text.strip()):
            raise ScenarioError(f"{location} success text must be non-empty")
        if shape is not None:
            _validate_shape(shape, location)
        if text is None and shape is None:
            raise ScenarioError(f"{location} success expectation needs text or shape")
        if "http_status" in result:
            result["http_status"] = _normalize_http_statuses(result["http_status"], location)
        if "state_text" in result and (
            not isinstance(result["state_text"], str) or not result["state_text"].strip()
        ):
            raise ScenarioError(f"{location} state_text must be non-empty")
        if "error_category" in result or "owner" in result:
            raise ScenarioError(f"{location} success expectation cannot set failure metadata")
    else:
        if "text" in result or "shape" in result or "state_text" in result:
            raise ScenarioError(f"{location} failure expectation cannot require successful output")
        result["http_status"] = _normalize_http_statuses(result.get("http_status"), location)
        category = result.get("error_category")
        if category is not None and category not in ALLOWED_ERROR_CATEGORIES:
            raise ScenarioError(f"{location} error_category is unsupported")
        owner = result.get("owner")
        if owner not in ALLOWED_OWNERS:
            raise ScenarioError(f"{location} failure expectation needs a supported owner")
        if result["http_status"] is None and category is None:
            raise ScenarioError(f"{location} failure expectation needs http_status or error_category")
    return result


def validate_scenario(config: Any) -> tuple[list[dict[str, Any]], list[str]]:
    if not isinstance(config, dict):
        raise ScenarioError("stdin JSON must be an object")
    if set(config) - {"scenario_version", "cases", "sensitive_values", "external_gates"}:
        raise ScenarioError("stdin JSON contains unsupported top-level fields")
    if config.get("scenario_version", 1) != 1:
        raise ScenarioError("scenario_version must be 1")
    external_gates = config.get("external_gates", {"MPR-131": "KNOWN_FAIL"})
    if external_gates != {"MPR-131": "KNOWN_FAIL"}:
        raise ScenarioError("external_gates must retain MPR-131 as KNOWN_FAIL")
    secrets = config.get("sensitive_values", [])
    if not isinstance(secrets, list) or not all(isinstance(item, str) and item for item in secrets):
        raise ScenarioError("sensitive_values must be a list of non-empty strings")
    if len(secrets) != len(set(secrets)):
        raise ScenarioError("sensitive_values must not contain duplicates")
    cases = config.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ScenarioError("stdin JSON must provide non-empty cases")
    names = set()
    allowed_case = {"name", "calls", "check_state", "expect_empty_state"}
    allowed_call = {
        "task_prompt",
        "system_prompt",
        "agent_timeout",
        "llm",
        "mcps",
        "knowledge_bases",
        "hitl_response",
        "structured_output",
        "structured_response",
        "payload",
        "expected_text",
        "expect",
    }
    for case_index, case in enumerate(cases):
        location = f"case {case_index + 1}"
        if not isinstance(case, dict) or set(case) - allowed_case:
            raise ScenarioError(
                f"{location} must contain only name, calls, check_state, and expect_empty_state"
            )
        name = case.get("name")
        if not isinstance(name, str) or not SAFE_CASE_NAME.fullmatch(name) or name in names:
            raise ScenarioError(f"{location} needs a unique safe name")
        names.add(name)
        if "check_state" in case and not isinstance(case["check_state"], bool):
            raise ScenarioError(f"{location} check_state must be boolean")
        if "expect_empty_state" in case and not isinstance(case["expect_empty_state"], bool):
            raise ScenarioError(f"{location} expect_empty_state must be boolean")
        if case.get("expect_empty_state") and case.get("check_state") is False:
            raise ScenarioError(f"{location} cannot disable state checks when empty state is expected")
        calls = case.get("calls")
        if not isinstance(calls, list) or not calls:
            raise ScenarioError(f"{location} needs one or more calls")
        for call_index, call in enumerate(calls):
            call_location = f"{location} call {call_index + 1}"
            if not isinstance(call, dict) or set(call) - allowed_call:
                raise ScenarioError(f"{call_location} contains unsupported fields")
            if "payload" in call and not isinstance(call["payload"], dict):
                raise ScenarioError(f"{call_location} payload must be an object")
            if "payload" in call and OWNED_PAYLOAD_FIELDS.intersection(call["payload"]):
                raise ScenarioError(
                    f"{call_location} payload cannot set harness-owned agent_id or session_id"
                )
            timeout = call.get("agent_timeout", 120)
            if not isinstance(timeout, int) or isinstance(timeout, bool) or not 1 <= timeout <= 600:
                raise ScenarioError(f"{call_location} agent_timeout must be 1..600")
            expectation = normalize_expectation(call, call_location)
            if expectation["outcome"] == "success":
                prompt = call.get("task_prompt")
                if "payload" not in call and (not isinstance(prompt, str) or not prompt):
                    raise ScenarioError(f"{call_location} successful call needs task_prompt")
    return cases, secrets


async def all_checkpoints(client: Any, thread_id: str) -> list[Any]:
    snapshots = []
    before = None
    seen = set()
    while True:
        page = await client.threads.get_history(thread_id, limit=100, before=before)
        if not page:
            return snapshots
        normalized = [jsonable(item) for item in page]
        snapshots.extend(normalized)
        if len(page) < 100:
            return snapshots
        checkpoint = normalized[-1].get("checkpoint", {})
        cursor = checkpoint.get("checkpoint_id") if isinstance(checkpoint, dict) else None
        if not cursor or cursor in seen:
            raise QualificationError("checkpoint history pagination did not advance")
        seen.add(cursor)
        before = checkpoint


async def collect(response: Any):
    chunks: list[bytes] = []
    response_bytes = 0
    async for chunk in response.body_iterator:
        encoded = chunk if isinstance(chunk, bytes) else str(chunk).encode("utf-8")
        response_bytes += len(encoded)
        if response_bytes > MAX_CALLER_RESPONSE_BYTES:
            raise QualificationError("caller response exceeded the bounded evidence limit")
        chunks.append(encoded)
    try:
        response_text = b"".join(chunks).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise QualificationError("caller response contained invalid UTF-8") from exc
    events = []
    for line in response_text.splitlines():
        if not line.strip():
            continue
        if len(events) >= MAX_CALLER_EVENTS:
            raise QualificationError("caller response exceeded the bounded event limit")
        try:
            events.append(strict_json_loads(line))
        except (json.JSONDecodeError, ValueError) as exc:
            raise QualificationError("caller response contained invalid NDJSON") from exc
    return response.status_code, events


class Capture(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records = []

    def emit(self, record):
        self.records.append(record.getMessage())


async def invoke(tenant: str, payload: Any, request_id: str):
    from slim_api.models.aws import InvokeAgentPayload
    from slim_api.routers.las_agent import invoke_agent

    handler = Capture()
    root = logging.getLogger()
    root.addHandler(handler)
    stdout, stderr = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            # Only request-model construction errors are local validation
            # outcomes. A ValueError raised by the router itself is an
            # unexpected implementation failure and must not be converted into
            # a passing malformed-input result.
            try:
                request_payload = InvokeAgentPayload(
                    payload=json.dumps(payload)
                )
            except (ValueError, json.JSONDecodeError):
                status, events = 422, [
                    {"status": "Error", "success": False, "error_category": "validation"}
                ]
            else:
                response = await invoke_agent(
                    tenant,
                    request_payload,
                    SimpleNamespace(headers={"request_id": request_id}),
                )
                status, events = await collect(response)
    except Exception as exc:
        status_code = exception_http_status(exc)
        if status_code is None:
            raise
        status, events = status_code, [{"status": "Error", "success": False}]
    finally:
        root.removeHandler(handler)
    return status, events, {"stdout": stdout.getvalue(), "stderr": stderr.getvalue(), "logs": handler.records}


def completed_responses(events: list[Any]) -> list[Any]:
    return [
        event["response"]
        for event in events
        if isinstance(event, dict) and event.get("status") == "Completed" and "response" in event
    ]


def assert_expected_result(events: list[Any], expected: Any, check: str) -> None:
    if not isinstance(expected, str) or not expected.strip():
        raise QualificationError(f"{check} needs a non-empty expected result")
    result_values = [response for response in completed_responses(events) if isinstance(response, str)]
    if expected not in "\n".join(result_values):
        raise QualificationError(f"{check} missed its expected text in the completed caller response")


def _path_value(value: Any, path: str) -> Any:
    current = value
    for segment in path.split("."):
        if isinstance(current, dict) and segment in current:
            current = current[segment]
            continue
        raise QualificationError("completed caller response missed a required structured field")
    return current


def _structured_candidates(events: list[Any]) -> list[Any]:
    candidates = []
    for response in completed_responses(events):
        if isinstance(response, (dict, list)):
            candidates.append(response)
        elif isinstance(response, str):
            try:
                parsed = strict_json_loads(response)
            except (json.JSONDecodeError, ValueError):
                continue
            if isinstance(parsed, (dict, list)):
                candidates.append(parsed)
    return candidates


def assert_expected_shape(events: list[Any], shape: dict[str, Any], check: str) -> None:
    candidates = _structured_candidates(events)
    if not candidates:
        raise QualificationError(f"{check} did not return a structured completed response")
    for candidate in candidates:
        try:
            for path in shape.get("required", []):
                _path_value(candidate, path)
            for path, expected_type in shape.get("types", {}).items():
                actual = _path_value(candidate, path)
                if expected_type == "integer":
                    matches = isinstance(actual, int) and not isinstance(actual, bool)
                elif expected_type == "number":
                    matches = (
                        isinstance(actual, (int, float))
                        and not isinstance(actual, bool)
                        and math.isfinite(actual)
                    )
                else:
                    matches = isinstance(actual, PRIMITIVE_TYPES[expected_type])
                if not matches:
                    raise QualificationError("completed caller response had an unexpected structured field type")
            return
        except QualificationError:
            continue
    raise QualificationError(f"{check} did not match the expected structured response shape")


def response_failed(status: int, events: list[Any]) -> bool:
    return status < 200 or status >= 300 or any(
        isinstance(event, dict)
        and (
            event.get("success") is False
            or str(event.get("status", "")).lower() in {"failed", "error", "cancelled", "timeout"}
        )
        for event in events
    )


def _reported_status(status: int, events: list[Any]) -> int:
    for event in reversed(events):
        if not isinstance(event, dict):
            continue
        value = event.get("http_error_code")
        try:
            candidate = int(value)
        except (TypeError, ValueError):
            continue
        if 100 <= candidate <= 599:
            return candidate
    return status


def classify_error(status: int, events: list[Any]) -> str:
    for event in reversed(events):
        if not isinstance(event, dict):
            continue
        category = event.get("error_category")
        if category in ALLOWED_ERROR_CATEGORIES:
            return category
        event_status = str(event.get("status", "")).lower()
        if event_status in ("cancelled", "timeout"):
            return event_status
    code = _reported_status(status, events)
    if code in (400, 409, 422):
        return "validation"
    if code == 401:
        return "authentication"
    if code == 403:
        return "authorization"
    if code == 404:
        return "not_found"
    if code in (408, 504):
        return "timeout"
    if code in (502, 503):
        return "dependency"
    return "platform"


def assert_expected_outcome(
    status: int, events: list[Any], expectation: dict[str, Any], check: str
) -> tuple[str, Optional[str]]:
    failed = response_failed(status, events)
    actual = "failure" if failed else "success"
    if actual != expectation["outcome"]:
        raise QualificationError(f"{check} returned an unexpected {actual} outcome")
    statuses = expectation.get("http_status")
    reported_status = _reported_status(status, events)
    if statuses is not None and reported_status not in statuses and status not in statuses:
        raise QualificationError(f"{check} returned an unexpected HTTP/error status")
    if actual == "success":
        if expectation.get("text") is not None:
            assert_expected_result(events, expectation["text"], check)
        if expectation.get("shape") is not None:
            assert_expected_shape(events, expectation["shape"], check)
        return actual, None
    category = classify_error(status, events)
    if expectation.get("error_category") is not None and category != expectation["error_category"]:
        raise QualificationError(f"{check} returned an unexpected sanitized error category")
    return actual, category


def build_payload(call: dict[str, Any], assistant_id: str, session_id: str) -> dict[str, Any]:
    if "payload" in call:
        payload = dict(call["payload"])
        # These identifiers define resources owned and cleaned up by this
        # harness. Never allow a scenario payload to redirect a call to a
        # pre-existing assistant or thread, even if validation was bypassed.
        payload["agent_id"] = assistant_id
        payload["session_id"] = session_id
        return payload
    payload = {
        "agent_id": assistant_id,
        "session_id": session_id,
        "system_prompt": call.get("system_prompt", ""),
        "agent_timeout": int(call.get("agent_timeout", 120)),
    }
    if "task_prompt" in call:
        payload["task_prompt"] = call["task_prompt"]
    payload.update({key: call[key] for key in FORWARDED_FIELDS if key in call})
    return payload


async def main():
    from slim_api.models.aws import CreateAgentPayload
    from slim_api.routers.las_agent import create_agent, delete_agent
    from slim_api.util.las_client import get_las_client
    from slim_api.util.las_utils import get_proper_thread_id

    try:
        config = strict_json_loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError) as exc:
        raise ScenarioError("stdin must contain strict JSON without duplicate keys") from exc
    cases, secrets = validate_scenario(config)
    tenant = "product-qualification"
    token = uuid.uuid4().hex[:12]
    request = SimpleNamespace(headers={"request_id": f"aip5410-{token}-create"})
    created = await create_agent(
        tenant,
        CreateAgentPayload(agent_name=f"aip5410{token}", app_version="aip5410-acceptance"),
        request,
    )
    if created.status_code != 201:
        raise QualificationError(f"assistant create returned HTTP {created.status_code}")
    try:
        body = strict_json_loads(created.body)
    except (json.JSONDecodeError, ValueError) as exc:
        raise QualificationError("assistant create returned invalid JSON") from exc
    assistant_id = body.get("runtime_id")
    if not assistant_id:
        raise QualificationError("assistant create omitted runtime_id")
    client = get_las_client()
    check_names = []
    results = []
    thread_ids = []
    try:
        for case_index, case in enumerate(cases):
            calls = case.get("calls")
            session_id = str(uuid.uuid4())
            thread_id = get_proper_thread_id(tenant, session_id)
            thread_ids.append(thread_id)
            state_expectations = []
            successful_calls = 0
            for call_index, call in enumerate(calls):
                expectation = normalize_expectation(call, f"case {case_index + 1} call {call_index + 1}")
                payload = build_payload(call, assistant_id, session_id)
                started = time.monotonic()
                request_id = f"aip5410-{token}-{case_index}-{call_index}"
                status, events, captured = await invoke(tenant, payload, request_id)
                duration_ms = round((time.monotonic() - started) * 1000)
                assert_absent(events, secrets, "caller response")
                assert_absent(captured, secrets, "caller logs")
                check = f"case {case['name']} call {call_index + 1}"
                actual, error_category = assert_expected_outcome(status, events, expectation, check)
                if expectation["outcome"] == "success":
                    successful_calls += 1
                    state_text = expectation.get("state_text", expectation.get("text"))
                    if state_text is not None:
                        state_expectations.append(state_text)
                result = {
                    "route": ROUTE,
                    "case": case["name"],
                    "call": call_index + 1,
                    "request_id": request_id,
                    "session_id": session_id,
                    "thread_id": thread_id,
                    "expected_outcome": expectation["outcome"],
                    "actual_outcome": actual,
                    "transport_http_status": status,
                    "duration_ms": duration_ms,
                    "owner": expectation.get("owner", "none"),
                }
                if error_category is not None:
                    result["error_category"] = error_category
                    result["reported_error_status"] = _reported_status(status, events)
                results.append(result)
                check_names.append(f"{case['name']}:call-{call_index + 1}")

            expect_empty_state = case.get("expect_empty_state", False)
            check_state = case.get("check_state", successful_calls > 0 or expect_empty_state)
            if check_state:
                thread_missing = False
                try:
                    state = jsonable(await client.threads.get_state(thread_id))
                except Exception as exc:
                    if not expect_empty_state or not is_not_found(exc):
                        raise
                    state = {"values": {}}
                    thread_missing = True
                values = state.get("values", {}) if isinstance(state, dict) else {}
                state_text = "\n".join(strings(values))
                if expect_empty_state and not state_is_effectively_empty(values):
                    raise QualificationError(
                        f"case {case['name']} wrote graph state despite an expected failure"
                    )
                if state_expectations and not all(
                    expected in state_text for expected in state_expectations
                ):
                    raise QualificationError(f"case {case['name']} expected outputs were not in graph state values")
                assert_absent(values, secrets, "graph state values")
                history = [] if thread_missing else await all_checkpoints(client, thread_id)
                assert_absent(history, secrets, "checkpoint history")
                if state_expectations:
                    check_names.append(f"{case['name']}:state-values")
                elif expect_empty_state:
                    check_names.append(f"{case['name']}:empty-state")
                else:
                    check_names.append(f"{case['name']}:state-inspected")
                check_names.append(f"{case['name']}:checkpoint-redaction")
    finally:
        cleanup_failed = False
        for thread_id in dict.fromkeys(thread_ids):
            try:
                await client.threads.delete(thread_id)
            except Exception as exc:
                status_code = getattr(exc, "status_code", None)
                if status_code is None:
                    status_code = getattr(getattr(exc, "response", None), "status_code", None)
                if status_code != 404:
                    cleanup_failed = True
        deleted = await delete_agent(tenant, assistant_id, request)
        if deleted.status_code < 200 or deleted.status_code >= 300:
            cleanup_failed = True
        if cleanup_failed:
            raise QualificationError("qualification resource cleanup failed")
    print(
        json.dumps(
            {
                "result": "PASS",
                "route": ROUTE,
                "checks": check_names,
                "case_results": results,
                "external_gates": EXTERNAL_GATES,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as exc:
        # Only messages authored as safe evidence by this module may be emitted.
        safe = (
            str(exc)
            if isinstance(exc, (QualificationError, ScenarioError, json.JSONDecodeError))
            else "qualification failed; sensitive failure details withheld"
        )
        print(json.dumps({"result": "FAIL", "reason": safe}, sort_keys=True), file=sys.stderr)
        raise SystemExit(1)
