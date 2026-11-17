package agentruntime

import (
	"context"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func profileTestEnv(t *testing.T) {
	t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_BASE", "docker.io/splunk/agent-runtime:test")
	t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_LAUNCHPAD", "docker.io/splunk/agent-runtime-provider-launchpad:test")
	t.Setenv("RELATED_AGENT_RUNTIME_MODULE_PROVIDER_LAUNCHPAD", "launchpad.loader:LaunchpadLoader")
	t.Setenv(schemaSetupImageEnv, "docker.io/splunk/agent-runtime-schema-setup:test")
}

func profileAIService() *aiv1.AIService {
	return &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "lp-agentruntime-launchpad", Namespace: "default", UID: types.UID("uid-ar")},
		Spec: aiv1.AIServiceSpec{
			Feature:               aiv1.FeatureSpec{Name: "agentruntime", Provider: "launchpad"},
			AIPlatformRef:         corev1.ObjectReference{Name: "lp", Namespace: "default"},
			CheckpointDbSecretRef: "pg",
			Replicas:              1,
		},
	}
}

func validateWith(t *testing.T, platform *aiv1.AIPlatform) (*aiv1.AIService, error) {
	t.Helper()
	scheme := buildAgentRuntimeTestScheme(t)
	ai := profileAIService()
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(platform).Build()
	r := &AgentRuntimeReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}
	return ai, r.validateAIService(context.Background(), ai)
}

func platformWith(profile aiv1.AIPlatformProfile, rayReady bool) *aiv1.AIPlatform {
	p := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "lp", Namespace: "default"},
		Spec:       aiv1.AIPlatformSpec{Profile: profile},
	}
	if rayReady {
		p.Status.RayServiceName = "ray-svc"
		p.Status.VectorDbServiceName = "weaviate"
		p.Status.Conditions = []metav1.Condition{{Type: "RayServiceStatusReady", Status: metav1.ConditionTrue}}
	}
	return p
}

// cpuOnly has no Ray and no vector database: the runtime must validate without
// either, and must not be given a PLATFORM_URL or a VECTOR_DB_URL.
func TestValidateAIService_CPUOnlyNeedsNoRayPlatformURLOrVectorDB(t *testing.T) {
	profileTestEnv(t)
	ai, err := validateWith(t, platformWith(aiv1.AIPlatformProfileCPUOnly, false))
	require.NoError(t, err)
	assert.Empty(t, ai.Spec.AIPlatformUrl, "no platform URL is derived for cpuOnly")
	assert.Empty(t, ai.Spec.VectorDbUrl)

	env := buildAgentRuntimeEnv(ai, "launchpad.loader:LaunchpadLoader")
	names := map[string]bool{}
	for _, e := range env {
		names[e.Name] = true
	}
	assert.False(t, names["PLATFORM_URL"], "cpuOnly runtime has no PLATFORM_URL")
	assert.False(t, names["VECTOR_DB_URL"], "cpuOnly runtime has no VECTOR_DB_URL")
	assert.True(t, names["AGENT_MODULE"])
	assertEnv(t, env, "CHECKPOINT_DB_SECRET_REF", "pg")
}

// Every other profile keeps its existing behaviour: it waits for Ray, derives the
// platform URL and always sets PLATFORM_URL.
func TestValidateAIService_FullfeatureKeepsTheRayPrecondition(t *testing.T) {
	profileTestEnv(t)
	for _, profile := range []aiv1.AIPlatformProfile{"", aiv1.AIPlatformProfileLegacyFull, aiv1.AIPlatformProfileFullFeature} {
		_, err := validateWith(t, platformWith(profile, false))
		require.Error(t, err, "profile %q must still wait for Ray", profile)
		assert.Contains(t, err.Error(), "RayService is not ready")

		ai, err := validateWith(t, platformWith(profile, true))
		require.NoError(t, err, "profile %q", profile)
		assert.Equal(t, "http://ray-svc.default.svc.cluster.local:8000", ai.Spec.AIPlatformUrl)
		assert.Equal(t, "weaviate.default.svc.cluster.local", ai.Spec.VectorDbUrl)
		assertEnv(t, buildAgentRuntimeEnv(ai, "launchpad.loader:LaunchpadLoader"), "PLATFORM_URL", "http://ray-svc.default.svc.cluster.local:8000")
	}
}

func TestServiceURL_MatchesTheServiceTheHandlerCreates(t *testing.T) {
	assert.Equal(t, "http://"+agentRuntimeServiceName("lp-agentruntime-launchpad")+".ns1.svc.cluster.local:8080",
		ServiceURL("lp-agentruntime-launchpad", "ns1", "cluster.local"))
	assert.Equal(t, ServiceURL("a", "ns", "cluster.local"), ServiceURL("a", "ns", ""), "an empty domain defaults to cluster.local")
	long := "lp-agentruntime-this-provider-name-is-long-enough-to-force-the-service-name-to-be-bounded"
	assert.LessOrEqual(t, len(agentRuntimeServiceName(long)), 63)
	assert.Contains(t, ServiceURL(long, "ns", "cluster.local"), agentRuntimeServiceName(long))
}

// The env list feeds the deployment hash, and the hash decides whether the
// Postgres schema Job is re-run. For every existing (fullfeature) service the
// list, its order and therefore the hash must be exactly what they were before
// profiles existed, or an operator upgrade would re-run every schema Job.
func TestRuntimeEnvFingerprint_FullfeatureOrderAndHashAreUnchanged(t *testing.T) {
	ai := profileAIService()
	ai.Spec.AIPlatformUrl = "http://ray-svc.default.svc.cluster.local:8000"
	ai.Spec.VectorDbUrl = "weaviate.default.svc.cluster.local"
	module := "launchpad.loader:LaunchpadLoader"

	// The list as it was built before this change, written out literally. The
	// fingerprint redacts sensitive names, hence the redacted Secret reference.
	before := []corev1.EnvVar{
		{Name: "AGENT_MODULE", Value: module},
		{Name: "CHECKPOINT_DB_SECRET_REF", Value: "<redacted>"},
		{Name: "PLATFORM_URL", Value: "http://ray-svc.default.svc.cluster.local:8000"},
		{Name: "PYTHONPATH", Value: sharedPackagesPath},
		{Name: "TLS_DISABLED", Value: "true"},
		{Name: "VECTOR_DB_URL", Value: "weaviate.default.svc.cluster.local"},
	}
	got := buildRuntimeEnvFingerprint(ai, module)
	assert.Equal(t, before, got, "fullfeature env list and order must not change")
	assert.Equal(t, stableHash(before), stableHash(got))
	// Computed with the code from the base branch (before MPR-229) for this fixture.
	assert.Equal(t, "d453b32b74c7390b", stableHash(got), "the hash existing services already carry")
}
