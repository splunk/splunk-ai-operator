package agentruntime

import (
	"context"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestAgentRuntimeFactory_NewReturnsConfiguredHandler(t *testing.T) {
	scheme := buildAgentRuntimeTestScheme(t)
	client := fake.NewClientBuilder().WithScheme(scheme).Build()
	recorder := record.NewFakeRecorder(10)
	factory := &AgentRuntimeFactory{}

	handler, err := factory.New(context.Background(), client, scheme, &aiv1.AIService{}, recorder)

	require.NoError(t, err)
	reconciler, ok := handler.(*AgentRuntimeReconciler)
	require.True(t, ok)
	assert.Same(t, client, reconciler.Client)
	assert.Same(t, scheme, reconciler.Scheme)
	assert.Same(t, recorder, reconciler.Recorder)
}
