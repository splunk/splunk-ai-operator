# Changelog

All notable changes to the Splunk AI Operator will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Placement and resource budgets by profile: shared validation of workload resources (no negative quantities, requests within limits, no accelerator on the agent runtime, or on SLIM under cpuOnly, positive agent-runtime budgets), a cpuOnly CPU scheduler that selects GPU capacity is refused on create (warning on update), an explicit fullfeature must identify its GPU capacity (error on create, warning on update), cpuOnly SLIM follows the CPU scheduler, missing agent-runtime limits are added as the larger of the default and the request, and the AIPlatform and AIService webhooks never block an object that is being deleted (MPR-186)
- cpuOnly AIPlatforms now reconcile without Ray, Weaviate or KubeRay: per-profile reconcile stages, conditional Ray watches, profile-aware AgentRuntime and SLIM preconditions (`AI_TIER_AGENT_RUNTIME_URL` for SLIM), `AIService.spec.agentRuntimeUrl`, and a webhook that rejects changing between cpuOnly and fullfeature (MPR-229)
- AIPlatform `spec.profile` (`cpuOnly` | `fullfeature`; omitted and legacy `full` resolve to `fullfeature`) with shared webhook/operator validation, installer `aiPlatform.profile` validation, `render-profile` command, `status.profile` and example values (MPR-184); see docs/agent-runtime/profile-contract.md
- Comprehensive Helm chart testing with lint, template validation, and install/upgrade/uninstall tests
- GitHub issue templates (bug report, feature request)
- Pull request template with detailed checklist
- CONTRIBUTING.md with contributor guidelines
- CODE_OF_CONDUCT.md following Contributor Covenant standards
- SECURITY.md with security policy and vulnerability reporting process
- Comprehensive badge collection in README (25+ badges)
- Workflow audit documentation for GHCR migration

### Changed
- Settled the items MPR-184 and MPR-229 had deferred to the MPR-188 contract: the installer examples and golden files use the confirmed provider `mltk`, `AGENT_MODULE=agentcore_operations.loader:MLTKAgentLoader` and the checkpoint Secret `mltk-postgres-conn` (new installer assertions keep them in step with `config/agent-runtime/candidate-manifest.yaml`); `images.aitk.image` is documented as an unused optional pass-through because AITK is a Splunk app, not an image; cpuOnly SLIM resolves `AI_TIER_AGENT_RUNTIME_URL` through the same single rule as every profile (`spec.agentRuntimeUrl`, else the platform's one agentruntime feature), and cpuOnly admission rejects a `slim` feature alongside more than one `agentruntime` feature, which SLIM cannot choose between (MPR-184, MPR-229)
- The SLIM Deployment now honours `spec.nodeSelector` (previously only affinity and tolerations were copied); a selector patched onto an existing SLIM AIService takes effect and rolls its pods (MPR-186)
- An AgentRuntime AIService that sets only some of cpu, memory and ephemeral-storage limits gets the missing limits added, which rolls its pods and re-runs its schema Job once; an AgentRuntime with an accelerator resource is now refused (MPR-186)
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
