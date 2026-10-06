# LAS sample agent image

A tiny, deterministic LangGraph graph for the LAS AI Tier POC. It has no model
provider or external API dependency, so it can exercise the Agent Server API,
queue, and persistence wiring without additional credentials.

The exported graph ID is `echo`. It expects `{"request": "..."}` and returns
`{"response": "LAS sample agent received: ..."}`.

## Build and publish

Build from this directory with a Linux AMD64 Docker builder and the LangGraph
CLI version used for the POC:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install 'langgraph-cli[inmem]==0.4.32'
langgraph build --platform linux/amd64 --tag las-sample-agent:local
```

Tag and push the image to the ECR repository `ml-platform/las-sample-agent` in
account `658391232643`, region `us-west-2`. Use a unique immutable tag for each
build. The ECR image URI is the value for
`images.apiServerImage.repository` and `images.apiServerImage.tag` in
`config/samples/las-ai-tier-chart-values.yaml`.

Do not add LAS license, PostgreSQL, Redis, or LangSmith credentials to the build
context or this project. The chart injects those at deployment time from
Kubernetes Secrets.
