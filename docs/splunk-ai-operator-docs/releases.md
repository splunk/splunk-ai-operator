# Release Guide

This document describes how to create releases for the Splunk AI Operator.

## Overview

Releases are fully automated via GitHub Actions. You create releases from the GitHub UI without needing local git commands.

## Quick Start

1. Go to: [Create Release Tag Workflow](https://github.com/splunk/splunk-ai-operator/actions/workflows/create-release-tag.yml)
2. Click **"Run workflow"**
3. Enter version (e.g., `0.2.0` for first release, `0.2.0` for next)
4. Click **"Run workflow"**
5. Wait ~10 minutes - Release created automatically!

---

## Release Process

### Step 1: Prepare for Release

**Pre-Release Checklist:**
- [ ] All PRs merged to `main`
- [ ] All CI/CD checks passing
- [ ] CHANGELOG.md updated (if exists)
- [ ] Breaking changes documented (if any)

### Step 2: Create Release Tag

1. Navigate to [Create Release Tag](https://github.com/splunk/splunk-ai-operator/actions/workflows/create-release-tag.yml)
2. Click **"Run workflow"** button (top right)
3. Fill in:
   - **Use workflow from**: `main` (default)
   - **Release version**: `0.2.0` (without 'v' prefix, it's added automatically)
   - **Mark as pre-release**: Check for beta/rc releases
4. Click **"Run workflow"**

### Step 3: Monitor Workflows

Two workflows run automatically:

**1. Create Release Tag** (~30 seconds)
- Validates version format
- Creates git tag `v0.2.0`
- Pushes tag to GitHub

**2. Release Package** (~5-10 minutes)
- Generates Kubernetes manifests
- Packages Helm charts
- Pushes charts to OCI registry (GHCR)
- Builds and pushes Docker images
- Creates GitHub Release with artifacts

**Monitor at:**
- [All Workflows](https://github.com/splunk/splunk-ai-operator/actions)
- [Release Workflow](https://github.com/splunk/splunk-ai-operator/actions/workflows/release-package-helm.yml)

### Step 4: Verify Release

After workflows complete:

**1. Check GitHub Release:**
```
https://github.com/splunk/splunk-ai-operator/releases
```

Verify assets:
- `install-v0.2.0.yaml` - Kubernetes manifests
- `splunk-ai-operator-0.2.0.tgz` - Helm chart
- `splunk-ai-platform-0.2.0.tgz` - Platform chart
- `index.yaml` - Helm repository index

**2. Check OCI Registry:**
```bash
# Verify chart is available
helm show chart oci://ghcr.io/splunk/charts/splunk-ai-operator --version 0.2.0
```

**3. Check Docker Images:**
- GHCR: https://github.com/splunk/splunk-ai-operator/pkgs/container/splunk-ai-operator
- Docker Hub: https://hub.docker.com/r/splunk/splunk-ai-operator

**4. Test Installation:**
```bash
# Test kubectl
kubectl apply -f https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/install-v0.2.0.yaml

# Test Helm OCI
helm install test-release oci://ghcr.io/splunk/charts/splunk-ai-operator --version 0.2.0

# Test Docker
docker pull ghcr.io/splunk/splunk-ai-operator:v0.2.0
```

---

## Version Format

We follow [Semantic Versioning 2.0.0](https://semver.org/):

### Format: `MAJOR.MINOR.PATCH[-PRERELEASE]`

**Examples:**
- `0.2.0` - First release
- `0.2.0` - Second release with new features
- `0.1.1` - Patch release
- `1.0.0` - GA release (when ready)
- `0.2.0-beta.1` - Pre-release
- `1.0.0-rc.1` - Release candidate

### When to Increment

**MAJOR** (`X.0.0`):
- Breaking API changes
- Incompatible CRD schema changes
- Removal of deprecated features

**MINOR** (`0.Y.0`):
- New features (backward compatible)
- New CRD fields (with defaults)
- Feature deprecations (with warnings)

**PATCH** (`0.0.Z`):
- Bug fixes
- Documentation updates
- Security patches (non-breaking)

**PRERELEASE** (`-suffix`):
- `-alpha.N` - Early testing
- `-beta.N` - Feature complete
- `-rc.N` - Release candidate

---

## What Gets Released

### Artifacts Published

When you release `v0.2.0`, the automation creates:

#### 1. Kubernetes Manifests
```
install-v0.2.0.yaml
```
Contains:
- All CRDs (AIPlatform, AIService)
- Operator deployment
- RBAC (ServiceAccount, ClusterRole, etc.)
- Webhooks configuration
- Cert-manager certificates

#### 2. Helm Charts (OCI Registry)
```
oci://ghcr.io/splunk/charts/splunk-ai-operator:0.2.0
oci://ghcr.io/splunk/charts/splunk-ai-platform:0.2.0
```

#### 3. Helm Charts (GitHub Release)
```
splunk-ai-operator-0.2.0.tgz
splunk-ai-platform-0.2.0.tgz
index.yaml
```

#### 4. Docker Images
```
ghcr.io/splunk/splunk-ai-operator:v0.2.0
ghcr.io/splunk/splunk-ai-operator:0.2.0
ghcr.io/splunk/splunk-ai-operator:latest  (if on main)

splunk/splunk-ai-operator:v0.2.0
splunk/splunk-ai-operator:0.2.0
splunk/splunk-ai-operator:latest  (if on main)
```

### Installation Methods

Users can install via:

**1. kubectl (Manifests):**
```bash
kubectl apply -f https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/install-v0.2.0.yaml
```

**2. Helm OCI (Recommended):**
```bash
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0
```

**3. Helm (GitHub Release):**
```bash
helm install splunk-ai-operator \
  https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/splunk-ai-operator-0.2.0.tgz
```

---

## Hotfix Releases

For critical bug fixes:

### Process

1. Merge hotfix PR to `main`
2. Create patch release: `1.0.1` (increment PATCH version)
3. Follow normal release process
4. Communicate to users via GitHub Release notes

### Example

If `v0.2.0` has a critical bug:
- Fix merged to `main`
- Create release: `0.1.1`
- Release notes should highlight:
  - What was fixed
  - Impact of the bug
  - Upgrade instructions

---

## Pre-releases

For testing before GA release:

### Beta Release

```
Version: 0.2.0-beta.1
Pre-release: ✅ (checked)
```

**Use cases:**
- Testing new features
- Getting community feedback
- Validating changes before GA

### Release Candidate

```
Version: 1.0.0-rc.1
Pre-release: ✅ (checked)
```

**Use cases:**
- Final testing before release
- No new features, only bug fixes
- Production-like testing

---

## Troubleshooting

### Tag Already Exists

**Error:**
```
❌ Tag v0.2.0 already exists
```

**Solution:**
1. Choose different version, or
2. Delete existing tag (requires admin):
   ```bash
   git push --delete origin v0.2.0
   ```
3. Delete GitHub Release if it exists

### Workflow Failed

**Check logs:**
1. Go to [Actions](https://github.com/splunk/splunk-ai-operator/actions)
2. Find failed workflow
3. Check error messages

**Common issues:**
- Docker Hub auth: Check `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets
- Tests failing: Fix tests on `main` before releasing
- Image build failure: Check Dockerfile and build logs

### Images Not Appearing

**Check:**
1. Workflow completed successfully
2. GHCR: May take 5-10 minutes to appear
3. Docker Hub: Check authentication secrets
4. Visibility: Ensure packages are public

### Charts Not in OCI Registry

**Verify:**
```bash
# This should work
helm show chart oci://ghcr.io/splunk/charts/splunk-ai-operator --version 0.2.0
```

**If not:**
1. Check workflow logs for OCI push step
2. Verify GHCR authentication
3. Check package visibility settings

---

## Post-Release

### Required Actions

After release is published:

1. **Announcement**
   - Update project communication channels
   - Post on relevant forums/discussions

2. **Documentation**
   - Update docs if needed
   - Add migration guides for breaking changes

3. **Monitoring**
   - Watch for issues
   - Monitor downloads/usage
   - Respond to user feedback

### First Release Setup (One-Time)

For the very first release (`v0.2.0`):

1. **Make GHCR packages public:**
   - Go to: https://github.com/orgs/splunk/packages
   - Find: `splunk-ai-operator` and `charts/splunk-ai-operator`
   - Settings → Change visibility → Public

2. **Register on Artifact Hub:**
   - Go to: https://artifacthub.io/
   - Sign in with GitHub
   - Add repository: `oci://ghcr.io/splunk/charts`
   - Charts will be discoverable

3. **Verify Docker Hub:**
   - Check: https://hub.docker.com/r/splunk/splunk-ai-operator
   - Images should appear automatically

---

## Security

### Secrets Required

Repository secrets needed:
- `DOCKERHUB_USERNAME` - Docker Hub username
- `DOCKERHUB_TOKEN` - Docker Hub access token
- `GITHUB_TOKEN` - Provided automatically by GitHub Actions

### Supply Chain Security

Each release includes:
- ✅ SLSA provenance attestation
- ✅ Signed artifacts
- ✅ Vulnerability scanning results
- ✅ SBOM (Software Bill of Materials)

View security info:
```
https://github.com/splunk/splunk-ai-operator/security
```

---

## Best Practices

### Versioning

- ✅ Use semantic versioning strictly
- ✅ Document breaking changes clearly
- ✅ Test pre-releases before GA
- ✅ Don't skip versions
- ✅ Tag from `main` branch only

### Release Notes

- ✅ Highlight key features/fixes
- ✅ Document breaking changes
- ✅ Include upgrade instructions
- ✅ Link to relevant PRs/issues
- ✅ Thank contributors

### Testing

Before releasing:
- ✅ All tests pass on `main`
- ✅ Manual testing completed
- ✅ Documentation updated
- ✅ No known critical bugs

---

## Support

### Getting Help

- **Issues:** https://github.com/splunk/splunk-ai-operator/issues
- **Discussions:** https://github.com/splunk/splunk-ai-operator/discussions
- **Documentation:** https://github.com/splunk/splunk-ai-operator/tree/main/docs

### Release Team

Contact maintainers for:
- Release access issues
- Secret management
- Emergency hotfixes

---

## Related Documentation

- [Installation Guide](installation.md)
- [Contributing Guide](../CONTRIBUTING.md)
- [Changelog](../CHANGELOG.md)
- [Security Policy](../SECURITY.md)
