"""Deterministic Agent Server fixture for the LAS deployment contract."""

from typing import Any, TypedDict

from langgraph.graph import END, START, StateGraph
from langgraph.runtime import Runtime
from langgraph.types import interrupt


class FixtureState(TypedDict, total=False):
    request: str
    response: str
    context_keys: list[str]
    pause: bool


class FixtureContext(TypedDict, total=False):
    llm_config: dict[str, Any]
    mcp_configs: list[dict[str, Any]]
    kb_configs: list[dict[str, Any]]


def respond(state: FixtureState, runtime: Runtime[FixtureContext]) -> FixtureState:
    """Expose only which context fields arrived; never copy their values."""
    if state.get("pause"):
        interrupt("Resume the fixture run with fresh context")
    context = runtime.context or {}
    allowed = ("llm_config", "mcp_configs", "kb_configs")
    return {
        "response": f"LAS contract fixture received: {state['request']}",
        "context_keys": [key for key in allowed if key in context],
    }


builder = StateGraph(FixtureState, context_schema=FixtureContext)
builder.add_node("respond", respond)
builder.add_edge(START, "respond")
builder.add_edge("respond", END)
graph = builder.compile()
