---
name: Bug Report
about: Report a bug to help us improve
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description

A clear and concise description of what the bug is.

## Environment

- **Operator Version**: [e.g., v0.2.0]
- **Kubernetes Version**: [e.g., v1.31.13]
- **Cloud Provider**: [e.g., AWS EKS, GKE, AKS, k0s]
- **OS**: [e.g., Ubuntu 22.04]
- **Deployment Method**: [e.g., Helm, YAML manifests, Kustomize]

## Steps to Reproduce

1. Deploy operator with '...'
2. Apply CRD '...'
3. Observe error '...'
4. See error

## Expected Behavior

A clear and concise description of what you expected to happen.

## Actual Behavior

A clear and concise description of what actually happened.

## Logs

<details>
<summary>Operator Logs</summary>

```
Paste operator pod logs here:
kubectl logs -n splunk-ai-operator-system -l app.kubernetes.io/name=splunk-ai-operator
```

</details>

<details>
<summary>Resource Status</summary>

```
Paste relevant resource status here:
kubectl describe aiplatform <name> -n <namespace>
```

</details>

## Configuration

<details>
<summary>AIPlatform YAML</summary>

```yaml
# Paste your AIPlatform or relevant CRD YAML here
```

</details>

<details>
<summary>Helm Values (if using Helm)</summary>

```yaml
# Paste your custom Helm values here
```

</details>

## Additional Context

Add any other context about the problem here, such as:
- Recent changes to your cluster
- Related issues or PRs
- Workarounds you've tried
- Screenshots (if applicable)

## Possible Solution

If you have an idea of what might be causing the issue or how to fix it, please share it here.
