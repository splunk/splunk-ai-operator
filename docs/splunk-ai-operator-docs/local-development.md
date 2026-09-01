# Local Development Guide

## Running the Operator Locally

### Prerequisites

1. **Kubernetes Cluster Access**
   - You must be connected to a Kubernetes cluster (kind, EKS, GKE, etc.)
   - Verify with: `kubectl cluster-info`

2. **Required CRDs**
   - Ray operator CRDs must be installed
   - Cert-manager for webhook certificates

### Quick Start

#### Option 1: Using the Helper Script (Recommended)

```bash
# Make sure you're connected to a cluster first
kubectl config use-context <your-context>

# Run the setup and start script
./scripts/run-local.sh
```

The script will:
- Check cluster connectivity
- Install Ray operator CRDs if missing
- Install operator CRDs
- Set up environment variables
- Start the operator

#### Option 2: Manual Setup

**Step 1: Connect to Cluster**

```bash
# For kind
kubectl config use-context kind-<cluster-name>

# For EKS
aws eks update-kubeconfig --region <region> --name <cluster-name>

# For GKE
gcloud container clusters get-credentials <cluster-name> --region <region>

# Verify
kubectl cluster-info
```

**Step 2: Install Ray Operator CRDs**

```bash
RAY_VERSION=v1.2.2

# Install RayCluster CRD
kubectl apply -f https://raw.githubusercontent.com/ray-project/kuberay/ray-operator/${RAY_VERSION}/config/crd/bases/ray.io_rayclusters.yaml

# Install RayService CRD
kubectl apply -f https://raw.githubusercontent.com/ray-project/kuberay/ray-operator/${RAY_VERSION}/config/crd/bases/ray.io_rayservices.yaml

# Install RayJob CRD
kubectl apply -f https://raw.githubusercontent.com/ray-project/kuberay/ray-operator/${RAY_VERSION}/config/crd/bases/ray.io_rayjobs.yaml

# Verify
kubectl get crd | grep ray
```

**Step 3: Install Cert-Manager (for webhooks)**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
```

**Step 4: Install Operator CRDs**

```bash
make install
```

**Step 5: Generate Webhook Certificates**

```bash
# Deploy cert-manager Certificate for webhooks
kubectl apply -f config/certmanager/certificate-webhook.yaml

# Wait for certificate to be ready
kubectl wait --for=condition=Ready certificate/serving-cert -n splunk-ai-operator-system --timeout=60s

# Export certificates for local use
kubectl get secret webhook-server-cert -n splunk-ai-operator-system -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/tls.crt
kubectl get secret webhook-server-cert -n splunk-ai-operator-system -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/tls.key
```

**Step 6: Set Environment Variables**

```bash
export RELATED_IMAGE_WEAVIATE="semitechnologies/weaviate:1.25.0"
export RELATED_IMAGE_RAY="rayproject/ray:2.9.0"
export RELATED_IMAGE_SAIA="your-registry/saia:latest"
```

**Step 7: Run the Operator**

```bash
# With webhook certificates
go run ./cmd/main.go --webhook-cert-path=/tmp

# Or use make run
make run
```

### Troubleshooting

#### Error: "failed to get informer from cache... *v1.RayCluster"

**Cause:** Ray operator CRDs are not installed

**Solution:**
```bash
kubectl apply -f https://raw.githubusercontent.com/ray-project/kuberay/ray-operator/v1.2.2/config/crd/bases/ray.io_rayclusters.yaml
kubectl apply -f https://raw.githubusercontent.com/ray-project/kuberay/ray-operator/v1.2.2/config/crd/bases/ray.io_rayservices.yaml
```

#### Error: "no such file or directory... tls.crt"

**Cause:** Webhook certificates not found

**Solution 1 - Generate certificates:**
```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# Wait for cert-manager
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s

# Create namespace
kubectl create namespace splunk-ai-operator-system --dry-run=client -o yaml | kubectl apply -f -

# Deploy certificate
kubectl apply -f config/certmanager/certificate-webhook.yaml

# Wait and export
kubectl wait --for=condition=Ready certificate/serving-cert -n splunk-ai-operator-system --timeout=60s
mkdir -p /tmp/webhook-certs
kubectl get secret webhook-server-cert -n splunk-ai-operator-system -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/webhook-certs/tls.crt
kubectl get secret webhook-server-cert -n splunk-ai-operator-system -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/webhook-certs/tls.key

# Run with certificates
go run ./cmd/main.go --webhook-cert-path=/tmp/webhook-certs
```

**Solution 2 - Use self-signed certificates:**
```bash
mkdir -p /tmp/webhook-certs

# Generate self-signed certificate
openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout /tmp/webhook-certs/tls.key \
  -out /tmp/webhook-certs/tls.crt \
  -days 365 \
  -subj "/CN=webhook-service.splunk-ai-operator-system.svc"

# Run with certificates
go run ./cmd/main.go --webhook-cert-path=/tmp/webhook-certs
```

#### Error: "You must be logged in to the server (Unauthorized)"

**Cause:** Not connected to a Kubernetes cluster

**Solution:**
```bash
# Check available contexts
kubectl config get-contexts

# Switch to a context
kubectl config use-context <context-name>

# Verify
kubectl cluster-info
```

#### Error: "Timeout: failed waiting for cache sync"

**Cause:** Cluster is slow or CRDs are not properly installed

**Solution:**
```bash
# Verify all CRDs are installed
kubectl get crd | grep -E "ray|aiplatform|aiservice"

# Expected output:
# aiplatforms.ai.splunk.com
# aiservices.ai.splunk.com
# rayclusters.ray.io
# rayservices.ray.io
# rayjobs.ray.io

# If missing, reinstall
make install
```

### Development Workflow

1. **Make Code Changes**
   ```bash
   # Edit code in pkg/, internal/, api/
   vim pkg/ai/reconciler.go
   ```

2. **Update Generated Code** (if API changed)
   ```bash
   make manifests generate
   ```

3. **Run Tests**
   ```bash
   make test
   ```

4. **Update CRDs in Cluster**
   ```bash
   make install
   ```

5. **Restart Operator**
   ```bash
   # Stop with Ctrl+C, then restart
   go run ./cmd/main.go --webhook-cert-path=/tmp/webhook-certs
   ```

6. **Test with Resources**
   ```bash
   kubectl apply -f config/samples/ai.splunk.com_v1_aiplatform.yaml
   kubectl logs -f <pod-name> -n splunk-ai-operator-system
   ```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `RELATED_IMAGE_WEAVIATE` | Weaviate vector database image | `semitechnologies/weaviate:1.25.0` |
| `RELATED_IMAGE_RAY` | Ray image for head/worker pods | `rayproject/ray:2.9.0` |
| `RELATED_IMAGE_SAIA` | SAIA service image | Required |
| `RELATED_IMAGE_POST_INSTALL_HOOK` | Post-install hook image | Optional |

### Tips

- **Use telepresence** for debugging in-cluster issues
- **Enable debug logging** with `--zap-log-level=debug`
- **Use delve** for debugging: `dlv debug ./cmd/main.go -- --webhook-cert-path=/tmp/webhook-certs`
- **Watch logs** in another terminal: `kubectl logs -f <pod> -n <namespace>`

### Common Commands

```bash
# Build
make build

# Run tests
make test

# Update CRDs
make manifests
make install

# Lint
make lint

# Generate code
make generate

# Build Docker image
make docker-build IMG=<your-registry>/splunk-ai-operator:dev

# Deploy to cluster
make deploy IMG=<your-registry>/splunk-ai-operator:dev
```

### Debugging

**Enable Debug Logging:**
```bash
go run ./cmd/main.go --webhook-cert-path=/tmp/webhook-certs --zap-log-level=debug
```

**Use Delve Debugger:**
```bash
dlv debug ./cmd/main.go -- --webhook-cert-path=/tmp/webhook-certs
```

**Check Operator Logs:**
```bash
# If running locally
# Logs appear in terminal

# If deployed to cluster
kubectl logs -f deployment/splunk-ai-operator-controller-manager -n splunk-ai-operator-system
```

**Check Resource Status:**
```bash
kubectl get aiplatform -A
kubectl describe aiplatform <name> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

### Clean Up

```bash
# Delete test resources
kubectl delete aiplatform --all -A

# Uninstall CRDs
make uninstall

# Delete certificates
rm -rf /tmp/webhook-certs
```

## Next Steps

- Read [DEVELOPMENT.md](DEVELOPMENT.md) for contribution guidelines
- Check [KUBEBUILDER_MARKERS.md](KUBEBUILDER_MARKERS.md) for API validation rules
- Review [ERROR_HANDLING_AND_EVENTS.md](troubleshooting.md) for error handling patterns
