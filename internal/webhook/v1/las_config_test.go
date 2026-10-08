package v1

import (
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

func fixtureLASForWebhookTest() *aiv1.LASFeatureSpec {
	return &aiv1.LASFeatureSpec{
		Image:       aiv1.LASImageSpec{Repository: "registry.example/fixture", Tag: "candidate-123"},
		AssistantID: "contract_fixture",
	}
}

func TestLASFeatureConfigValidation(t *testing.T) {
	path := field.NewPath("spec", "features").Index(0).Child("las")
	if errs := validateLASFeature(nil, path); len(errs) != 1 || errs[0].Field != "spec.features[0].las" {
		t.Fatalf("missing LAS config errors: %v", errs)
	}
	if errs := validateLASFeature(fixtureLASForWebhookTest(), path); len(errs) != 0 {
		t.Fatalf("valid LAS config errors: %v", errs)
	}
	bad := &aiv1.LASFeatureSpec{}
	if errs := validateLASFeature(bad, path); len(errs) != 3 {
		t.Fatalf("incomplete LAS config errors: %v", errs)
	}
}
