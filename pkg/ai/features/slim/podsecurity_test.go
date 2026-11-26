package slim

import (
	"context"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/podsecurity"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// PSB SEC-RUN-ASLR (FR3): the SLIM pod runs with the RuntimeDefault seccomp
// profile, which blocks personality(ADDR_NO_RANDOMIZE) ("setarch -R").
func TestSlimPodTemplateUsesRuntimeDefaultSeccomp(t *testing.T) {
	t.Setenv("RELATED_IMAGE_SLIM_API", "slim-api:test")
	scheme := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "test-slim", Namespace: "default", UID: "uid-slim-seccomp"},
	}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SlimReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSlimDeployment(context.Background(), ai))

	dep := &appsv1.Deployment{}
	require.NoError(t, fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "test-slim-slim-deployment", Namespace: "default",
	}, dep))
	spec := dep.Spec.Template.Spec
	assert.Equal(t, podsecurity.RuntimeDefaultSeccomp(), spec.SecurityContext)
	for _, c := range append(spec.InitContainers, spec.Containers...) {
		if c.SecurityContext != nil {
			assert.Nil(t, c.SecurityContext.SeccompProfile, "container %s overrides the pod seccomp profile", c.Name)
		}
	}
}
