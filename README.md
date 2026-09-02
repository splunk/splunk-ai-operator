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
The Splunk AI Operator is a Kubernetes operator that enables customers to manage AI workloads using standardized CRDs, Helm charts, and Kubernetes primitives without reliance on any specific cloud provider’s tooling or rigid infrastructure. This repo includes the Splunk AI Operator, and multiple CRDs to manage the Splunk AI tier and Splunk AI Services.

## Getting Started

The default installation path deploys the complete Splunk AI tier on a k0s cluster by using
`tools/ai-tier-cluster-setup/k0s_cluster_with_stack.sh`.

```bash
git clone https://github.com/splunk/splunk-ai-operator.git
cd splunk-ai-operator/tools/ai-tier-cluster-setup
cp k0s-cluster-config.yaml my-cluster-config.yaml

# Edit my-cluster-config.yaml for your environment, then validate and install.
CONFIG_FILE=./my-cluster-config.yaml ./k0s_cluster_with_stack.sh validate
CONFIG_FILE=./my-cluster-config.yaml ./k0s_cluster_with_stack.sh install
CONFIG_FILE=./my-cluster-config.yaml ./k0s_cluster_with_stack.sh verify-pods
```

Review the [k0s Deployment Quick Reference](docs/ai-tier-docs/k0s-quick-reference.md)
before installation. See the [complete k0s guide](docs/ai-tier-docs/k0s-readme.md) for
standard and air-gapped deployment details.

## Documentation

- **[k0s Deployment Quick Reference](docs/ai-tier-docs/k0s-quick-reference.md)** - Default installation workflow
- **[Complete k0s Guide](docs/ai-tier-docs/k0s-readme.md)** - Configuration, installation, and operations
- **[Deployment Guide](docs/ai-tier-docs/deployment-guide.md)** - Standard and air-gapped deployment details
- **[OpenShift Guide](docs/ai-tier-docs/openshift-readme.md)** - OpenShift-specific deployment
- **[AWS EKS Guide](docs/ai-tier-docs/eks-readme.md)** - AWS EKS deployment
- **[API Reference](docs/splunk-ai-operator-docs/api-reference.md)** - Complete CRD specification
- **[Configuration Guides](docs/splunk-ai-operator-docs/splunk-ai-operator-configuration/)** - Storage, ingress, and webhook configuration
- **[Installer Troubleshooting](docs/ai-tier-docs/troubleshooting.md)** - k0s installation issues
- **[Local Development](docs/splunk-ai-operator-docs/local-development.md)** - Build and development workflow

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
