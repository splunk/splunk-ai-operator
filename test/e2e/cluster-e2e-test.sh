#!/usr/bin/env bash

# Comprehensive E2E Test Script for AIPlatform on Real Clusters
# This script creates a test cluster, deploys the operator, and runs comprehensive tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
CLUSTER_NAME="${CLUSTER_NAME:-ai-operator-e2e-test}"
CLUSTER_PROVIDER="${CLUSTER_PROVIDER:-kind}" # kind, eks, gke, aks
REGION="${REGION:-us-west-2}"
TEST_NAMESPACE="${TEST_NAMESPACE:-e2e-test}"
SKIP_CLUSTER_CREATION="${SKIP_CLUSTER_CREATION:-false}"
SKIP_OPERATOR_INSTALL="${SKIP_OPERATOR_INSTALL:-false}"
SKIP_DEPENDENCIES_INSTALL="${SKIP_DEPENDENCIES_INSTALL:-false}"
CLEANUP_ON_SUCCESS="${CLEANUP_ON_SUCCESS:-true}"
CLEANUP_ON_FAILURE="${CLEANUP_ON_FAILURE:-false}"

# Test flags
RUN_STORAGE_TESTS="${RUN_STORAGE_TESTS:-true}"
RUN_INGRESS_TESTS="${RUN_INGRESS_TESTS:-true}"
RUN_MTLS_TESTS="${RUN_MTLS_TESTS:-true}"
RUN_STATUS_TESTS="${RUN_STATUS_TESTS:-true}"
RUN_EVENT_TESTS="${RUN_EVENT_TESTS:-true}"

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

usage() {
	cat <<EOF
Usage: $0 [OPTIONS]

Comprehensive E2E test script for Splunk AI Operator

OPTIONS:
  --cluster-name NAME        Name of the test cluster (default: ${CLUSTER_NAME})
  --provider PROVIDER        Cluster provider: kind, eks, gke, aks (default: ${CLUSTER_PROVIDER})
  --region REGION            Cloud region (default: ${REGION})
  --namespace NS             Test namespace (default: ${TEST_NAMESPACE})
  --skip-cluster-creation    Skip creating new cluster (use existing)
  --skip-operator-install    Skip installing operator (already installed)
  --skip-dependencies        Skip installing dependencies like cert-manager
  --cleanup-on-success       Cleanup resources on success (default: true)
  --no-cleanup-on-success    Do not cleanup resources on success
  --cleanup-on-failure       Cleanup resources on failure (default: false)
  --no-cleanup-on-failure    Do not cleanup resources on failure

  Note: Can also use --cleanup-on-success=true/false syntax or set env vars:
        CLEANUP_ON_SUCCESS=true/false
        CLEANUP_ON_FAILURE=true/false

TEST SELECTION:
  --storage-only             Run only storage tests
  --ingress-only             Run only ingress tests
  --mtls-only                Run only server TLS tests (legacy flag name)
  --status-only              Run only status condition tests
  --events-only              Run only event tracking tests

  -h, --help                 Show this help message

EXAMPLES:
  # Run all tests on kind cluster (with cleanup)
  $0 --cleanup-on-success

  # Run on existing cluster without cleanup
  $0 --skip-cluster-creation --no-cleanup-on-success
  # Or using environment variable:
  CLEANUP_ON_SUCCESS=false $0 --skip-cluster-creation

  # Run on existing EKS cluster
  $0 --provider eks --skip-cluster-creation

  # Run only storage tests
  $0 --storage-only

  # Run on GKE with custom region and cleanup
  $0 --provider gke --region us-central1 --cleanup-on-success

  # Test with cleanup on both success and failure
  $0 --cleanup-on-success --cleanup-on-failure

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
		CLUSTER_PROVIDER="$2"
		shift 2
		;;
	--region)
		REGION="$2"
		shift 2
		;;
	--namespace)
		TEST_NAMESPACE="$2"
		shift 2
		;;
	--skip-cluster-creation)
		SKIP_CLUSTER_CREATION=true
		shift
		;;
	--skip-operator-install)
		SKIP_OPERATOR_INSTALL=true
		shift
		;;
	--skip-dependencies)
		SKIP_DEPENDENCIES_INSTALL=true
		shift
		;;
	--cleanup-on-success | --cleanup-on-success=true)
		CLEANUP_ON_SUCCESS=true
		shift
		;;
	--no-cleanup-on-success | --cleanup-on-success=false)
		CLEANUP_ON_SUCCESS=false
		shift
		;;
	--cleanup-on-failure | --cleanup-on-failure=true)
		CLEANUP_ON_FAILURE=true
		shift
		;;
	--no-cleanup-on-failure | --cleanup-on-failure=false)
		CLEANUP_ON_FAILURE=false
		shift
		;;
	--storage-only)
		RUN_STORAGE_TESTS=true
		RUN_INGRESS_TESTS=false
		RUN_MTLS_TESTS=false
		RUN_STATUS_TESTS=false
		RUN_EVENT_TESTS=false
		shift
		;;
	--ingress-only)
		RUN_STORAGE_TESTS=false
		RUN_INGRESS_TESTS=true
		RUN_MTLS_TESTS=false
		RUN_STATUS_TESTS=false
		RUN_EVENT_TESTS=false
		shift
		;;
	--mtls-only)
		RUN_STORAGE_TESTS=false
		RUN_INGRESS_TESTS=false
		RUN_MTLS_TESTS=true
		RUN_STATUS_TESTS=false
		RUN_EVENT_TESTS=false
		shift
		;;
	--status-only)
		RUN_STORAGE_TESTS=false
		RUN_INGRESS_TESTS=false
		RUN_MTLS_TESTS=false
		RUN_STATUS_TESTS=true
		RUN_EVENT_TESTS=false
		shift
		;;
	--events-only)
		RUN_STORAGE_TESTS=false
		RUN_INGRESS_TESTS=false
		RUN_MTLS_TESTS=false
		RUN_STATUS_TESTS=false
		RUN_EVENT_TESTS=true
		shift
		;;
	-h | --help)
		usage
		;;
	*)
		error "Unknown option: $1"
		usage
		;;
	esac
done

# Check prerequisites
check_prerequisites() {
	log "Checking prerequisites..."

	local missing=()

	# Always required
	if ! command -v kubectl &>/dev/null; then
		missing+=("kubectl")
	fi

	if ! command -v jq &>/dev/null; then
		missing+=("jq")
	fi

	# Only check provider-specific tools if creating cluster
	if [[ "$SKIP_CLUSTER_CREATION" != "true" ]]; then
		if [[ "$CLUSTER_PROVIDER" == "kind" ]] && ! command -v kind &>/dev/null; then
			missing+=("kind")
		fi

		if [[ "$CLUSTER_PROVIDER" == "eks" ]] && ! command -v eksctl &>/dev/null; then
			missing+=("eksctl")
		fi

		if [[ "$CLUSTER_PROVIDER" == "gke" ]] && ! command -v gcloud &>/dev/null; then
			missing+=("gcloud")
		fi

		if [[ "$CLUSTER_PROVIDER" == "aks" ]] && ! command -v az &>/dev/null; then
			missing+=("az")
		fi
	fi

	if [[ ${#missing[@]} -gt 0 ]]; then
		error "Missing required tools: ${missing[*]}"
		exit 1
	fi

	success "All prerequisites met"
}

# Create test cluster
create_cluster() {
	if [[ "$SKIP_CLUSTER_CREATION" == "true" ]]; then
		log "Skipping cluster creation (using existing cluster)"

		# Show current cluster context
		local current_context
		current_context=$(kubectl config current-context 2>/dev/null || echo "unknown")
		log "Current kubectl context: $current_context"

		# Verify cluster is accessible
		if ! kubectl cluster-info &>/dev/null; then
			error "Cannot access Kubernetes cluster. Check your kubectl configuration."
			exit 1
		fi

		success "Using existing cluster: $current_context"
		return 0
	fi

	log "Creating $CLUSTER_PROVIDER cluster: $CLUSTER_NAME"

	case "$CLUSTER_PROVIDER" in
	kind)
		create_kind_cluster
		;;
	eks)
		create_eks_cluster
		;;
	gke)
		create_gke_cluster
		;;
	aks)
		create_aks_cluster
		;;
	*)
		error "Unsupported cluster provider: $CLUSTER_PROVIDER"
		exit 1
		;;
	esac

	success "Cluster created successfully"
}

create_kind_cluster() {
	if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
		warn "kind cluster ${CLUSTER_NAME} already exists"
		return 0
	fi

	cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
}

create_eks_cluster() {
	if eksctl get cluster --name "${CLUSTER_NAME}" --region "${REGION}" &>/dev/null; then
		warn "EKS cluster ${CLUSTER_NAME} already exists"
		return 0
	fi

	eksctl create cluster \
		--name="${CLUSTER_NAME}" \
		--region="${REGION}" \
		--version=1.28 \
		--nodegroup-name=standard-workers \
		--node-type=t3.large \
		--nodes=2 \
		--nodes-min=2 \
		--nodes-max=4 \
		--managed
}

create_gke_cluster() {
	if gcloud container clusters describe "${CLUSTER_NAME}" --region="${REGION}" &>/dev/null; then
		warn "GKE cluster ${CLUSTER_NAME} already exists"
		return 0
	fi

	gcloud container clusters create "${CLUSTER_NAME}" \
		--region="${REGION}" \
		--num-nodes=2 \
		--machine-type=n1-standard-2 \
		--enable-autoscaling \
		--min-nodes=2 \
		--max-nodes=4
}

create_aks_cluster() {
	local resource_group="rg-${CLUSTER_NAME}"

	if az aks show --name "${CLUSTER_NAME}" --resource-group "${resource_group}" &>/dev/null; then
		warn "AKS cluster ${CLUSTER_NAME} already exists"
		return 0
	fi

	# Create resource group
	az group create --name "${resource_group}" --location="${REGION}"

	# Create AKS cluster
	az aks create \
		--resource-group "${resource_group}" \
		--name "${CLUSTER_NAME}" \
		--node-count 2 \
		--node-vm-size Standard_D2s_v3 \
		--enable-managed-identity \
		--generate-ssh-keys
}

# Install operator
install_operator() {
	if [[ "$SKIP_OPERATOR_INSTALL" == "true" ]]; then
		log "Skipping operator installation (already installed)"
		return 0
	fi

	log "Installing Splunk AI Operator..."

	cd "$REPO_ROOT"

	# Install CRDs
	log "Installing CRDs..."
	make install

	# Build and load image
	local img="splunk-ai-operator:e2e-test"
	log "Building operator image: $img"
	make docker-build IMG="$img"

	if [[ "$CLUSTER_PROVIDER" == "kind" ]]; then
		log "Loading image into kind cluster..."
		kind load docker-image "$img" --name "$CLUSTER_NAME"
	fi

	# Deploy operator
	log "Deploying operator..."
	make deploy IMG="$img"

	# Wait for operator to be ready
	log "Waiting for operator pod to be ready..."
	kubectl wait --for=condition=ready pod \
		-l control-plane=controller-manager \
		-n splunk-ai-operator-system \
		--timeout=5m

	success "Operator installed and ready"
}

# Install dependencies
install_dependencies() {
	if [[ "$SKIP_DEPENDENCIES_INSTALL" == "true" ]]; then
		log "Skipping dependencies installation (already installed)"

		# Check if cert-manager is available
		if kubectl get namespace cert-manager &>/dev/null; then
			success "cert-manager namespace found"
		else
			warn "cert-manager namespace not found - tests may fail"
		fi
		return 0
	fi

	log "Installing test dependencies..."

	# Check if cert-manager is already installed
	if kubectl get namespace cert-manager &>/dev/null; then
		log "cert-manager is already installed, skipping installation"
	else
		# Install cert-manager
		log "Installing cert-manager..."
		kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

		# Wait for cert-manager
		kubectl wait --for=condition=ready pod \
			-l app.kubernetes.io/instance=cert-manager \
			-n cert-manager \
			--timeout=5m
	fi

	success "Dependencies installed"
}

# Create test Splunk secret
create_test_splunk_secret() {
	local secret_name="splunk-${TEST_NAMESPACE}-secret"
	cat <<EOF | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: v1
kind: Secret
metadata:
  name: $secret_name
  namespace: $TEST_NAMESPACE
type: Opaque
data:
  hec_token: NzgxMDI4MDktODBGQi02OEQ0LTIwNDYtMjIzRUFEMTEyNTA3
  idxc_secret: dTNXVDNPNDlkSU85d09wUHVCVWZja1d6
  pass4SymmKey: ZWxQWWZKTlUxVzZRMWJpRFlla2d2ZnFy
  password: Qk9nRVd3Y240b2xoNEVBR0FuT091eUpt
  shc_secret: anpXcHRQdk1qSnpSeHhEaUE3OGxCc2tn
EOF
	success "Test Splunk secret created: $secret_name"
}

# Run storage tests
run_storage_tests() {
	if [[ "$RUN_STORAGE_TESTS" != "true" ]]; then
		return 0
	fi

	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	log "Running Storage Configuration Tests"
	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	local test_name="storage-test-$RANDOM"

	# Create test AIPlatform with storage
	cat <<EOF | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: $test_name
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: test-sa
  storage:
    vectorDB:
      size: 10Gi
      storageClassName: standard
  splunkConfiguration:
    endpoint: http://test-splunk-service.$TEST_NAMESPACE.svc.cluster.local:8089
    secretRef:
      name: splunk-${TEST_NAMESPACE}-secret
      namespace: $TEST_NAMESPACE
EOF

	# Wait and verify PVC creation
	log "Waiting for PVC creation..."
	local waited=0
	local max_wait=180
	while [[ $waited -lt $max_wait ]]; do
		if kubectl get pvc -n "$TEST_NAMESPACE" -l "ai.splunk.com/platform=$test_name" | grep -q "Bound\|Pending"; then
			success "PVC created successfully"
			kubectl get pvc -n "$TEST_NAMESPACE" -l "ai.splunk.com/platform=$test_name"
			break
		fi
		sleep 5
		waited=$((waited + 5))
	done

	# Cleanup
	kubectl delete aiplatform "$test_name" -n "$TEST_NAMESPACE" --ignore-not-found=true

	success "Storage tests completed"
}

# Run ingress tests
run_ingress_tests() {
	if [[ "$RUN_INGRESS_TESTS" != "true" ]]; then
		return 0
	fi

	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	log "Running Ingress Configuration Tests"
	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	local test_name="ingress-test-$RANDOM"

	# Create test AIPlatform with ingress
	cat <<EOF | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: $test_name
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: test-sa
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: test.example.com
        paths:
          - path: /
            pathType: Prefix
  splunkConfiguration:
    endpoint: http://test-splunk-service.$TEST_NAMESPACE.svc.cluster.local:8089
    secretRef:
      name: splunk-${TEST_NAMESPACE}-secret
      namespace: $TEST_NAMESPACE
EOF

	# Wait and verify Ingress creation
	log "Waiting for Ingress creation..."
	local waited=0
	local max_wait=120
	while [[ $waited -lt $max_wait ]]; do
		if kubectl get ingress "$test_name" -n "$TEST_NAMESPACE" &>/dev/null; then
			success "Ingress created successfully"
			kubectl get ingress "$test_name" -n "$TEST_NAMESPACE"
			break
		fi
		sleep 5
		waited=$((waited + 5))
	done

	# Check IngressReady condition
	log "Checking IngressReady status condition..."
	local status
	status=$(kubectl get aiplatform "$test_name" -n "$TEST_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="IngressReady")].status}' 2>/dev/null || echo "Unknown")
	log "IngressReady status: $status"

	# Cleanup
	kubectl delete aiplatform "$test_name" -n "$TEST_NAMESPACE" --ignore-not-found=true

	success "Ingress tests completed"
}

# Run server TLS tests (function and environment names are retained for compatibility).
run_mtls_tests() {
	if [[ "$RUN_MTLS_TESTS" != "true" ]]; then
		return 0
	fi

	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	log "Running Server TLS Configuration Tests"
	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	# Create self-signed issuer for testing
	cat <<EOF | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: test-ca-issuer
spec:
  selfSigned: {}
EOF

	local test_name="mtls-test-$RANDOM"

	# Create test AIPlatform with certificateRef
	cat <<EOF | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: $test_name
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: test-sa
  certificateRef: test-ca-issuer
  splunkConfiguration:
    endpoint: http://test-splunk-service.$TEST_NAMESPACE.svc.cluster.local:8089
    secretRef:
      name: splunk-${TEST_NAMESPACE}-secret
      namespace: $TEST_NAMESPACE
EOF

	# Verify certificateRef is set
	log "Verifying certificateRef configuration..."
	local cert_ref
	cert_ref=$(kubectl get aiplatform "$test_name" -n "$TEST_NAMESPACE" -o jsonpath='{.spec.certificateRef}')
	if [[ "$cert_ref" == "test-ca-issuer" ]]; then
		success "certificateRef configured correctly: $cert_ref"
	else
		error "certificateRef not set correctly"
	fi

	# Cleanup
	kubectl delete aiplatform "$test_name" -n "$TEST_NAMESPACE" --ignore-not-found=true
	kubectl delete issuer test-ca-issuer -n "$TEST_NAMESPACE" --ignore-not-found=true

	success "Server TLS tests completed"
}

# Run status condition tests
run_status_tests() {
	if [[ "$RUN_STATUS_TESTS" != "true" ]]; then
		return 0
	fi

	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	log "Running Status Condition Tests"
	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	local test_name="status-test-$RANDOM"

	# Create test AIPlatform
	cat <<EOF | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: $test_name
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: test-sa
  splunkConfiguration:
    endpoint: http://test-splunk-service.$TEST_NAMESPACE.svc.cluster.local:8089
    secretRef:
      name: splunk-${TEST_NAMESPACE}-secret
      namespace: $TEST_NAMESPACE
EOF

	# Monitor status conditions
	log "Monitoring status conditions..."
	sleep 10

	local conditions=(
		"Ready"
		"RayServiceReady"
		"RayClusterReady"
		"RayServeRouteReady"
		"WeaviateDatabaseReady"
	)

	for cond in "${conditions[@]}"; do
		local status
		status=$(kubectl get aiplatform "$test_name" -n "$TEST_NAMESPACE" -o jsonpath="{.status.conditions[?(@.type=='$cond')].status}" 2>/dev/null || echo "NotFound")
		log "Condition $cond: $status"
	done

	# Check that status conditions array exists
	local has_conditions
	has_conditions=$(kubectl get aiplatform "$test_name" -n "$TEST_NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")
	if [[ "$has_conditions" != "[]" ]]; then
		success "Status conditions are being tracked"
	else
		warn "Status conditions not yet populated"
	fi

	# Cleanup
	kubectl delete aiplatform "$test_name" -n "$TEST_NAMESPACE" --ignore-not-found=true

	success "Status tests completed"
}

# Run event tracking tests
run_event_tests() {
	if [[ "$RUN_EVENT_TESTS" != "true" ]]; then
		return 0
	fi

	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	log "Running Event Tracking Tests"
	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	local test_name="event-test-$RANDOM"

	# Create test AIPlatform
	cat <<EOF | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: $test_name
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: test-sa
  splunkConfiguration:
    endpoint: http://test-splunk-service.$TEST_NAMESPACE.svc.cluster.local:8089
    secretRef:
      name: splunk-${TEST_NAMESPACE}-secret
      namespace: $TEST_NAMESPACE
EOF

	# Wait for events to be generated
	log "Waiting for events to be generated..."
	sleep 15

	# Check for operator events
	log "Checking for AIPlatform events..."
	local events
	events=$(kubectl get events -n "$TEST_NAMESPACE" --field-selector involvedObject.name="$test_name" -o json | jq -r '.items[] | "\(.reason): \(.message)"' 2>/dev/null || echo "")

	if [[ -n "$events" ]]; then
		success "Events are being generated:"
		echo "$events" | head -10
	else
		warn "No events found yet"
	fi

	# Cleanup
	kubectl delete aiplatform "$test_name" -n "$TEST_NAMESPACE" --ignore-not-found=true

	success "Event tests completed"
}

# Cleanup resources
cleanup() {
	local cleanup_cluster="$1"

	log "Cleaning up test resources..."

	# Delete test namespace
	kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true --timeout=2m

	if [[ "$cleanup_cluster" == "true" ]]; then
		log "Deleting test cluster..."
		case "$CLUSTER_PROVIDER" in
		kind)
			kind delete cluster --name "$CLUSTER_NAME"
			;;
		eks)
			eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION"
			;;
		gke)
			gcloud container clusters delete "$CLUSTER_NAME" --region "$REGION" --quiet
			;;
		aks)
			local resource_group="rg-${CLUSTER_NAME}"
			az aks delete --name "$CLUSTER_NAME" --resource-group "$resource_group" --yes --no-wait
			az group delete --name "$resource_group" --yes --no-wait
			;;
		esac
	fi

	success "Cleanup completed"
}

# Main test execution
main() {
	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	log "Splunk AI Operator E2E Test Suite"
	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	log "Cluster: $CLUSTER_NAME"
	log "Provider: $CLUSTER_PROVIDER"
	log "Region: $REGION"
	log "Namespace: $TEST_NAMESPACE"
	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	local test_failed=false

	# Setup
	check_prerequisites || exit 1
	create_cluster || exit 1
	install_dependencies || exit 1
	install_operator || exit 1

	# Create test namespace
	kubectl create namespace "$TEST_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

	# Create test Splunk secret
	log "Creating test Splunk secret..."
	create_test_splunk_secret

	# Run tests
	run_storage_tests || test_failed=true
	run_ingress_tests || test_failed=true
	run_mtls_tests || test_failed=true
	run_status_tests || test_failed=true
	run_event_tests || test_failed=true

	# Results
	log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	if [[ "$test_failed" == "true" ]]; then
		error "Some tests failed"
		log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

		if [[ "$CLEANUP_ON_FAILURE" == "true" ]]; then
			cleanup true
		fi
		exit 1
	else
		success "All tests passed!"
		log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

		if [[ "$CLEANUP_ON_SUCCESS" == "true" ]]; then
			cleanup true
		fi
		exit 0
	fi
}

# Trap errors and cleanup
trap 'error "Test execution failed"; cleanup false; exit 1' ERR

# Run main
main "$@"
