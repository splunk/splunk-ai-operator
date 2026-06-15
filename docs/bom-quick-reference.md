# BOM & Compatibility Matrix - Quick Reference Card

## 📥 Download Files

```bash
VERSION="0.2.0"
BASE_URL="https://github.com/splunk/splunk-ai-operator/releases/download/v${VERSION}"

# Essential files
curl -LO "${BASE_URL}/compatibility-matrix.yaml"
curl -LO "${BASE_URL}/bom-v${VERSION}.txt"
curl -LO "${BASE_URL}/bom-v${VERSION}.yaml"
```

## 🔍 Quick Checks

### Check if My Cluster is Compatible
```bash
# Your cluster version
kubectl version --short

# Required version range
yq '.platform.kubernetes | "min: \(.minVersion) max: \(.maxVersion)"' compatibility-matrix.yaml
```

### List All Container Images
```bash
yq '.spec.containerImages[].image' bom-v${VERSION}.yaml
```

### Check Splunk Enterprise Version
```bash
yq '.spec.dependencies.splunkEnterpriseVersion' bom-v${VERSION}.yaml
```

## 🛡️ Security Scanning

### Scan Operator for Vulnerabilities
```bash
trivy image ghcr.io/splunk/splunk-ai-operator:v${VERSION}
```

### Scan Using SBOM
```bash
curl -LO "${BASE_URL}/sbom-operator-v${VERSION}.cyclonedx.json"
grype sbom:./sbom-operator-v${VERSION}.cyclonedx.json
```

### Scan All Managed Images
```bash
yq '.spec.containerImages[].image' bom-v${VERSION}.yaml | while read img; do
  echo "Scanning: $img"
  trivy image "$img" --severity HIGH,CRITICAL
done
```

## 📋 What Each File Contains

| File | Contains | Use For |
|------|----------|---------|
| `compatibility-matrix.yaml` | K8s versions, required services, component versions | Pre-deployment checks |
| `bom-v0.2.0.txt` | All images + dependency versions | Quick review |
| `bom-v0.2.0.yaml` | Machine-readable BOM | Automation, scripts |
| `sbom-operator-v0.2.0.cyclonedx.json` | Software dependencies | Vulnerability scanning |

## 🎯 Common Tasks

### Pre-Deployment Checklist
```bash
# 1. Check Kubernetes compatibility
yq '.platform.kubernetes' compatibility-matrix.yaml

# 2. Verify cert-manager installed
kubectl get deployment -n cert-manager cert-manager

# 3. Scan for vulnerabilities
trivy image ghcr.io/splunk/splunk-ai-operator:v${VERSION}

# 4. Review managed components
yq '.managedComponents | keys' compatibility-matrix.yaml
```

### Verify Deployed Version
```bash
# Expected version
yq '.spec.operatorImage' bom-v${VERSION}.yaml

# Actual deployed version
kubectl get deployment -n splunk-ai-operator-system \
  splunk-ai-operator-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### Create Compliance Report
```bash
# Download files
curl -sLO "${BASE_URL}/bom-v${VERSION}.txt"

# Print report
cat bom-v${VERSION}.txt
```

## 🔧 Required Tools

```bash
# Install tools (macOS)
brew install yq jq grype trivy

# Verify installation
yq --version
grype version
trivy --version
```

## 📖 Full Documentation

- **Detailed Guide:** [docs/using-bom-compatibility.md](./using-bom-compatibility.md)
- **BOM Overview:** [docs/bill-of-materials.md](./bill-of-materials.md)
- **Issues:** https://github.com/splunk/splunk-ai-operator/issues

## 💡 Pro Tips

1. **Save locally:** Keep BOM for each deployed version
   ```bash
   mkdir -p ~/bom-archive/v${VERSION}
   cd ~/bom-archive/v${VERSION}
   curl -LO "${BASE_URL}/bom-v${VERSION}.yaml"
   curl -LO "${BASE_URL}/compatibility-matrix.yaml"
   ```

2. **Automated checks:** Add to CI/CD pipeline
   ```yaml
   - run: yq '.platform.kubernetes.minVersion' compatibility-matrix.yaml
   - run: grype sbom:./sbom-operator-v${VERSION}.cyclonedx.json
   ```

3. **Monitor CVEs:** Upload SBOM to Dependency-Track for continuous monitoring

4. **Air-gap deployments:** Extract all images from BOM before mirroring
   ```bash
   yq '.spec.containerImages[].image' bom-v${VERSION}.yaml > images.txt
   ```
