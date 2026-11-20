package controller

import (
	"context"
	"reflect"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const runtimeWorkloadIndex = "agentruntime.backend"

// Index the rendered names so backend events can find their AIService without
// guessing names from labels that may have been shortened for Kubernetes limits.
func runtimeWorkloadKeys(obj client.Object) []string {
	ai := obj.(*aiv1.AIService)
	if ai.Spec.Feature.Name != "agentruntime" {
		return nil
	}
	return []string{"service/" + agentruntime.ServiceName(ai.Name), "pod/" + agentruntime.WorkloadName(ai.Name)}
}

// Pods and EndpointSlices have intermediate owners, so direct AIService Owns
// watches cannot map them. Use metadata carried by the event, even on deletion,
// without fetching an owner that may already be gone. Reconciliation validates
// actual ownership; these labels only select which AIService to wake.
func (r *AIServiceReconciler) findRuntimeServicesForBackend(ctx context.Context, obj client.Object) []reconcile.Request {
	key := ""
	switch o := obj.(type) {
	case *discoveryv1.EndpointSlice:
		if name := o.Labels[discoveryv1.LabelServiceName]; name != "" {
			key = "service/" + name
		}
	case *corev1.Pod:
		if app := o.Labels["app"]; app != "" && o.Labels["component"] == app {
			key = "pod/" + app
		}
	case *appsv1.ReplicaSet:
		if app := o.Labels["app"]; app != "" && o.Labels["component"] == app {
			key = "pod/" + app
		}
	}
	if key == "" {
		return nil
	}
	var services aiv1.AIServiceList
	if err := r.List(ctx, &services, client.InNamespace(obj.GetNamespace()), client.MatchingFields{runtimeWorkloadIndex: key}); err != nil {
		ctrl.LoggerFrom(ctx).Error(err, "cannot map runtime backend event")
		return nil
	}
	requests := make([]reconcile.Request, 0, len(services.Items))
	for i := range services.Items {
		requests = append(requests, reconcile.Request{NamespacedName: client.ObjectKeyFromObject(&services.Items[i])})
	}
	return requests
}

// Health and routing changes need not advance metadata.generation. Admit the
// relevant observations and ownership changes while filtering unchanged writes.
func runtimeBackendChangedPredicate() predicate.Predicate {
	isBackend := func(obj client.Object) bool {
		switch obj.(type) {
		case *corev1.Pod, *discoveryv1.EndpointSlice, *corev1.Service, *appsv1.ReplicaSet:
			return true
		}
		return false
	}
	return predicate.Funcs{
		CreateFunc:  func(e event.CreateEvent) bool { return isBackend(e.Object) },
		DeleteFunc:  func(e event.DeleteEvent) bool { return isBackend(e.Object) },
		GenericFunc: func(e event.GenericEvent) bool { return false },
		UpdateFunc: func(e event.UpdateEvent) bool {
			if !isBackend(e.ObjectNew) {
				return false
			}
			if !reflect.DeepEqual(e.ObjectOld.GetLabels(), e.ObjectNew.GetLabels()) || !reflect.DeepEqual(e.ObjectOld.GetOwnerReferences(), e.ObjectNew.GetOwnerReferences()) || !reflect.DeepEqual(e.ObjectOld.GetDeletionTimestamp(), e.ObjectNew.GetDeletionTimestamp()) {
				return true
			}
			switch n := e.ObjectNew.(type) {
			case *discoveryv1.EndpointSlice:
				o, ok := e.ObjectOld.(*discoveryv1.EndpointSlice)
				return !ok || !reflect.DeepEqual(o.Endpoints, n.Endpoints) || !reflect.DeepEqual(o.Ports, n.Ports) || o.AddressType != n.AddressType
			case *corev1.Pod:
				o, ok := e.ObjectOld.(*corev1.Pod)
				return !ok || !reflect.DeepEqual(o.Status, n.Status) || !reflect.DeepEqual(o.Spec.Containers, n.Spec.Containers)
			case *corev1.Service:
				o, ok := e.ObjectOld.(*corev1.Service)
				return !ok || !reflect.DeepEqual(o.Spec, n.Spec)
			case *appsv1.ReplicaSet:
				o, ok := e.ObjectOld.(*appsv1.ReplicaSet)
				return !ok || !reflect.DeepEqual(o.Spec.Template, n.Spec.Template)
			}
			return false
		},
	}
}

// Only the readiness projection wakes the parent; arbitrary child spec/status
// writes must not restore the previous parent/child spec reconciliation loop.
func agentRuntimeReadyChangedPredicate() predicate.Predicate {
	isRuntime := func(obj client.Object) bool {
		ai, ok := obj.(*aiv1.AIService)
		return ok && ai.Spec.Feature.Name == "agentruntime"
	}
	projection := func(ai *aiv1.AIService) any {
		c := metav1.Condition{}
		if condition := meta.FindStatusCondition(ai.Status.Conditions, "Ready"); condition != nil {
			c = *condition
			// A timestamp-only write does not change what the parent can conclude
			// about readiness, so it must not trigger another parent reconcile.
			c.LastTransitionTime = metav1.Time{}
		}
		return struct {
			Generation, Observed int64
			Deleted              bool
			Ready                metav1.Condition
		}{ai.Generation, ai.Status.ObservedGeneration, ai.DeletionTimestamp != nil, c}
	}
	return predicate.Funcs{
		CreateFunc:  func(e event.CreateEvent) bool { return isRuntime(e.Object) },
		DeleteFunc:  func(e event.DeleteEvent) bool { return isRuntime(e.Object) },
		GenericFunc: func(e event.GenericEvent) bool { return false },
		UpdateFunc: func(e event.UpdateEvent) bool {
			old, oldOK := e.ObjectOld.(*aiv1.AIService)
			current, newOK := e.ObjectNew.(*aiv1.AIService)
			return oldOK && newOK && (isRuntime(old) || isRuntime(current)) && !reflect.DeepEqual(projection(old), projection(current))
		},
	}
}
