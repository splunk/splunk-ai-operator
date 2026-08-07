# VERSION defines the project version for the bundle.
# Update this value when you upgrade the version of your project.
# To re-generate a bundle for another specific version without changing the standard setup, you can:
# - use the VERSION as arg of the bundle target (e.g make bundle VERSION=0.0.2)
# - use environment variables to overwrite this value (e.g export VERSION=0.0.2)
VERSION ?= 0.0.1

# CHANNELS define the bundle channels used in the bundle.
# Add a new line here if you would like to change its default config. (E.g CHANNELS = "candidate,fast,stable")
# To re-generate a bundle for other specific channels without changing the standard setup, you can:
# - use the CHANNELS as arg of the bundle target (e.g make bundle CHANNELS=candidate,fast,stable)
# - use environment variables to overwrite this value (e.g export CHANNELS="candidate,fast,stable")
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif

# DEFAULT_CHANNEL defines the default channel used in the bundle.
# Add a new line here if you would like to change its default config. (E.g DEFAULT_CHANNEL = "stable")
# To re-generate a bundle for any other default channel without changing the default setup, you can:
# - use the DEFAULT_CHANNEL as arg of the bundle target (e.g make bundle DEFAULT_CHANNEL=stable)
# - use environment variables to overwrite this value (e.g export DEFAULT_CHANNEL="stable")
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# IMAGE_TAG_BASE defines the docker.io namespace and part of the image name for remote images.
# This variable is used to construct full image tags for bundle and catalog images.
#
# For example, running 'make bundle-build bundle-push catalog-build catalog-push' will build and push both
# splunk.com/splunk-ai-operator-bundle:$VERSION and splunk.com/splunk-ai-operator-catalog:$VERSION.
IMAGE_TAG_BASE ?= splunk.com/splunk-ai-operator

# BUNDLE_IMG defines the image:tag used for the bundle.
# You can use it as an arg. (E.g make bundle-build BUNDLE_IMG=<some-registry>/<project-name-bundle>:<tag>)
BUNDLE_IMG ?= $(IMAGE_TAG_BASE)-bundle:v$(VERSION)

# BUNDLE_GEN_FLAGS are the flags passed to the operator-sdk generate bundle command
BUNDLE_GEN_FLAGS ?= -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)

# USE_IMAGE_DIGESTS defines if images are resolved via tags or digests
# You can enable this value if you would like to use SHA Based Digests
# To enable set flag to true
USE_IMAGE_DIGESTS ?= false
ifeq ($(USE_IMAGE_DIGESTS), true)
	BUNDLE_GEN_FLAGS += --use-image-digests
endif

# Set the Operator SDK version to use. By default, what is installed on the system is used.
# This is useful for CI or a project to utilize a specific version of the operator-sdk toolkit.
OPERATOR_SDK_VERSION ?= v1.40.0
# Image URL to use all building/pushing image targets
IMG ?= controller:latest

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# CONTAINER_TOOL defines the container tool to be used for building images.
# Be aware that the target commands are only tested with Docker which is
# scaffolded by default. However, you might want to replace it to use other
# tools. (i.e. podman)
CONTAINER_TOOL ?= docker

# GO_VERSION is read from .env if not already set, and passed as a build-arg to docker builds.
GO_VERSION ?= $(shell grep '^GO_VERSION=' .env | cut -d= -f2)

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk command is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: test
test: manifests generate fmt vet setup-envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" go test $$(go list ./... | grep -v /e2e) -coverprofile cover.out

# TODO(user): To use a different vendor for e2e tests, modify the setup under 'tests/e2e'.
# The default setup assumes Kind is pre-installed and builds/loads the Manager Docker image locally.
# CertManager is installed by default; skip with:
# - CERT_MANAGER_INSTALL_SKIP=true
.PHONY: e2e-all
e2e-all:
	IMG=$(IMG) go test ./test/e2e/... -v -ginkgo.v -ginkgo.progress

e2e-manager:
	IMG=$(IMG) go test ./test/e2e/specs -run Manager -v -ginkgo.v -ginkgo.progress

e2e-ai:
	OPERATOR_NAMESPACE?=splunk-ai-operator-system
	WORKLOAD_NAMESPACE?=aiplatform-e2e
	AIPLATFORM_SAMPLE?=config/samples/ai.splunk.com_v1alpha1_aiplatform.yaml
	AISERVICE_SAMPLE?=config/samples/ai.splunk.com_v1alpha1_aiservice_saia.yaml
	AIPLATFORM_NAME?=testtenant
	AISERVICE_NAME?=saia
	FORWARD_SERVICE?=saia-gateway
	IMG=$(IMG) OPERATOR_NAMESPACE=$(OPERATOR_NAMESPACE) WORKLOAD_NAMESPACE=$(WORKLOAD_NAMESPACE) \
	AIPLATFORM_SAMPLE=$(AIPLATFORM_SAMPLE) AISERVICE_SAMPLE=$(AISERVICE_SAMPLE) \
	AIPLATFORM_NAME=$(AIPLATFORM_NAME) AISERVICE_NAME=$(AISERVICE_NAME) \
	FORWARD_SERVICE=$(FORWARD_SERVICE) \
	go test ./test/e2e/specs -run "AIPlatform.*" -v -ginkgo.v -ginkgo.progress

# Comprehensive E2E tests for all AIPlatform features
.PHONY: e2e-comprehensive
e2e-comprehensive: ## Run comprehensive E2E tests (storage, ingress, server TLS, status, events)
	IMG=$(IMG) go test ./test/e2e/specs -run "AIPlatform Comprehensive" -v -ginkgo.v -ginkgo.progress

# Run specific feature tests
.PHONY: e2e-storage
e2e-storage: ## Run storage configuration E2E tests
	IMG=$(IMG) go test ./test/e2e/specs -run "Storage Configuration" -v -ginkgo.v -ginkgo.progress

.PHONY: e2e-ingress
e2e-ingress: ## Run ingress configuration E2E tests
	IMG=$(IMG) go test ./test/e2e/specs -run "Ingress Configuration" -v -ginkgo.v -ginkgo.progress

.PHONY: e2e-mtls
e2e-mtls: ## Run server TLS configuration E2E tests (legacy target name)
	IMG=$(IMG) go test ./test/e2e/specs -run "Server TLS Configuration" -v -ginkgo.v -ginkgo.progress

.PHONY: e2e-status
e2e-status: ## Run status condition E2E tests
	IMG=$(IMG) go test ./test/e2e/specs -run "Status Conditions" -v -ginkgo.v -ginkgo.progress

.PHONY: e2e-events
e2e-events: ## Run event tracking E2E tests
	IMG=$(IMG) go test ./test/e2e/specs -run "Event Tracking" -v -ginkgo.v -ginkgo.progress

.PHONY: e2e-health
e2e-health: ## Run component health E2E tests
	IMG=$(IMG) go test ./test/e2e/specs -run "Component Health" -v -ginkgo.v -ginkgo.progress

.PHONY: e2e-webhook
e2e-webhook: ## Run webhook validation E2E tests
	IMG=$(IMG) go test ./test/e2e/specs -run "Webhook Validation" -v -ginkgo.v -ginkgo.progress

# Cluster E2E tests - creates cluster and runs full test suite
.PHONY: e2e-cluster-kind
e2e-cluster-kind: ## Run E2E tests on kind cluster (creates and destroys cluster)
	./test/e2e/cluster-e2e-test.sh --provider kind --cleanup-on-success

.PHONY: e2e-cluster-eks
e2e-cluster-eks: ## Run E2E tests on EKS cluster (creates and destroys cluster)
	./test/e2e/cluster-e2e-test.sh --provider eks --region us-west-2 --cleanup-on-success

.PHONY: e2e-cluster-gke
e2e-cluster-gke: ## Run E2E tests on GKE cluster (creates and destroys cluster)
	./test/e2e/cluster-e2e-test.sh --provider gke --region us-central1 --cleanup-on-success

.PHONY: e2e-cluster-existing
e2e-cluster-existing: ## Run E2E tests on existing cluster (no creation/deletion)
	CLEANUP_ON_SUCCESS=false ./test/e2e/cluster-e2e-test.sh --skip-cluster-creation --skip-operator-install --skip-dependencies

.PHONY: lint
lint: golangci-lint ## Run golangci-lint linter
	$(GOLANGCI_LINT) run

.PHONY: lint-fix
lint-fix: golangci-lint ## Run golangci-lint linter and perform fixes
	$(GOLANGCI_LINT) run --fix

.PHONY: lint-config
lint-config: golangci-lint ## Verify golangci-lint linter configuration
	$(GOLANGCI_LINT) config verify

##@ Build

.PHONY: build
build: manifests generate fmt vet ## Build manager binary.
	go build -o bin/manager cmd/main.go

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./cmd/main.go

# If you wish to build the manager image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
docker-build: ## Build docker image with the manager.
	$(CONTAINER_TOOL) build --build-arg GO_VERSION=$(GO_VERSION) -t ${IMG} .

.PHONY: docker-build-amd64
docker-build-amd64: ## Build docker image for linux/amd64 (e.g. for x86_64 servers/EC2).
	$(CONTAINER_TOOL) build --platform=linux/amd64 --build-arg GO_VERSION=$(GO_VERSION) -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	$(CONTAINER_TOOL) push ${IMG}

# PLATFORMS defines the target platforms for the manager image be built to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - be able to use docker buildx. More info: https://docs.docker.com/build/buildx/
# - have enabled BuildKit. More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image to your registry (i.e. if you do not set a valid value via IMG=<myregistry/image:<tag>> then the export will fail)
# To adequately provide solutions that are compatible with multiple platforms, you should consider using this option.
PLATFORMS ?= linux/arm64,linux/amd64 #,linux/s390x,linux/ppc64le
.PHONY: docker-buildx
docker-buildx: ## Build and push docker image for the manager for cross-platform support
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	- $(CONTAINER_TOOL) buildx create --name splunk-ai-operator-builder
	$(CONTAINER_TOOL) buildx use splunk-ai-operator-builder
	- $(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --build-arg GO_VERSION=$(GO_VERSION) --tag ${IMG} -f Dockerfile.cross .
	- $(CONTAINER_TOOL) buildx rm splunk-ai-operator-builder
	rm Dockerfile.cross

.PHONY: build-installer
build-installer: manifests generate kustomize ## Generate a consolidated YAML with CRDs and deployment.
	mkdir -p dist
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default > dist/install.yaml

.PHONY: generate-bom
generate-bom: ## Generate Bill of Materials (BOM) for release
	@echo "Generating Bill of Materials..."
	@mkdir -p dist
	@./scripts/generate-bom.sh $(VERSION) dist
	@echo "✅ BOM generated in dist/ directory"

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | $(KUBECTL) apply -f -

.PHONY: undeploy
undeploy: kustomize ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: generate-artifacts
generate-artifacts: sync-crd-artifacts kustomize ## Generate artifacts for the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/default > artifacts.yaml

.PHONY: sync-crd-artifacts
sync-crd-artifacts: manifests ## Sync canonical CRDs to Helm and the cluster-setup bundle without changing its image overrides.
	@echo "Syncing generated CRDs to distribution copies..."
	@cp config/crd/bases/*.yaml helm-chart/splunk-ai-operator/crds/
	@bash hack/sync-crd-artifacts.sh sync

.PHONY: check-crd-artifacts
check-crd-artifacts: ## Verify that all distributed CRD copies match config/crd/bases/.
	@for crd in config/crd/bases/*.yaml; do \
		name=$$(basename "$$crd"); \
		if ! cmp -s "$$crd" "helm-chart/splunk-ai-operator/crds/$$name"; then \
			echo "helm-chart/splunk-ai-operator/crds/$$name is stale; run 'make sync-crd-artifacts'." >&2; \
			diff -u "helm-chart/splunk-ai-operator/crds/$$name" "$$crd" || true; \
			exit 1; \
		fi; \
	done
	@bash hack/sync-crd-artifacts.sh check

##@ Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KUBECTL ?= kubectl
KIND ?= kind
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest
GOLANGCI_LINT = $(LOCALBIN)/golangci-lint

## Tool Versions
KUSTOMIZE_VERSION ?= v5.6.0
CONTROLLER_TOOLS_VERSION ?= v0.17.2
#ENVTEST_VERSION is the version of controller-runtime release branch to fetch the envtest setup script (i.e. release-0.20)
ENVTEST_VERSION ?= $(shell go list -m -f "{{ .Version }}" sigs.k8s.io/controller-runtime | awk -F'[v.]' '{printf "release-%d.%d", $$2, $$3}')
#ENVTEST_K8S_VERSION is the version of Kubernetes to use for setting up ENVTEST binaries (i.e. 1.31)
ENVTEST_K8S_VERSION ?= $(shell go list -m -f "{{ .Version }}" k8s.io/api | awk -F'[v.]' '{printf "1.%d", $$3}')
GOLANGCI_LINT_VERSION ?= v1.63.4

.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary.
$(KUSTOMIZE): $(LOCALBIN)
	$(call go-install-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v5,$(KUSTOMIZE_VERSION))

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN): $(LOCALBIN)
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen,$(CONTROLLER_TOOLS_VERSION))

.PHONY: setup-envtest
setup-envtest: envtest ## Download the binaries required for ENVTEST in the local bin directory.
	@echo "Setting up envtest binaries for Kubernetes version $(ENVTEST_K8S_VERSION)..."
	@$(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path || { \
		echo "Error: Failed to set up envtest binaries for version $(ENVTEST_K8S_VERSION)."; \
		exit 1; \
	}

.PHONY: envtest
envtest: $(ENVTEST) ## Download setup-envtest locally if necessary.
$(ENVTEST): $(LOCALBIN)
	$(call go-install-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest,$(ENVTEST_VERSION))

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT) ## Download golangci-lint locally if necessary.
$(GOLANGCI_LINT): $(LOCALBIN)
	$(call go-install-tool,$(GOLANGCI_LINT),github.com/golangci/golangci-lint/cmd/golangci-lint,$(GOLANGCI_LINT_VERSION))

# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f "$(1)-$(3)" ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
rm -f $(1) || true ;\
GOBIN=$(LOCALBIN) go install $${package} ;\
mv $(1) $(1)-$(3) ;\
} ;\
ln -sf $(1)-$(3) $(1)
endef

.PHONY: operator-sdk
OPERATOR_SDK ?= $(LOCALBIN)/operator-sdk
operator-sdk: ## Download operator-sdk locally if necessary.
ifeq (,$(wildcard $(OPERATOR_SDK)))
ifeq (, $(shell which operator-sdk 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(OPERATOR_SDK)) ;\
	OS=$(shell go env GOOS) && ARCH=$(shell go env GOARCH) && \
	curl -sSLo $(OPERATOR_SDK) https://github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)/operator-sdk_$${OS}_$${ARCH} ;\
	chmod +x $(OPERATOR_SDK) ;\
	}
else
OPERATOR_SDK = $(shell which operator-sdk)
endif
endif

.PHONY: bundle
bundle: manifests kustomize operator-sdk ## Generate bundle manifests and metadata, then validate generated files.
	$(OPERATOR_SDK) generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | $(OPERATOR_SDK) generate bundle $(BUNDLE_GEN_FLAGS)
	$(OPERATOR_SDK) bundle validate ./bundle

.PHONY: bundle-build
bundle-build: ## Build the bundle image.
	$(CONTAINER_TOOL) build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push the bundle image.
	$(MAKE) docker-push IMG=$(BUNDLE_IMG)

.PHONY: opm
OPM = $(LOCALBIN)/opm
opm: ## Download opm locally if necessary.
ifeq (,$(wildcard $(OPM)))
ifeq (,$(shell which opm 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(OPM)) ;\
	OS=$(shell go env GOOS) && ARCH=$(shell go env GOARCH) && \
	curl -sSLo $(OPM) https://github.com/operator-framework/operator-registry/releases/download/v1.55.0/$${OS}-$${ARCH}-opm ;\
	chmod +x $(OPM) ;\
	}
else
OPM = $(shell which opm)
endif
endif

# A comma-separated list of bundle images (e.g. make catalog-build BUNDLE_IMGS=example.com/operator-bundle:v0.1.0,example.com/operator-bundle:v0.2.0).
# These images MUST exist in a registry and be pull-able.
BUNDLE_IMGS ?= $(BUNDLE_IMG)

# The image tag given to the resulting catalog image (e.g. make catalog-build CATALOG_IMG=example.com/operator-catalog:v0.2.0).
CATALOG_IMG ?= $(IMAGE_TAG_BASE)-catalog:v$(VERSION)

# Set CATALOG_BASE_IMG to an existing catalog image tag to add $BUNDLE_IMGS to that image.
ifneq ($(origin CATALOG_BASE_IMG), undefined)
FROM_INDEX_OPT := --from-index $(CATALOG_BASE_IMG)
endif

# Build a catalog image by adding bundle images to an empty catalog using the operator package manager tool, 'opm'.
# This recipe invokes 'opm' in 'semver' bundle add mode. For more information on add modes, see:
# https://github.com/operator-framework/community-operators/blob/7f1438c/docs/packaging-operator.md#updating-your-existing-operator
.PHONY: catalog-build
catalog-build: opm ## Build a catalog image.
	$(OPM) index add --container-tool $(CONTAINER_TOOL) --mode semver --tag $(CATALOG_IMG) --bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT)

# Push the catalog image.
.PHONY: catalog-push
catalog-push: ## Push a catalog image.
	$(MAKE) docker-push IMG=$(CATALOG_IMG)

.PHONY: setup/ginkgo
setup/ginkgo:
	@echo Installing ginkgo
	@go get github.com/onsi/ginkgo/v2
	@go install -mod=mod github.com/onsi/ginkgo/v2/ginkgo@latest
	@echo Installing gomega
	@go get github.com/onsi/gomega/...

##@ Helm Charts

HELM_CHART_VERSION ?= $(VERSION)
HELM_CHART_OPERATOR_DIR = helm-chart/splunk-ai-operator
HELM_CHART_PLATFORM_DIR = helm-chart/splunk-ai-platform
HELM_OUTPUT_DIR ?= dist/helm

.PHONY: helm-sync
helm-sync: sync-crd-artifacts kustomize ## Sync CRDs and RBAC from config/ to helm charts
	@echo "Syncing CRDs and RBAC to Helm charts..."
	@echo "  CRDs copied by sync-crd-artifacts."
	@echo "  Extracting RBAC from kustomize build..."
	@mkdir -p dist
	@$(KUSTOMIZE) build config/default > dist/install.yaml
	@echo "  Updating RBAC templates..."
	@# Extract ClusterRole from kustomize build and update helm template
	@echo "✓ CRDs synced to $(HELM_CHART_OPERATOR_DIR)/crds/"
	@echo "⚠️  RBAC sync requires manual review - check dist/install.yaml for latest ClusterRole"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Review dist/install.yaml for ClusterRole changes"
	@echo "  2. Update $(HELM_CHART_OPERATOR_DIR)/templates/rbac/role.yaml manually"
	@echo "  3. Run 'make helm-lint' to verify changes"

.PHONY: helm-lint
helm-lint: ## Lint Helm charts
	@echo "Linting Helm charts..."
	@helm lint $(HELM_CHART_OPERATOR_DIR)
	@helm lint $(HELM_CHART_PLATFORM_DIR)
	@echo "✓ Helm charts linting complete"

.PHONY: helm-package
helm-package: helm-lint ## Package Helm charts into tgz archives
	@echo "Packaging Helm charts..."
	@mkdir -p $(HELM_OUTPUT_DIR)
	@helm package $(HELM_CHART_OPERATOR_DIR) --version $(HELM_CHART_VERSION) --app-version $(VERSION) --destination $(HELM_OUTPUT_DIR)
	@helm package $(HELM_CHART_PLATFORM_DIR) --version $(HELM_CHART_VERSION) --app-version $(VERSION) --destination $(HELM_OUTPUT_DIR)
	@echo "✓ Helm charts packaged:"
	@ls -lh $(HELM_OUTPUT_DIR)/*.tgz

.PHONY: helm-index
helm-index: helm-package ## Generate Helm repository index
	@echo "Generating Helm repository index..."
	@helm repo index $(HELM_OUTPUT_DIR) --url https://github.com/splunk/splunk-ai-operator/releases/download/v$(VERSION)
	@echo "✓ Helm repository index generated: $(HELM_OUTPUT_DIR)/index.yaml"

.PHONY: helm-template
helm-template: ## Render Helm chart templates locally (for testing)
	@echo "Rendering splunk-ai-operator chart templates..."
	@helm template test-operator $(HELM_CHART_OPERATOR_DIR) --debug
	@echo ""
	@echo "Rendering splunk-ai-platform chart templates..."
	@helm template test-platform $(HELM_CHART_PLATFORM_DIR) --debug

.PHONY: helm-install-operator
helm-install-operator: ## Install splunk-ai-operator chart locally
	@echo "Installing splunk-ai-operator chart..."
	@helm upgrade --install splunk-ai-operator $(HELM_CHART_OPERATOR_DIR) \
		--namespace splunk-ai-operator --create-namespace \
		--set image.repository=$(IMG)
	@echo "✓ Operator installed. Check status:"
	@kubectl get pods -n splunk-ai-operator

.PHONY: helm-install-platform
helm-install-platform: ## Install splunk-ai-platform chart locally
	@echo "Installing splunk-ai-platform chart..."
	@echo "⚠️  Make sure to customize values first!"
	@helm upgrade --install splunk-ai-platform $(HELM_CHART_PLATFORM_DIR) \
		--namespace ai-platform --create-namespace
	@echo "✓ Platform installed. Check status:"
	@kubectl get aiplatform -n ai-platform

.PHONY: helm-uninstall
helm-uninstall: ## Uninstall both Helm charts
	@echo "Uninstalling Helm charts..."
	-@helm uninstall splunk-ai-platform -n ai-platform 2>/dev/null || true
	-@helm uninstall splunk-ai-operator -n splunk-ai-operator 2>/dev/null || true
	@echo "✓ Helm charts uninstalled"

.PHONY: helm-clean
helm-clean: ## Clean Helm build artifacts
	@echo "Cleaning Helm artifacts..."
	@rm -rf $(HELM_OUTPUT_DIR)
	@echo "✓ Helm artifacts cleaned"

.PHONY: helm-docs
helm-docs: ## Generate Helm chart README from values.yaml (requires helm-docs)
	@if command -v helm-docs >/dev/null 2>&1; then \
		echo "Generating Helm chart documentation..."; \
		helm-docs $(HELM_CHART_OPERATOR_DIR); \
		helm-docs $(HELM_CHART_PLATFORM_DIR); \
		echo "✓ Helm documentation generated"; \
	else \
		echo "⚠️  helm-docs not installed. Install: https://github.com/norwoodj/helm-docs"; \
	fi

.PHONY: helm-all
helm-all: helm-lint helm-package helm-index ## Build and package all Helm charts with index
	@echo "✓ All Helm operations complete"
	@echo ""
	@echo "📦 Packaged charts ready for release:"
	@ls -lh $(HELM_OUTPUT_DIR)/*.tgz
	@echo ""
	@echo "Next steps:"
	@echo "  1. Upload .tgz files to GitHub release"
	@echo "  2. Upload index.yaml to release"

##@ Zarf Operations

ZARF_VERSION ?= $(VERSION)
ZARF_DIR := tools/cluster_setup/zarf

.PHONY: zarf-check
zarf-check: ## Check if Zarf CLI is installed
	@if ! command -v zarf >/dev/null 2>&1; then \
		echo "❌ Zarf CLI not found. Install from: https://docs.zarf.dev/docs/getting-started#installing-zarf"; \
		exit 1; \
	else \
		echo "✓ Zarf CLI installed: $$(zarf version)"; \
	fi

.PHONY: zarf-build
zarf-build: zarf-check helm-package ## Build Zarf package for air-gapped deployment
	@echo "Building Zarf package..."
	@echo "⚠️  This will take 15-30 minutes depending on image sizes"
	@echo "⚠️  Ensure you're authenticated to all required registries (Docker Hub, ECR, etc.)"
	@cd $(ZARF_DIR) && zarf package create . --confirm
	@mv $(ZARF_DIR)/zarf-package-*.tar.zst . 2>/dev/null || true
	@echo "✓ Zarf package created in project root"

.PHONY: zarf-build-complete
zarf-build-complete: zarf-check helm-package ## Build complete Zarf package (k0s + operator + platform)
	@echo "=========================================="
	@echo "Building COMPLETE Zarf Package"
	@echo "=========================================="
	@echo "This package includes:"
	@echo "  • k0s cluster installation"
	@echo "  • Storage and networking"
	@echo "  • GPU support (optional)"
	@echo "  • Monitoring stack (optional)"
	@echo "  • Splunk AI Operator"
	@echo "  • Splunk Enterprise"
	@echo "  • AI Platform instance"
	@echo ""
	@echo "⚠️  This will take 45-90 minutes"
	@echo "⚠️  Package size will be 30-50GB"
	@echo "⚠️  Ensure you're authenticated to all registries"
	@echo ""
	@cd $(ZARF_DIR) && zarf package create . -f zarf-complete.yaml --confirm
	@mv $(ZARF_DIR)/zarf-package-splunk-ai-platform-complete-*.tar.zst . 2>/dev/null || true
	@echo ""
	@echo "=========================================="
	@echo "✓ Complete package created"
	@echo "=========================================="
	@ls -lh zarf-package-splunk-ai-platform-complete-*.tar.zst
	@echo ""
	@echo "This package can deploy everything from bare metal to AI Platform"
	@echo "See tools/cluster_setup/zarf/docs/COMPLETE_DEPLOYMENT.md"

.PHONY: zarf-inspect
zarf-inspect: ## Inspect the Zarf package contents
	@if ls zarf-package-*.tar.zst 1> /dev/null 2>&1; then \
		zarf package inspect zarf-package-*.tar.zst; \
	else \
		echo "❌ No Zarf package found. Run 'make zarf-build' first"; \
		exit 1; \
	fi

.PHONY: zarf-deploy
zarf-deploy: ## Deploy Zarf package to current Kubernetes cluster
	@if ls zarf-package-*.tar.zst 1> /dev/null 2>&1; then \
		echo "Deploying Zarf package to cluster..."; \
		zarf package deploy zarf-package-*.tar.zst --confirm; \
	else \
		echo "❌ No Zarf package found. Run 'make zarf-build' first"; \
		exit 1; \
	fi

.PHONY: zarf-deploy-minimal
zarf-deploy-minimal: ## Deploy only core operator components (no monitoring)
	@if ls zarf-package-*.tar.zst 1> /dev/null 2>&1; then \
		echo "Deploying minimal Zarf package (core + operator only)..."; \
		zarf package deploy zarf-package-*.tar.zst \
			--components=core-dependencies,splunk-ai-operator,ai-platform-images \
			--confirm; \
	else \
		echo "❌ No Zarf package found. Run 'make zarf-build' first"; \
		exit 1; \
	fi

.PHONY: zarf-deploy-full
zarf-deploy-full: ## Deploy full stack including monitoring
	@if ls zarf-package-*.tar.zst 1> /dev/null 2>&1; then \
		echo "Deploying full Zarf package (all components)..."; \
		zarf package deploy zarf-package-*.tar.zst \
			--components=core-dependencies,monitoring,splunk-ai-operator,ai-platform-images,ai-platform-instances \
			--confirm; \
	else \
		echo "❌ No Zarf package found. Run 'make zarf-build' first"; \
		exit 1; \
	fi

.PHONY: zarf-remove
zarf-remove: ## Remove deployed Zarf package
	@echo "Removing Zarf package deployment..."
	@zarf package remove splunk-ai-operator --confirm

.PHONY: zarf-clean
zarf-clean: ## Clean Zarf build artifacts
	@echo "Cleaning Zarf artifacts..."
	@rm -f zarf-package-*.tar.zst
	@rm -f zarf-sbom-*.tar
	@echo "✓ Zarf artifacts cleaned"

.PHONY: zarf-all
zarf-all: helm-all zarf-build zarf-inspect ## Build Helm charts and Zarf package
	@echo "✓ Zarf package ready for air-gapped deployment"
	@echo ""
	@echo "📦 Package files:"
	@ls -lh zarf-package-*.tar.zst
	@echo ""
	@echo "Next steps:"
	@echo "  1. Transfer package to air-gapped environment"
	@echo "  2. Run: zarf init --confirm"
	@echo "  3. Run: zarf package deploy <package-file> --confirm"
	@echo ""
	@echo "See tools/cluster_setup/zarf/docs/zarf-deployment.md for complete guide"
	@echo "  3. Update docs with new version"
