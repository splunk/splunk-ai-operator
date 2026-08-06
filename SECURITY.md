# Security Policy

## Supported Versions

The Splunk AI Operator project maintains security updates for the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1   | :x:                |

Once version 1.0.0 is released, we will provide security updates for:
- The latest stable release
- The previous major version for 6 months after a new major release

## Reporting a Vulnerability

We take the security of the Splunk AI Operator seriously. If you discover a security vulnerability, please follow these steps:

### Private Disclosure Process

**DO NOT** create a public GitHub issue for security vulnerabilities.

1. **Email**: Send details to **splunkai@cisco.com** with:
   - Subject line: `[SECURITY] Brief description`
   - Detailed description of the vulnerability
   - Steps to reproduce the issue
   - Potential impact assessment
   - Any proof-of-concept code (if applicable)
   - Suggested fix (if you have one)

2. **Response Time**:
   - Initial acknowledgment: Within 48 hours
   - Status update: Within 5 business days
   - Fix timeline: Depends on severity (see below)

3. **Severity Levels**:
   - **Critical**: Fix within 7 days
   - **High**: Fix within 30 days
   - **Medium**: Fix within 90 days
   - **Low**: Fix in next scheduled release

### What to Expect

1. **Acknowledgment**: We'll confirm receipt of your report within 48 hours
2. **Investigation**: Our team will investigate and may request additional information
3. **Updates**: We'll keep you informed about our progress
4. **Fix & Release**: We'll develop, test, and release a fix
5. **Public Disclosure**: After the fix is released, we'll publicly disclose the vulnerability (with credit to you, if desired)
6. **CVE Assignment**: For significant vulnerabilities, we'll work to get a CVE assigned

### Security Updates

Security patches will be released as:
- Patch releases for the current minor version (e.g., 0.1.2 → 0.1.3)
- Backported to supported versions when applicable
- Announced via GitHub Security Advisories
- Documented in CHANGELOG.md

Subscribe to security updates:
- Watch this repository on GitHub (Settings → Watch → Custom → Security alerts)
- Check [GitHub Security Advisories](https://github.com/splunk/splunk-ai-operator/security/advisories)

## Security Best Practices

When deploying the Splunk AI Operator:

### 1. Image Security
- Always use official images from trusted registries
- Verify image signatures when available
- Scan images for vulnerabilities before deployment
- Use specific version tags, avoid `latest`

```yaml
# Good
image: ghcr.io/splunk/splunk-ai-operator:v0.2.0

# Avoid
image: ghcr.io/splunk/splunk-ai-operator:latest
```

### 2. RBAC Configuration
- Follow principle of least privilege
- Review and customize RBAC permissions for your environment
- Regularly audit service account permissions
- Use namespace-scoped roles when possible

### 3. Network Security
- Enable Kubernetes Network Policies
- Restrict ingress/egress traffic
- Use private registries for sensitive deployments
- Use a service mesh or gateway that validates client certificates when mutual
  TLS is required. The legacy `spec.mtls` field currently enables one-way
  server TLS only.

### 4. Secrets Management
- Never commit secrets to version control
- Use Kubernetes Secrets or external secret managers (HashiCorp Vault, AWS Secrets Manager)
- Enable encryption at rest for etcd
- Rotate credentials regularly

```bash
# Create secret securely
kubectl create secret generic splunk-credentials \
  --from-literal=hec-token=$(openssl rand -base64 32) \
  --namespace ai-platform
```

### 5. Monitoring & Logging
- Enable audit logging in Kubernetes
- Monitor for suspicious activity
- Set up alerts for security events
- Review logs regularly

### 6. Updates & Patching
- Keep the operator updated to the latest stable version
- Subscribe to security advisories
- Test updates in non-production environments first
- Maintain a rollback plan

### 7. Cluster Security
- Keep Kubernetes updated
- Enable Pod Security Standards/Policies
- Use dedicated namespaces for isolation
- Regularly scan cluster for misconfigurations

```yaml
# Example: Enable Pod Security Standards
apiVersion: v1
kind: Namespace
metadata:
  name: ai-platform
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

## Known Security Considerations

### 1. Service Account Permissions
The operator requires cluster-wide permissions to manage resources across namespaces. Review the RBAC configuration in `config/rbac/` to understand the required permissions.

### 2. Custom Resource Definitions (CRDs)
The operator installs CRDs that define new resource types. Ensure only authorized users can create/modify these resources.

### 3. Webhook Security
The operator uses admission webhooks for validation and mutation. These require TLS certificates which are automatically managed by cert-manager.

### 4. Image Pull Secrets
If using private registries, ensure `imagePullSecrets` are properly configured and credentials are securely stored.

## Vulnerability Scanning

We continuously scan our codebase and dependencies for vulnerabilities using:

- **GitHub Dependabot**: Automated dependency updates
- **CodeQL**: Semantic code analysis
- **Trivy**: Container image and filesystem scanning
- **Snyk**: Open source dependency scanning (planned)

Scan results are reviewed by maintainers and addressed based on severity.

## Third-Party Dependencies

The Splunk AI Operator relies on several third-party components:

- **Kubernetes**: Follow Kubernetes security best practices
- **Ray (KubeRay)**: Review Ray security documentation
- **cert-manager**: Keep cert-manager updated for webhook TLS
- **Prometheus Operator**: Follow Prometheus security guidelines
- **OpenTelemetry**: Review OTEL security considerations

Refer to each component's security documentation for specific guidance.

## Security Tooling

### Container Scanning
```bash
# Scan operator image with Trivy
trivy image ghcr.io/splunk/splunk-ai-operator:v0.2.0

# Scan with Grype
grype ghcr.io/splunk/splunk-ai-operator:v0.2.0
```

### Kubernetes Security Scanning
```bash
# Scan cluster with kubescape
kubescape scan

# Scan manifests with kube-bench
kube-bench run --targets master,node

# Check for misconfigurations
checkov -d config/
```

### RBAC Analysis
```bash
# Audit RBAC permissions
kubectl auth can-i --list --as=system:serviceaccount:splunk-ai-operator-system:splunk-ai-operator-controller-manager

# Use rbac-tool for analysis
rbac-tool viz --include-subjects=".*splunk.*"
```

## Compliance

The Splunk AI Operator is designed to support deployments in regulated environments. For compliance requirements:

- **GDPR**: The operator does not collect or process personal data by default
- **HIPAA**: Can be deployed in HIPAA-compliant Kubernetes clusters with appropriate controls
- **SOC 2**: Follow security best practices and enable audit logging
- **FedRAMP**: Use in approved cloud environments with required security controls

Consult with your security and compliance teams for specific requirements.

## Security Contacts

- **Primary**: splunkai@cisco.com
- **GitHub Security Advisories**: https://github.com/splunk/splunk-ai-operator/security/advisories
- **Splunk Security**: For issues affecting other Splunk products, see [Splunk Security](https://www.splunk.com/en_us/product-security.html)

## Hall of Fame

We recognize security researchers who responsibly disclose vulnerabilities:

- *No vulnerabilities reported yet*

Thank you to all security researchers who help keep Splunk AI Operator secure!

## Additional Resources

- [Kubernetes Security Documentation](https://kubernetes.io/docs/concepts/security/)
- [OWASP Kubernetes Top 10](https://owasp.org/www-project-kubernetes-top-ten/)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [NSA Kubernetes Hardening Guide](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF)

---

**Last Updated**: 2025-01-17

For general questions, please use [GitHub Discussions](https://github.com/splunk/splunk-ai-operator/discussions). For security issues, use the private disclosure process above.
