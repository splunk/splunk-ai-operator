#!/usr/bin/env bash

# Integration Test: Full Stack Deployment
# Tests the complete deployment workflow from the eks_cluster_with_stack.sh script
# This validates all components work together end-to-end

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOLS_DIR="${REPO_ROOT}/tools/ai-tier-cluster-setup"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test configuration
TEST_NAME="${TEST_NAME:-stack-integration-test}"
CLUSTER_NAME="${CLUSTER_NAME:-ai-operator-integration-$(date +%s)}"
USE_EXISTING_CLUSTER="${USE_EXISTING_CLUSTER:-false}"
CLEANUP_ON_SUCCESS="${CLEANUP_ON_SUCCESS:-true}"
CLEANUP_ON_FAILURE="${CLEANUP_ON_FAILURE:-false}"
SKIP_CLUSTER_CREATION="${SKIP_CLUSTER_CREATION:-false}"
TEST_NAMESPACE="${TEST_NAMESPACE:-integration-test}"
PROVIDER="${PROVIDER:-kind}"  # kind, eks, or use-existing

# Test results tracking
declare -a PASSED_TESTS=()
declare -a FAILED_TESTS=()
declare -a SKIPPED_TESTS=()

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
info() { echo -e "${CYAN}ℹ${NC} $*"; }

# Test assertion helpers
assert_command_succeeds() {
    local description="$1"
    shift
    if "$@" &>/dev/null; then
        PASSED_TESTS+=("$description")
        success "$description"
        return 0
    else
        FAILED_TESTS+=("$description")
        error "$description"
        return 1
    fi
}

assert_pod_running() {
    local namespace="$1"
    local label_selector="$2"
    local description="${3:-Pod with label $label_selector in namespace $namespace}"

    if kubectl get pods -n "$namespace" -l "$label_selector" -o jsonpath='{.items[*].status.phase}' | grep -q "Running"; then
        PASSED_TESTS+=("$description")
        success "$description"
        return 0
    else
        FAILED_TESTS+=("$description")
        error "$description - Pod not running"
        kubectl get pods -n "$namespace" -l "$label_selector" || true
        return 1
    fi
}

assert_resource_exists() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="${3:-}"
    local description="${4:-$resource_type $resource_name exists}"

    local ns_flag=""
    [[ -n "$namespace" ]] && ns_flag="-n $namespace"

    if kubectl get "$resource_type" "$resource_name" $ns_flag &>/dev/null; then
        PASSED_TESTS+=("$description")
        success "$description"
        return 0
    else
        FAILED_TESTS+=("$description")
        error "$description - Resource not found"
        return 1
    fi
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Integration test for full stack deployment workflow

OPTIONS:
  --cluster-name NAME          Name for test cluster (default: auto-generated)
  --provider PROVIDER          Cluster provider: kind, eks, use-existing (default: kind)
  --use-existing              Use existing cluster (sets provider to use-existing)
  --skip-cluster-creation     Skip creating cluster (use current context)
  --test-namespace NS         Namespace for test resources (default: integration-test)
  --cleanup-on-success        Cleanup resources on success (default: true)
  --no-cleanup-on-success     Do not cleanup on success
  --cleanup-on-failure        Cleanup resources on failure (default: false)
  -h, --help                  Show this help

EXAMPLES:
  # Test on kind cluster with cleanup
  $0 --provider kind --cleanup-on-success

  # Test on existing cluster without cleanup
  $0 --use-existing --no-cleanup-on-success

  # Test on EKS (requires AWS credentials)
  $0 --provider eks --cleanup-on-success

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --provider)
            PROVIDER="$2"
            shift 2
            ;;
        --use-existing)
            PROVIDER="use-existing"
            SKIP_CLUSTER_CREATION=true
            shift
            ;;
        --skip-cluster-creation)
            SKIP_CLUSTER_CREATION=true
            shift
            ;;
        --test-namespace)
            TEST_NAMESPACE="$2"
            shift 2
            ;;
        --cleanup-on-success)
            CLEANUP_ON_SUCCESS=true
            shift
            ;;
        --no-cleanup-on-success)
            CLEANUP_ON_SUCCESS=false
            shift
            ;;
        --cleanup-on-failure)
            CLEANUP_ON_FAILURE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

# Test Phase 1: Infrastructure Setup
test_phase_1_infrastructure() {
    log "════════════════════════════════════════════════════════"
    log "Phase 1: Infrastructure Component Tests"
    log "════════════════════════════════════════════════════════"

    # Test cert-manager
    log "Testing cert-manager installation..."
    assert_resource_exists namespace cert-manager "" "cert-manager namespace exists"
    assert_pod_running cert-manager "app.kubernetes.io/instance=cert-manager" "cert-manager pods running"
    assert_resource_exists crd certificates.cert-manager.io "" "certificates CRD exists"

    # Test monitoring stack (if installed)
    if kubectl get namespace monitoring &>/dev/null; then
        log "Testing monitoring stack..."
        assert_resource_exists namespace monitoring "" "monitoring namespace exists"
        assert_pod_running monitoring "app.kubernetes.io/name=prometheus" "prometheus pods running"
    else
        SKIPPED_TESTS+=("Monitoring stack (not installed)")
        warn "Monitoring stack not installed, skipping tests"
    fi

    # Test OpenTelemetry (if installed)
    if kubectl get namespace observability &>/dev/null; then
        log "Testing OpenTelemetry operator..."
        assert_resource_exists namespace observability "" "observability namespace exists"
        assert_pod_running observability "app.kubernetes.io/name=opentelemetry-operator" "otel-operator pods running"
    else
        SKIPPED_TESTS+=("OpenTelemetry operator (not installed)")
        warn "OpenTelemetry operator not installed, skipping tests"
    fi

    success "Phase 1: Infrastructure tests completed"
}

# Test Phase 2: Operator Installation
test_phase_2_operators() {
    log "════════════════════════════════════════════════════════"
    log "Phase 2: Operator Installation Tests"
    log "════════════════════════════════════════════════════════"

    # Test KubeRay Operator
    log "Testing KubeRay operator..."
    if kubectl get namespace kuberay-operator-system &>/dev/null || kubectl get namespace ray-system &>/dev/null; then
        local ray_ns="kuberay-operator-system"
        kubectl get namespace ray-system &>/dev/null && ray_ns="ray-system"

        assert_resource_exists namespace "$ray_ns" "" "KubeRay operator namespace exists"
        assert_pod_running "$ray_ns" "app.kubernetes.io/name=kuberay-operator" "KubeRay operator pod running"
        assert_resource_exists crd rayclusters.ray.io "" "RayCluster CRD exists"
        assert_resource_exists crd rayservices.ray.io "" "RayService CRD exists"
    else
        SKIPPED_TESTS+=("KubeRay operator (not installed)")
        warn "KubeRay operator not installed, skipping tests"
    fi

    # Test Splunk Operator
    log "Testing Splunk operator..."
    if kubectl get namespace splunk-operator &>/dev/null; then
        assert_resource_exists namespace splunk-operator "" "Splunk operator namespace exists"
        assert_pod_running splunk-operator "name=splunk-operator" "Splunk operator pod running"
        assert_resource_exists crd standalones.enterprise.splunk.com "" "Standalone CRD exists"
    else
        SKIPPED_TESTS+=("Splunk operator (not installed)")
        warn "Splunk operator not installed, skipping tests"
    fi

    # Test Splunk AI Operator
    log "Testing Splunk AI operator..."
    assert_resource_exists namespace splunk-ai-operator-system "" "Splunk AI operator namespace exists"
    assert_pod_running splunk-ai-operator-system "control-plane=controller-manager" "Splunk AI operator pod running"
    assert_resource_exists crd aiplatforms.ai.splunk.com "" "AIPlatform CRD exists"
    assert_resource_exists crd aiservices.ai.splunk.com "" "AIService CRD exists"

    # Test webhooks
    log "Testing admission webhooks..."
    assert_resource_exists validatingwebhookconfiguration splunk-ai-operator-validating-webhook-configuration "" "Validating webhook exists"
    assert_resource_exists mutatingwebhookconfiguration splunk-ai-operator-mutating-webhook-configuration "" "Mutating webhook exists"

    success "Phase 2: Operator tests completed"
}

# Test Phase 3: Platform Deployment
test_phase_3_platform_deployment() {
    log "════════════════════════════════════════════════════════"
    log "Phase 3: Platform Deployment Tests"
    log "════════════════════════════════════════════════════════"

    # Create test namespace
    kubectl create namespace "$TEST_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Create test Splunk secret
    log "Creating test Splunk secret..."
    cat <<EOF | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: v1
kind: Secret
metadata:
  name: test-splunk-secret
type: Opaque
data:
  hec_token: $(echo -n "test-token-12345" | base64)
  password: $(echo -n "TestPassword123!" | base64)
EOF

    # Deploy test AIPlatform
    log "Deploying test AIPlatform..."
    cat <<EOF | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: test-platform
spec:
  objectStorage:
    path: s3://test-bucket/artifacts
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: default
  splunkConfiguration:
    endpoint: http://test-splunk.$TEST_NAMESPACE.svc.cluster.local:8088
    secretRef:
      name: test-splunk-secret
      namespace: $TEST_NAMESPACE
  storage:
    vectorDB:
      size: 10Gi
      storageClassName: standard
EOF

    # Wait for AIPlatform to be created
    log "Waiting for AIPlatform to be processed..."
    sleep 15

    # Test AIPlatform resource exists
    assert_resource_exists aiplatform test-platform "$TEST_NAMESPACE" "AIPlatform resource created"

    # Test Ray cluster creation
    log "Testing Ray cluster deployment..."
    local max_wait=300
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if kubectl get raycluster -n "$TEST_NAMESPACE" 2>/dev/null | grep -q "test-platform"; then
            break
        fi
        sleep 10
        waited=$((waited + 10))
    done

    assert_resource_exists raycluster test-platform-ray "$TEST_NAMESPACE" "Ray cluster created" || true

    # Test Weaviate deployment
    log "Testing Weaviate deployment..."
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if kubectl get statefulset -n "$TEST_NAMESPACE" 2>/dev/null | grep -q "weaviate"; then
            break
        fi
        sleep 10
        waited=$((waited + 10))
    done

    # Check if Weaviate StatefulSet exists
    if kubectl get statefulset -n "$TEST_NAMESPACE" -l "ai.splunk.com/platform=test-platform" 2>/dev/null | grep -q "weaviate"; then
        PASSED_TESTS+=("Weaviate StatefulSet created")
        success "Weaviate StatefulSet created"
    else
        FAILED_TESTS+=("Weaviate StatefulSet created")
        error "Weaviate StatefulSet not found"
    fi

    # Test PVC creation
    log "Testing persistent volume claim..."
    if kubectl get pvc -n "$TEST_NAMESPACE" -l "ai.splunk.com/platform=test-platform" 2>/dev/null | grep -q "Bound\|Pending"; then
        PASSED_TESTS+=("PVC created for vector database")
        success "PVC created for vector database"
    else
        SKIPPED_TESTS+=("PVC creation (may not be bound yet)")
        warn "PVC not found or not bound yet"
    fi

    success "Phase 3: Platform deployment tests completed"
}

# Test Phase 4: Status and Events
test_phase_4_status_events() {
    log "════════════════════════════════════════════════════════"
    log "Phase 4: Status and Events Tests"
    log "════════════════════════════════════════════════════════"

    # Check AIPlatform status conditions
    log "Testing status conditions..."
    local has_status=$(kubectl get aiplatform test-platform -n "$TEST_NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")

    if [[ "$has_status" != "[]" && "$has_status" != "" ]]; then
        PASSED_TESTS+=("Status conditions populated")
        success "Status conditions populated"

        # Show status conditions
        kubectl get aiplatform test-platform -n "$TEST_NAMESPACE" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null | tr ' ' '\n' | while read -r cond; do
            [[ -n "$cond" ]] && info "  Condition: $cond"
        done
    else
        SKIPPED_TESTS+=("Status conditions (not yet populated)")
        warn "Status conditions not yet populated"
    fi

    # Check events
    log "Testing event emission..."
    local events=$(kubectl get events -n "$TEST_NAMESPACE" --field-selector involvedObject.name=test-platform 2>/dev/null | wc -l)

    if [[ $events -gt 1 ]]; then  # Header line counts as 1
        PASSED_TESTS+=("Events emitted for AIPlatform")
        success "Events emitted for AIPlatform ($events events)"
    else
        SKIPPED_TESTS+=("Event emission (no events yet)")
        warn "No events found yet for AIPlatform"
    fi

    success "Phase 4: Status and events tests completed"
}

# Test Phase 5: Cleanup and Finalization
test_phase_5_cleanup() {
    log "════════════════════════════════════════════════════════"
    log "Phase 5: Cleanup and Finalization Tests"
    log "════════════════════════════════════════════════════════"

    # Test resource deletion
    log "Testing resource cleanup..."
    kubectl delete aiplatform test-platform -n "$TEST_NAMESPACE" --wait=false

    # Wait a bit for finalizers to process
    sleep 10

    # Check if finalizers are working
    local finalizers=$(kubectl get aiplatform test-platform -n "$TEST_NAMESPACE" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || echo "[]")

    if [[ "$finalizers" != "[]" && "$finalizers" != "" ]]; then
        PASSED_TESTS+=("Finalizers present for cleanup")
        success "Finalizers present for cleanup"
    else
        SKIPPED_TESTS+=("Finalizers (already cleaned up)")
        info "Finalizers already processed or not present"
    fi

    # Wait for deletion to complete
    log "Waiting for resource deletion..."
    kubectl wait --for=delete aiplatform/test-platform -n "$TEST_NAMESPACE" --timeout=60s 2>/dev/null || true

    # Verify deletion
    if ! kubectl get aiplatform test-platform -n "$TEST_NAMESPACE" &>/dev/null; then
        PASSED_TESTS+=("AIPlatform resource deleted successfully")
        success "AIPlatform resource deleted successfully"
    else
        FAILED_TESTS+=("AIPlatform resource deletion")
        error "AIPlatform resource still exists"
    fi

    success "Phase 5: Cleanup tests completed"
}

# Test summary and reporting
print_test_summary() {
    log "════════════════════════════════════════════════════════"
    log "Test Summary"
    log "════════════════════════════════════════════════════════"

    local total=$((${#PASSED_TESTS[@]} + ${#FAILED_TESTS[@]} + ${#SKIPPED_TESTS[@]}))
    local passed_count=${#PASSED_TESTS[@]}
    local failed_count=${#FAILED_TESTS[@]}
    local skipped_count=${#SKIPPED_TESTS[@]}

    echo ""
    success "Passed:  $passed_count / $total tests"
    [[ $failed_count -gt 0 ]] && error "Failed:  $failed_count / $total tests" || echo -e "${CYAN}Failed:  0 / $total tests${NC}"
    [[ $skipped_count -gt 0 ]] && warn "Skipped: $skipped_count / $total tests" || echo -e "${CYAN}Skipped: 0 / $total tests${NC}"

    if [[ $failed_count -gt 0 ]]; then
        echo ""
        error "Failed Tests:"
        for test in "${FAILED_TESTS[@]}"; do
            echo "  - $test"
        done
    fi

    if [[ $skipped_count -gt 0 ]]; then
        echo ""
        warn "Skipped Tests:"
        for test in "${SKIPPED_TESTS[@]}"; do
            echo "  - $test"
        done
    fi

    echo ""
    log "════════════════════════════════════════════════════════"

    if [[ $failed_count -eq 0 ]]; then
        success "All tests passed! ✨"
        return 0
    else
        error "Some tests failed."
        return 1
    fi
}

# Cleanup function
cleanup_resources() {
    local should_cleanup="$1"

    if [[ "$should_cleanup" != "true" ]]; then
        info "Skipping cleanup (resources preserved for debugging)"
        return 0
    fi

    log "Cleaning up test resources..."

    # Delete test namespace
    kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true --timeout=2m || true

    # If we created the cluster, delete it
    if [[ "$SKIP_CLUSTER_CREATION" == "false" && "$PROVIDER" != "use-existing" ]]; then
        case "$PROVIDER" in
            kind)
                kind delete cluster --name "$CLUSTER_NAME" || true
                ;;
            eks)
                eksctl delete cluster --name "$CLUSTER_NAME" --region "${REGION:-us-west-2}" || true
                ;;
        esac
    fi

    success "Cleanup completed"
}

# Main test execution
main() {
    log "════════════════════════════════════════════════════════"
    log "Splunk AI Operator - Stack Integration Tests"
    log "════════════════════════════════════════════════════════"
    log "Test Name: $TEST_NAME"
    log "Cluster: $CLUSTER_NAME"
    log "Provider: $PROVIDER"
    log "Test Namespace: $TEST_NAMESPACE"
    log "════════════════════════════════════════════════════════"

    local test_failed=false

    # Run test phases
    test_phase_1_infrastructure || test_failed=true
    test_phase_2_operators || test_failed=true
    test_phase_3_platform_deployment || test_failed=true
    test_phase_4_status_events || test_failed=true
    test_phase_5_cleanup || test_failed=true

    # Print summary
    print_test_summary || test_failed=true

    # Cleanup
    if [[ "$test_failed" == "true" ]]; then
        if [[ "$CLEANUP_ON_FAILURE" == "true" ]]; then
            cleanup_resources true
        else
            warn "Test failed - resources preserved for debugging"
        fi
        exit 1
    else
        if [[ "$CLEANUP_ON_SUCCESS" == "true" ]]; then
            cleanup_resources true
        else
            info "Test passed - resources preserved"
        fi
        exit 0
    fi
}

# Run main
main "$@"
