# Weaviate-Service Feature

The `weaviate-service` feature deploys Weaviate behind a Splunk-authenticated service managed by `splunk-ai-operator`.

This flow is intended for users who want a smaller setup focused on:

- Splunk standalone
- weaviate
- weaviate-service

This lightweight flow does not require MinIO or external object storage.

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

## Refer tools/cluster_setup/K0S_README.md for cluster creation details

## Install

For k0s:

```bash
cd tools/cluster_setup

CONFIG_FILE=k0s-cluster-config.yaml \
bash k0s_weaviate_service_cluster_with_stack.sh install
```

For EKS:

```bash
cd tools/cluster_setup

CONFIG_FILE=eks-cluster-config.yaml \
bash eks_weaviate_service_cluster_with_stack.sh install
```

## Verify

```bash
export KUBECONFIG=~/.kube/k0s-my-ai-cluster 

kubectl get pods -n ai-platform
kubectl get aiplatform,aiservice -n ai-platform
kubectl get svc -n ai-platform
```

## Access With Interactive Token

Use the `weaviate-service` Kubernetes Service for in-cluster access, and the Ingress host with a `/weaviate` prefix for outside-cluster access when Ray is disabled.

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

Example outside the cluster through Ingress:

```bash
INGRESS_HOST=ai.example.com

curl -sS \
  -H "Authorization: Bearer $INTERACTIVE_TOKEN" \
  "http://${INGRESS_HOST}/weaviate/v1/meta" | jq .
```

```bash
curl -sS \
  -H "Authorization: Bearer $INTERACTIVE_TOKEN" \
  "http://${INGRESS_HOST}/weaviate/v1/schema" | jq .
```

Create a sample collection:

```bash
curl -sS -X POST \
  -H "Authorization: Bearer $INTERACTIVE_TOKEN" \
  -H "Content-Type: application/json" \
  "http://${INGRESS_HOST}/weaviate/v1/schema" \
  -d '{
    "class": "SampleDocs",
    "vectorizer": "none",
    "properties": [
      { "name": "text", "dataType": ["text"] }
    ]
  }' | jq .
```

The equivalent external request uses the `/weaviate` prefix:

```bash
curl -sS -X POST \
  -H "Authorization: Bearer $INTERACTIVE_TOKEN" \
  -H "Content-Type: application/json" \
  "http://${INGRESS_HOST}/weaviate/v1/schema" \
  -d '{
    "class": "SampleDocs",
    "vectorizer": "none",
    "properties": [
      { "name": "text", "dataType": ["text"] }
    ]
  }' | jq .
```
