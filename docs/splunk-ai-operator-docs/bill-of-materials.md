# Bill of Materials (BOM)

The Splunk AI Operator provides comprehensive Bill of Materials (BOM) and Software Bill of Materials (SBOM) for each release to support supply chain security and transparency.

## Overview

Each release includes multiple artifact types to meet different compliance and security requirements:

1. **Custom BOM** - Lists all container images managed by the operator
2. **SBOM** - Complete software dependencies of the operator binary
3. **Attestations** - Cryptographic proof of build provenance

## BOM Artifacts

### Custom Bill of Materials

The custom BOM tracks all container images that the operator deploys and manages:

#### Available Formats

| Format | Filename | Use Case |
|--------|----------|----------|
| **Text** | `bom-vX.Y.Z.txt` | Human-readable, easy to review |
| **YAML** | `bom-vX.Y.Z.yaml` | Kubernetes-native, machine-readable |
| **JSON** | `bom-vX.Y.Z.json` | CycloneDX format, tool integration |

#### What's Included

The BOM includes:

- **Operator Image**: The operator controller image
- **Managed Images**: All container images deployed by the operator:
  - Splunk Enterprise
  - Ray Head (ML runtime)
  - Ray Worker (GPU-enabled ML workers)
  - Weaviate (Vector database)
  - SAIA API (AI services)
  - Post-install hooks
  - Fluent Bit (Logging)
- **Dependency Versions**: Model versions, framework versions

#### Example BOM Output

```text
================================================================================
Bill of Materials (BOM)
Splunk AI Operator v0.2.0
Generated: 2025-11-18T19:34:23Z
================================================================================

OPERATOR IMAGE
--------------
ghcr.io/splunk/splunk-ai-operator:v0.2.0

MANAGED CONTAINER IMAGES
------------------------
splunk-enterprise:        splunk/splunk:9.2.3
ray-head:                 example.ecr.us-west-2.amazonaws.com/ray/ray-head:build-5
ray-worker:               example.ecr.us-west-2.amazonaws.com/ray/ray-worker-gpu:build-6
weaviate:                 semitechnologies/weaviate:stable-v1.28-007846a
fluent-bit:               fluent/fluent-bit:1.9.6
...

DEPENDENCY VERSIONS
-------------------
Model Version:      v0.3.14-36-g1549f5a
Ray Version:        2.44.0
```

### Software Bill of Materials (SBOM)

The SBOM provides a complete inventory of all software dependencies in the operator binary:

#### Available Formats

| Format | Filename | Standard |
|--------|----------|----------|
| **CycloneDX** | `sbom-operator-vX.Y.Z.cyclonedx.json` | CycloneDX 1.4+ |
| **SPDX** | `sbom-operator-vX.Y.Z.spdx.json` | SPDX 2.3+ |
| **Syft** | `sbom-operator-vX.Y.Z.syft.json` | Syft native |

#### What's Included

The SBOM catalogs:

- Go packages and dependencies
- System libraries
- Third-party dependencies
- License information
- Package versions and hashes

#### Tools Integration

SBOMs can be used with security scanning tools:

```bash
# Grype (vulnerability scanning)
grype sbom:./sbom-operator-v0.2.0.cyclonedx.json

# Trivy (security scanning)
trivy sbom --scanners vuln sbom-operator-v0.2.0.spdx.json

# Dependency-Track (component analysis platform)
# Upload the CycloneDX file to Dependency-Track
```

## Accessing BOM/SBOM Files

### From GitHub Releases

All BOM and SBOM files are attached to each GitHub release:

```bash
VERSION="0.2.0"
BASE_URL="https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}"

# Download custom BOM (human-readable)
curl -LO "${BASE_URL}/bom-v${VERSION}.txt"

# Download SBOM (CycloneDX)
curl -LO "${BASE_URL}/sbom-operator-v${VERSION}.cyclonedx.json"

# Download SBOM (SPDX)
curl -LO "${BASE_URL}/sbom-operator-v${VERSION}.spdx.json"
```

### Generate Locally

You can generate the custom BOM locally:

```bash
# Generate BOM for current version
make generate-bom VERSION=0.2.0

# Output files created in dist/
ls -l dist/bom-*
```

## Verification and Security

### Verify Image Digests

To verify the exact images used in a release:

```bash
# Pull image and get digest
docker pull ghcr.io/splunk/splunk-ai-operator:v0.2.0 --platform linux/amd64
docker inspect ghcr.io/splunk/splunk-ai-operator:v0.2.0 --format='{{.RepoDigests}}'
```

### Verify Build Attestations

Each operator image includes cryptographic attestations:

```bash
# View attestation using GitHub CLI
gh attestation verify oci://ghcr.io/splunk/splunk-ai-operator:v0.2.0 \
  --owner splunk

# Verify with cosign (SLSA provenance)
cosign verify-attestation \
  --type slsaprovenance \
  --certificate-identity-regexp="^https://github.com/splunk/splunk-ai-operator" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/splunk/splunk-ai-operator:v0.2.0
```

### Security Scanning

Scan operator image for vulnerabilities:

```bash
# Using Trivy
trivy image ghcr.io/splunk/splunk-ai-operator:v0.2.0

# Using Grype
grype ghcr.io/splunk/splunk-ai-operator:v0.2.0

# Scan all managed images from BOM
while read -r line; do
  if [[ $line =~ ^[a-z-]+:[[:space:]]+([^[:space:]]+)$ ]]; then
    image="${BASH_REMATCH[1]}"
    echo "Scanning: $image"
    trivy image "$image"
  fi
done < bom-v0.2.0.txt
```

## Compliance Use Cases

### Software Supply Chain Security

The BOM/SBOM artifacts support compliance with:

- **SLSA** (Supply chain Levels for Software Artifacts)
- **SSDF** (Secure Software Development Framework)
- **Executive Order 14028** (Cybersecurity requirements)
- **NTIA Minimum Elements** for SBOM

### Vulnerability Management

Use SBOMs for continuous vulnerability monitoring:

1. Upload SBOM to vulnerability management platform (e.g., Dependency-Track)
2. Receive alerts when new CVEs affect your dependencies
3. Track remediation across releases

### License Compliance

Extract license information from SBOM:

```bash
# Using jq to extract licenses from CycloneDX SBOM
jq -r '.components[] | select(.licenses) | "\(.name): \(.licenses[].license.id // .licenses[].license.name)"' \
  sbom-operator-v0.2.0.cyclonedx.json | sort -u
```

### Audit Trail

The BOM provides an audit trail showing:

- Which versions of components were deployed
- When the release was built (timestamp)
- What dependencies were included
- Build provenance (via attestations)

## Integration with CI/CD

### Automated Scanning

Integrate BOM/SBOM into your CI/CD pipeline:

```yaml
# Example GitHub Actions workflow
- name: Download SBOM
  run: |
    VERSION="0.2.0"
    curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/sbom-operator-v${VERSION}.cyclonedx.json"

- name: Scan for vulnerabilities
  uses: anchore/scan-action@v3
  with:
    sbom: "sbom-operator-v0.2.0.cyclonedx.json"
    fail-build: true
    severity-cutoff: high
```

### Policy Enforcement

Use BOM to enforce organizational policies:

```bash
#!/bin/bash
# Example: Verify all images are from approved registries

APPROVED_REGISTRIES=(
  "ghcr.io/splunk"
  "splunk"
  "semitechnologies"
  "fluent"
)

while read -r line; do
  if [[ $line =~ image:[[:space:]]+([^[:space:]]+) ]]; then
    image="${BASH_REMATCH[1]}"
    approved=false

    for registry in "${APPROVED_REGISTRIES[@]}"; do
      if [[ $image == $registry* ]]; then
        approved=true
        break
      fi
    done

    if [ "$approved" = false ]; then
      echo "ERROR: Unapproved registry for image: $image"
      exit 1
    fi
  fi
done < bom-v0.2.0.yaml

echo "✅ All images from approved registries"
```

## Best Practices

1. **Store BOM/SBOM**: Archive BOM/SBOM files for each deployed version
2. **Automate Scanning**: Integrate vulnerability scanning into deployment pipelines
3. **Track Changes**: Compare BOMs across versions to identify dependency changes
4. **Verify Signatures**: Always verify attestations before deployment
5. **Monitor CVEs**: Use SBOM with vulnerability databases for continuous monitoring
6. **Document Exceptions**: Maintain records of approved security exceptions

## Updating Image Versions

When updating managed image versions:

1. Update `.env` file with new image tags:
   ```bash
   RELATED_IMAGE_RAY_HEAD=example.ecr.aws.com/ray/ray-head:build-6
   RELATED_IMAGE_RAY_WORKER=example.ecr.aws.com/ray/ray-worker-gpu:build-7
   ```

2. Update `config/manager/kustomization.yaml` if needed

3. Generate new BOM to verify:
   ```bash
   make generate-bom VERSION=0.2.0
   cat dist/bom-v0.2.0.txt
   ```

4. Release workflow automatically generates BOM/SBOM

## Support and Resources

- **CycloneDX**: https://cyclonedx.org/
- **SPDX**: https://spdx.dev/
- **SLSA**: https://slsa.dev/
- **Syft**: https://github.com/anchore/syft
- **Grype**: https://github.com/anchore/grype
- **Trivy**: https://github.com/aquasecurity/trivy

## Questions?

For questions about BOM/SBOM:
- Open an issue: https://github.com/splunk/splunk-ai-operator/issues
- Security concerns: See [SECURITY.md](../SECURITY.md)
