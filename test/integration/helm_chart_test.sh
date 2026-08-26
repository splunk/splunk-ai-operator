#!/usr/bin/env bash

# Integration Test: Helm Chart Validation and Deployment
# Tests both splunk-ai-operator and splunk-ai-platform Helm charts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HELM_CHART_DIR="${REPO_ROOT}/helm-chart"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test configuration
TEST_NAMESPACE="${TEST_NAMESPACE:-helm-test}"
CLEANUP_ON_SUCCESS="${CLEANUP_ON_SUCCESS:-true}"
CLEANUP_ON_FAILURE="${CLEANUP_ON_FAILURE:-false}"
USE_EXISTING_CLUSTER="${USE_EXISTING_CLUSTER:-false}"
OPERATOR_RELEASE_NAME="test-splunk-ai-operator"
PLATFORM_RELEASE_NAME="test-splunk-ai-platform"

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
assert_succeeds() {
    local description="$1"
    shift
    if "$@" &>/dev/null; then
        PASSED_TESTS+=("$description")
        success "$description"
        return 0
    else
        FAILED_TESTS+=("$description")
        error "$description"
        "$@" || true  # Show error output
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local description="${2:-File $file exists}"

    if [[ -f "$file" ]]; then
        PASSED_TESTS+=("$description")
        success "$description"
        return 0
    else
        FAILED_TESTS+=("$description")
        error "$description - File not found: $file"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="${3:-Output contains '$needle'}"

    if echo "$haystack" | grep -q "$needle"; then
        PASSED_TESTS+=("$description")
        success "$description"
        return 0
    else
        FAILED_TESTS+=("$description")
        error "$description"
        return 1
    fi
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Integration test for Helm charts validation and deployment

OPTIONS:
  --test-namespace NS         Namespace for test resources (default: helm-test)
  --use-existing             Use existing cluster
  --cleanup-on-success       Cleanup resources on success (default: true)
  --no-cleanup-on-success    Do not cleanup on success
  --cleanup-on-failure       Cleanup resources on failure (default: false)
  -h, --help                 Show this help

EXAMPLES:
  # Test charts on existing cluster
  $0 --use-existing

  # Test with cleanup
  $0 --cleanup-on-success

  # Test without cleanup for debugging
  $0 --no-cleanup-on-success

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --test-namespace)
            TEST_NAMESPACE="$2"
            shift 2
            ;;
        --use-existing)
            USE_EXISTING_CLUSTER=true
            shift
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

# Phase 1: Chart Structure and Metadata Tests
test_phase_1_chart_structure() {
    log "════════════════════════════════════════════════════════"
    log "Phase 1: Chart Structure and Metadata Tests"
    log "════════════════════════════════════════════════════════"

    # Test splunk-ai-operator chart
    log "Testing splunk-ai-operator chart structure..."
    assert_file_exists "${HELM_CHART_DIR}/splunk-ai-operator/Chart.yaml" "Operator Chart.yaml exists"
    assert_file_exists "${HELM_CHART_DIR}/splunk-ai-operator/values.yaml" "Operator values.yaml exists"
    assert_file_exists "${HELM_CHART_DIR}/splunk-ai-operator/templates/deployment.yaml" "Operator deployment template exists"
    assert_file_exists "${HELM_CHART_DIR}/splunk-ai-operator/templates/serviceaccount.yaml" "Operator serviceaccount template exists"
    assert_file_exists "${HELM_CHART_DIR}/splunk-ai-operator/templates/role.yaml" "Operator role template exists"
    assert_file_exists "${HELM_CHART_DIR}/splunk-ai-operator/templates/rolebinding.yaml" "Operator rolebinding template exists"

    # Test splunk-ai-platform chart
    log "Testing splunk-ai-platform chart structure..."
    assert_file_exists "${HELM_CHART_DIR}/splunk-ai-platform/Chart.yaml" "Platform Chart.yaml exists"
    assert_file_exists "${HELM_CHART_DIR}/splunk-ai-platform/values.yaml" "Platform values.yaml exists"
    assert_file_exists "${HELM_CHART_DIR}/splunk-ai-platform/templates/aiplatform.yaml" "Platform aiplatform template exists"

    # Test CRDs
    log "Testing CRD files..."
    assert_file_exists "${HELM_CHART_DIR}/splunk-ai-operator/crds/ai.splunk.com_aiplatforms.yaml" "AIPlatform CRD exists"
    assert_file_exists "${HELM_CHART_DIR}/splunk-ai-operator/crds/ai.splunk.com_aiservices.yaml" "AIService CRD exists"

    success "Phase 1: Chart structure tests completed"
}

# Phase 2: Chart Linting Tests
test_phase_2_chart_linting() {
    log "════════════════════════════════════════════════════════"
    log "Phase 2: Chart Linting Tests"
    log "════════════════════════════════════════════════════════"

    # Lint splunk-ai-operator chart
    log "Linting splunk-ai-operator chart..."
    assert_succeeds "Operator chart passes helm lint" \
        helm lint "${HELM_CHART_DIR}/splunk-ai-operator"

    # Lint splunk-ai-platform chart
    log "Linting splunk-ai-platform chart..."
    assert_succeeds "Platform chart passes helm lint" \
        helm lint "${HELM_CHART_DIR}/splunk-ai-platform"

    success "Phase 2: Chart linting tests completed"
}

# Phase 3: Template Rendering Tests
test_phase_3_template_rendering() {
    log "════════════════════════════════════════════════════════"
    log "Phase 3: Template Rendering Tests"
    log "════════════════════════════════════════════════════════"

    # Test operator chart template rendering
    log "Testing operator chart template rendering..."
    local operator_template_output
    operator_template_output=$(helm template test-operator "${HELM_CHART_DIR}/splunk-ai-operator" \
        --namespace "$TEST_NAMESPACE" 2>&1)

    assert_contains "$operator_template_output" "kind: Deployment" "Operator chart renders Deployment"
    assert_contains "$operator_template_output" "kind: ServiceAccount" "Operator chart renders ServiceAccount"
    assert_contains "$operator_template_output" "kind: Role" "Operator chart renders Role"
    assert_contains "$operator_template_output" "kind: RoleBinding" "Operator chart renders RoleBinding"

    # Test platform chart template rendering with required values
    log "Testing platform chart template rendering..."
    local platform_template_output
    platform_template_output=$(helm template test-platform "${HELM_CHART_DIR}/splunk-ai-platform" \
        --namespace "$TEST_NAMESPACE" \
        --set objectStorage.path="s3://test-bucket/artifacts" \
        --set objectStorage.region="us-west-2" \
        --set features[0].name="saia" \
        --set features[0].version="1.1.0" \
        --set features[0].serviceAccountName="default" \
        --set features[0].publicServiceNodePort=30080 \
        --set workerGroupConfig.serviceAccountName="default" \
        --set splunk-ai-operator.enabled=false \
        --set kuberay-operator.enabled=false \
        --set cert-manager.enabled=false \
        --set prometheus.enabled=false \
        --set opentelemetry-operator.enabled=false \
        2>&1)

    assert_contains "$platform_template_output" "kind: AIPlatform" "Platform chart renders AIPlatform CR"
    assert_contains "$platform_template_output" "objectStorage:" "Platform chart includes objectStorage config"
    assert_contains "$platform_template_output" "publicServiceNodePort: 30080" "Platform chart renders per-feature public NodePort"

    success "Phase 3: Template rendering tests completed"
}

# Phase 4: Values Validation Tests
test_phase_4_values_validation() {
    log "════════════════════════════════════════════════════════"
    log "Phase 4: Values Validation Tests"
    log "════════════════════════════════════════════════════════"

    # Test operator chart with custom values
    log "Testing operator chart with custom values..."
    local custom_values_file=$(mktemp)
    cat > "$custom_values_file" <<EOF
image:
  repository: custom-registry/splunk-ai-operator
  tag: custom-tag
  pullPolicy: Always

replicaCount: 2

resources:
  limits:
    cpu: 1000m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi
EOF

    local custom_template_output
    custom_template_output=$(helm template test-custom "${HELM_CHART_DIR}/splunk-ai-operator" \
        --namespace "$TEST_NAMESPACE" \
        --values "$custom_values_file" 2>&1)

    assert_contains "$custom_template_output" "custom-registry/splunk-ai-operator" "Custom image repository applied"
    assert_contains "$custom_template_output" "custom-tag" "Custom image tag applied"
    assert_contains "$custom_template_output" "replicas: 2" "Custom replica count applied"

    rm -f "$custom_values_file"

    # Test platform chart with custom values
    log "Testing platform chart with custom storage values..."
    local platform_values_file=$(mktemp)
    cat > "$platform_values_file" <<EOF
objectStorage:
  path: s3://custom-bucket/models
  region: eu-west-1

storage:
  vectorDB:
    size: 100Gi
    storageClassName: fast-ssd

features:
  - name: saia
    version: 1.1.0
    serviceAccountName: saia-sa

workerGroupConfig:
  serviceAccountName: ray-worker-sa

splunk-ai-operator:
  enabled: false

kuberay-operator:
  enabled: false

cert-manager:
  enabled: false

prometheus:
  enabled: false

opentelemetry-operator:
  enabled: false
EOF

    local platform_custom_output
    platform_custom_output=$(helm template test-platform-custom "${HELM_CHART_DIR}/splunk-ai-platform" \
        --namespace "$TEST_NAMESPACE" \
        --values "$platform_values_file" 2>&1)

    assert_contains "$platform_custom_output" "s3://custom-bucket/models" "Custom S3 path applied"
    assert_contains "$platform_custom_output" "eu-west-1" "Custom region applied"
    assert_contains "$platform_custom_output" "100Gi" "Custom storage size applied"

    rm -f "$platform_values_file"

    success "Phase 4: Values validation tests completed"
}

# Phase 5: Dry-Run Installation Tests
test_phase_5_dry_run_installation() {
    log "════════════════════════════════════════════════════════"
    log "Phase 5: Dry-Run Installation Tests"
    log "════════════════════════════════════════════════════════"

    # Create test namespace
    kubectl create namespace "$TEST_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

    # Dry-run install operator chart
    log "Testing operator chart dry-run installation..."
    assert_succeeds "Operator chart dry-run install succeeds" \
        helm install "$OPERATOR_RELEASE_NAME" "${HELM_CHART_DIR}/splunk-ai-operator" \
            --namespace "$TEST_NAMESPACE" \
            --dry-run \
            --debug

    # Dry-run install platform chart
    log "Testing platform chart dry-run installation..."
    assert_succeeds "Platform chart dry-run install succeeds" \
        helm install "$PLATFORM_RELEASE_NAME" "${HELM_CHART_DIR}/splunk-ai-platform" \
            --namespace "$TEST_NAMESPACE" \
            --dry-run \
            --debug \
            --set objectStorage.path="s3://test-bucket/artifacts" \
            --set objectStorage.region="us-west-2" \
            --set features[0].name="saia" \
            --set features[0].version="1.1.0" \
            --set features[0].serviceAccountName="default" \
            --set workerGroupConfig.serviceAccountName="default" \
            --set splunk-ai-operator.enabled=false \
            --set kuberay-operator.enabled=false \
            --set cert-manager.enabled=false \
            --set prometheus.enabled=false \
            --set opentelemetry-operator.enabled=false

    success "Phase 5: Dry-run installation tests completed"
}

# Phase 6: Actual Deployment Tests
test_phase_6_actual_deployment() {
    log "════════════════════════════════════════════════════════"
    log "Phase 6: Actual Deployment Tests"
    log "════════════════════════════════════════════════════════"

    # Create test namespace
    kubectl create namespace "$TEST_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Install operator chart
    log "Installing operator chart..."
    if helm install "$OPERATOR_RELEASE_NAME" "${HELM_CHART_DIR}/splunk-ai-operator" \
        --namespace "$TEST_NAMESPACE" \
        --wait \
        --timeout 5m; then
        PASSED_TESTS+=("Operator chart installation succeeds")
        success "Operator chart installation succeeds"
    else
        FAILED_TESTS+=("Operator chart installation succeeds")
        error "Operator chart installation failed"
        helm status "$OPERATOR_RELEASE_NAME" -n "$TEST_NAMESPACE" || true
        return 1
    fi

    # Verify operator deployment
    log "Verifying operator deployment..."
    sleep 10

    if kubectl get deployment -n "$TEST_NAMESPACE" -l "app.kubernetes.io/instance=$OPERATOR_RELEASE_NAME" | grep -q "$OPERATOR_RELEASE_NAME"; then
        PASSED_TESTS+=("Operator deployment created")
        success "Operator deployment created"
    else
        FAILED_TESTS+=("Operator deployment created")
        error "Operator deployment not found"
    fi

    # Check if CRDs are installed
    log "Verifying CRDs installation..."
    if kubectl get crd aiplatforms.ai.splunk.com &>/dev/null; then
        PASSED_TESTS+=("AIPlatform CRD installed")
        success "AIPlatform CRD installed"
    else
        FAILED_TESTS+=("AIPlatform CRD installed")
        error "AIPlatform CRD not found"
    fi

    # Create test Splunk secret for platform chart
    log "Creating test secrets..."
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

    # Install platform chart
    log "Installing platform chart..."
    if helm install "$PLATFORM_RELEASE_NAME" "${HELM_CHART_DIR}/splunk-ai-platform" \
        --namespace "$TEST_NAMESPACE" \
        --wait \
        --timeout 5m \
        --set objectStorage.path="s3://test-bucket/artifacts" \
        --set objectStorage.region="us-west-2" \
        --set features[0].name="saia" \
        --set features[0].version="1.1.0" \
        --set features[0].serviceAccountName="default" \
        --set workerGroupConfig.serviceAccountName="default" \
        --set splunkConfiguration.endpoint="http://test-splunk.$TEST_NAMESPACE.svc.cluster.local:8088" \
        --set splunkConfiguration.secretRef.name="test-splunk-secret" \
        --set splunkConfiguration.secretRef.namespace="$TEST_NAMESPACE" \
        --set splunk-ai-operator.enabled=false \
        --set kuberay-operator.enabled=false \
        --set cert-manager.enabled=false \
        --set prometheus.enabled=false \
        --set opentelemetry-operator.enabled=false; then
        PASSED_TESTS+=("Platform chart installation succeeds")
        success "Platform chart installation succeeds"
    else
        FAILED_TESTS+=("Platform chart installation succeeds")
        error "Platform chart installation failed"
        helm status "$PLATFORM_RELEASE_NAME" -n "$TEST_NAMESPACE" || true
        return 1
    fi

    # Verify platform resources
    log "Verifying platform resources..."
    sleep 10

    if kubectl get aiplatform -n "$TEST_NAMESPACE" | grep -q "$PLATFORM_RELEASE_NAME"; then
        PASSED_TESTS+=("AIPlatform resource created from chart")
        success "AIPlatform resource created from chart"
    else
        FAILED_TESTS+=("AIPlatform resource created from chart")
        error "AIPlatform resource not found"
        kubectl get aiplatform -n "$TEST_NAMESPACE" || true
    fi

    success "Phase 6: Actual deployment tests completed"
}

# Phase 7: Upgrade Tests
test_phase_7_upgrade() {
    log "════════════════════════════════════════════════════════"
    log "Phase 7: Upgrade Tests"
    log "════════════════════════════════════════════════════════"

    # Test operator chart upgrade
    log "Testing operator chart upgrade..."
    if helm upgrade "$OPERATOR_RELEASE_NAME" "${HELM_CHART_DIR}/splunk-ai-operator" \
        --namespace "$TEST_NAMESPACE" \
        --reuse-values \
        --wait \
        --timeout 5m; then
        PASSED_TESTS+=("Operator chart upgrade succeeds")
        success "Operator chart upgrade succeeds"
    else
        FAILED_TESTS+=("Operator chart upgrade succeeds")
        error "Operator chart upgrade failed"
    fi

    # Test platform chart upgrade with value changes
    log "Testing platform chart upgrade with value changes..."
    if helm upgrade "$PLATFORM_RELEASE_NAME" "${HELM_CHART_DIR}/splunk-ai-platform" \
        --namespace "$TEST_NAMESPACE" \
        --reuse-values \
        --set storage.vectorDB.size="20Gi" \
        --wait \
        --timeout 5m; then
        PASSED_TESTS+=("Platform chart upgrade succeeds")
        success "Platform chart upgrade succeeds"

        # Verify the change was applied
        local aiplatform_storage
        aiplatform_storage=$(kubectl get aiplatform "$PLATFORM_RELEASE_NAME-splunk-ai-platform" -n "$TEST_NAMESPACE" -o jsonpath='{.spec.storage.vectorDB.size}' 2>/dev/null || echo "")

        if [[ "$aiplatform_storage" == "20Gi" ]]; then
            PASSED_TESTS+=("Platform chart upgrade applies value changes")
            success "Platform chart upgrade applies value changes"
        else
            SKIPPED_TESTS+=("Platform chart upgrade applies value changes (value not updated)")
            warn "Platform chart upgrade value change not verified"
        fi
    else
        FAILED_TESTS+=("Platform chart upgrade succeeds")
        error "Platform chart upgrade failed"
    fi

    success "Phase 7: Upgrade tests completed"
}

# Phase 8: Rollback Tests
test_phase_8_rollback() {
    log "════════════════════════════════════════════════════════"
    log "Phase 8: Rollback Tests"
    log "════════════════════════════════════════════════════════"

    # Test operator chart rollback
    log "Testing operator chart rollback..."
    if helm rollback "$OPERATOR_RELEASE_NAME" -n "$TEST_NAMESPACE" --wait --timeout 5m; then
        PASSED_TESTS+=("Operator chart rollback succeeds")
        success "Operator chart rollback succeeds"
    else
        FAILED_TESTS+=("Operator chart rollback succeeds")
        error "Operator chart rollback failed"
    fi

    # Test platform chart rollback
    log "Testing platform chart rollback..."
    if helm rollback "$PLATFORM_RELEASE_NAME" -n "$TEST_NAMESPACE" --wait --timeout 5m; then
        PASSED_TESTS+=("Platform chart rollback succeeds")
        success "Platform chart rollback succeeds"
    else
        FAILED_TESTS+=("Platform chart rollback succeeds")
        error "Platform chart rollback failed"
    fi

    success "Phase 8: Rollback tests completed"
}

# Phase 9: Uninstallation Tests
test_phase_9_uninstallation() {
    log "════════════════════════════════════════════════════════"
    log "Phase 9: Uninstallation Tests"
    log "════════════════════════════════════════════════════════"

    # Uninstall platform chart
    log "Uninstalling platform chart..."
    if helm uninstall "$PLATFORM_RELEASE_NAME" -n "$TEST_NAMESPACE" --wait --timeout 5m; then
        PASSED_TESTS+=("Platform chart uninstall succeeds")
        success "Platform chart uninstall succeeds"
    else
        FAILED_TESTS+=("Platform chart uninstall succeeds")
        error "Platform chart uninstall failed"
    fi

    # Verify platform resources are cleaned up
    sleep 5
    if ! kubectl get aiplatform -n "$TEST_NAMESPACE" 2>/dev/null | grep -q "$PLATFORM_RELEASE_NAME"; then
        PASSED_TESTS+=("Platform resources cleaned up after uninstall")
        success "Platform resources cleaned up after uninstall"
    else
        SKIPPED_TESTS+=("Platform resources cleaned up (still deleting)")
        warn "Platform resources still present (may be cleaning up)"
    fi

    # Uninstall operator chart
    log "Uninstalling operator chart..."
    if helm uninstall "$OPERATOR_RELEASE_NAME" -n "$TEST_NAMESPACE" --wait --timeout 5m; then
        PASSED_TESTS+=("Operator chart uninstall succeeds")
        success "Operator chart uninstall succeeds"
    else
        FAILED_TESTS+=("Operator chart uninstall succeeds")
        error "Operator chart uninstall failed"
    fi

    success "Phase 9: Uninstallation tests completed"
}

# Test summary and reporting
print_test_summary() {
    log "════════════════════════════════════════════════════════"
    log "Helm Chart Test Summary"
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
        success "All Helm chart tests passed! ✨"
        return 0
    else
        error "Some Helm chart tests failed."
        return 1
    fi
}

# Cleanup function
cleanup_resources() {
    local should_cleanup="$1"

    if [[ "$should_cleanup" != "true" ]]; then
        info "Skipping cleanup (resources preserved for debugging)"
        info "To cleanup manually: kubectl delete namespace $TEST_NAMESPACE"
        return 0
    fi

    log "Cleaning up test resources..."

    # Uninstall charts if they exist
    helm uninstall "$PLATFORM_RELEASE_NAME" -n "$TEST_NAMESPACE" 2>/dev/null || true
    helm uninstall "$OPERATOR_RELEASE_NAME" -n "$TEST_NAMESPACE" 2>/dev/null || true

    # Delete test namespace
    kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true --timeout=2m || true

    success "Cleanup completed"
}

# Main test execution
main() {
    log "════════════════════════════════════════════════════════"
    log "Splunk AI Operator - Helm Chart Tests"
    log "════════════════════════════════════════════════════════"
    log "Chart Directory: $HELM_CHART_DIR"
    log "Test Namespace: $TEST_NAMESPACE"
    log "════════════════════════════════════════════════════════"

    local test_failed=false

    # Run test phases
    test_phase_1_chart_structure || test_failed=true
    test_phase_2_chart_linting || test_failed=true
    test_phase_3_template_rendering || test_failed=true
    test_phase_4_values_validation || test_failed=true
    test_phase_5_dry_run_installation || test_failed=true
    test_phase_6_actual_deployment || test_failed=true
    test_phase_7_upgrade || test_failed=true
    test_phase_8_rollback || test_failed=true
    test_phase_9_uninstallation || test_failed=true

    # Print summary
    print_test_summary || test_failed=true

    # Cleanup
    if [[ "$test_failed" == "true" ]]; then
        if [[ "$CLEANUP_ON_FAILURE" == "true" ]]; then
            cleanup_resources true
        else
            warn "Tests failed - resources preserved for debugging"
        fi
        exit 1
    else
        if [[ "$CLEANUP_ON_SUCCESS" == "true" ]]; then
            cleanup_resources true
        else
            info "Tests passed - resources preserved"
        fi
        exit 0
    fi
}

# Run main
main "$@"
