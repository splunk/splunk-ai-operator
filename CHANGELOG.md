# Changelog

All notable changes to the Splunk AI Operator will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Comprehensive Helm chart testing with lint, template validation, and install/upgrade/uninstall tests
- GitHub issue templates (bug report, feature request)
- Pull request template with detailed checklist
- CONTRIBUTING.md with contributor guidelines
- CODE_OF_CONDUCT.md following Contributor Covenant standards
- SECURITY.md with security policy and vulnerability reporting process
- Comprehensive badge collection in README (25+ badges)
- Workflow audit documentation for GHCR migration

### Changed
- README badges reorganized into logical categories
- Modular GitHub Actions workflows using `workflow_call`

### Documentation
- Added deployment guides for EKS and k0s clusters
- Created comprehensive API documentation
- Added architecture diagrams
- Created troubleshooting guides

## [0.2.0] - 2025-01-17

### Added
- Initial release of Splunk AI Operator
- Support for AIPlatform CRD
- Support for AIService CRD
- Integration with KubeRay for Ray cluster management
- Helm chart for operator deployment
- Helm chart for AI platform deployment
- Support for GPU and CPU workloads
- Integration with Splunk for logging and metrics
- Support for custom accelerator types
- Namespace isolation and multi-tenancy
- Automatic scaling configuration
- Volume mount support for models and data
- ConfigMap and Secret support for configuration
- Image pull secrets support for private registries
- Service mesh integration (optional)
- Prometheus metrics export
- OpenTelemetry tracing support

### Cluster Setup
- EKS cluster setup script with full automation
- k0s cluster setup script for bare metal/VMs
- Support for Kubernetes 1.31-1.34
- Automatic cluster-autoscaler installation
- GPU node support (NVIDIA, AMD)
- Spot instance support (EKS)
- Load balancer configuration
- Ingress controller setup
- Cert-manager integration
- Docker Hub authentication support
- Image pre-validation before deployment

### CI/CD
- GitHub Actions workflows for build and test
- Unit test automation
- Code formatting checks
- Vulnerability scanning with Trivy
- Helm chart linting and testing
- Modular workflow design
- Automated release process

### Documentation
- README with quick start guide
- Deployment guides for EKS and k0s
- API reference documentation
- Architecture overview
- Contributing guidelines
- Security policy
- Code of conduct

## Release Types

### Major Version (X.0.0)
- Breaking API changes
- Major feature additions
- Significant architectural changes

### Minor Version (0.X.0)
- New features (backwards compatible)
- Deprecations
- Performance improvements
- Enhanced functionality

### Patch Version (0.0.X)
- Bug fixes
- Security patches
- Documentation updates
- Minor improvements

## Categories

Changes are grouped into the following categories:

- **Added**: New features
- **Changed**: Changes in existing functionality
- **Deprecated**: Soon-to-be removed features
- **Removed**: Removed features
- **Fixed**: Bug fixes
- **Security**: Security vulnerability fixes

## Links

- [GitHub Repository](https://github.com/splunk/splunk-ai-operator)
- [GitHub Releases](https://github.com/splunk/splunk-ai-operator/releases)
- [Documentation](https://github.com/splunk/splunk-ai-operator/tree/main/docs)
- [Issue Tracker](https://github.com/splunk/splunk-ai-operator/issues)

---

**Note**: This project follows [Semantic Versioning](https://semver.org/). For information on how to contribute, see [CONTRIBUTING.md](CONTRIBUTING.md).
