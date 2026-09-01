# Using the BOM and Compatibility Matrix

This guide shows you how to practically use the Bill of Materials (BOM) and Compatibility Matrix for deployment planning, security scanning, and compliance.

## Quick Reference

| File | Purpose | When to Use |
|------|---------|-------------|
| `compatibility-matrix.yaml` | Version compatibility info | **Before deployment** - Check if your environment meets requirements |
| `bom-vX.Y.Z.txt` | Human-readable BOM | **Quick review** - See all images at a glance |
| `bom-vX.Y.Z.yaml` | Machine-readable BOM | **Automation** - Parse with tools, CI/CD integration |
| `bom-vX.Y.Z.json` | CycloneDX BOM | **Tool integration** - Dependency-Track, compliance tools |
| `sbom-*.json` | Software Bill of Materials | **Security scanning** - Vulnerability analysis |

## Common Use Cases

### 1. Pre-Deployment: Check Compatibility

**Scenario:** You want to deploy Splunk AI Operator v0.2.0 on your Kubernetes cluster.

**Steps:**

```bash
# Download the compatibility matrix
VERSION="0.2.0"
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/compatibility-matrix.yaml"

# Check Kubernetes compatibility
yq '.platform.kubernetes' compatibility-matrix.yaml
```

**Output:**
```yaml
minVersion: "1.28.0"
maxVersion: "1.31.99"
tested:
  - "1.28"
  - "1.29"
  - "1.30"
  - "1.31"
notes: "Operator tested on EKS, AKS, GKE, and vanilla Kubernetes"
```

**Decision:**
- ✅ Your cluster is 1.30.x → **Compatible**
- ❌ Your cluster is 1.27.x → **Not supported** (below minVersion)
- ⚠️ Your cluster is 1.32.x → **Not tested** (above maxVersion, may work but untested)

**Check required services:**
```bash
# What services do I need?
yq '.requiredServices' compatibility-matrix.yaml
```

**Output:**
```yaml
certManager:
  name: cert-manager
  minVersion: "1.13.0"
  required: true

vaultInjector:
  name: vault-injector
  minVersion: "0.25.0"
  required: false
```

**Action:**
```bash
# Verify cert-manager is installed and meets minimum version
kubectl get deployment -n cert-manager cert-manager -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}'
# Should be >= 1.13.0
```

### 2. Security Scanning: Check for Vulnerabilities

**Scenario:** You need to scan all images before deployment for security vulnerabilities.

#### Option A: Scan Operator Image

```bash
VERSION="0.2.0"

# Download SBOM
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/sbom-operator-v${VERSION}.cyclonedx.json"

# Scan using Grype
grype sbom:./sbom-operator-v${VERSION}.cyclonedx.json

# Or scan using Trivy
trivy sbom ./sbom-operator-v${VERSION}.cyclonedx.json
```

#### Option B: Scan All Managed Images

```bash
# Download BOM
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/bom-v${VERSION}.yaml"

# Extract all images and scan them
yq '.spec.containerImages[].image' bom-v${VERSION}.yaml | while read image; do
  echo "Scanning: $image"
  trivy image "$image" --severity HIGH,CRITICAL
done
```

**Example Output:**
```
Scanning: ghcr.io/splunk/splunk-ai-operator:v0.2.0
✅ No HIGH or CRITICAL vulnerabilities

Scanning: splunk/splunk:10.2.0
⚠️ Found 2 MEDIUM vulnerabilities
...
```

### 3. Upgrade Planning: Compare Versions

**Scenario:** You're on v0.0.5 and want to upgrade to v0.2.0. What changed?

```bash
# Download both BOMs
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v0.0.5/bom-v0.0.5.yaml"
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/bom-v0.2.0.yaml"

# Compare Splunk Enterprise versions
echo "Old version:"
yq '.spec.dependencies.splunkEnterpriseVersion' bom-v0.0.5.yaml

echo "New version:"
yq '.spec.dependencies.splunkEnterpriseVersion' bom-v0.2.0.yaml

# Check if upgrade is safe
yq '.upgradePaths[] | select(.from == "0.0.x" and .to == "0.1.x")' compatibility-matrix.yaml
```

**Output:**
```yaml
from: "0.0.x"
to: "0.1.x"
automatic: true
breaking: false
notes: "Initial pre-GA release"
```

**Decision:** ✅ Safe to upgrade, no breaking changes

### 4. Compliance: Export Dependency List

**Scenario:** Audit team needs a complete list of all software dependencies.

```bash
VERSION="0.2.0"

# Download all compliance files
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/bom-v${VERSION}.txt"
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/sbom-operator-v${VERSION}.spdx.json"

# Human-readable summary
cat bom-v${VERSION}.txt

# SPDX format for compliance tools
# Upload sbom-operator-v${VERSION}.spdx.json to your compliance platform
```

### 5. Policy Enforcement: Verify Approved Registries

**Scenario:** Company policy requires all images from approved registries only.

Create a validation script:

```bash
#!/bin/bash
# check-registry-policy.sh

VERSION="0.2.0"
APPROVED_REGISTRIES=(
  "ghcr.io/splunk"
  "splunk"
  "semitechnologies"
  "fluent"
)

# Download BOM
curl -sLO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/bom-v${VERSION}.yaml"

echo "Checking registry policy compliance..."

# Extract and check each image
yq '.spec.containerImages[].image' bom-v${VERSION}.yaml | while read image; do
  approved=false

  for registry in "${APPROVED_REGISTRIES[@]}"; do
    if [[ "$image" == ${registry}/* ]] || [[ "$image" == ${registry}:* ]]; then
      approved=true
      echo "✅ $image"
      break
    fi
  done

  if [ "$approved" = false ]; then
    echo "❌ POLICY VIOLATION: $image"
    echo "   Image from unapproved registry!"
    exit 1
  fi
done

echo ""
echo "✅ All images comply with registry policy"
```

Run it:
```bash
chmod +x check-registry-policy.sh
./check-registry-policy.sh
```

### 6. CI/CD Integration: Automated Checks

**Scenario:** Integrate BOM/compatibility checks into your deployment pipeline.

#### GitHub Actions Example

```yaml
name: Pre-Deployment Validation

on:
  workflow_dispatch:
    inputs:
      operator_version:
        description: 'Operator version to deploy'
        required: true
        default: '0.2.0'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - name: Download BOM and Compatibility Matrix
        run: |
          VERSION="${{ github.event.inputs.operator_version }}"
          curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/bom-v${VERSION}.yaml"
          curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/compatibility-matrix.yaml"
          curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/sbom-operator-v${VERSION}.cyclonedx.json"

      - name: Check Kubernetes Version Compatibility
        run: |
          K8S_VERSION=$(kubectl version --short | grep Server | awk '{print $3}' | sed 's/v//')
          MIN_VERSION=$(yq '.platform.kubernetes.minVersion' compatibility-matrix.yaml)
          MAX_VERSION=$(yq '.platform.kubernetes.maxVersion' compatibility-matrix.yaml)

          echo "Cluster K8s version: $K8S_VERSION"
          echo "Required: $MIN_VERSION - $MAX_VERSION"

          # Version comparison logic here
          # Fail if out of range

      - name: Scan for Vulnerabilities
        uses: anchore/scan-action@v3
        with:
          sbom: "sbom-operator-v${{ github.event.inputs.operator_version }}.cyclonedx.json"
          fail-build: true
          severity-cutoff: high

      - name: Verify Required Services
        run: |
          # Check cert-manager
          if ! kubectl get deployment -n cert-manager cert-manager; then
            echo "❌ cert-manager not found (required)"
            exit 1
          fi

          CERT_MANAGER_VERSION=$(kubectl get deployment -n cert-manager cert-manager -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}')
          MIN_CERT_MANAGER=$(yq '.requiredServices.certManager.minVersion' compatibility-matrix.yaml)

          echo "cert-manager: $CERT_MANAGER_VERSION (required: >= $MIN_CERT_MANAGER)"

      - name: Generate Deployment Report
        run: |
          cat <<EOF > deployment-report.md
          ## Pre-Deployment Validation Report

          **Operator Version:** ${{ github.event.inputs.operator_version }}
          **Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")

          ### Compatibility Checks
          - ✅ Kubernetes version compatible
          - ✅ Required services present
          - ✅ No HIGH/CRITICAL vulnerabilities

          ### Managed Components
          $(yq '.managedComponents | to_entries | .[] | "- " + .key + ": " + .value.versions[0].version' compatibility-matrix.yaml)

          ### Next Steps
          Proceed with deployment using:
          \`\`\`bash
          helm install splunk-ai-operator oci://ghcr.io/splunk/charts/splunk-ai-operator --version ${{ github.event.inputs.operator_version }}
          \`\`\`
          EOF

          cat deployment-report.md
```

### 7. Continuous Monitoring: Track CVEs

**Scenario:** Monitor for new vulnerabilities in deployed components.

#### Using Dependency-Track

```bash
VERSION="0.2.0"

# Download CycloneDX SBOM
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/sbom-operator-v${VERSION}.cyclonedx.json"

# Upload to Dependency-Track (replace with your instance)
DTRACK_URL="https://dependency-track.example.com"
DTRACK_API_KEY="your-api-key"
PROJECT_NAME="splunk-ai-operator"
PROJECT_VERSION="${VERSION}"

curl -X POST "${DTRACK_URL}/api/v1/bom" \
  -H "X-API-Key: ${DTRACK_API_KEY}" \
  -H "Content-Type: multipart/form-data" \
  -F "project=${PROJECT_NAME}" \
  -F "projectVersion=${PROJECT_VERSION}" \
  -F "bom=@sbom-operator-v${VERSION}.cyclonedx.json"
```

Dependency-Track will:
- Continuously monitor for new CVEs
- Alert when vulnerabilities are discovered
- Track remediation across versions

### 8. Air-Gapped Deployments: Image Mirror Planning

**Scenario:** You need to mirror all images to a private registry for air-gapped deployment.

```bash
VERSION="0.2.0"
PRIVATE_REGISTRY="registry.internal.company.com"

# Download BOM
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/bom-v${VERSION}.yaml"

# Create mirror script
cat > mirror-images.sh <<'EOF'
#!/bin/bash
VERSION="0.2.0"
PRIVATE_REGISTRY="registry.internal.company.com"
BOM_FILE="bom-v${VERSION}.yaml"

echo "Mirroring images to ${PRIVATE_REGISTRY}..."

yq '.spec.containerImages[].image' "${BOM_FILE}" | while read source_image; do
  # Extract image name without registry
  image_name=$(echo "$source_image" | awk -F'/' '{print $NF}')
  target_image="${PRIVATE_REGISTRY}/splunk-ai/${image_name}"

  echo ""
  echo "Source: $source_image"
  echo "Target: $target_image"

  # Pull, tag, and push
  docker pull "$source_image"
  docker tag "$source_image" "$target_image"
  docker push "$target_image"

  echo "✅ Mirrored: $image_name"
done

echo ""
echo "All images mirrored successfully!"
echo "Update your values.yaml to use: ${PRIVATE_REGISTRY}/splunk-ai/"
EOF

chmod +x mirror-images.sh
./mirror-images.sh
```

### 9. Troubleshooting: Version Mismatch Issues

**Scenario:** Deployment failing, need to verify actual vs expected versions.

```bash
VERSION="0.2.0"
NAMESPACE="splunk-ai-operator-system"

# Download expected BOM
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/bom-v${VERSION}.yaml"

# Check deployed operator version
DEPLOYED_IMAGE=$(kubectl get deployment -n ${NAMESPACE} splunk-ai-operator-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}')
EXPECTED_IMAGE=$(yq '.spec.operatorImage' bom-v${VERSION}.yaml)

echo "Expected: $EXPECTED_IMAGE"
echo "Deployed: $DEPLOYED_IMAGE"

if [ "$DEPLOYED_IMAGE" = "$EXPECTED_IMAGE" ]; then
  echo "✅ Operator version matches"
else
  echo "❌ Version mismatch detected!"
fi

# Check all managed workloads
echo ""
echo "Checking managed components..."

# Check Ray deployment
kubectl get deployment -n splunk-ai ray-head -o jsonpath='{.spec.template.spec.containers[0].image}'
# Compare with: yq '.spec.containerImages[] | select(.name == "ray-head") | .image' bom-v${VERSION}.yaml
```

### 10. Generating Reports: Executive Summary

**Scenario:** Create an executive summary for stakeholders.

```bash
VERSION="0.2.0"

# Download files
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/bom-v${VERSION}.yaml"
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/compatibility-matrix.yaml"

# Generate summary
cat > executive-summary.md <<EOF
# Splunk AI Operator v${VERSION} - Deployment Summary

**Generated:** $(date -u +"%Y-%m-%d")

## Platform Requirements

- **Kubernetes:** $(yq '.platform.kubernetes.minVersion' compatibility-matrix.yaml) - $(yq '.platform.kubernetes.maxVersion' compatibility-matrix.yaml)
- **Splunk Enterprise:** $(yq '.platform.splunkEnterprise.recommended' compatibility-matrix.yaml)
- **Go Version:** $(yq '.platform.go.version' compatibility-matrix.yaml)

## Managed Components

| Component | Version | Status |
|-----------|---------|--------|
$(yq '.managedComponents | to_entries | .[] | "| " + .value.displayName + " | " + .value.versions[0].version + " | " + .value.versions[0].status + " |"' compatibility-matrix.yaml)

## Container Images

Total Images: $(yq '.spec.containerImages | length' bom-v${VERSION}.yaml)

\`\`\`
$(yq '.spec.containerImages[] | .name + ": " + .image' bom-v${VERSION}.yaml)
\`\`\`

## Security & Compliance

- ✅ SBOM Available (CycloneDX, SPDX formats)
- ✅ SLSA Provenance Attestation
- ✅ All images scanned for vulnerabilities
- ✅ Supply chain documentation complete

## Upgrade Path

$(yq '.upgradePaths[] | "**From " + .from + " to " + .to + "**\n- Automatic: " + (.automatic | tostring) + "\n- Breaking Changes: " + (.breaking | tostring) + "\n- Notes: " + .notes' compatibility-matrix.yaml)

---

For detailed technical information, see:
- compatibility-matrix.yaml
- bom-v${VERSION}.yaml
EOF

cat executive-summary.md
```

## Quick Command Reference

### Essential Commands

```bash
# Set your version
VERSION="0.2.0"

# Download compatibility matrix
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/compatibility-matrix.yaml"

# Download BOM (human-readable)
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/bom-v${VERSION}.txt"

# Download BOM (machine-readable)
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/bom-v${VERSION}.yaml"

# Download SBOM for scanning
curl -LO "https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}/sbom-operator-v${VERSION}.cyclonedx.json"

# Quick view BOM
cat bom-v${VERSION}.txt

# Check K8s compatibility
yq '.platform.kubernetes' compatibility-matrix.yaml

# List all managed images
yq '.spec.containerImages[].image' bom-v${VERSION}.yaml

# Scan for vulnerabilities
grype sbom:./sbom-operator-v${VERSION}.cyclonedx.json

# Scan operator image
trivy image ghcr.io/splunk/splunk-ai-operator:v${VERSION}
```

## Tools You'll Need

| Tool | Purpose | Installation |
|------|---------|--------------|
| **yq** | Parse YAML files | `brew install yq` or [download](https://github.com/mikefarah/yq) |
| **jq** | Parse JSON files | `brew install jq` or [download](https://jqlang.github.io/jq/) |
| **grype** | Vulnerability scanning | `brew install grype` or [download](https://github.com/anchore/grype) |
| **trivy** | Security scanning | `brew install trivy` or [download](https://github.com/aquasecurity/trivy) |
| **syft** | SBOM generation | `brew install syft` or [download](https://github.com/anchore/syft) |

## Best Practices

### Before Every Deployment

1. ✅ Download and review `compatibility-matrix.yaml`
2. ✅ Verify your Kubernetes version is supported
3. ✅ Check required services are installed
4. ✅ Scan images for vulnerabilities
5. ✅ Review upgrade path if upgrading

### For Compliance

1. ✅ Archive BOM/SBOM for each deployed version
2. ✅ Upload SBOM to vulnerability tracking platform
3. ✅ Document any security exceptions
4. ✅ Track component versions in asset inventory

### For Operations

1. ✅ Monitor CVE feeds for components in BOM
2. ✅ Plan upgrades when new versions available
3. ✅ Test upgrades in non-prod first
4. ✅ Keep BOM/compatibility matrix accessible to team

## Need Help?

- **Documentation:** [bill-of-materials.md](./bill-of-materials.md)
- **Issues:** https://github.com/splunk/splunk-ai-operator/issues
- **Discussions:** https://github.com/splunk/splunk-ai-operator/discussions
