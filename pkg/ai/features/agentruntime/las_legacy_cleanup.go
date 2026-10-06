package agentruntime

import (
	"context"
	"fmt"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Delete only objects controlled by this AIService's former direct-managed
// reconciler, after LAS is ready. Helm chart resources have no such owner ref.
func (r *LASReconciler) removeLegacyResources(ctx context.Context, ai *aiv1.AIService) error {
	for _, kind := range []struct{ apiVersion, listKind string }{
		{"v1", "ServiceAccountList"},
		{"v1", "ConfigMapList"},
		{"v1", "ServiceList"},
		{"apps/v1", "DeploymentList"},
		{"batch/v1", "JobList"},
		{"autoscaling/v2", "HorizontalPodAutoscalerList"},
		{"cert-manager.io/v1", "CertificateList"},
		{"monitoring.coreos.com/v1", "ServiceMonitorList"},
	} {
		list := &unstructured.UnstructuredList{}
		list.SetAPIVersion(kind.apiVersion)
		list.SetKind(kind.listKind)
		if err := r.List(ctx, list, client.InNamespace(ai.Namespace)); err != nil {
			if meta.IsNoMatchError(err) || apierrors.IsNotFound(err) {
				continue
			}
			return fmt.Errorf("listing former agentruntime %s: %w", kind.listKind, err)
		}
		for i := range list.Items {
			object := &list.Items[i]
			if !metav1.IsControlledBy(object, ai) {
				continue
			}
			if object.GetKind() == "Service" && object.GetName() == agentRuntimeServiceName(ai.Name) {
				continue
			}
			if err := r.Delete(ctx, object); err != nil && !apierrors.IsNotFound(err) {
				return fmt.Errorf("deleting former agentruntime %s %s: %w", object.GetKind(), object.GetName(), err)
			}
		}
	}
	return nil
}
