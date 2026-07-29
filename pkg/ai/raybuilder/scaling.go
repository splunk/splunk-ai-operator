package raybuilder

import (
	"context"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	kuberayutils "github.com/ray-project/kuberay/ray-operator/controllers/ray/utils"
	enterpriseApi "github.com/splunk/splunk-ai-operator/api/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/client-go/util/retry"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

// ReconcileActiveClusterScale patches the ALREADY-RUNNING active RayCluster's worker-group
// replica counts to match the just-reconciled RayService, when — and only when — the two
// clusters are otherwise identical (a pure scaleFactor change).
//
// Why this exists: KubeRay's own comparison
// (generateHashWithoutReplicasAndWorkersToDelete → isClusterSpecHashEqual) strips
// Replicas/MinReplicas/MaxReplicas/WorkersToDelete before deciding whether the active
// RayCluster needs an update. A pure replica change therefore hashes equal to what's already
// running, so KubeRay logs "Active Ray cluster config matches goal config. No need to update
// RayCluster." and never grows/shrinks the active cluster's worker pool. Ray Serve then asks
// for more (or fewer) model replicas than the cluster has GPU capacity for. Because KubeRay's
// comparison ignores those same fields, it will neither propagate a replica change to the
// active cluster nor revert one we apply directly — so patching the active RayCluster's
// worker replicas here is safe.
//
// This stage deliberately does NOT touch anything else: head group, pod templates, images,
// scheduling, and autoscaling options are left untouched, and any non-replica spec change is
// treated as a signal to back off and let KubeRay run its normal NewCluster rollout.
func (b *Builder) ReconcileActiveClusterScale(ctx context.Context, p *enterpriseApi.AIPlatform) error {
	logger := log.FromContext(ctx)

	// Fetch the API-server-stored RayService the reconciler just wrote so the desired
	// sizing and non-replica comparison use the same defaulted representation as the
	// live RayCluster.
	var rayService rayv1.RayService
	if err := b.Get(ctx, client.ObjectKey{Namespace: p.Namespace, Name: p.Name}, &rayService); err != nil {
		if apierrors.IsNotFound(err) {
			// RayService doesn't exist yet (e.g. first reconcile ordering); nothing to scale.
			return nil
		}
		return err
	}

	activeName := rayService.Status.ActiveServiceStatus.RayClusterName
	if activeName == "" {
		// No active cluster yet — RayService hasn't reported one, or none exists.
		return nil
	}

	// If KubeRay has started a zero-downtime rollout, leave both the active and pending
	// clusters to KubeRay. The deployed KubeRay v1.2.2 does not publish the newer
	// UpgradeInProgress condition, so the pending cluster is the compatible signal.
	if rayService.Status.PendingServiceStatus.RayClusterName != "" {
		return nil
	}

	desiredSpec := rayService.Spec.RayClusterSpec
	desiredHash, err := hashWithoutReplicas(desiredSpec)
	if err != nil {
		return err
	}

	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var live rayv1.RayCluster
		if err := b.Get(ctx, client.ObjectKey{Namespace: p.Namespace, Name: activeName}, &live); err != nil {
			if apierrors.IsNotFound(err) {
				// KubeRay may have already retired/replaced the active cluster. Safe to skip;
				// the next reconcile will pick up whatever is active then.
				return nil
			}
			return err
		}

		// Scale-only guard: only patch when the active cluster's non-replica spec exactly
		// matches the desired spec's non-replica spec. We hash the live RayCluster's own
		// fetched spec here — rather than trusting KubeRay's stored
		// ray.io/hash-without-replicas-and-workers-to-delete annotation — because that
		// annotation is computed by the in-cluster KubeRay operator, which may be running a
		// different KubeRay version than this Go module vendors. WorkerGroupSpec changed
		// fields across KubeRay releases, so the same spec hashes differently across
		// versions even when every field value is identical, making the stored annotation
		// non-comparable to a hash computed from our vendored struct.
		liveHash, err := hashWithoutReplicas(live.Spec)
		if err != nil {
			return err
		}
		if liveHash != desiredHash {
			return nil
		}

		// Snapshot BEFORE mutating so the merge patch below diffs against the
		// pre-mutation state. Deep-copying live after applyDesiredWorkerSizing
		// would make original == live and produce an empty (no-op) patch.
		original := live.DeepCopy()

		changed := applyDesiredWorkerSizing(&live, desiredSpec.WorkerGroupSpecs)
		if !changed {
			return nil
		}

		logger.Info("Scaling active RayCluster worker groups to match RayService", "rayCluster", activeName)
		patch := client.MergeFromWithOptions(original, client.MergeFromWithOptimisticLock{})
		return b.Patch(ctx, &live, patch)
	})
}

// hashWithoutReplicas mirrors KubeRay's generateHashWithoutReplicasAndWorkersToDelete
// (rayservice_controller.go) so we compare against the exact same signal KubeRay uses to
// decide whether the active RayCluster's non-replica spec has changed.
func hashWithoutReplicas(spec rayv1.RayClusterSpec) (string, error) {
	muted := spec.DeepCopy()
	for i := range muted.WorkerGroupSpecs {
		muted.WorkerGroupSpecs[i].Replicas = nil
		muted.WorkerGroupSpecs[i].MinReplicas = nil
		muted.WorkerGroupSpecs[i].MaxReplicas = nil
		muted.WorkerGroupSpecs[i].ScaleStrategy.WorkersToDelete = nil
	}
	return kuberayutils.GenerateJsonHash(muted)
}

// applyDesiredWorkerSizing matches live worker groups to desired ones by GroupName and
// updates only their replica fields in place. Returns true if anything changed.
//
//   - Fixed groups (desired Min == Max, i.e. GPU tiers): Replicas/Min/Max are all set to the
//     desired value. There's no autoscaler freedom to preserve (the feasible range is a
//     single point both before and after), so setting Replicas directly makes the capacity
//     change take effect immediately rather than waiting on an autoscaler bound reconcile.
//   - Autoscalable groups (desired Min != Max, i.e. CPU tiers): only Min/Max move to the
//     desired bounds. The live Replicas value is left alone when it already falls inside the
//     new [Min,Max] range (the Ray autoscaler owns it there); it is clamped only when it now
//     falls outside the new range. Resetting Replicas unconditionally here would fight the
//     autoscaler: autoscaler changes Replicas -> RayCluster generation bumps -> AIPlatform
//     reconciles -> we reset Replicas -> repeat.
func applyDesiredWorkerSizing(live *rayv1.RayCluster, desiredGroups []rayv1.WorkerGroupSpec) bool {
	desiredByName := make(map[string]rayv1.WorkerGroupSpec, len(desiredGroups))
	for _, g := range desiredGroups {
		desiredByName[g.GroupName] = g
	}

	changed := false
	for i := range live.Spec.WorkerGroupSpecs {
		lg := &live.Spec.WorkerGroupSpecs[i]
		dg, ok := desiredByName[lg.GroupName]
		if !ok {
			// Group present on the live cluster but not in the desired spec (shouldn't
			// happen in steady state) - leave it untouched.
			continue
		}
		if dg.Replicas == nil || dg.MinReplicas == nil || dg.MaxReplicas == nil {
			// Malformed desired spec - nothing sensible to apply, skip this group.
			continue
		}

		desiredMin := *dg.MinReplicas
		desiredMax := *dg.MaxReplicas
		fixed := desiredMin == desiredMax

		if lg.MinReplicas == nil || *lg.MinReplicas != desiredMin {
			lg.MinReplicas = int32Ptr(desiredMin)
			changed = true
		}
		if lg.MaxReplicas == nil || *lg.MaxReplicas != desiredMax {
			lg.MaxReplicas = int32Ptr(desiredMax)
			changed = true
		}

		var desiredReplicas int32
		switch {
		case fixed:
			// GPU tier: pin Replicas to the single feasible point.
			desiredReplicas = desiredMin
		case lg.Replicas != nil && *lg.Replicas >= desiredMin && *lg.Replicas <= desiredMax:
			// Autoscaler-managed and already in range: leave it alone.
			desiredReplicas = *lg.Replicas
		case lg.Replicas == nil:
			desiredReplicas = *dg.Replicas
		case *lg.Replicas < desiredMin:
			desiredReplicas = desiredMin
		default: // *lg.Replicas > desiredMax
			desiredReplicas = desiredMax
		}

		if lg.Replicas == nil || *lg.Replicas != desiredReplicas {
			lg.Replicas = int32Ptr(desiredReplicas)
			changed = true
		}
	}
	return changed
}
