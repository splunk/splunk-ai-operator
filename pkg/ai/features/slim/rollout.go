package slim

import (
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	appsv1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func slimRolloutReady(ai *aiv1.AIService, deployment *appsv1.Deployment) bool {
	return deployment.Spec.Replicas != nil && *deployment.Spec.Replicas > 0 &&
		slimDeploymentSettled(ai, deployment, *deployment.Spec.Replicas)
}

func slimDeploymentDrained(ai *aiv1.AIService, deployment *appsv1.Deployment) bool {
	return deployment.Spec.Replicas != nil && *deployment.Spec.Replicas == 0 &&
		slimDeploymentSettled(ai, deployment, 0)
}

func slimDeploymentSettled(ai *aiv1.AIService, deployment *appsv1.Deployment, want int32) bool {
	status := deployment.Status
	// During a rollout, available old replicas can mask unready replacements.
	// Check the applied generation and require all capacity to use its template.
	return metav1.IsControlledBy(deployment, ai) && deployment.DeletionTimestamp == nil &&
		status.ObservedGeneration == deployment.Generation &&
		status.Replicas == want && status.UpdatedReplicas == want &&
		status.ReadyReplicas == want && status.AvailableReplicas == want &&
		status.UnavailableReplicas == 0 && (status.TerminatingReplicas == nil || *status.TerminatingReplicas == 0)
}
