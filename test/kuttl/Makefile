# Makefile for running KUTTL tests

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: install-kuttl
install-kuttl: ## Install KUTTL CLI
	@echo "Installing KUTTL..."
	@if command -v kubectl-kuttl >/dev/null 2>&1; then \
		echo "KUTTL already installed"; \
		kubectl-kuttl version; \
	else \
		echo "Installing KUTTL..."; \
		VERSION=0.15.0; \
		OS=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
		ARCH=$$(uname -m); \
		if [ "$$ARCH" = "x86_64" ]; then ARCH="x86_64"; fi; \
		if [ "$$ARCH" = "arm64" ] || [ "$$ARCH" = "aarch64" ]; then ARCH="arm64"; fi; \
		curl -LO https://github.com/kudobuilder/kuttl/releases/download/v$${VERSION}/kubectl-kuttl_$${VERSION}_$${OS}_$${ARCH}; \
		chmod +x kubectl-kuttl_$${VERSION}_$${OS}_$${ARCH}; \
		sudo mv kubectl-kuttl_$${VERSION}_$${OS}_$${ARCH} /usr/local/bin/kubectl-kuttl; \
		kubectl-kuttl version; \
	fi

.PHONY: test
test: ## Run all KUTTL tests
	kubectl kuttl test

.PHONY: test-basic
test-basic: ## Run basic AIPlatform test
	kubectl kuttl test --test aiplatform-basic

.PHONY: test-ingress
test-ingress: ## Run ingress configuration test
	kubectl kuttl test --test aiplatform-with-ingress

.PHONY: test-saia
test-saia: ## Run SAIA feature test
	kubectl kuttl test --test aiplatform-with-saia

.PHONY: test-update
test-update: ## Run update/modification test
	kubectl kuttl test --test aiplatform-update

.PHONY: test-deletion
test-deletion: ## Run deletion and finalizer test
	kubectl kuttl test --test aiplatform-deletion

.PHONY: test-webhook
test-webhook: ## Run webhook validation test
	kubectl kuttl test --test webhook-validation

.PHONY: test-debug
test-debug: ## Run tests with debug output and no cleanup
	kubectl kuttl test --skip-delete --v=1

.PHONY: test-with-kind
test-with-kind: ## Run tests with kind cluster (creates cluster)
	kubectl kuttl test --start-kind=true

.PHONY: test-artifacts
test-artifacts: ## Run tests and collect artifacts on failure
	kubectl kuttl test --artifacts-dir=_output/kuttl-artifacts

.PHONY: test-custom
test-custom: ## Run specific test (usage: make test-custom TEST=my-test)
	@if [ -z "$(TEST)" ]; then \
		echo "Usage: make test-custom TEST=test-name"; \
		exit 1; \
	fi
	kubectl kuttl test --test $(TEST)

.PHONY: clean
clean: ## Clean up test artifacts
	rm -rf _output/

.PHONY: verify-cluster
verify-cluster: ## Verify cluster is accessible and operator is running
	@echo "Checking cluster access..."
	@kubectl cluster-info
	@echo ""
	@echo "Checking operator..."
	@kubectl get pods -n splunk-ai-operator-system
	@echo ""
	@echo "Checking CRDs..."
	@kubectl get crd aiplatforms.ai.splunk.com
	@kubectl get crd aiservices.ai.splunk.com

.DEFAULT_GOAL := help
