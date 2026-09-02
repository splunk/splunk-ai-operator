# Installation Guide

This guide covers all installation methods for the Splunk AI Operator.

## Prerequisites

- Kubernetes v1.31+ cluster
- kubectl v1.11.3+
- Helm v3.8+ (for Helm installation)

## Installation Methods

### Method 1: Helm OCI Registry (Recommended)

The recommended way to install using Helm 3.8+:

**IMPORTANT:** You must explicitly accept the Splunk General Terms before installing the operator.
Review the terms at: https://www.splunk.com/en_us/legal/splunk-general-terms.html

```bash
# Install operator with terms acceptance
# Note: Both flags are required - acceptGeneralTerms validates user consent,
# and splunkGeneralTerms configures the splunk-operator environment
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --set splunk-operator.acceptGeneralTerms=true \
  --set splunk-operator.splunkOperator.splunkGeneralTerms="<required value>"
```

**Note**: For the required value for `splunkGeneralTerms`, see the [Splunk Operator README](https://github.com/splunk/splunk-operator?tab=readme-ov-file#splunk-general-terms-acceptance).

**With custom values:**
```bash
# Create values file
cat > my-values.yaml <<EOF
# Accept Splunk General Terms (REQUIRED)
splunk-operator:
  acceptGeneralTerms: true
  splunkOperator:
    splunkGeneralTerms: "<required value>"

# Custom operator configuration
replicaCount: 2
image:
  pullPolicy: IfNotPresent
resources:
  limits:
    cpu: 1000m
    memory: 512Mi
EOF

# Install with custom values
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --values my-values.yaml
```

**Note**: For the required value for `splunkGeneralTerms`, see the [Splunk Operator README](https://github.com/splunk/splunk-operator?tab=readme-ov-file#splunk-general-terms-acceptance).

**View available versions:**
```bash
# Visit GHCR package page
# https://github.com/splunk/splunk-ai-operator/pkgs/container/charts%2Fsplunk-ai-operator
```

---

### Method 2: kubectl (Manifests)

Install using Kubernetes manifests:

```bash
# Install operator with all dependencies
kubectl apply -f https://github.com/splunk/splunk-ai-operator/releases/download/v1.0.0/install-v1.0.0.yaml
```

**Verify installation:**
```bash
kubectl get pods -n splunk-ai-operator-system
kubectl get crds | grep ai.splunk.com
```

---

### Method 3: Helm from GitHub Release

For compatibility with older Helm versions (< 3.8):

**IMPORTANT:** You must explicitly accept the Splunk General Terms.
Review the terms at: https://www.splunk.com/en_us/legal/splunk-general-terms.html

```bash
# Install from GitHub Release
helm install splunk-ai-operator \
  https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/splunk-ai-operator-0.2.0.tgz \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --set splunk-operator.acceptGeneralTerms=true \
  --set splunk-operator.splunkOperator.splunkGeneralTerms="<required value>"
```

**Note**: For the required value for `splunkGeneralTerms`, see the [Splunk Operator README](https://github.com/splunk/splunk-operator?tab=readme-ov-file#splunk-general-terms-acceptance).

---

### Method 4: From Source (Development)

For developers working on the operator:

```bash
# Clone repository
git clone https://github.com/splunk/splunk-ai-operator.git
cd splunk-ai-operator

# Install CRDs
make install

# Build and push image
make docker-build docker-push IMG=ghcr.io/YOUR_ORG/splunk-ai-operator:dev

# Deploy
make deploy IMG=ghcr.io/YOUR_ORG/splunk-ai-operator:dev
```

See [Local Development Guide](local-development.md) for more details.

---

## Installation Scope

### Cluster-Scoped (Default)

By default, the operator is installed cluster-scoped and watches all namespaces:

**IMPORTANT:** Accept Splunk General Terms: https://www.splunk.com/en_us/legal/splunk-general-terms.html

```bash
# Helm installation is cluster-scoped by default
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --set splunk-operator.acceptGeneralTerms=true \
  --set splunk-operator.splunkOperator.splunkGeneralTerms="<required value>"
```

**Note**: For the required value for `splunkGeneralTerms`, see the [Splunk Operator README](https://github.com/splunk/splunk-operator?tab=readme-ov-file#splunk-general-terms-acceptance).

### Namespace-Scoped

To restrict the operator to a single namespace:

```bash
# Install with namespace scope
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0 \
  --namespace my-app-namespace \
  --create-namespace \
  --set splunk-operator.acceptGeneralTerms=true \
  --set splunk-operator.splunkOperator.splunkGeneralTerms="<required value>" \
  --set watchNamespace=my-app-namespace
```

**Note**: For the required value for `splunkGeneralTerms`, see the [Splunk Operator README](https://github.com/splunk/splunk-operator?tab=readme-ov-file#splunk-general-terms-acceptance).

---

## Private Registry Support

### Using Private Container Registry

If using a private registry for the operator image:

```bash
# Create image pull secret
kubectl create secret docker-registry private-registry \
  --docker-server=your-registry.com \
  --docker-username=your-username \
  --docker-password=your-password \
  --namespace splunk-ai-operator-system

# Install with private registry
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 1.0.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --set image.repository=your-registry.com/splunk-ai-operator \
  --set image.tag=1.0.0 \
  --set imagePullSecrets[0].name=private-registry
```

### Using Private Registry for Related Images

Configure private registry for related images (Ray, Weaviate, etc.):

```bash
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 1.0.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --set env.RELATED_IMAGE_RAY_HEAD=your-registry.com/ray-head:latest \
  --set env.RELATED_IMAGE_WEAVIATE=your-registry.com/weaviate:latest
```

---

## Advanced Configuration

### Custom Cluster Domain

If your cluster uses a custom domain (not `cluster.local`):

```bash
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 1.0.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --set env.CLUSTER_DOMAIN=internal.mycluster
```

### Resource Limits

Configure resource limits:

```bash
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 1.0.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --set resources.limits.cpu=1000m \
  --set resources.limits.memory=512Mi \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=256Mi
```

### High Availability

Run multiple replicas for high availability:

```bash
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 1.0.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --set replicaCount=3 \
  --set leaderElection.enabled=true
```

---

## Verification

### Check Operator Status

```bash
# Check operator pods
kubectl get pods -n splunk-ai-operator-system

# Check operator logs
kubectl logs -n splunk-ai-operator-system \
  -l control-plane=controller-manager \
  --tail=100

# Verify CRDs are installed
kubectl get crds | grep ai.splunk.com
```

Expected output:
```
aiplatforms.ai.splunk.com
aiservices.ai.splunk.com
```

### Check Webhooks

```bash
# Verify webhook configuration
kubectl get validatingwebhookconfigurations | grep splunk-ai-operator
kubectl get mutatingwebhookconfigurations | grep splunk-ai-operator

# Check certificate
kubectl get certificates -n splunk-ai-operator-system
```

---

## Upgrading

### Upgrade Operator

```bash
# Upgrade to new version
helm upgrade splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 1.1.0 \
  --namespace splunk-ai-operator-system
```

### View Upgrade Status

```bash
# Check helm release history
helm history splunk-ai-operator -n splunk-ai-operator-system

# Check rollout status
kubectl rollout status deployment/splunk-ai-operator-controller-manager \
  -n splunk-ai-operator-system
```

---

## Uninstallation

### Using Helm

```bash
# Uninstall operator
helm uninstall splunk-ai-operator \
  --namespace splunk-ai-operator-system

# Delete namespace (if desired)
kubectl delete namespace splunk-ai-operator-system

# Remove CRDs (optional - this will delete all custom resources)
kubectl delete crd aiplatforms.ai.splunk.com
kubectl delete crd aiservices.ai.splunk.com
```

### Using kubectl

```bash
# Delete manifests
kubectl delete -f https://github.com/splunk/splunk-ai-operator/releases/download/v1.0.0/install-v1.0.0.yaml

# Delete namespace
kubectl delete namespace splunk-ai-operator-system
```

---

## Troubleshooting

### Operator Pod Not Starting

```bash
# Check pod status
kubectl describe pod -n splunk-ai-operator-system \
  -l control-plane=controller-manager

# Check events
kubectl get events -n splunk-ai-operator-system --sort-by='.lastTimestamp'
```

### Webhook Issues

If webhook is not working:

```bash
# Check webhook service
kubectl get svc -n splunk-ai-operator-system

# Check certificate
kubectl get secret -n splunk-ai-operator-system | grep tls

# Delete and recreate webhook (cert-manager will regenerate)
kubectl delete validatingwebhookconfigurations splunk-ai-operator-validating-webhook
kubectl delete mutatingwebhookconfigurations splunk-ai-operator-mutating-webhook
```

### Image Pull Errors

```bash
# Check image pull secrets
kubectl get secrets -n splunk-ai-operator-system

# Verify image exists
docker pull ghcr.io/splunk/splunk-ai-operator:v1.0.0

# Check pod events for pull errors
kubectl describe pod -n splunk-ai-operator-system <pod-name>
```

---

## Next Steps

After installing the operator:

1. **Deploy AI Platform**: See [Deployment Guide](../ai-tier-docs/deployment-guide.md)
2. **Configure Storage**: See [Storage Configuration](splunk-ai-operator-configuration/storage-configuration.md)
3. **Set Up Ingress**: See [Ingress Configuration](splunk-ai-operator-configuration/ingress-configuration.md)
4. **Review API**: See [API Reference](api-reference.md)

---

## Additional Resources

- [Deployment Guide](../ai-tier-docs/deployment-guide.md)
- [Local Development](local-development.md)
- [Troubleshooting Guide](troubleshooting.md)
- [Releases](releases.md)
