# Install the Splunk AI Operator

Use the release-qualified installer for the selected platform. The installer installs, verifies,
or reuses the required dependency operators and renders the Splunk AI Operator manifest with the
qualified runtime and workload-image values.

## k0s installation

Follow the appropriate section of the k0s deployment guide:

- [Standard deployment](../../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#standard-deployment-internet-connected)
- [Air-gapped deployment](../../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#air-gapped-deployment-no-internet-on-cluster)

Run commands from `tools/cluster_setup` and use the configuration file documented for the
selected flow. Do not apply the operator artifact separately before running the installer.

## OpenShift installation

Follow the OpenShift onboarding guide:

- [OpenShift quick start](../../../tools/cluster_setup/OPENSHIFT_README.md#quick-start)
- [OpenShift air-gapped deployment](../../../tools/cluster_setup/OPENSHIFT_README.md#air-gapped-deployment)

Before running the OpenShift installer, replace the development image references in its sample
configuration with these qualified images, or their digest-equivalent private-registry mirrors:

```yaml
images:
  operator:
    image: docker.io/splunk/splunk-ai-operator:v1.0
  ray:
    headImage: docker.io/splunk/ai-tier-ray-head:v1.0
    workerImage: docker.io/splunk/ai-tier-ray-worker:v1.0
  saia:
    apiImage: docker.io/splunk/ai-tier-saia-api:v1.0
    apiV2Image: docker.io/splunk/ai-tier-saia-api-v2:v1.0
    dataLoaderImage: docker.io/splunk/ai-tier-saia-data-loader:v1.0
  slim:
    apiImage: docker.io/splunk/ai-tier-slim-service:v1.0

operators:
  ray:
    rayVersion: "2.56.0"
```

Do not use the sample's development or test tags for a release deployment. Preserve all other
required OpenShift configuration fields described by the onboarding guide. `features[].version`
is metadata and can be omitted; it does not select these images.

The bundled Splunk Operator manifest contains the Splunk General Terms acceptance flag, and the
installers do not prompt for separate confirmation. Review the
[Splunk General Terms requirements](https://github.com/splunk/splunk-operator#splunk-general-terms-acceptance)
and run an installer only if you are authorized to accept them for the deployment.

## Direct artifact limitations

Do not install this release directly from the published `1.0.0` OCI chart, packaged chart, or
standalone Kubernetes manifest.

- The chart embeds workload-image defaults outside the qualified v1.0 combination and fixes
  `RAY_VERSION` at `2.44.0`. Image-value overrides alone cannot select the qualified Ray `2.56.0`
  runtime.
- The standalone manifest assumes that dependency CRDs and controllers already exist and does not
  install cert-manager, Prometheus Operator, KubeRay, or any enabled OpenTelemetry or Splunk
  Operator dependencies.

The platform installers supply and verify those dependencies, runtime settings, and images. A
future direct-chart or manifest installation path must be explicitly identified as supported by
its release documentation.

## Air-gapped installation

Follow the selected platform guide's complete air-gapped flow. Set mirror locations in that
installer's YAML configuration file; do not substitute a generic Helm values file. The installer
creates the `AIPlatform` as part of the stack installation, so do not create it independently
during this flow.

The air-gapped process must include every transitive dependency-chart, hook, operator, and workload
image used by the selected features. Do not use the operator release BOM alone as the mirroring
list; it does not enumerate every transitive image.

## Verify the operator

```bash
kubectl rollout status \
  deployment/splunk-ai-operator-controller-manager \
  --namespace splunk-ai-operator-system \
  --timeout 5m
kubectl wait --for=condition=Established --timeout=60s \
  crd/aiplatforms.ai.splunk.com \
  crd/aiservices.ai.splunk.com
kubectl logs -n splunk-ai-operator-system \
  -l control-plane=controller-manager --tail=100
```

The rollout and CRD waits must succeed before you continue. Also verify the enabled dependency
operators are ready.

## Operator scope

The current release is cluster-scoped and uses cluster-wide RBAC. A `WATCH_NAMESPACE` environment
variable or chart `watchNamespace` value does not restrict the manager cache or permissions and
must not be treated as a namespace-isolation or security control.
