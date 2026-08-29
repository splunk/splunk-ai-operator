# Splunk AI Operator

<!-- Build & Test Status -->
[![Build and Test](https://github.com/splunk/splunk-ai-operator/actions/workflows/main.yml/badge.svg)](https://github.com/splunk/splunk-ai-operator/actions/workflows/main.yml)
[![Helm Lint and Test](https://github.com/splunk/splunk-ai-operator/actions/workflows/helm-lint-test.yml/badge.svg)](https://github.com/splunk/splunk-ai-operator/actions/workflows/helm-lint-test.yml)
[![CodeQL](https://github.com/splunk/splunk-ai-operator/actions/workflows/codeql-analysis.yml/badge.svg)](https://github.com/splunk/splunk-ai-operator/actions/workflows/codeql-analysis.yml)
[![Coverage Status](https://coveralls.io/repos/github/splunk/splunk-ai-operator/badge.svg?branch=main)](https://coveralls.io/github/splunk/splunk-ai-operator?branch=main)
[![Go Report Card](https://goreportcard.com/badge/github.com/splunk/splunk-ai-operator)](https://goreportcard.com/report/github.com/splunk/splunk-ai-operator)

<!-- Release & Version -->
[![GitHub release](https://img.shields.io/github/v/release/splunk/splunk-ai-operator?include_prereleases)](https://github.com/splunk/splunk-ai-operator/releases)
[![License](https://img.shields.io/github/license/splunk/splunk-ai-operator)](LICENSE)
[![Go Version](https://img.shields.io/github/go-mod/go-version/splunk/splunk-ai-operator)](go.mod)
[![Kubernetes](https://img.shields.io/badge/kubernetes-v1.31+-326CE5.svg?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
<!-- Artifact Hub badge will be added after first release - see .github/ARTIFACTHUB_SETUP.md -->

<!-- Container Registry -->
[![GHCR](https://img.shields.io/badge/ghcr.io-splunk%2Fsplunk--ai--operator-blue?logo=github)](https://github.com/splunk/splunk-ai-operator/pkgs/container/splunk-ai-operator)
[![Docker Hub](https://img.shields.io/badge/docker.io-splunk%2Fsplunk--ai--operator-blue?logo=docker&logoColor=white)](https://hub.docker.com/r/splunk/splunk-ai-operator)

<!-- Community -->
[![GitHub issues](https://img.shields.io/github/issues/splunk/splunk-ai-operator)](https://github.com/splunk/splunk-ai-operator/issues)
[![GitHub pull requests](https://img.shields.io/github/issues-pr/splunk/splunk-ai-operator)](https://github.com/splunk/splunk-ai-operator/pulls)
[![GitHub contributors](https://img.shields.io/github/contributors/splunk/splunk-ai-operator)](https://github.com/splunk/splunk-ai-operator/graphs/contributors)
[![GitHub stars](https://img.shields.io/github/stars/splunk/splunk-ai-operator)](https://github.com/splunk/splunk-ai-operator/stargazers)

---
The Splunk AI Operator is a Kubernetes operator that enables customers to manage AI workloads using standardized CRDs, Helm charts, and Kubernetes primitives without reliance on any specific cloud provider’s tooling or rigid infrastructure. This repo includes the Splunk AI Operator, and multiple CRDs to manage the Splunk AI Platform and Splunk AI Services.

## Customer Deployment on k0s

Customers deploying the Splunk AI Platform on k0s should start with the
[k0s Deployment Quick Reference](docs/deployment/k0s-quick-reference.md). It
covers the prerequisites, standard and air-gapped deployment paths, image
mirroring, installation, verification, and Splunk integration.

## Getting Started

### Quick Install

```bash
# Install using Helm OCI registry (Recommended - Helm 3.8+)
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace

# Or install using kubectl
kubectl apply -f https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/install-v0.2.0.yaml
```

See [Installation Guide](docs/installation.md) for detailed instructions and all installation methods.

### Prerequisites
- **Kubernetes**: v1.31+ cluster
- **kubectl**: v1.11.3+
- **Helm**: v3.8+ (for Helm installation)
- **Go**: v1.23.0+ (for development only)
- **Docker**: 17.03+ (for development only)

### Installation Options

**Option 1: Helm OCI Registry (Recommended)**
```bash
# Requires Helm 3.8+
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace
```

**Option 2: kubectl (Manifests)**
```bash
# Install operator with all dependencies
kubectl apply -f https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/install-v0.2.0.yaml
```

**Option 3: Helm (GitHub Release)**
```bash
# For compatibility with older Helm versions
helm install splunk-ai-operator \
  https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/splunk-ai-operator-0.2.0.tgz \
  --namespace splunk-ai-operator-system \
  --create-namespace
```

**Option 4: From Source (Development)**
```bash
# Install CRDs
make install

# Build and deploy
make docker-build docker-push IMG=ghcr.io/splunk/splunk-ai-operator:tag
make deploy IMG=ghcr.io/splunk/splunk-ai-operator:tag
```

### Helm Charts

Charts are published to OCI registry and GitHub Releases:

- **OCI Registry (GHCR)**: `oci://ghcr.io/splunk/charts/splunk-ai-operator` (recommended)
- **GitHub Releases**: Available as `.tgz` files for compatibility

```bash
# Install from OCI registry
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0

# View available versions
# Visit: https://github.com/splunk/splunk-ai-operator/pkgs/container/charts%2Fsplunk-ai-operator
```

### Container Images

Images are published to multiple registries:

- **GHCR**: `ghcr.io/splunk/splunk-ai-operator:v0.2.0`
- **Docker Hub**: `splunk/splunk-ai-operator:v0.2.0`

```bash
# Pull from GHCR (recommended)
docker pull ghcr.io/splunk/splunk-ai-operator:v0.2.0

# Pull from Docker Hub
docker pull splunk/splunk-ai-operator:v0.2.0
```

### Deploy AI Platform

```bash
# Create sample AI Platform
kubectl apply -k config/samples/
```

### Uninstall

**Helm:**
```bash
helm uninstall splunk-ai-operator -n splunk-ai-operator
```

**From Source:**
```bash
kubectl delete -k config/samples/
make undeploy
make uninstall
```

### Documentation

- **[Installation Guide](docs/installation.md)** - Detailed installation instructions
- **[Helm Deployment](docs/deployment/helm-deployment.md)** - Helm chart installation
- **[API Reference](docs/api-reference.md)** - Complete CRD specification
- **[AWS EKS Deployment](docs/deployment/deployment-aws-eks.md)** - Production deployment on AWS
- **[Configuration Guides](docs/configuration/)** - Storage, ingress, and webhook configuration
- **[Troubleshooting](docs/troubleshooting.md)** - Common issues and solutions

## License

Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

