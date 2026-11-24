package slim

import (
	"context"
	"errors"
	"fmt"
	"maps"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	slimRouteDisabledLabel = "ai.splunk.com/slim-route-disabled"
	slimTrustRevisionLabel = "ai.splunk.com/slim-issuer-revision"
	slimRolloutBlocked     = "true"
	slimIssuerRejected     = "issuer-rejected"
	issuerRejectedReason   = "IssuerTrustRejected"
)

func slimDeploymentName(name string) string {
	return name + "-slim-deployment"
}

func slimServiceSelector(ai *aiv1.AIService, blocked, trustRevision string) map[string]string {
	selector := map[string]string{"app": ai.Name, "component": ai.Name}
	if blocked != "" {
		// No SLIM Pod has this label. A nonempty selector lets the EndpointSlice
		// controller withdraw its endpoints while preserving the Service address.
		selector[slimRouteDisabledLabel] = blocked
	} else if trustRevision != "" {
		selector[slimTrustRevisionLabel] = trustRevision
	}
	return selector
}

func (r *SlimReconciler) prepareSlimIssuerTrust(ctx context.Context, ai *aiv1.AIService, hash string, previouslyRejected bool) (bool, error) {
	if previouslyRejected {
		// Retry both writes if an earlier rejection only made it to status.
		return true, r.suspendSlimServing(ctx, ai)
	}
	service, err := r.getOwnedSlimService(ctx, ai)
	if err != nil || service == nil {
		return false, err
	}
	if service.Spec.Selector[slimRouteDisabledLabel] == slimIssuerRejected {
		return true, r.stopSlimDeployment(ctx, ai)
	}
	deployment := &appsv1.Deployment{}
	err = r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: slimDeploymentName(ai.Name)}, deployment)
	if err != nil && !apierrors.IsNotFound(err) {
		return false, fmt.Errorf("read the applied SLIM issuer trust: %w", err)
	}
	if err == nil && metav1.IsControlledBy(deployment, ai) && deployment.Spec.Template.Annotations[issuerTrustHashAnnotation] == hash {
		return false, nil
	}
	// Withdraw the old trust even when another dependency delays the rollout.
	return false, r.setBlockedSlimSelector(ctx, ai, service, slimRolloutBlocked)
}

func (r *SlimReconciler) getOwnedSlimService(ctx context.Context, ai *aiv1.AIService) (*corev1.Service, error) {
	service := &corev1.Service{}
	if err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: slimServiceName(ai.Name)}, service); err != nil {
		return nil, client.IgnoreNotFound(err)
	}
	if !metav1.IsControlledBy(service, ai) {
		return nil, errors.New("SLIM application Service is not controlled by this AIService")
	}
	return service, nil
}

func (r *SlimReconciler) blockSlimService(ctx context.Context, ai *aiv1.AIService, blocked string) error {
	service, err := r.getOwnedSlimService(ctx, ai)
	if err != nil || service == nil {
		return err
	}
	return r.setBlockedSlimSelector(ctx, ai, service, blocked)
}

func (r *SlimReconciler) setBlockedSlimSelector(ctx context.Context, ai *aiv1.AIService, service *corev1.Service, blocked string) error {
	selector := slimServiceSelector(ai, blocked, "")
	if maps.Equal(service.Spec.Selector, selector) && !service.Spec.PublishNotReadyAddresses {
		return nil
	}
	service.Spec.Selector = selector
	service.Spec.PublishNotReadyAddresses = false
	if err := r.Update(ctx, service); err != nil {
		return fmt.Errorf("disable the SLIM application Service backends: %w", err)
	}
	return nil
}

func (r *SlimReconciler) suspendSlimServing(ctx context.Context, ai *aiv1.AIService) error {
	// Withdraw the Service first and also stop the Pods so existing connections
	// and in-memory issuer keys are retired. Retry either write if it fails.
	return errors.Join(r.blockSlimService(ctx, ai, slimIssuerRejected), r.stopSlimDeployment(ctx, ai))
}

func (r *SlimReconciler) stopSlimDeployment(ctx context.Context, ai *aiv1.AIService) error {
	deployment := &appsv1.Deployment{}
	if err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: slimDeploymentName(ai.Name)}, deployment); err != nil {
		return client.IgnoreNotFound(err)
	}
	if !metav1.IsControlledBy(deployment, ai) {
		return errors.New("cannot suspend a SLIM Deployment controlled by another owner or with no controller")
	}
	if deployment.Spec.Replicas != nil && *deployment.Spec.Replicas == 0 {
		return nil
	}
	deployment.Spec.Replicas = ptr.To(int32(0))
	if err := r.Update(ctx, deployment); err != nil {
		return fmt.Errorf("stop SLIM Pods using the previous issuer trust: %w", err)
	}
	return nil
}

func (r *SlimReconciler) slimWorkloadDrained(ctx context.Context, ai *aiv1.AIService, deployment *appsv1.Deployment) (bool, error) {
	if !slimDeploymentDrained(ai, deployment) {
		return false, nil
	}
	if deployment.Status.TerminatingReplicas != nil {
		return true, nil
	}
	// Older clusters can report zero desired replicas while terminating Pods
	// still hold connections. Check the Deployment's Pods before restarting.
	var pods corev1.PodList
	if err := r.List(ctx, &pods, client.InNamespace(ai.Namespace), client.MatchingLabels(slimServiceSelector(ai, "", ""))); err != nil {
		return false, fmt.Errorf("check for SLIM Pods still draining: %w", err)
	}
	for i := range pods.Items {
		owner := metav1.GetControllerOf(&pods.Items[i])
		if owner == nil || owner.Kind != "ReplicaSet" {
			continue
		}
		var rs appsv1.ReplicaSet
		err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: owner.Name}, &rs)
		if apierrors.IsNotFound(err) {
			// The ReplicaSet may have been deleted before its Pods were removed.
			return false, nil
		}
		if err != nil {
			return false, fmt.Errorf("check the controller of a draining SLIM Pod: %w", err)
		}
		if owner.UID == rs.UID && metav1.IsControlledBy(&rs, deployment) {
			return false, nil
		}
	}
	return true, nil
}
