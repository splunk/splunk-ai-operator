package slim

import (
	"context"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestSlimFactory_New(t *testing.T) {
	s := runtime.NewScheme()
	_ = scheme.AddToScheme(s)
	_ = aiv1.AddToScheme(s)

	factory := &SlimFactory{}
	fakeClient := fake.NewClientBuilder().WithScheme(s).Build()
	recorder := record.NewFakeRecorder(10)

	aiService := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-service",
			Namespace: "default",
		},
	}

	handler, err := factory.New(context.Background(), fakeClient, s, aiService, recorder)

	require.NoError(t, err)
	require.NotNil(t, handler)

	// Verify it returns a SlimReconciler
	reconciler, ok := handler.(*SlimReconciler)
	assert.True(t, ok, "Expected handler to be *SlimReconciler")
	assert.NotNil(t, reconciler.Client)
	assert.NotNil(t, reconciler.Scheme)
	assert.NotNil(t, reconciler.Recorder)
}
