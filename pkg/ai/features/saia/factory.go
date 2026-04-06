package saia

import (
	"context"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type SaiaFactory struct{}

func (f *SaiaFactory) RequiresRay() bool { return true }

func (f *SaiaFactory) New(ctx context.Context, c client.Client, scheme *runtime.Scheme, ai *aiv1.AIService, recorder record.EventRecorder) (common.FeatureHandler, error) {
	return &SaiaReconciler{
		Client:   c,
		Scheme:   scheme,
		Recorder: recorder,
	}, nil
}
