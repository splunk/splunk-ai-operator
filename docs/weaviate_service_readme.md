# Weaviate-Service Feature

The `weaviate-service` feature deploys Weaviate behind a Splunk-authenticated service managed by `splunk-ai-operator`.

This flow is intended for users who want a smaller setup focused on:

- Splunk standalone
- weaviate
- weaviate-service
- object storage for AIPlatform

## Prerequisites

- An existing k0s or EKS cluster
- `kubectl` access to the target cluster
- A valid config file for the target environment
- Container images available from a registry reachable by the cluster
- `curl` and `jq` available for verification steps

## Required Config

Set these values in your config file:

- `aiPlatform.features[0].name: weaviate-service`
- `aiPlatform.features[0].serviceAccountName`
- `images.operator.image`
- `images.splunk.image`
- `images.weaviate.image`

The k0s weaviate-service script enables `WEAVIATE_PROXY_AUTH_MODE=true` by default.


## Install

For k0s:

```bash
cd /path/to/splunk-ai-operator

CONFIG_FILE=config/samples/k0s-cluster-config-sample.yaml \
bash tools/cluster_setup/k0s_weaviate_service_cluster_with_stack.sh install
```

For EKS:

```bash
cd /path/to/splunk-ai-operator

CONFIG_FILE=config/samples/eks-cluster-config.yaml \
bash tools/cluster_setup/eks_weaviate_service_cluster_with_stack.sh install
```

## Verify

```bash
kubectl get pods -n ai-platform
kubectl get aiplatform,aiservice -n ai-platform
kubectl get svc -n ai-platform
```

## Access With Interactive Token

Run these from a test pod inside the `ai-platform` namespace.

Create an interactive token from Splunk:

```bash
SPLUNK_USER=admin
SPLUNK_PASS='<splunk-password>'

INTERACTIVE_TOKEN=$(curl -sS -k -u "$SPLUNK_USER:$SPLUNK_PASS" \
  -X POST "https://splunk-splunk-standalone-standalone-service.ai-platform.svc.cluster.local:8089/services/authorization/tokens?output_mode=json" \
  --data "type=interactive" \
  | jq -r '.entry[0].content.token')
```

GET metadata from `weaviate-service`:

```bash
curl -sS \
  -H "Authorization: Bearer $INTERACTIVE_TOKEN" \
  "http://splunk-ai-stack-weaviate-service-weaviate-service.ai-platform.svc.cluster.local/v1/meta" | jq .
```

GET schema / collections:

```bash
curl -sS \
  -H "Authorization: Bearer $INTERACTIVE_TOKEN" \
  "http://splunk-ai-stack-weaviate-service-weaviate-service.ai-platform.svc.cluster.local/v1/schema" | jq .
```
