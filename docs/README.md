# Splunk AI Operator Documentation

Welcome to the Splunk AI Operator documentation!

## Getting Started

1. **[Installation Guide](installation.md)** - Install the operator in your Kubernetes cluster
2. **[API Reference](api-reference.md)** - Complete CRD specification
3. **[Local Development](local-development.md)** - Set up local development environment
4. **[Troubleshooting](troubleshooting.md)** - Common issues and solutions

## Deployment Guides

- **[Helm Deployment](deployment/helm-deployment.md)** - Deploy using Helm charts
- **[AWS EKS Deployment](deployment/deployment-aws-eks.md)** - Production deployment on AWS EKS

## Configuration Guides

- **[Storage Configuration](configuration/storage-configuration.md)** - Persistent storage for Weaviate vector database
- **[Storage Artifacts](configuration/storage-artifacts.md)** - S3 and S3-compatible storage for AI models
- **[Ingress Configuration](configuration/ingress-configuration.md)** - Expose AI services externally
- **[Webhook Certificates](configuration/webhook-certificates.md)** - Configure admission webhook TLS

## Project Documentation

- **[Open Source Readiness](project/OPEN_SOURCE_READINESS.md)** - OSS preparation checklist
- **[OSS Preparation Summary](project/OSS_PREPARATION_SUMMARY.md)** - Complete summary of OSS prep work
- **[Documentation Organization](project/DOCUMENTATION_ORGANIZATION.md)** - How docs are organized

## Quick Reference

### Check if Platform is Ready
```bash
kubectl get aiplatform <name> -n <namespace>
```

### View Status Details
```bash
kubectl get aiplatform <name> -n <namespace> -o jsonpath='{.status.conditions}'
```

### Watch Events
```bash
kubectl get events -n <namespace> --watch --field-selector involvedObject.name=<name>
```

### Common Tasks

**Configure persistent storage:**
```yaml
spec:
  storage:
    vectorDB:
      size: "100Gi"
      storageClassName: "gp3"
```

**Enable external access:**
```yaml
spec:
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: ai.example.com
        paths:
          - path: /
            pathType: Prefix
```

**Check what's failing:**
```bash
kubectl get aiplatform <name> -o jsonpath='{.status.conditions}' | jq '.[] | select(.status=="False")'
```

## Need Help?

1. Check [Error Handling and Events](troubleshooting.md) for troubleshooting guides
2. View operator logs: `kubectl logs -n splunk-ai-operator-system deployment/splunk-ai-operator-controller-manager`
3. Report issues with diagnostic info (see troubleshooting guide)

## Documentation Organization

- **Getting Started** - Installation and basic setup
- **Configuration Guides** - Detailed configuration for specific features
- **Monitoring** - Understanding status and troubleshooting
- **Architecture** - System design and components
