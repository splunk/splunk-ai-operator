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

// Route consumers depend on the current readiness and ownership of a runtime.
// Ignore unrelated status changes and timestamps to keep reconciles stable.
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
			Owner                *metav1.OwnerReference
			Ready                metav1.Condition
		}{ai.Generation, ai.Status.ObservedGeneration, ai.DeletionTimestamp != nil, metav1.GetControllerOf(ai), c}
	}
	return predicate.Funcs{
		CreateFunc:  func(e event.CreateEvent) bool { return isRuntime(e.Object) },
		DeleteFunc:  func(e event.DeleteEvent) bool { return isRuntime(e.Object) },
		GenericFunc: func(e event.GenericEvent) bool { return false },
		UpdateFunc: func(e event.UpdateEvent) bool {
			old, oldOK := e.ObjectOld.(*aiv1.AIService)
			current, newOK := e.ObjectNew.(*aiv1.AIService)
			if !oldOK || !newOK {
				return false
			}
			wasRuntime, remainsRuntime := isRuntime(old), isRuntime(current)
			// The mapped watch receives both objects. A feature or owner change
			// must wake the previously dependent sibling as well as any new one.
			return wasRuntime != remainsRuntime || (remainsRuntime && !reflect.DeepEqual(projection(old), projection(current)))
		},
	}
}

func aiServiceRouteLifecycleChanged(e event.UpdateEvent) bool {
	old, oldOK := e.ObjectOld.(*aiv1.AIService)
	current, newOK := e.ObjectNew.(*aiv1.AIService)
	if !oldOK || !newOK {
		return false
	}
	feature := current.Spec.Feature.Name
	if feature != "agentruntime" && feature != "slim" {
		return false
	}
	// Ownership and the start of deletion can change without a spec update.
	return (old.DeletionTimestamp == nil) != (current.DeletionTimestamp == nil) ||
		!reflect.DeepEqual(metav1.GetControllerOf(old), metav1.GetControllerOf(current))
}

// A readiness event only affects the SLIM feature owned by the same platform
// instance. The event carries the former owner even after a runtime is deleted.
func (r *AIServiceReconciler) findSlimSiblingsForRuntime(ctx context.Context, obj client.Object) []reconcile.Request {
	runtime, ok := obj.(*aiv1.AIService)
	if !ok || runtime.Spec.Feature.Name != "agentruntime" {
		return nil
	}
	owner := metav1.GetControllerOf(runtime)
	if owner == nil || owner.APIVersion != aiv1.GroupVersion.String() || owner.Kind != "AIPlatform" || owner.UID == "" {
		return nil
	}

	var services aiv1.AIServiceList
	if err := r.List(ctx, &services, client.InNamespace(runtime.Namespace)); err != nil {
		ctrl.LoggerFrom(ctx).Error(err, "cannot find SLIM for runtime readiness event", "platform", owner.Name)
		return nil
	}
	var requests []reconcile.Request
	for i := range services.Items {
		slim := &services.Items[i]
		if slim.Spec.Feature.Name != "slim" || slim.DeletionTimestamp != nil {
			continue
		}
		slimOwner := metav1.GetControllerOf(slim)
		if slimOwner != nil && slimOwner.UID == owner.UID && slimOwner.Name == owner.Name && slimOwner.Kind == owner.Kind && slimOwner.APIVersion == owner.APIVersion {
			requests = append(requests, reconcile.Request{NamespacedName: client.ObjectKeyFromObject(slim)})
		}
	}
	return requests
}
