# Storage Configuration for AIPlatform

This guide explains how to configure persistent storage for the Weaviate vector database so your AI data persists across restarts.

## Quick Start

**Most common configuration:**

```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: my-ai-platform
spec:
  # ... other config ...
  storage:
    vectorDB:
      size: "100Gi"         # How much space you need
      storageClassName: "gp3"  # Your cloud storage class
```

That's it! The operator will automatically create a persistent volume for your vector database.

## Why You Need This

Without persistent storage:
- ❌ Vector embeddings are lost when pods restart
- ❌ You have to re-index all your data after updates
- ❌ Data is stored on the pod's ephemeral storage

With persistent storage:
- ✅ Data survives pod restarts and upgrades
- ✅ Can expand volume size as data grows
- ✅ Production-ready data durability

## Overview

The `storage.vectorDB` field configures persistent storage for Weaviate. This ensures that vector data persists across pod restarts and upgrades.

## StorageSpec Structure

```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: my-ai-platform
spec:
  storage:
    vectorDB:
      # Option 1: Use existing PVC
      pvcName: "my-existing-pvc"

      # Option 2: Create dynamic PVC (via VolumeClaimTemplate)
      size: "100Gi"
      storageClassName: "gp3"
```

## Configuration Options

### 1. Dynamic PVC Creation (Recommended)

The operator will create a PersistentVolumeClaim automatically using StatefulSet VolumeClaimTemplates:

```yaml
spec:
  storage:
    vectorDB:
      size: "100Gi"               # Volume size (default: 50Gi)
      storageClassName: "gp3"     # Optional StorageClass
```

**How it works:**
- StatefulSet creates a PVC named `weaviate-data-<platform-name>-weaviate-0`
- PVC is bound to a dynamically provisioned PersistentVolume
- Data persists across pod restarts and StatefulSet updates
- Each replica gets its own volume (for multi-replica Weaviate clusters)

**Example:**
```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: prod-ai
  namespace: ai-platform
spec:
  defaultAcceleratorType: "nvidia-tesla-t4"
  objectStorage:
    path: "s3://my-bucket/models"
    region: "us-west-2"

  storage:
    vectorDB:
      size: "200Gi"
      storageClassName: "gp3-encrypted"
```

### 2. Using Existing PVC

If you have a pre-provisioned PVC, you can reference it:

```yaml
spec:
  storage:
    vectorDB:
      pvcName: "my-weaviate-pvc"
```

**When to use this:**
- You have existing Weaviate data to migrate
- You want to manage PVC lifecycle separately
- You need specific PV settings not supported by dynamic provisioning

**Important:** When using an existing PVC:
- The PVC must exist in the same namespace as the AIPlatform
- The PVC will NOT be deleted when the AIPlatform is deleted
- Only one Weaviate replica can use the PVC (ReadWriteOnce access mode)

## Volume Expansion

### Automatic Expansion (Requires StorageClass Support)

If your StorageClass supports volume expansion (`allowVolumeExpansion: true`), you can increase the volume size by updating the AIPlatform spec:

```yaml
# Initial configuration
spec:
  storage:
    vectorDB:
      size: "50Gi"
      storageClassName: "gp3"
```

To expand the volume:

```bash
# Update the size in your AIPlatform manifest
kubectl edit aiplatform my-ai-platform -n ai-platform

# Change size from "50Gi" to "100Gi"
spec:
  storage:
    vectorDB:
      size: "100Gi"  # ← Increase this value
      storageClassName: "gp3"
```

**What happens:**
1. Operator updates the StatefulSet VolumeClaimTemplate with new size
2. Kubernetes expands the underlying PersistentVolume (if StorageClass allows)
3. File system is expanded automatically (for most volume types)
4. Weaviate pod may need to be restarted to see the new space

**Check StorageClass expansion support:**
```bash
kubectl get storageclass gp3 -o jsonpath='{.allowVolumeExpansion}'
# Should return: true
```

### Manual Expansion Process

If automatic expansion is not working, follow these steps:

```bash
# 1. Check current PVC status
kubectl get pvc -n ai-platform | grep weaviate

# 2. Manually edit the PVC to request more storage
kubectl edit pvc weaviate-data-my-ai-platform-weaviate-0 -n ai-platform

# 3. Update spec.resources.requests.storage
spec:
  resources:
    requests:
      storage: 100Gi  # ← Increase this

# 4. Check PVC conditions for expansion status
kubectl describe pvc weaviate-data-my-ai-platform-weaviate-0 -n ai-platform | grep -A5 Conditions

# 5. Restart Weaviate pod if needed
kubectl delete pod my-ai-platform-weaviate-0 -n ai-platform
```

### Important Notes on Volume Expansion

**✅ Supported:**
- Increasing volume size (expansion)
- Works with most cloud storage classes (AWS EBS, GCE PD, Azure Disk)
- Automatic file system resize for most volume types

**❌ Not Supported:**
- Decreasing volume size (shrinking)
- Changing StorageClass after PVC creation
- Changing access modes after PVC creation

**Volume expansion requirements:**
1. StorageClass must have `allowVolumeExpansion: true`
2. Volume type must support online expansion (most cloud volumes do)
3. New size must be larger than current size

## Storage Classes

### AWS EBS (Recommended for AWS)

```yaml
spec:
  storage:
    vectorDB:
      size: "100Gi"
      storageClassName: "gp3"  # Or "gp2", "io1", "io2"
```

**EBS CSI Driver features:**
- ✅ Volume expansion supported
- ✅ Online expansion (no pod restart needed for most cases)
- ✅ Encryption support
- Recommended: gp3 (better performance/cost than gp2)

### GCE Persistent Disk

```yaml
spec:
  storage:
    vectorDB:
      size: "100Gi"
      storageClassName: "standard"  # Or "ssd"
```

### Azure Disk

```yaml
spec:
  storage:
    vectorDB:
      size: "100Gi"
      storageClassName: "managed-premium"
```

### Creating Custom StorageClass with Expansion

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: weaviate-storage
provisioner: kubernetes.io/aws-ebs
parameters:
  type: gp3
  encrypted: "true"
  iops: "3000"
  throughput: "125"
allowVolumeExpansion: true  # ← Enable expansion
volumeBindingMode: WaitForFirstConsumer
```

## Default Values

If `storage.vectorDB` is not specified, the following defaults are used:

```yaml
spec:
  storage:
    vectorDB:
      size: "50Gi"              # Default size
      storageClassName: ""      # Use cluster default StorageClass
      pvcName: ""               # No existing PVC, create new one
```

## Verification

### Check PVC Creation

```bash
# List PVCs in namespace
kubectl get pvc -n ai-platform

# Should see:
# NAME                                        STATUS   VOLUME     CAPACITY   STORAGECLASS
# weaviate-data-my-ai-platform-weaviate-0   Bound    pvc-xxx    100Gi      gp3
```

### Check Volume Mount in Pod

```bash
# Describe Weaviate pod
kubectl describe pod my-ai-platform-weaviate-0 -n ai-platform | grep -A5 Volumes

# Should see:
# Volumes:
#   weaviate-data:
#     Type:       PersistentVolumeClaim
#     ClaimName:  weaviate-data-my-ai-platform-weaviate-0
```

### Check Storage Usage

```bash
# Exec into Weaviate pod
kubectl exec -it my-ai-platform-weaviate-0 -n ai-platform -- df -h /var/lib/weaviate

# Output:
# Filesystem      Size  Used Avail Use% Mounted on
# /dev/xvdxx      100G   5G   95G   5% /var/lib/weaviate
```

### Check Data Persistence

```bash
# 1. Create some test data in Weaviate
kubectl exec -it my-ai-platform-weaviate-0 -n ai-platform -- curl localhost:8080/v1/schema

# 2. Delete the pod
kubectl delete pod my-ai-platform-weaviate-0 -n ai-platform

# 3. Wait for pod to restart
kubectl wait --for=condition=ready pod -l app=my-ai-platform-weaviate -n ai-platform

# 4. Verify data is still there
kubectl exec -it my-ai-platform-weaviate-0 -n ai-platform -- curl localhost:8080/v1/schema
# ← Should return the same schema as before
```

## Troubleshooting

### PVC Not Created

**Symptom:** No PVC appears after creating AIPlatform

**Causes:**
1. StatefulSet not created successfully
2. Invalid storage size format

**Debug:**
```bash
# Check StatefulSet
kubectl get statefulset -n ai-platform

# Check operator logs
kubectl logs -n splunk-ai-operator-system deployment/splunk-ai-operator-controller-manager | grep -i weaviate

# Check events
kubectl get events -n ai-platform --sort-by='.lastTimestamp' | grep -i weaviate
```

### PVC Stuck in Pending

**Symptom:** PVC shows `Pending` status

**Causes:**
1. StorageClass not found
2. No available storage in cluster
3. Insufficient permissions

**Debug:**
```bash
# Check PVC details
kubectl describe pvc weaviate-data-<platform-name>-weaviate-0 -n ai-platform

# Check available StorageClasses
kubectl get storageclass

# Check if StorageClass supports required access mode
kubectl get storageclass <class-name> -o yaml | grep -A5 parameters
```

### Volume Expansion Failed

**Symptom:** PVC shows `FileSystemResizePending` or expansion doesn't complete

**Causes:**
1. StorageClass doesn't allow expansion
2. Volume type doesn't support online expansion
3. File system resize failed

**Debug:**
```bash
# Check PVC conditions
kubectl describe pvc weaviate-data-<platform-name>-weaviate-0 -n ai-platform | grep -A10 Conditions

# Check for expansion events
kubectl get events -n ai-platform --field-selector involvedObject.name=weaviate-data-<platform-name>-weaviate-0

# If stuck, restart the pod
kubectl delete pod <platform-name>-weaviate-0 -n ai-platform
```

### Data Loss After Restart

**Symptom:** Weaviate data disappears after pod restart

**Causes:**
1. PVC not mounted correctly
2. Using emptyDir instead of PVC
3. Mount path incorrect

**Verify:**
```bash
# Check if PVC is mounted
kubectl describe pod <platform-name>-weaviate-0 -n ai-platform | grep -A10 "Mounts:"

# Should see:
#   Mounts:
#     /var/lib/weaviate from weaviate-data (rw)

# Check if using correct volume
kubectl get pod <platform-name>-weaviate-0 -n ai-platform -o yaml | grep -A5 volumes:
```

## Best Practices

1. **Always configure persistent storage in production**
   - Never rely on default ephemeral storage
   - Vector data is critical and should persist

2. **Choose appropriate size based on data volume**
   - Estimate: ~1GB per 1M vectors (depends on dimensionality)
   - Leave 30-50% headroom for growth

3. **Use StorageClasses with expansion support**
   - Verify `allowVolumeExpansion: true`
   - Test expansion in staging before production

4. **Monitor storage usage**
   - Set up alerts for >80% usage
   - Expand proactively before hitting limits

5. **Use encrypted storage for sensitive data**
   - Configure encryption in StorageClass
   - Especially important for regulated industries

6. **Consider IOPS and throughput requirements**
   - Weaviate benefits from fast I/O
   - Use SSD-backed storage (gp3, io1, io2 on AWS)

7. **Test backup and restore procedures**
   - Take volume snapshots regularly
   - Test restoring from snapshots

8. **Plan for disaster recovery**
   - Cross-region replication if needed
   - Document restore procedures

## Example Configurations

### Small Development Environment
```yaml
spec:
  storage:
    vectorDB:
      size: "20Gi"
      storageClassName: "standard"
```

### Medium Production Environment
```yaml
spec:
  storage:
    vectorDB:
      size: "100Gi"
      storageClassName: "gp3"
```

### Large High-Performance Environment
```yaml
spec:
  storage:
    vectorDB:
      size: "500Gi"
      storageClassName: "io2"  # High IOPS for AWS
```

### Using Pre-provisioned PVC
```yaml
spec:
  storage:
    vectorDB:
      pvcName: "weaviate-production-pvc"
```

## Migration Guide

### Migrating from Non-Persistent to Persistent Storage

If you have an existing AIPlatform without persistent storage:

1. **Export data** (if needed):
   ```bash
   kubectl exec -it <platform-name>-weaviate-0 -n ai-platform -- weaviate-backup export
   ```

2. **Update AIPlatform spec** to add storage configuration:
   ```bash
   kubectl edit aiplatform <platform-name> -n ai-platform
   ```

3. **Add storage spec**:
   ```yaml
   spec:
     storage:
       vectorDB:
         size: "100Gi"
         storageClassName: "gp3"
   ```

4. **Operator will recreate StatefulSet** with PVC

5. **Import data** (if needed):
   ```bash
   kubectl exec -it <platform-name>-weaviate-0 -n ai-platform -- weaviate-backup import
   ```

### Migrating Between StorageClasses

To change StorageClass (requires data migration):

1. Create new PVC with desired StorageClass
2. Scale down Weaviate (set replicas to 0)
3. Copy data from old PVC to new PVC
4. Update AIPlatform to reference new PVC
5. Scale up Weaviate

Note: This process causes downtime. Plan accordingly.
