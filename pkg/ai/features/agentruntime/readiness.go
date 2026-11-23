package agentruntime

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	schemaReady     = "PostgresSchemaSetupReady"
	deploymentReady = "AgentRuntimeDeploymentReady"
	serviceReady    = "AgentRuntimeServiceReady"
	endpointReady   = "AgentRuntimeEndpointReady"
)

// setRuntimeCondition updates one gate without replacing unrelated conditions.
// SetStatusCondition retains its transition time while the status is unchanged.
func setRuntimeCondition(ai *aiv1.AIService, kind string, status metav1.ConditionStatus, reason, message string) {
	meta.SetStatusCondition(&ai.Status.Conditions, metav1.Condition{
		Type: kind, Status: status, Reason: reason, Message: message, ObservedGeneration: ai.Generation,
	})
}

// blockRuntimeCondition marks a gate that could not be evaluated in this pass.
// Historical success must not appear current when a prerequisite stops progress.
func blockRuntimeCondition(ai *aiv1.AIService, kind, stage string) {
	message := "waiting for " + stage
	if old := meta.FindStatusCondition(ai.Status.Conditions, kind); old != nil {
		if old.Reason == "Blocked" {
			_, prior, ok := strings.Cut(old.Message, "; previous observation: ")
			parts := strings.Fields(prior)
			if ok && len(parts) == 4 && parts[1] == "at" && parts[2] == "generation" {
				if generation, err := strconv.ParseInt(parts[3], 10, 64); err == nil {
					message += fmt.Sprintf("; previous observation: %s at generation %d", safePriorReason(parts[0]), generation)
				}
			}
		} else if old.Status == metav1.ConditionFalse {
			// Older operator versions copied raw API errors into messages. Retain
			// the diagnostic reason and generation without copying those payloads.
			message += fmt.Sprintf("; previous observation: %s at generation %d", safePriorReason(old.Reason), old.ObservedGeneration)
		}
	}
	if len(message) > 512 {
		message = message[:512]
	}
	setRuntimeCondition(ai, kind, metav1.ConditionUnknown, "Blocked", message)
}

// Persisted conditions can predate safe diagnostics. Retain useful known
// outcomes without trusting arbitrary reason strings or historical messages.
func safePriorReason(reason string) string {
	switch reason {
	case "Failed", "TimedOut", "Pending", "Superseded", "ReconcileFailed", "InvalidCheckpointSecret", "CheckpointSecretMissing", "InvalidCheckpointEnvironment", "InvalidConfiguration",
		"DeploymentMissing", "ObservationFailed", "DeploymentUnavailable", "ReplicaTargetMismatch", "DeploymentNotObserved",
		"SelectorMismatch", "RolloutPending", "PodsNotReady", "ServiceMissing", "ServiceUnavailable", "ServicePortMismatch",
		"EndpointSliceMismatch", "EndpointTargetMismatch", "EndpointsPending":
		return reason
	default:
		return "Unknown"
	}
}

// observeReadiness runs after both objects have been reconciled. Waiting for
// Deployment availability must not prevent the Service from being created.
func (r *AgentRuntimeReconciler) observeReadiness(ctx context.Context, ai *aiv1.AIService) error {
	pods, depErr := r.observeDeployment(ctx, ai)
	svc, svcErr := r.observeService(ctx, ai)
	var endpointErr error
	if depErr == nil && svcErr == nil && svc != nil {
		endpointErr = r.observeEndpoints(ctx, ai, svc, pods)
	} else {
		blockRuntimeCondition(ai, endpointReady, "Deployment and Service observation")
	}
	// The schema stage has already checked the current input identity, including
	// recorded success after Job cleanup. Consume that result rather than
	// requiring the completed Job to remain present or replaying schema work.
	for _, kind := range []string{schemaReady, deploymentReady, serviceReady, endpointReady} {
		c := meta.FindStatusCondition(ai.Status.Conditions, kind)
		if c == nil || c.Status != metav1.ConditionTrue || c.ObservedGeneration != ai.Generation {
			reason, message := "ObservationPending", "waiting for "+kind
			if c != nil {
				reason, message = c.Reason, c.Message
			}
			setRuntimeCondition(ai, "Ready", metav1.ConditionFalse, reason, message)
			return firstObservationError(depErr, svcErr, endpointErr)
		}
	}
	setRuntimeCondition(ai, "Ready", metav1.ConditionTrue, "Available", "schema is current; all desired runtime replicas and the Service endpoint are ready")
	return nil
}

// Missing or unhealthy workloads are normal waiting states. Only failed API
// observations return errors; readiness conditions describe both cases.
func firstObservationError(errs ...error) error {
	for _, err := range errs {
		if err != nil {
			return err
		}
	}
	return nil
}

// observeDeployment also returns the healthy current Pods that endpoints may
// target. Replica counts alone cannot establish ownership or probe health.
func (r *AgentRuntimeReconciler) observeDeployment(ctx context.Context, ai *aiv1.AIService) (map[types.UID]*corev1.Pod, error) {
	pods := map[types.UID]*corev1.Pod{}
	fail := func(reason, message string) {
		setRuntimeCondition(ai, deploymentReady, metav1.ConditionFalse, reason, message)
	}
	dep := &appsv1.Deployment{}
	if err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-agentruntime-deployment"}, dep); err != nil {
		if apierrors.IsNotFound(err) {
			fail("DeploymentMissing", "waiting for the runtime Deployment")
			return pods, nil
		}
		fail("ObservationFailed", "cannot read the runtime Deployment; check operator permissions and API availability")
		return pods, fmt.Errorf("observe runtime Deployment: %w", err)
	}
	if !metav1.IsControlledBy(dep, ai) || dep.DeletionTimestamp != nil {
		fail("DeploymentUnavailable", "runtime Deployment must be owned by this AIService and not terminating")
		return pods, nil
	}
	want := ai.Spec.Replicas
	if want <= 0 || dep.Spec.Replicas == nil || *dep.Spec.Replicas != want {
		fail("ReplicaTargetMismatch", "waiting for a positive runtime Deployment replica target matching the AIService")
		return pods, nil
	}
	if dep.Status.ObservedGeneration < dep.Generation {
		fail("DeploymentNotObserved", "waiting for the Deployment controller to observe the current generation")
		return pods, nil
	}
	if dep.Spec.Selector == nil || !equality.Semantic.DeepEqual(dep.Spec.Selector.MatchLabels, agentRuntimeSelectorLabels(ai)) || len(dep.Spec.Selector.MatchExpressions) != 0 {
		fail("SelectorMismatch", "runtime Deployment selector must match the runtime workload labels")
		return pods, nil
	}
	// Rolling updates can retain available old replicas while replacements fail.
	// Require the entire desired rollout to converge, including removal of surplus
	// old replicas, before that capacity can satisfy readiness.
	if dep.Status.UpdatedReplicas != want || dep.Status.Replicas != want || dep.Status.ReadyReplicas < want || dep.Status.AvailableReplicas < want || dep.Status.UnavailableReplicas != 0 {
		fail("RolloutPending", fmt.Sprintf("waiting for all %d desired runtime replicas: %d updated, %d ready, %d available, %d total", want, dep.Status.UpdatedReplicas, dep.Status.ReadyReplicas, dep.Status.AvailableReplicas, dep.Status.Replicas))
		return pods, nil
	}
	var replicaSets appsv1.ReplicaSetList
	var candidates corev1.PodList
	selector := client.MatchingLabels(agentRuntimeSelectorLabels(ai))
	if err := r.List(ctx, &replicaSets, client.InNamespace(ai.Namespace), selector); err != nil {
		fail("ObservationFailed", "cannot list runtime ReplicaSets; check operator permissions and API availability")
		return pods, fmt.Errorf("observe runtime ReplicaSets: %w", err)
	}
	// Labels narrow the search but can also match old or unrelated workloads.
	// Follow controller UIDs and the desired template before counting any Pod.
	current := map[types.UID]bool{}
	for i := range replicaSets.Items {
		rs := &replicaSets.Items[i]
		if rs.UID != "" && rs.DeletionTimestamp == nil && metav1.IsControlledBy(rs, dep) && sameRuntimeTemplate(rs.Spec.Template, dep.Spec.Template) {
			current[rs.UID] = true
		}
	}
	if err := r.List(ctx, &candidates, client.InNamespace(ai.Namespace), selector); err != nil {
		fail("ObservationFailed", "cannot list runtime Pods; check operator permissions and API availability")
		return pods, fmt.Errorf("observe runtime Pods: %w", err)
	}
	for i := range candidates.Items {
		pod := &candidates.Items[i]
		owner := metav1.GetControllerOf(pod)
		if owner != nil && owner.APIVersion == appsv1.SchemeGroupVersion.String() && owner.Kind == "ReplicaSet" && current[owner.UID] && pod.UID != "" && healthyRuntimePod(pod, agentRuntimeWorkloadName(ai.Name)) {
			pods[pod.UID] = pod
		}
	}
	if len(pods) < int(want) {
		fail("PodsNotReady", fmt.Sprintf("waiting for all %d current runtime Pods to pass their readiness probe; %d are ready", want, len(pods)))
		return pods, nil
	}
	setRuntimeCondition(ai, deploymentReady, metav1.ConditionTrue, "Available", "all desired runtime replicas are updated, ready and available")
	return pods, nil
}

// The Deployment controller adds a hash label to ReplicaSet templates. Ignore
// only that label; every other template difference identifies another rollout.
func sameRuntimeTemplate(a, b corev1.PodTemplateSpec) bool {
	x, y := a.DeepCopy(), b.DeepCopy()
	delete(x.Labels, appsv1.DefaultDeploymentUniqueLabelKey)
	delete(y.Labels, appsv1.DefaultDeploymentUniqueLabelKey)
	return equality.Semantic.DeepEqual(x, y)
}

// PodReady includes readiness gates and sidecars. Also require the named runtime
// container to be running and ready with the expected application probe.
func healthyRuntimePod(pod *corev1.Pod, containerName string) bool {
	if pod.DeletionTimestamp != nil || pod.Status.Phase != corev1.PodRunning {
		return false
	}
	ready := false
	for _, c := range pod.Status.Conditions {
		if c.Type == corev1.PodReady && c.Status == corev1.ConditionTrue {
			ready = true
		}
	}
	if !ready {
		return false
	}
	probeOK := false
	for _, c := range pod.Spec.Containers {
		if c.Name == containerName && c.ReadinessProbe != nil && c.ReadinessProbe.HTTPGet != nil {
			get := c.ReadinessProbe.HTTPGet
			probeOK = get.Path == "/health" && get.Port == intstr.FromInt32(defaultAgentRuntimeHTTPPort) && (get.Scheme == "" || get.Scheme == corev1.URISchemeHTTP)
		}
	}
	for _, c := range pod.Status.ContainerStatuses {
		if c.Name == containerName {
			return probeOK && c.Ready && c.State.Running != nil
		}
	}
	return false
}

// observeService checks routing configuration separately from backend health.
// A valid selector and application port do not prove any endpoint is usable.
func (r *AgentRuntimeReconciler) observeService(ctx context.Context, ai *aiv1.AIService) (*corev1.Service, error) {
	fail := func(reason, message string) {
		setRuntimeCondition(ai, serviceReady, metav1.ConditionFalse, reason, message)
	}
	svc := &corev1.Service{}
	if err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: agentRuntimeServiceName(ai.Name)}, svc); err != nil {
		if apierrors.IsNotFound(err) {
			fail("ServiceMissing", "waiting for the runtime Service")
			return nil, nil
		}
		fail("ObservationFailed", "cannot read the runtime Service; check operator permissions and API availability")
		return nil, fmt.Errorf("observe runtime Service: %w", err)
	}
	if svc.DeletionTimestamp != nil || !metav1.IsControlledBy(svc, ai) || svc.Spec.Type != corev1.ServiceTypeClusterIP || svc.Spec.ClusterIP == "" || svc.Spec.ClusterIP == corev1.ClusterIPNone {
		fail("ServiceUnavailable", "waiting for an owned, nonterminating runtime ClusterIP Service")
		return nil, nil
	}
	if !equality.Semantic.DeepEqual(svc.Spec.Selector, agentRuntimeSelectorLabels(ai)) {
		fail("SelectorMismatch", "runtime Service selector must match the runtime workload labels")
		return nil, nil
	}
	for _, port := range svc.Spec.Ports {
		if port.Name == "http" && port.Port == defaultAgentRuntimeHTTPPort && port.TargetPort == intstr.FromInt32(defaultAgentRuntimeHTTPPort) && (port.Protocol == "" || port.Protocol == corev1.ProtocolTCP) {
			setRuntimeCondition(ai, serviceReady, metav1.ConditionTrue, "Configured", "runtime application Service and selector are configured")
			return svc, nil
		}
	}
	fail("ServicePortMismatch", "runtime Service must route TCP application traffic to port 8080")
	return nil, nil
}

// observeEndpoints cross-checks advertised routing with independently verified
// Pod health. Endpoint readiness alone can be misleading when a Service publishes
// unready addresses or cached slices still refer to replaced workloads.
func (r *AgentRuntimeReconciler) observeEndpoints(ctx context.Context, ai *aiv1.AIService, svc *corev1.Service, pods map[types.UID]*corev1.Pod) error {
	fail := func(reason, message string) {
		setRuntimeCondition(ai, endpointReady, metav1.ConditionFalse, reason, message)
	}
	var slices discoveryv1.EndpointSliceList
	if err := r.List(ctx, &slices, client.InNamespace(ai.Namespace), client.MatchingLabels{discoveryv1.LabelServiceName: svc.Name}); err != nil {
		fail("ObservationFailed", "cannot list runtime EndpointSlices; check operator permissions and API availability")
		return fmt.Errorf("observe runtime EndpointSlices: %w", err)
	}
	found := false
	for i := range slices.Items {
		slice := &slices.Items[i]
		if slice.DeletionTimestamp != nil {
			continue
		}
		// A Service can be recreated under the same name. Its UID distinguishes
		// current slices from backends left over from the previous instance.
		if !metav1.IsControlledBy(slice, svc) {
			fail("EndpointSliceMismatch", "runtime EndpointSlices must belong to the current Service UID")
			return nil
		}
		applicationPort := false
		for _, port := range slice.Ports {
			if port.Name != nil && *port.Name == "http" && port.Port != nil && *port.Port == defaultAgentRuntimeHTTPPort && (port.Protocol == nil || *port.Protocol == corev1.ProtocolTCP) {
				applicationPort = true
			}
		}
		if !applicationPort {
			continue
		}
		for _, endpoint := range slice.Endpoints {
			if endpoint.Conditions.Ready == nil || !*endpoint.Conditions.Ready || (endpoint.Conditions.Terminating != nil && *endpoint.Conditions.Terminating) {
				continue
			}
			// Every advertised ready application backend must be safe to route to;
			// one valid target cannot mask another stale or foreign ready target.
			ref := endpoint.TargetRef
			if ref == nil || ref.Kind != "Pod" || ref.Namespace != ai.Namespace || (ref.APIVersion != "" && ref.APIVersion != "v1") {
				fail("EndpointTargetMismatch", "a ready application endpoint does not reference a current runtime Pod")
				return nil
			}
			pod := pods[ref.UID]
			if pod == nil || pod.Name != ref.Name || !labels.SelectorFromSet(svc.Spec.Selector).Matches(labels.Set(pod.Labels)) || !endpointAddressesMatch(endpoint.Addresses, pod) {
				fail("EndpointTargetMismatch", "a ready application endpoint must target a current owned runtime Pod passing its readiness probe")
				return nil
			}
			found = true
		}
	}
	if !found {
		fail("EndpointsPending", "waiting for a matching ready runtime application endpoint")
		return nil
	}
	setRuntimeCondition(ai, endpointReady, metav1.ConditionTrue, "Available", "runtime Service has a matching ready application endpoint")
	return nil
}

// Check every advertised address against the current Pod's assigned addresses,
// including its secondary IPs on dual-stack clusters.
func endpointAddressesMatch(addresses []string, pod *corev1.Pod) bool {
	if len(addresses) == 0 {
		return false
	}
	for _, address := range addresses {
		match := address == pod.Status.PodIP && address != ""
		for _, ip := range pod.Status.PodIPs {
			match = match || address == ip.IP
		}
		if !match {
			return false
		}
	}
	return true
}
