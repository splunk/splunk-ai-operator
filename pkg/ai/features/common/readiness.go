package common

import (
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// IsCurrentServiceReady requires both the overall status and its Ready condition
// to describe the current spec generation. If either is stale, the parent must
// keep waiting for the newer spec to be applied.
func IsCurrentServiceReady(ai *aiv1.AIService) bool {
	c := meta.FindStatusCondition(ai.Status.Conditions, "Ready")
	return ai.DeletionTimestamp == nil && c != nil && c.Status == metav1.ConditionTrue &&
		c.ObservedGeneration == ai.Generation && ai.Status.ObservedGeneration == ai.Generation
}
