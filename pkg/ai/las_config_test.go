package ai_platform

import (
	"context"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestBuildAIServicePropagatesLASImageAndAssistant(t *testing.T) {
	platform := &aiv1.AIPlatform{ObjectMeta: metav1.ObjectMeta{Name: "platform", Namespace: "default"}}
	feature := aiv1.FeatureSpec{
		Name:              "agentruntime",
		Provider:          "mltk",
		LicenseSecretRef:  "offline-license",
		PostgresSecretRef: "fixture-postgres",
		RedisSecretRef:    "fixture-redis",
		LAS: &aiv1.LASFeatureSpec{
			Image:       aiv1.LASImageSpec{Repository: "registry.example/fixture", Tag: "candidate-1"},
			AssistantID: "contract_fixture",
		},
	}
	r := &AIPlatformReconciler{}
	first := r.buildAIService(context.Background(), platform, feature, "platform-agentruntime-mltk")
	if first.Spec.Feature.LAS == nil || first.Spec.Feature.LAS.Image != feature.LAS.Image || first.Spec.Feature.LAS.AssistantID != "contract_fixture" {
		t.Fatalf("LAS selection was not propagated to AIService: %#v", first.Spec.Feature.LAS)
	}
	if first.Spec.Feature.LicenseSecretRef != "offline-license" || first.Spec.Feature.PostgresSecretRef != "fixture-postgres" || first.Spec.Feature.RedisSecretRef != "fixture-redis" {
		t.Fatalf("LAS deployment Secret references were not propagated: %#v", first.Spec.Feature)
	}
	feature.LAS.Image.Tag = "candidate-2"
	updated := r.buildAIService(context.Background(), platform, feature, "platform-agentruntime-mltk")
	if updated.Spec.Feature.LAS.Image.Tag != "candidate-2" {
		t.Fatalf("changed image tag was not propagated: %#v", updated.Spec.Feature.LAS)
	}
}
