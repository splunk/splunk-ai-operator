"""Small deterministic graph for the standalone LAS deployment POC."""

from typing import TypedDict

from langgraph.graph import END, START, StateGraph


class EchoState(TypedDict):
    request: str
    response: str


def echo(state: EchoState) -> EchoState:
    """Return the request as a response without calling an external model."""
    return {"response": f"LAS sample agent received: {state['request']}"}


builder = StateGraph(EchoState)
builder.add_node("echo", echo)
builder.add_edge(START, "echo")
builder.add_edge("echo", END)

graph = builder.compile()
