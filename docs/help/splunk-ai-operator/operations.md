# Operations and lifecycle management

Use Kubernetes resources, status conditions, events, and logs to operate the platform.

## Check platform health

```bash
kubectl get aiplatform <platform-name> -n <namespace>
kubectl get aiservice -n <namespace>
kubectl get pods -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

Inspect conditions when a resource is not ready:

```bash
kubectl get aiplatform <platform-name> -n <namespace> \
  -o jsonpath='{.status.conditions}'
```

## View logs

```bash
kubectl logs -n splunk-ai-operator-system \
  -l control-plane=controller-manager --tail=200
kubectl logs -n <namespace> \
  -l app=<platform-name>-saia \
  --all-containers=true --prefix --tail=200
```

SAIA pod templates use `app=<AIPlatform-name>-saia`. Confirm that a selector returns pods with
`kubectl get pods` before relying on it for logs.

## Scale workloads

Set `AIPlatform.spec.scaleFactor` to a positive integer. It multiplies both the base Ray Serve
model-replica counts and every Ray worker-group count in the selected accelerator profile,
including its zero-GPU group:

```bash
kubectl patch aiplatform <platform-name> -n <namespace> \
  --type=merge \
  -p '{"spec":{"scaleFactor":2}}'
kubectl get pods -n <namespace> --watch
```

The default and minimum value is `1`. It does not change SAIA or SLIM replicas or per-pod resource
requests and limits. Do not edit generated `RayService` or `RayCluster` resources directly, and do
not scale beyond available CPU, memory, GPU, storage, or object-store capacity.

## Maintenance and upgrades

The initial v1.0 release does not support an in-place version-to-version AI Platform upgrade. The
published `1.0.0` chart is not a supported direct installation or maintenance path. Do not use
`helm upgrade` or change `features[].version` to move workloads to another release.

Before any approved maintenance operation:

1. Review the [release information](release-notes.md) and
   [qualified deployment platforms](prerequisites.md#cluster-requirements).
2. Retain the configuration file used by the original platform installer.
3. Back up custom resources, configuration, and important persistent data.
4. Obtain the release-specific procedure from Splunk Support or the selected platform guide.
5. Use the same k0s or OpenShift installer path that created the deployment.
6. Verify status conditions, running images, and application behavior.

The k0s guide documents its supported
[common operations](../../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#common-operations). For
OpenShift, use only an operation documented in the
[OpenShift onboarding guide](../../../tools/cluster_setup/OPENSHIFT_README.md). Contact Splunk
Support when the required maintenance operation is not documented.

After maintenance, verify the operator rollout and the images actually running in the workload
namespace. The pod query includes KubeRay head and worker pods and any init containers:

```bash
kubectl rollout status \
  deployment/splunk-ai-operator-controller-manager \
  --namespace splunk-ai-operator-system --timeout 5m
kubectl get pods -n <namespace> \
  -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].image,INIT-CONTAINERS:.spec.initContainers[*].image'
```

## Uninstall

Before uninstalling, determine which persistent volumes, object-store data, Secrets, and custom
resources must be retained. The following installer commands remove the AI Platform stack; the k0s
`delete` command also deletes the k0s cluster. Run the command for the platform that created the
deployment from `tools/cluster_setup`. The k0s flow prompts for the cluster name; the OpenShift flow
prompts for `yes`. Confirm the displayed target carefully.

```bash
# k0s
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh delete

# OpenShift
CONFIG_FILE=./openshift-cluster-config.yaml ./openshift_with_stack.sh delete
```

The OpenShift command leaves the underlying OpenShift cluster and nodes running. Follow the
release-specific cleanup procedure for persistent data and shared dependency operators. Do not
remove a dependency CRD while corresponding custom resources remain.
