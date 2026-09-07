package features

import (
	"context"
	"testing"

	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestFeatureFactories_AgentRuntimeIsRegistered(t *testing.T) {
	factory, ok := FeatureFactories["agentruntime"]

	require.True(t, ok)
	require.NotNil(t, factory)
	assert.IsType(t, &agentruntime.AgentRuntimeFactory{}, factory)
}

func TestFeatureFactories_AgentRuntimeCreatesHandler(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, corev1.AddToScheme(scheme))
	client := fake.NewClientBuilder().WithScheme(scheme).Build()
	var factory common.FeatureFactory = FeatureFactories["agentruntime"]

	handler, err := factory.New(context.Background(), client, scheme, nil, record.NewFakeRecorder(10))

	require.NoError(t, err)
	require.NotNil(t, handler)
	assert.IsType(t, &agentruntime.AgentRuntimeReconciler{}, handler)
}
