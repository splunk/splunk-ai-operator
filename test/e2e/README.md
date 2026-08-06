# Splunk AI Operator E2E Tests

Comprehensive end-to-end tests for the Splunk AI Operator covering all features and scenarios.

## Overview

The E2E test suite validates:
- ✅ **Storage Configuration** - Persistent volumes for Weaviate vector database
- ✅ **Ingress Configuration** - External access via HTTP/HTTPS
- ✅ **Server TLS Configuration** - Server certificate management through the legacy `mtls` field
- ✅ **Status Conditions** - Component readiness tracking
- ✅ **Event Tracking** - Kubernetes event generation
- ✅ **Component Health** - Ray cluster, Weaviate, and service endpoints

## Test Types

### 1. Unit-style E2E Tests (Ginkgo/Gomega)

Located in `test/e2e/specs/`, these tests use the Ginkgo BDD framework:

- `aiplatform_saia_test.go` - SAIA feature tests
- `aiplatform_comprehensive_test.go` - **NEW: Comprehensive feature tests**
- `manager_test.go` - Operator manager tests

### 2. Cluster E2E Test Script

`cluster-e2e-test.sh` - Bash script for real cluster testing that:
- Creates test clusters (kind, EKS, GKE, AKS)
- Installs operator and dependencies
- Runs comprehensive tests
- Cleans up resources

## Quick Start

### Running Ginkgo Tests on Existing Cluster

```bash
# Run all comprehensive tests
cd test/e2e/specs
ginkgo -v

# Run specific test suite
ginkgo -v --focus="Storage Configuration"

# Run with custom timeout
AIPLATFORM_READY_TIMEOUT=20m ginkgo -v
```

### Running Cluster E2E Tests

```bash
# Run all tests on kind cluster (creates and destroys cluster)
./test/e2e/cluster-e2e-test.sh

# Run on existing cluster (skip cluster creation, operator install, dependencies)
make e2e-cluster-existing
# Or manually:
./test/e2e/cluster-e2e-test.sh --skip-cluster-creation --skip-operator-install --skip-dependencies

# Run specific test category
./test/e2e/cluster-e2e-test.sh --storage-only
./test/e2e/cluster-e2e-test.sh --ingress-only
./test/e2e/cluster-e2e-test.sh --mtls-only

# Run on cloud providers
./test/e2e/cluster-e2e-test.sh --provider eks --region us-west-2
./test/e2e/cluster-e2e-test.sh --provider gke --region us-central1
./test/e2e/cluster-e2e-test.sh --provider aks --region eastus
```

## Test Scenarios

### Storage Configuration Tests

Tests persistent volume configuration for Weaviate:

**Scenarios:**
- ✅ Dynamic PVC creation with size and storage class
- ✅ Using existing PVC via `pvcName`
- ✅ Data persistence across pod restarts
- ✅ Volume expansion support

**Example:**
```yaml
spec:
  storage:
    vectorDB:
      size: 50Gi
      storageClassName: gp3
```

### Ingress Configuration Tests

Tests external access configuration:

**Scenarios:**
- ✅ Ingress resource creation
- ✅ Host and path configuration
- ✅ TLS/HTTPS configuration
- ✅ IngressReady status condition
- ✅ Ingress lifecycle events
- ✅ Disabled ingress (no resource created)

**Example:**
```yaml
spec:
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: ai.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts:
          - ai.example.com
        secretName: ai-platform-tls
```

### Server TLS Configuration Tests

Tests server certificate management. The command-line flag retains its legacy
`--mtls-only` name; client-certificate authentication is not implemented.

**Scenarios:**
- ✅ Certificate issuer reference
- ✅ Certificate creation via cert-manager
- ✅ Secure service communication

**Example:**
```yaml
spec:
  certificateRef: my-ca-issuer
```

### Status Condition Tests

Tests platform readiness tracking:

**Conditions Tested:**
- ✅ `Ready` - Overall platform health
- ✅ `RayServiceReady` - Ray cluster operational
- ✅ `RayClusterReady` - Ray pods running
- ✅ `RayServeRouteReady` - AI inference API available
- ✅ `WeaviateDatabaseReady` - Vector database operational
- ✅ `IngressReady` - External access configured

**Verification:**
```bash
# Check all conditions
kubectl get aiplatform my-platform -o jsonpath='{.status.conditions}' | jq .

# Check specific condition
kubectl get aiplatform my-platform -o jsonpath='{.status.conditions[?(@.type=="Ready")]}'
```

### Event Tracking Tests

Tests Kubernetes event generation:

**Events Tested:**
- ✅ RayService lifecycle events
- ✅ Weaviate lifecycle events
- ✅ Ingress lifecycle events
- ✅ Warning events for failures
- ✅ Success events for ready states

**Verification:**
```bash
# View all events
kubectl get events -n namespace --field-selector involvedObject.name=my-platform

# Watch events in real-time
kubectl get events -n namespace --watch --field-selector involvedObject.name=my-platform
```

### Component Health Tests

Tests individual component health:

**Components Tested:**
- ✅ Ray head pod readiness
- ✅ Ray worker pod scaling
- ✅ Weaviate StatefulSet readiness
- ✅ Service endpoint availability
- ✅ Pod restarts and recovery

## Environment Variables

Configure tests via environment variables:

### General Configuration
```bash
CLUSTER_NAME=my-test-cluster          # Cluster name
CLUSTER_PROVIDER=kind                 # kind, eks, gke, aks
REGION=us-west-2                      # Cloud region
TEST_NAMESPACE=e2e-test               # Test namespace
```

### Test Control
```bash
RUN_STORAGE_TESTS=true                # Run storage tests
RUN_INGRESS_TESTS=true                # Run ingress tests
RUN_MTLS_TESTS=true                   # Run server TLS tests (legacy variable name)
RUN_STATUS_TESTS=true                 # Run status tests
RUN_EVENT_TESTS=true                  # Run event tests
```

### Cleanup Behavior
```bash
CLEANUP_ON_SUCCESS=true               # Cleanup after success
CLEANUP_ON_FAILURE=false              # Cleanup after failure
SKIP_CLUSTER_CREATION=false           # Use existing cluster
SKIP_OPERATOR_INSTALL=false           # Use existing operator
SKIP_DEPENDENCIES_INSTALL=false       # Skip cert-manager installation
```

### Ginkgo Test Configuration
```bash
IMG=my-operator:v1.0.0                # Operator image
AIPLATFORM_SAMPLE=path/to/sample.yaml # AIPlatform sample
AISERVICE_SAMPLE=path/to/sample.yaml  # AIService sample
AIPLATFORM_READY_TIMEOUT=15m          # Platform ready timeout
CERT_MANAGER_INSTALL_SKIP=false       # Skip cert-manager install
```

## Using Existing Clusters

When running tests on an existing cluster (EKS, GKE, AKS, or local):

### Quick Command
```bash
make e2e-cluster-existing
```

This assumes:
- ✅ Operator is already installed
- ✅ cert-manager is already installed
- ✅ kubectl is configured for your cluster

### Manual Control
```bash
# Skip everything except tests
CLEANUP_ON_SUCCESS=false ./test/e2e/cluster-e2e-test.sh \
    --skip-cluster-creation \
    --skip-operator-install \
    --skip-dependencies

# Let script install operator and dependencies
./test/e2e/cluster-e2e-test.sh --skip-cluster-creation

# Run specific tests only
./test/e2e/cluster-e2e-test.sh \
    --skip-cluster-creation \
    --skip-operator-install \
    --skip-dependencies \
    --storage-only
```

### Prerequisites for Existing Cluster
1. **Verify cluster access**
   ```bash
   kubectl config current-context
   kubectl cluster-info
   ```

2. **Check operator (if skipping install)**
   ```bash
   kubectl get pods -n splunk-ai-operator-system
   ```

3. **Check cert-manager (if skipping dependencies)**
   ```bash
   kubectl get pods -n cert-manager
   ```

### Troubleshooting Existing Cluster

**Error: "Missing required tools: kind"**
- **Cause**: Script checking for cluster provider tools
- **Fix**: Use `--skip-cluster-creation` flag (now fixed in latest version)

**Error: "Cannot access Kubernetes cluster"**
- **Cause**: kubectl not configured
- **Fix**: Set correct context: `kubectl config use-context <your-context>`

**Tests fail with "operator not found"**
- **Cause**: Operator not installed and `--skip-operator-install` used
- **Fix**: Either install operator or remove the skip flag

## Running Tests in CI/CD

### GitHub Actions Example

```yaml
name: E2E Tests

on: [push, pull_request]

jobs:
  e2e-kind:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install kind
        run: |
          curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
          chmod +x ./kind
          sudo mv ./kind /usr/local/bin/kind

      - name: Run E2E Tests
        run: ./test/e2e/cluster-e2e-test.sh
        env:
          CLEANUP_ON_SUCCESS: true
          CLEANUP_ON_FAILURE: true

  e2e-eks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-west-2

      - name: Run E2E Tests on EKS
        run: ./test/e2e/cluster-e2e-test.sh
        env:
          CLUSTER_PROVIDER: eks
          CLUSTER_NAME: ci-test-${{ github.run_id }}
          CLEANUP_ON_SUCCESS: true
```

### Jenkins Pipeline Example

```groovy
pipeline {
    agent any

    environment {
        CLUSTER_NAME = "jenkins-e2e-${env.BUILD_ID}"
        CLUSTER_PROVIDER = "kind"
    }

    stages {
        stage('E2E Tests') {
            steps {
                sh './test/e2e/cluster-e2e-test.sh'
            }
        }
    }

    post {
        always {
            sh '''
                # Collect logs
                kubectl logs -n splunk-ai-operator-system \
                    deployment/splunk-ai-operator-controller-manager \
                    > operator-logs.txt || true

                # Cleanup
                CLEANUP_ON_FAILURE=true ./test/e2e/cluster-e2e-test.sh --cleanup-only || true
            '''
            archiveArtifacts artifacts: 'operator-logs.txt', allowEmptyArchive: true
        }
    }
}
```

## Test Development

### Adding New Test Scenarios

1. **Add to Ginkgo test suite:**

```go
Describe("New Feature", func() {
    Context("With specific configuration", func() {
        It("should behave correctly", func() {
            // Test implementation
            By("creating test resources")
            // ...

            By("verifying expected behavior")
            Eventually(func(g Gomega) {
                // Assertions
                g.Expect(result).To(BeTrue())
            }, 2*time.Minute, 5*time.Second).Should(Succeed())
        })
    })
})
```

2. **Add to cluster test script:**

```bash
run_new_feature_tests() {
    if [[ "$RUN_NEW_FEATURE_TESTS" != "true" ]]; then
        return 0
    fi

    log "Running New Feature Tests"

    # Test implementation
    # ...

    success "New feature tests completed"
}
```

### Test Helper Functions

The test suite provides helper functions:

**kubectl helpers:**
- `k8s.CreateNamespace(ns)` - Create namespace
- `k8s.Apply(ns, manifestPath)` - Apply manifest
- `k8s.WaitCRReady(kind, name, ns, condition, timeout)` - Wait for CR ready
- `k8s.ServiceHasEndpointPort(ns, svc, port)` - Check service endpoints
- `k8s.GetLogs(ns, pod)` - Get pod logs

**Custom helpers:**
- `getConditionStatus(ns, name, type)` - Get status condition
- `getEvents(ns, name)` - Get Kubernetes events
- `getPVCName(ns, platformName)` - Get PVC for platform
- `ingressExists(ns, name)` - Check ingress existence

## Troubleshooting

### Tests Failing Due to Timeout

Increase timeouts:
```bash
AIPLATFORM_READY_TIMEOUT=30m ginkgo -v
```

Or in cluster test script:
```bash
# Edit script to increase wait times
max_wait=300  # Increase from 180 to 300 seconds
```

### Cluster Creation Issues

**kind:**
```bash
# Check Docker is running
docker ps

# Check kind clusters
kind get clusters

# Delete stuck cluster
kind delete cluster --name ai-operator-e2e-test
```

**EKS:**
```bash
# Check AWS credentials
aws sts get-caller-identity

# Check eksctl
eksctl version

# List clusters
eksctl get clusters --region us-west-2
```

### Operator Not Starting

```bash
# Check operator logs
kubectl logs -n splunk-ai-operator-system \
    deployment/splunk-ai-operator-controller-manager

# Check if image loaded (kind)
docker exec -it kind-control-plane crictl images | grep splunk-ai-operator

# Re-deploy operator
make deploy IMG=splunk-ai-operator:e2e-test
```

### Test Cleanup Issues

```bash
# Manually cleanup namespace
kubectl delete namespace e2e-test --timeout=5m

# Force delete stuck resources
kubectl delete aiplatforms --all -n e2e-test --grace-period=0 --force

# Cleanup cluster
kind delete cluster --name ai-operator-e2e-test
```

## Test Coverage

Current test coverage:

| Feature | Unit Tests | Integration Tests | E2E Tests |
|---------|------------|-------------------|-----------|
| Storage | ✅ | ✅ | ✅ |
| Ingress | ✅ | ✅ | ✅ |
| Server TLS (`mtls` field) | ✅ | ✅ | ✅ |
| Status Conditions | ✅ | ✅ | ✅ |
| Event Tracking | ✅ | ✅ | ✅ |
| Ray Cluster | ✅ | ✅ | ✅ |
| Weaviate | ✅ | ✅ | ✅ |
| SAIA Feature | ✅ | ✅ | ✅ |

## Contributing

When adding new features:

1. Add unit tests in `internal/controller/*_test.go`
2. Add integration tests in `test/e2e/specs/*_test.go`
3. Add cluster test scenarios in `cluster-e2e-test.sh`
4. Update this README with new test scenarios
5. Ensure all tests pass before submitting PR

## References

- [Ginkgo Documentation](https://onsi.github.io/ginkgo/)
- [Gomega Matchers](https://onsi.github.io/gomega/)
- [Kubernetes Testing Best Practices](https://kubernetes.io/blog/2019/03/22/kubernetes-end-to-end-testing-for-everyone/)
- [Operator SDK Testing](https://sdk.operatorframework.io/docs/building-operators/golang/testing/)
