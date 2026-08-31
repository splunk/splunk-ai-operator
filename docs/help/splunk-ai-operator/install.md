# Install the Splunk AI Operator

This page describes the supported installation patterns. Replace the version placeholders with
the version listed in the release-specific compatibility matrix.

## Install from an OCI chart

OCI installation is the recommended method when the cluster can access the chart registry.

Review and accept the applicable Splunk General Terms before installation.

```bash
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version <operator-version> \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --set splunk-operator.acceptGeneralTerms=true \
  --set splunk-operator.splunkOperator.splunkGeneralTerms="<required-value>"
```

The required terms-acceptance value is documented by the Splunk Operator for Kubernetes
installation instructions.

## Install from a release package

Use the release package when OCI registry access is unavailable or when the environment requires
an approved release artifact.

```bash
helm install splunk-ai-operator \
  https://github.com/splunk/splunk-ai-operator/releases/download/<release-tag>/splunk-ai-operator-<operator-version>.tgz \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --set splunk-operator.acceptGeneralTerms=true \
  --set splunk-operator.splunkOperator.splunkGeneralTerms="<required-value>"
```

## Install from Kubernetes manifests

Use the release manifest when Helm is not available.

```bash
kubectl apply -f https://github.com/splunk/splunk-ai-operator/releases/download/<release-tag>/install-<operator-version>.yaml
```

Use the manifest published for the exact operator release. Do not mix CRDs or manifests from
different releases.

## Air-gapped installation

For an air-gapped cluster:

1. Download the approved operator and platform charts on a connected machine.
2. Download or mirror all required container images into the private registry.
3. Transfer charts, image metadata, model artifacts, and configuration to the secured environment.
4. Create image-pull and storage credentials in the target cluster.
5. Update the values file to use private registry locations.
6. Install the operator and verify its pods before creating an `AIPlatform` resource.

The air-gapped process must include every transitive image used by the selected platform features.
Use the release bill of materials to build the image-mirroring list.

## Verify the operator

```bash
kubectl get pods -n splunk-ai-operator-system
kubectl get crds | grep ai.splunk.com
kubectl logs -n splunk-ai-operator-system \
  -l control-plane=controller-manager --tail=100
```

The operator pod should be `Running`, and the AI Platform CRDs should be present before you
continue.

## Install with namespace scope

By default, the operator can watch all namespaces. To restrict it, set the chart's watch namespace
value and install the operator in the selected namespace:

```bash
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version <operator-version> \
  --namespace <operator-namespace> \
  --create-namespace \
  --set watchNamespace=<workload-namespace> \
  --set splunk-operator.acceptGeneralTerms=true \
  --set splunk-operator.splunkOperator.splunkGeneralTerms="<required-value>"
```

Confirm that the operator's RBAC and watch scope match the namespaces where AI Platform resources
will be created.
