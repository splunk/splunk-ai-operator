# Troubleshooting with Events and Status

This guide helps you understand what's happening with your AI Platform deployments using Kubernetes events and status conditions.

## Quick Start

### Is My Platform Ready?

```bash
# Check overall status
kubectl get aiplatform <name> -n <namespace>

# Get detailed readiness
kubectl get aiplatform <name> -n <namespace> -o jsonpath='{.status.conditions[?(@.type=="Ready")]}'
```

If `status: "True"` - your platform is ready!
If `status: "False"` - check the message field for what's wrong.

### What's Happening Right Now?

```bash
# Watch events in real-time
kubectl get events -n <namespace> --watch --field-selector involvedObject.name=<name>

# See recent events
kubectl describe aiplatform <name> -n <namespace> | tail -30
```

## Understanding Status Conditions

Your AI Platform tracks several health indicators:

### Platform Components

| Condition | What It Means | When It's False |
|-----------|---------------|-----------------|
| `Ready` | Everything is working | One or more components have issues |
| `RayServiceReady` | Ray cluster is operational | Ray is starting, upgrading, or failed |
| `RayClusterReady` | Ray pods are running | Pods are pending, failing, or not enough replicas |
| `RayServeRouteReady` | AI inference API is available | Applications failed to deploy or endpoints not ready |
| `WeaviateDatabaseReady` | Vector database is running | Weaviate pods are not ready |
| `IngressReady` | External access is configured | Ingress hasn't received an address yet |

### Check Specific Components

```bash
# Check if Ray is ready
kubectl get aiplatform <name> -n <namespace> \
  -o jsonpath='{.status.conditions[?(@.type=="RayServiceReady")]}'

# Check if Weaviate is ready
kubectl get aiplatform <name> -n <namespace> \
  -o jsonpath='{.status.conditions[?(@.type=="WeaviateDatabaseReady")]}'

# Check if external access is ready
kubectl get aiplatform <name> -n <namespace> \
  -o jsonpath='{.status.conditions[?(@.type=="IngressReady")]}'
```

## Understanding Events

Events tell you what's happening as your platform deploys and runs.

### Normal Events (Good News)

These indicate successful operations:

| Event | Meaning |
|-------|---------|
| `RayServiceCreated` | Ray cluster was created successfully |
| `RayServiceReady` | Ray cluster is now operational |
| `RayClusterReady` | All Ray pods are running |
| `RayServeReady` | AI inference endpoints are available |
| `WeaviateCreated` | Vector database was created |
| `WeaviateReady` | Vector database is operational |
| `IngressCreated` | External access was configured |
| `IngressReady` | External URL is now available |
| `PlatformReady` | Everything is working! |

### Warning Events (Needs Attention)

These indicate problems that need investigation:

| Event | What's Wrong | What To Do |
|-------|--------------|------------|
| `PlatformDegraded` | One or more components failing | Check the message to see which components |
| `RayServiceNotReady` | Ray cluster is unhealthy | Check Ray pods and logs |
| `RayApplicationErrors` | AI models failed to load | Check application logs and model paths |
| `RayClusterNotReady` | Ray pods are failing | Check pod status and events |
| `WeaviateNotReady` | Vector database is failing | Check Weaviate pod status |
| `IngressNotReady` | External access lost | Check Ingress controller |

## Common Troubleshooting Scenarios

### Scenario 1: Platform Stuck in "Not Ready"

**Check what's failing:**
```bash
kubectl get aiplatform <name> -n <namespace> -o jsonpath='{.status.conditions}' | jq '.[] | select(.status=="False")'
```

This shows all components that aren't ready yet.

**Check recent events:**
```bash
kubectl get events -n <namespace> --field-selector involvedObject.name=<name> --sort-by='.lastTimestamp' | tail -20
```

### Scenario 2: AI Models Won't Load

**Symptoms:**
- Events show `RayApplicationErrors`
- Status condition `RayServeRouteReady` is False

**Check which models are failing:**
```bash
# View detailed error messages
kubectl get aiplatform <name> -n <namespace> \
  -o jsonpath='{.status.conditions[?(@.type=="RayServeRouteReady")].message}'

# Check Ray Serve logs
kubectl logs -l ray.io/cluster=<name> -n <namespace> | grep -i error
```

**Common causes:**
- Model files not in S3/object storage
- Wrong S3 bucket path in `objectStorage.path`
- IAM permissions issues (IRSA not configured correctly)
- Model files are corrupted or wrong format

### Scenario 3: Weaviate Database Issues

**Symptoms:**
- Events show `WeaviateNotReady`
- Status condition `WeaviateDatabaseReady` is False

**Check Weaviate status:**
```bash
# Check StatefulSet
kubectl get statefulset <name>-weaviate -n <namespace>

# Check pods
kubectl get pods -l app=<name>-weaviate -n <namespace>

# Check logs
kubectl logs <name>-weaviate-0 -n <namespace>
```

**Common causes:**
- Persistent volume not provisioned (check PVC)
- Resource limits too low
- Storage class not available

### Scenario 4: Can't Access from Outside

**Symptoms:**
- Ingress is enabled but can't access the URL
- Status condition `IngressReady` is False

**Check Ingress status:**
```bash
# View Ingress resource
kubectl get ingress <name> -n <namespace>

# Check if address is assigned
kubectl describe ingress <name> -n <namespace>

# Check Ingress controller logs
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller
```

**Common causes:**
- Ingress controller not installed
- DNS not pointing to LoadBalancer IP
- Wrong Ingress class name
- Certificate not issued (if using TLS)

## View Detailed Errors

### Ray Application Errors

When AI models fail to load, you'll see detailed errors:

```bash
# View application errors
kubectl get events -n <namespace> \
  --field-selector involvedObject.name=<name>,reason=RayApplicationErrors

# Check specific application logs
kubectl logs -l ray.io/node-type=worker -n <namespace> | grep <app-name>
```

**Example error messages:**
- `FileNotFoundError: model_artifacts/my-model/model.bin` → Check S3 path
- `CUDA_VISIBLE_DEVICES is set to empty string` → GPU configuration issue
- `RuntimeError: CUDA out of memory` → Increase GPU resources

#### "Invalid repository ID or local directory" (e.g. Llama31Instruct / VLLMTextGenModel)

If you see a validation error like:

```text
Invalid repository ID or local directory specified: '/home/ray/.cache/s3/artifacts/model_artifacts/llama31-8b-instruct'.
Please verify the following requirements:
1. Provide a valid Hugging Face repository ID.
2. Specify a local directory that contains a recognized configuration file.
   - For Hugging Face models: ensure the presence of a 'config.json'.
```

the model loader is trying to use a **local path** where the model should have been downloaded from object storage (S3/MinIO). That path is either missing or does not contain the required files (e.g. `config.json`). Common causes:

1. **Model not in object storage**  
   The prefix `model_artifacts/llama31-8b-instruct` must exist in your bucket with a full Hugging Face–style layout (including `config.json` and weight files).
   - Download: `./tools/artifacts_download_upload_scripts/download_from_huggingface.sh`
   - Upload to MinIO/S3-compatible: `./tools/artifacts_download_upload_scripts/upload_to_minio.sh` (set `S3COMPAT_OBJECT_STORE_ENDPOINT`, `S3COMPAT_OBJECT_STORE_BUCKET`, and credentials as in the [artifacts README](../../tools/artifacts_download_upload_scripts/README.md); `MINIO_*` env vars are also accepted).

2. **Ray workers cannot reach MinIO/S3**  
   - For **external MinIO** (e.g. EC2): ensure the MinIO endpoint in `cluster-config.yaml` (`storage.minio.endpoint`) is reachable from EKS (security groups, VPC, and if using a public IP, that nodes can egress to it).
   - From a Ray worker pod:  
     `kubectl exec -it -n <namespace> <ray-worker-pod> -- env | grep -E 'OBJECT_STORE|ARTIFACTS|S3'`  
     then test connectivity (e.g. curl to the object store endpoint or use the same client the SDK uses).

3. **Wrong or missing credentials**  
   AIPlatform must have `objectStorage.secretRef` pointing to a secret with `s3_access_key` and `s3_secret_key` (the operator passes these as `S3COMPAT_OBJECT_STORE_ACCESS_KEY` / `S3COMPAT_OBJECT_STORE_SECRET_KEY` to Ray). Verify the secret exists and matches the S3-compatible account that can read the bucket:
   - `kubectl get secret minio-credentials -n <namespace> -o jsonpath='{.data}'`

4. **Bucket/prefix mismatch**  
   The bucket name in AIPlatform `objectStorage.path` (e.g. `minio://<bucket>`) and the prefix in the application config (`model_artifacts/llama31-8b-instruct`) must match where you uploaded the model.

**Quick checks:**

- List objects in the object store for the model prefix (from a host with `mc` or AWS CLI configured):
  - `mc ls myminio/<bucket>/model_artifacts/llama31-8b-instruct/`  
  You should see at least `config.json` and the model weight files.
- From a Ray worker pod, confirm env vars and that the path is writable:
  - `kubectl exec -it -n <namespace> <ray-worker-pod> -- ls -la /home/ray/.cache/s3/artifacts/model_artifacts/ 2>/dev/null || echo "path missing or empty"`
  If the directory is missing or empty, the download from object storage failed (network, credentials, or missing objects).

**Full reset when the deployment keeps failing (e.g. Llama31Instruct / LLMDeploymentL40S):**

If the model is correct in object storage and credentials are in the serve config but the replica still fails with "Invalid repository ID or local directory", clear the artifact cache and restart Ray so replicas run a fresh download and load.

1. **Clear the artifact cache on all workers**  
   Either remove only the failing model prefix or the entire `model_artifacts` tree (more thorough):

   ```bash
   export AI_NS="${AI_NS:-ai-platform}"

   # Option A: clear only the failing model (e.g. llama31-8b-instruct)
   for p in $(kubectl get pods -n "$AI_NS" -l ray.io/node-type=worker -o jsonpath='{.items[*].metadata.name}'); do
     kubectl exec -n "$AI_NS" "$p" -c ray-worker -- rm -rf /home/ray/.cache/s3/artifacts/model_artifacts/llama31-8b-instruct
   done

   # Option B: clear entire model_artifacts (use if multiple models or unknown state)
   for p in $(kubectl get pods -n "$AI_NS" -l ray.io/node-type=worker -o jsonpath='{.items[*].metadata.name}'); do
     kubectl exec -n "$AI_NS" "$p" -c ray-worker -- rm -rf /home/ray/.cache/s3/artifacts/model_artifacts
   done
   ```

2. **Restart worker pods** so new replicas run and download from object storage:

   ```bash
   kubectl delete pods -n "$AI_NS" -l ray.io/node-type=worker
   ```

3. **Optional: restart the Ray head** to force a full Ray Serve redeploy (new replica placement and startup):

   ```bash
   kubectl delete pod -n "$AI_NS" -l ray.io/node-type=head
   ```

4. **Wait 10–15 minutes** for workers (and head) to be Running and for the deployment replica to download the model and start. The first download can be large (e.g. ~16 GB for Llama 3.1 8B); if the replica is restarted too soon (e.g. after a few quick failures), the download may never complete.

5. **Verify** the deployment status and, if needed, that a worker has the model:

   ```bash
   kubectl get rayservice <rayservice-name> -n "$AI_NS" -o yaml | grep -A 30 'Llama31Instruct:'
   WORKER=$(kubectl get pods -n "$AI_NS" -l ray.io/node-type=worker -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n "$AI_NS" "$WORKER" -c ray-worker -- sh -c 'ls /home/ray/.cache/s3/artifacts/model_artifacts/llama31-8b-instruct/*.safetensors 2>/dev/null || echo "No safetensors"'
   ```

### Object store credentials and serve config verification

When using S3-compatible object storage (MinIO, SeaweedFS, etc.), the operator injects credentials from the object storage secret into the Ray Serve config so replicas can download model artifacts. Use these steps to verify the secret and that the updated serve config is applied.

**1. Check that the AIPlatform object storage secret exists and has the required keys**

Replace `<namespace>` with your AIPlatform namespace (e.g. `ai-platform`) and `<secret-name>` with the value of `spec.objectStorage.secretRef` from your AIPlatform (e.g. `minio-credentials`).

```bash
# Get AIPlatform namespace and secretRef (optional: discover from the CR)
kubectl get aiplatform -A -o custom-columns=NAME:.metadata.name,NS:.metadata.namespace,SECRET:.spec.objectStorage.secretRef

# Confirm the secret exists in the same namespace as the AIPlatform
kubectl get secret <secret-name> -n <namespace>

# List secret keys (names only; values are base64-encoded and must not be logged)
kubectl get secret <secret-name> -n <namespace> -o jsonpath='{.data}' | jq -r 'keys[]'

# Verify required keys are present (expect s3_access_key and s3_secret_key)
kubectl get secret <secret-name> -n <namespace> -o jsonpath='{.data}' | jq -r 'keys[]' | grep -E 's3_access_key|s3_secret_key'
```

If either `s3_access_key` or `s3_secret_key` is missing, create or update the secret, for example:

```bash
kubectl -n <namespace> create secret generic <secret-name> \
  --from-literal=s3_access_key="<minio-access-key>" \
  --from-literal=s3_secret_key="<minio-secret-key>" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**2. Reconcile or restart the operator with the new image**

After updating the operator image (with the change that injects object store credentials into the serve config), either trigger a reconcile or restart the operator so it rewrites `RayService.spec.serveConfigV2`.

- **Option A – Restart the operator deployment** (simplest; causes one reconcile when the pod comes back):

  ```bash
  # Replace <operator-namespace> with the namespace where the operator runs (e.g. splunk-ai-operator-system)
  kubectl rollout restart deployment splunk-ai-operator-controller-manager -n <operator-namespace>
  kubectl rollout status deployment splunk-ai-operator-controller-manager -n <operator-namespace>
  ```

- **Option B – Trigger reconcile by touching the AIPlatform** (no operator restart):

  ```bash
  kubectl annotate aiplatform <aiplatform-name> -n <namespace> \
    reconcile-$(date +%s)=triggered --overwrite
  ```

  The operator will reconcile and regenerate the RayService; ensure the operator is already running the new image before doing this.

**3. Confirm RayService.spec.serveConfigV2 includes S3COMPAT_OBJECT_STORE_ACCESS_KEY and S3COMPAT_OBJECT_STORE_SECRET_KEY**

The serve config is a JSON string in `RayService.spec.serveConfigV2`. Check that it contains the object store env vars for the apps (e.g. after the operator has reconciled).

```bash
# Set your AIPlatform namespace and RayService name (often the same as AIPlatform name, e.g. splunk-ai-stack)
NAMESPACE="<namespace>"
RAY_SERVICE_NAME="<rayservice-name>"

# Count occurrences of S3COMPAT_OBJECT_STORE_ACCESS_KEY in the serve config (expect > 0 when using S3-compatible storage)
kubectl get rayservice "$RAY_SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.serveConfigV2}' | jq -Rs 'split("S3COMPAT_OBJECT_STORE_ACCESS_KEY") | length - 1'

# Show a snippet to confirm the keys are present (values are redacted in output)
kubectl get rayservice "$RAY_SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.serveConfigV2}' | grep -o '"S3COMPAT_OBJECT_STORE_ACCESS_KEY"[^,]*' | head -1
kubectl get rayservice "$RAY_SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.serveConfigV2}' | grep -o '"S3COMPAT_OBJECT_STORE_SECRET_KEY"[^,]*' | head -1
```

If the count is 0, the operator may not be using the new image, or `objectStorage.secretRef` may be unset. Ensure:

- The AIPlatform has `spec.objectStorage.path` with scheme `s3compat://`, `minio://`, or `seaweedfs://` and `spec.objectStorage.secretRef` set to the secret name.
- The secret exists in the AIPlatform namespace and contains `s3_access_key` and `s3_secret_key`.
- The operator deployment has been restarted (or reconciled) with the image that injects object store credentials into the applications template.

After confirming, restart Ray workers if needed so they pick up the new env (e.g. scale down and up the Ray cluster or wait for rolling restart), then re-check replica logs and the cache path `/home/ray/.cache/s3/artifacts/model_artifacts/...`.

### Weaviate Errors

```bash
# View Weaviate errors
kubectl get events -n <namespace> \
  --field-selector involvedObject.name=<name>,reason=WeaviateNotReady

# Check Weaviate logs
kubectl logs <name>-weaviate-0 -n <namespace>
```

### Pod-Level Errors

Sometimes individual pods fail:

```bash
# List all pods
kubectl get pods -n <namespace> -l ai.splunk.com/platform=<name>

# Check failing pods
kubectl describe pod <pod-name> -n <namespace>

# View pod logs
kubectl logs <pod-name> -n <namespace>
```

## Event Timeline

During deployment, you'll typically see events in this order:

1. **Creation Phase** (1-2 minutes)
   - `RayServiceCreating`
   - `RayServiceCreated`
   - `WeaviateCreating`
   - `WeaviateCreated`
   - `IngressCreating` (if enabled)
   - `IngressCreated` (if enabled)

2. **Startup Phase** (2-5 minutes)
   - `RayClusterReady` - Pods are running
   - `WeaviateReady` - Database is running
   - `RayServiceReady` - Ray is operational

3. **Application Loading** (5-15 minutes depending on model sizes)
   - Model artifacts downloading from S3
   - Models loading into GPU memory
   - `RayServeReady` - AI inference ready

4. **Ready!**
   - `IngressReady` (if enabled) - External access available
   - `PlatformReady` - Everything is operational

## Monitoring in Production

### Set Up Alerts

Monitor Warning events to catch problems early:

```bash
# Count Warning events
kubectl get events -n <namespace> --field-selector type=Warning

# Watch for specific problems
kubectl get events -n <namespace> --watch --field-selector reason=PlatformDegraded
```

### Integration with Monitoring Systems

Export events to your monitoring system:

**Prometheus:**
```yaml
# Example PromQL query
rate(kube_event_count{type="Warning",involved_object_kind="AIPlatform"}[5m]) > 0
```

**Splunk:**
Configure the Splunk operator to forward events to your Splunk instance.

## Getting Help

If you're still stuck:

1. **Collect diagnostics:**
```bash
# Save all relevant information
kubectl get aiplatform <name> -n <namespace> -o yaml > aiplatform.yaml
kubectl get events -n <namespace> > events.txt
kubectl get pods -n <namespace> > pods.txt
kubectl logs <pod-name> -n <namespace> > pod-logs.txt
```

2. **Check operator logs:**
```bash
kubectl logs -n splunk-ai-operator-system \
  deployment/splunk-ai-operator-controller-manager
```

3. **Report an issue:** Include the diagnostics files when reporting issues

## Summary

**Use Status Conditions** to understand current state:
```bash
kubectl get aiplatform <name> -o jsonpath='{.status.conditions}'
```

**Use Events** to understand what happened:
```bash
kubectl get events --field-selector involvedObject.name=<name>
```

**Use Logs** for detailed debugging:
```bash
kubectl logs <pod-name>
```

For more technical details about the event system, see [Event Coverage](EVENT_COVERAGE.md) and [Event Strategy](EVENT_STRATEGY.md).
