# LAS contract fixture

This is a deterministic Agent Server graph for integration checks while the
Launchpad product image is developed. It makes no model, MCP, or knowledge-base
connections. The graph ID and default assistant ID are `contract_fixture`.

Input: `{"request":"hello"}`. The response is
`LAS contract fixture received: hello`. The graph reports only the names of
`llm_config`, `mcp_configs`, and `kb_configs` present in the per-run context.
It never returns the context values or places them in graph state.
Set `pause: true` to interrupt a run; resume it with fresh per-run context to
check that the resumed node sees that invocation's fields.

Build with `langgraph-cli[inmem]==0.4.32` on Linux AMD64 using a candidate
tag. AIP-5388 validates this candidate; product-image approval and immutable
identity belong to AIP-5567 when the Launchpad image is ready. The LAS state
API persisted fake per-run credential values in checkpoint metadata during
candidate testing (AIP-5402), so the fixture is not qualified for real
credential-bearing context. Runtime license, PostgreSQL, and Redis
credentials belong in Kubernetes Secrets and must never be included in the
image build context.
