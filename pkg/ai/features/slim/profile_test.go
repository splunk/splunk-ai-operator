package slim

import (
	"context"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

const testAgentRuntimeURL = "http://lp-agentruntime-launchpad-svc.default.svc.cluster.local:8080"

func slimPlatform(profile aiv1.AIPlatformProfile, rayReady bool) *aiv1.AIPlatform {
	p := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "lp", Namespace: "default"},
		Spec:       aiv1.AIPlatformSpec{Profile: profile},
	}
	if rayReady {
		p.Status.RayServiceName = "ray-svc"
		p.Status.Conditions = []metav1.Condition{{Type: "RayServiceStatusReady", Status: metav1.ConditionTrue}}
	}
	return p
}

func slimService(agentRuntimeURL string) *aiv1.AIService {
	return &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "lp-slim", Namespace: "default", UID: types.UID("uid-slim")},
		Spec: aiv1.AIServiceSpec{
			Feature:         aiv1.FeatureSpec{Name: "slim"},
			AIPlatformRef:   corev1.ObjectReference{Name: "lp", Namespace: "default"},
			AgentRuntimeUrl: agentRuntimeURL,
		},
	}
}

func slimReconciler(t *testing.T, objs ...*aiv1.AIPlatform) (*SlimReconciler, struct{}) {
	t.Helper()
	t.Setenv("RELATED_IMAGE_SLIM_API", "docker.io/splunk/slim:test")
	scheme := buildTestScheme(t)
	b := fake.NewClientBuilder().WithScheme(scheme)
	for _, o := range objs {
		b = b.WithObjects(o)
	}
	c := b.Build()
	return &SlimReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}, struct{}{}
}

// cpuOnly SLIM has no Ray: it validates without Ray or a platform URL, and it
// needs the AgentRuntime URL the platform controller sets.
func TestValidateAIService_CPUOnlySlimNeedsAgentRuntimeURLNotRay(t *testing.T) {
	r, _ := slimReconciler(t, slimPlatform(aiv1.AIPlatformProfileCPUOnly, false))

	ai := slimService(testAgentRuntimeURL)
	require.NoError(t, r.validateAIService(context.Background(), ai))
	assert.Empty(t, ai.Spec.AIPlatformUrl, "no Ray platform URL is derived for cpuOnly")

	missing := slimService("")
	err := r.validateAIService(context.Background(), missing)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "AgentRuntimeUrl must be set for the cpuOnly profile")
}

// Every other profile keeps waiting for Ray and deriving its platform URL.
func TestValidateAIService_FullfeatureSlimKeepsTheRayPrecondition(t *testing.T) {
	for _, profile := range []aiv1.AIPlatformProfile{"", aiv1.AIPlatformProfileLegacyFull, aiv1.AIPlatformProfileFullFeature} {
		r, _ := slimReconciler(t, slimPlatform(profile, false))
		err := r.validateAIService(context.Background(), slimService(""))
		require.Error(t, err, "profile %q must still wait for Ray", profile)
		assert.Contains(t, err.Error(), "RayService is not ready")

		r, _ = slimReconciler(t, slimPlatform(profile, true))
		ai := slimService("")
		require.NoError(t, r.validateAIService(context.Background(), ai), "profile %q", profile)
		assert.Equal(t, "http://ray-svc.default.svc.cluster.local:8000", ai.Spec.AIPlatformUrl)
	}
}

func deploymentEnv(t *testing.T, r *SlimReconciler, ai *aiv1.AIService) map[string]string {
	t.Helper()
	require.NoError(t, r.reconcileSlimDeployment(context.Background(), ai))
	var dep appsv1.Deployment
	require.NoError(t, r.Client.Get(context.Background(), types.NamespacedName{Namespace: ai.Namespace, Name: ai.Name + "-slim-deployment"}, &dep))
	require.NotEmpty(t, dep.Spec.Template.Spec.Containers)
	env := map[string]string{}
	for _, e := range dep.Spec.Template.Spec.Containers[0].Env {
		env[e.Name] = e.Value
	}
	return env
}

func TestSlimDeploymentEnv_CPUOnlyHasAgentRuntimeURLAndNoPlatformURL(t *testing.T) {
	r, _ := slimReconciler(t, slimPlatform(aiv1.AIPlatformProfileCPUOnly, false))
	ai := slimService(testAgentRuntimeURL + "/")
	require.NoError(t, r.validateAIService(context.Background(), ai))

	env := deploymentEnv(t, r, ai)
	assert.Equal(t, testAgentRuntimeURL, env["AI_TIER_AGENT_RUNTIME_URL"], "a trailing slash is trimmed")
	_, hasPlatform := env["PLATFORM_URL"]
	assert.False(t, hasPlatform, "cpuOnly SLIM has no PLATFORM_URL")
}

func TestSlimDeploymentEnv_FullfeatureIsUnchanged(t *testing.T) {
	r, _ := slimReconciler(t, slimPlatform(aiv1.AIPlatformProfileFullFeature, true))
	ai := slimService("")
	require.NoError(t, r.validateAIService(context.Background(), ai))

	env := deploymentEnv(t, r, ai)
	assert.Equal(t, "http://ray-svc.default.svc.cluster.local:8000", env["PLATFORM_URL"])
	_, hasRuntime := env["AI_TIER_AGENT_RUNTIME_URL"]
	assert.False(t, hasRuntime, "fullfeature SLIM does not get the AgentRuntime URL")
}
