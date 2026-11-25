# Changelog

All notable changes to the Splunk AI Operator will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Air-gapped import and install that fail closed (MPR-193): `airgap-bundle` (`cmd/airgap-bundle`, `internal/airgapbundle`) writes a checksummed bundle manifest (every file's role, size and sha256, the image-archive digests, the fullfeature model artifacts, the image snapshot); verifies a bundle before transfer and, before any cluster change, against the snapshot, the mirror, the install configuration and the target hosts (including the fullfeature GPU driver, runtime and capacity); and imports it idempotently and resumably. `image-snapshot install-config --profile` prints the digest-pinned installer image settings for one profile. `airgap_install.sh` stages the tool, the snapshot and the manifest and checks the bundle; `k0s_cluster_with_stack.sh` runs the preflight before any change, fails instead of downloading in air-gap mode, accepts registry credentials as `images.imagePullSecrets` Secret references (which also authenticate its registry checks), checks node images by digest after import and writes an install record. See docs/agent-runtime/airgap-bundle.md
- AgentRuntime readiness now requires current schema success, all desired runtime replicas available, healthy current Pods and matching Service endpoints; AIPlatform follows runtime readiness changes with generation-aware conditions (MPR-191).
- Placement and resource budgets by profile: shared validation of workload resources (no negative quantities, requests within limits, no accelerator on the agent runtime, or on SLIM under cpuOnly, positive agent-runtime budgets), a cpuOnly CPU scheduler that selects GPU capacity is refused on create (warning on update), an explicit fullfeature must identify its GPU capacity (error on create, warning on update), cpuOnly SLIM follows the CPU scheduler, missing agent-runtime limits are added as the larger of the default and the request, and the AIPlatform and AIService webhooks never block an object that is being deleted (MPR-186)
- `image-snapshot` (`cmd/image-snapshot`, `internal/imagesnapshot`): derives the per-profile image inventory from an agent-runtime candidate revision, the installer configuration, the rendered profile values and the air-gap add-on and k0s lists; resolves every image to its linux/amd64 digest; mirrors by digest to a private registry and re-verifies the target; stores a versioned, checksummed, never-rewritten snapshot manifest; and provides a preflight (`verify`), a comparison of install references against the snapshot (`compare`) and a `refresh` that redoes only the changed images and names the install jobs and qualification cells to rerun. Adds the `go-containerregistry` dependency (and moves `klauspost/compress` from 1.18.0 to 1.19.2). See docs/agent-runtime/image-snapshot.md
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
- The operator's ClusterRole (generated and Helm) grants `create` and `patch` on core `events`. Before, every event it recorded on an AIService or AIPlatform outside its own namespace was rejected ("events is forbidden"), so `InvalidSpec`, `OwnershipConflict` and the other warnings never appeared. A test keeps the generated and Helm ClusterRoles identical and requires the rule.
- Deleting an AgentRuntime feature removes only the objects the operator created for it (MPR-202). Each object is created owned by its AIService, and an existing object under a name the feature uses that the AIService does not control (matched by UID) is no longer adopted or overwritten: the stage fails with reason `OwnershipConflict` naming it. The shared ServiceAccount and Certificate helpers apply this rule only when asked (`RefuseUnowned`), so SAIA keeps its behaviour; a ServiceAccount named in `features[].serviceAccountName` is customer-managed: used if it exists, created without an owner if not, and released if an earlier build owned it. The operator-generated mTLS Secret `<name>-tls` gets an owner reference once cert-manager issues it, so it is removed with the AIService; a user-named `mtls.secretName` is kept. The platform prunes a removed feature's AIService only when it controls it by UID. The operator adds no finalizer: the unused `aiservice-protect` and `aiplatform-protect` cleanup handlers are removed, and an object still carrying one of those finalizers from 2025-08 builds is released at once. See docs/agent-runtime/ownership-and-deletion.md
- AgentRuntime PostgreSQL credentials must use a complete, consistent six-key Secret; plaintext connection overrides are rejected with safe diagnostics. Deployment profiles create the Secret from a deployment-time input before applying AIPlatform, preserve identical or externally managed Secrets, and reject conflicting existing content. Automatic credential rotation remains deferred. See [PostgreSQL Secret deployment](docs/agent-runtime/postgres-secrets.md).
- AgentRuntime Deployment reconciliation preserves Kubernetes' revision annotation without copying it into Pod templates, preventing generation churn that blocks observed readiness (MPR-191).
- Settled the items MPR-184 and MPR-229 had deferred to the MPR-188 contract: the installer examples and golden files use the confirmed provider `mltk`, `AGENT_MODULE=agentcore_operations.loader:MLTKAgentLoader` and the checkpoint Secret `mltk-postgres-conn` (new installer assertions keep them in step with `config/agent-runtime/candidate-manifest.yaml`); `images.aitk.image` is documented as an unused optional pass-through because AITK is a Splunk app, not an image; cpuOnly SLIM resolves `AI_TIER_AGENT_RUNTIME_URL` through the same single rule as every profile (`spec.agentRuntimeUrl`, else the platform's one agentruntime feature), and cpuOnly admission rejects a `slim` feature alongside more than one `agentruntime` feature, which SLIM cannot choose between (MPR-184, MPR-229)
- The SLIM Deployment now honours `spec.nodeSelector` (previously only affinity and tolerations were copied); a selector patched onto an existing SLIM AIService takes effect and rolls its pods (MPR-186)
- An AgentRuntime AIService that sets only some of cpu, memory and ephemeral-storage limits gets the missing limits added, which rolls its pods and re-runs its schema Job once; an AgentRuntime with an accelerator resource is now refused (MPR-186)
- README badges reorganized into logical categories
- Modular GitHub Actions workflows using `workflow_call`

### Removed
- The installer setting `images.aitk.image`, an unused pass-through that implied AITK is a container image. AITK is the Splunk app `Splunk_ML_Toolkit`; nothing in cluster setup depends on it, and `render-profile` no longer renders an `aitk` key. A configuration that still sets it is unaffected: the key is ignored.

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
