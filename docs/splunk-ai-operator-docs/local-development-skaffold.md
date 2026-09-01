# Local Development with Skaffold

This guide shows you how to use Skaffold for rapid local development of the Splunk AI Operator.

## What is Skaffold?

[Skaffold](https://skaffold.dev/) is a command-line tool that facilitates continuous development for Kubernetes applications. It handles the workflow for building, pushing, and deploying your application.

## Prerequisites

### Required Tools

```bash
# Install Skaffold
# macOS
brew install skaffold

# Linux
curl -Lo skaffold https://storage.googleapis.com/skaffold/releases/latest/skaffold-linux-amd64
chmod +x skaffold
sudo mv skaffold /usr/local/bin

# Verify installation
skaffold version
```

### Additional Requirements

- Docker or Podman
- kubectl configured with a Kubernetes cluster
- Access to a container registry (optional, for remote clusters)

## Quick Start

### 1. Configure Environment

Copy and customize the Skaffold environment file:

```bash
# Copy the template
cp skaffold.env skaffold.env.local

# Edit with your registry and image references
vim skaffold.env.local
```

**Example `skaffold.env.local`:**
```bash
# Use public images where available
RELATED_IMAGE_SPLUNK_ENTERPRISE=splunk/splunk:10.2.0
RELATED_IMAGE_WEAVIATE=semitechnologies/weaviate:stable-v1.28-007846a

# Use your own registry for custom components
YOUR_REGISTRY=myregistry.io/myorg
RELATED_IMAGE_RAY_HEAD=${YOUR_REGISTRY}/ray-head:dev
RELATED_IMAGE_RAY_WORKER=${YOUR_REGISTRY}/ray-worker:dev
RELATED_IMAGE_SAIA_API=${YOUR_REGISTRY}/saia-api:dev
RELATED_IMAGE_POST_INSTALL_HOOK=${YOUR_REGISTRY}/saia-data-loader:dev
```

### 2. Start Development

```bash
# Load environment variables
source skaffold.env.local

# Run Skaffold in development mode
skaffold dev
```

**What happens:**
1. Builds the operator Docker image
2. Deploys to your current Kubernetes context
3. Streams logs to your terminal
4. Watches for code changes and automatically rebuilds/redeploys

### 3. Make Changes

Edit code in your favorite editor. Skaffold will:
- Detect file changes
- Rebuild the Docker image
- Redeploy to Kubernetes
- Stream new logs

## Development Workflows

### Continuous Development (Recommended)

Watch for changes and auto-deploy:

```bash
skaffold dev --port-forward
```

Benefits:
- Automatic rebuilds on code changes
- Automatic port forwarding (webhooks, metrics)
- Real-time log streaming
- Clean up on exit (Ctrl+C)

### One-time Build and Deploy

Build, deploy, and exit:

```bash
skaffold run
```

Use for:
- Testing a specific change
- Deployment to staging
- CI/CD integration

### Debug Mode

Build with debug configuration:

```bash
skaffold debug --port-forward
```

Enables:
- Delve debugger for Go
- Remote debugging support
- Debug ports forwarded

## Working with Different Clusters

### Local Development (kind, minikube, k3s)

Default profile works out of the box:

```bash
# Ensure kubectl context is set
kubectl config current-context

# Run Skaffold
skaffold dev
```

Images stay local, no registry push needed.

### Google Kubernetes Engine (GKE)

1. Update `skaffold.yaml` profile:

```yaml
profiles:
  - name: gke
    activation:
      - kubeContext: gke_myproject_us-west1_my-cluster
    build:
      local:
        push: true
      platforms:
        - linux/amd64
```

2. Authenticate with GCR:

```bash
gcloud auth configure-docker
```

3. Run with profile:

```bash
skaffold dev --profile gke
```

### Amazon EKS

1. Update `skaffold.yaml`:

```yaml
profiles:
  - name: eks
    activation:
      - kubeContext: arn:aws:eks:us-west-2:123456789:cluster/my-cluster
    build:
      local:
        push: true
      platforms:
        - linux/amd64
```

2. Authenticate with ECR:

```bash
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin 123456789.dkr.ecr.us-west-2.amazonaws.com
```

3. Run with profile:

```bash
skaffold dev --profile eks
```

## Port Forwarding

Skaffold automatically forwards ports defined in `skaffold.yaml`:

```yaml
portForward:
  - resourceType: deployment
    resourceName: controller-manager
    port: 9443          # Webhook server
    localPort: 9443
    namespace: system
```

Access services locally:
- Webhook: `https://localhost:9443`
- Metrics: `http://localhost:8080/metrics`

## Tips and Tricks

### Speed Up Builds

Use BuildKit for faster builds:

```bash
export DOCKER_BUILDKIT=1
skaffold dev
```

### Skip Tests During Development

Temporarily disable test hooks:

```bash
skaffold dev --skip-tests
```

### Use Specific Namespace

Deploy to a specific namespace:

```bash
skaffold dev --namespace=my-dev-namespace
```

### Tail Logs for Specific Pod

```bash
skaffold dev --tail --tail-dev-mode=true
```

### Cleanup Resources

Skaffold cleans up on exit (Ctrl+C), but you can also manually clean:

```bash
skaffold delete
```

## Troubleshooting

### Build Fails: "Cannot connect to Docker daemon"

**Problem:** Docker isn't running or Skaffold can't access it.

**Solution:**
```bash
# Check Docker status
docker ps

# Restart Docker Desktop (macOS)
# or
sudo systemctl restart docker
```

### Deploy Fails: "context deadline exceeded"

**Problem:** Kubernetes cluster is slow or unreachable.

**Solution:**
```bash
# Check cluster connectivity
kubectl get nodes

# Increase timeout
skaffold dev --status-check-timeout=5m
```

### Image Pull Errors: "unauthorized"

**Problem:** Not authenticated to container registry.

**Solution:**
```bash
# For ECR
aws ecr get-login-password | docker login ...

# For GCR
gcloud auth configure-docker

# For Docker Hub
docker login
```

### "Port 9443 already in use"

**Problem:** Another process using the port.

**Solution:**
```bash
# Find process using port
lsof -ti:9443

# Kill it
kill $(lsof -ti:9443)

# Or use different local port in skaffold.yaml
```

## Advanced Configuration

### Custom Build Args

Pass build arguments:

```yaml
build:
  artifacts:
    - image: splunk-ai-operator
      docker:
        dockerfile: Dockerfile
        buildArgs:
          GO_VERSION: "1.23.0"
          BUILD_DATE: "{{.Date}}"
```

### Multi-Platform Builds

Build for multiple architectures:

```yaml
build:
  platforms:
    - linux/amd64
    - linux/arm64
```

### Custom Deploy Namespace

```yaml
deploy:
  kubectl:
    defaultNamespace: my-dev-namespace
```

## Integration with Other Tools

### With Tilt

If your team prefers Tilt, you can use both:

```bash
# Tiltfile
load('ext://skaffold', 'skaffold')
skaffold('skaffold.yaml')
```

### With VS Code

Install the [Cloud Code extension](https://cloud.google.com/code/docs/vscode/install):

1. Open VS Code
2. Install "Cloud Code" extension
3. Use `Cloud Code: Run on Kubernetes` command
4. Select `skaffold.yaml`

### With IntelliJ/GoLand

Install the [Cloud Code plugin](https://cloud.google.com/code/docs/intellij/install):

1. Open IntelliJ/GoLand
2. Install "Cloud Code" plugin
3. Use run configurations for Skaffold

## Best Practices

### 1. Use `.gitignore`

```gitignore
# Skaffold
skaffold.env.local
.skaffold/
```

### 2. Keep Environment-Specific Config Local

Never commit:
- Personal registry URLs
- Cloud credentials
- Cluster-specific contexts

### 3. Use Profiles for Different Environments

```yaml
profiles:
  - name: dev
    # Local development
  - name: staging
    # Staging cluster
  - name: production
    # Production (read-only)
```

### 4. Leverage File Sync for Fast Iteration

For config changes without rebuilds:

```yaml
build:
  artifacts:
    - image: splunk-ai-operator
      sync:
        manual:
          - src: "config/**/*.yaml"
            dest: /config
```

## Resources

- [Skaffold Documentation](https://skaffold.dev/docs/)
- [Skaffold Examples](https://github.com/GoogleContainerTools/skaffold/tree/main/examples)
- [Operator SDK with Skaffold](https://sdk.operatorframework.io/docs/building-operators/golang/tutorial/#run-locally-outside-the-cluster)

## Need Help?

- **Issues:** https://github.com/splunk/splunk-ai-operator/issues
- **Discussions:** https://github.com/splunk/splunk-ai-operator/discussions
- **Skaffold Slack:** https://kubernetes.slack.com (join #skaffold)
