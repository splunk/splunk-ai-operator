package ai_platform

import (
	"context"
	"encoding/json"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/validation/field"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

func stageNames(stages []reconcileStage) []string {
	names := make([]string, 0, len(stages))
	for _, s := range stages {
		names = append(names, s.name)
	}
	return names
}

// The stage list of every profile except cpuOnly is exactly what it was before
// profiles existed. This pins that baseline.
var fullfeatureStages = []string{
	"Validate", "Sidecars", "rayAutoscalerRBAC", "RayService", "ActiveClusterScale",
	"WeaviateDatabase", "Ingress", "RayServiceStatus", "WeaviateDatabaseStatus",
	"IngressStatus", "AIService", "AIServiceStatus",
}

func TestStagesFor_PerProfile(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, aiApi.AddToScheme(scheme))
	for _, profile := range []aiApi.AIPlatformProfile{"", aiApi.AIPlatformProfileLegacyFull, aiApi.AIPlatformProfileFullFeature} {
		p := &aiApi.AIPlatform{Spec: aiApi.AIPlatformSpec{Profile: profile}}
		r := New(p, fake.NewClientBuilder().WithScheme(scheme).Build(), scheme, record.NewFakeRecorder(10))
		var scale reconcile.Result
		assert.Equal(t, fullfeatureStages, stageNames(r.stagesFor(p, &scale)), "profile %q keeps the pre-profile stages", profile)
	}

	p := &aiApi.AIPlatform{Spec: aiApi.AIPlatformSpec{Profile: aiApi.AIPlatformProfileCPUOnly}}
	r := New(p, fake.NewClientBuilder().WithScheme(scheme).Build(), scheme, record.NewFakeRecorder(10))
	var scale reconcile.Result
	assert.Equal(t, []string{"Validate", "AIService", "AIServiceStatus"}, stageNames(r.stagesFor(p, &scale)),
		"cpuOnly runs no Ray, Weaviate, ingress or sidecar stage")
}

func buildCPUOnlyPlatform() *aiApi.AIPlatform {
	return &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "lp", Namespace: "ns1", UID: "uid-lp"},
		Spec: aiApi.AIPlatformSpec{
			Profile:       aiApi.AIPlatformProfileCPUOnly,
			ClusterDomain: "cluster.local",
			ObjectStorage: aiApi.ObjectStorageSpec{Path: "s3://bucket", Region: "us-west-2"},
			Features: []aiApi.FeatureSpec{
				{Name: "slim", Version: "1.0.0"},
				{Name: "agentruntime", Provider: "launchpad", CheckpointDbSecretRef: "pg"},
			},
		},
	}
}

func TestBuildAIService_SlimGetsAgentRuntimeURLOnlyForCPUOnly(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, aiApi.AddToScheme(scheme))
	platform := buildCPUOnlyPlatform()
	r := New(platform, fake.NewClientBuilder().WithScheme(scheme).Build(), scheme, record.NewFakeRecorder(10))

	build := func(p *aiApi.AIPlatform, f aiApi.FeatureSpec) *aiApi.AIService {
		return r.buildAIService(context.Background(), p, f, featureServiceName(p.Name, f))
	}

	// The URL comes from the first agentruntime feature, using the Service name and
	// port the AgentRuntime handler defines (never a hard-coded copy).
	slim := build(platform, platform.Spec.Features[0])
	want := agentruntime.FeatureServiceURL("lp", "launchpad", "ns1", "cluster.local")
	assert.Equal(t, want, slim.Spec.AgentRuntimeUrl)
	assert.Contains(t, want, ":8080")
	assert.Contains(t, want, ".ns1.svc.cluster.local")
	assert.Empty(t, slim.Spec.AIPlatformUrl, "cpuOnly SLIM has no Ray platform URL")

	// No other feature is given it, and the agentruntime service has no Ray URL either.
	ar := build(platform, platform.Spec.Features[1])
	assert.Empty(t, ar.Spec.AgentRuntimeUrl)
	assert.Empty(t, ar.Spec.AIPlatformUrl)

	// fullfeature, omitted and legacy "full" never set it, and the field is left out
	// of the serialized spec entirely, so existing AIServices are not rewritten.
	for _, profile := range []aiApi.AIPlatformProfile{"", aiApi.AIPlatformProfileLegacyFull, aiApi.AIPlatformProfileFullFeature} {
		p := buildCPUOnlyPlatform()
		p.Spec.Profile = profile
		for _, f := range p.Spec.Features {
			got := build(p, f)
			assert.Empty(t, got.Spec.AgentRuntimeUrl, "profile %q feature %s", profile, f.Name)
			raw, err := json.Marshal(got.Spec)
			require.NoError(t, err)
			assert.NotContains(t, string(raw), "agentRuntimeUrl", "profile %q must not change the serialized AIService spec", profile)
		}
	}

	// cpuOnly without an agentruntime feature leaves it empty (SLIM then reports why).
	noRuntime := buildCPUOnlyPlatform()
	noRuntime.Spec.Features = noRuntime.Spec.Features[:1]
	assert.Empty(t, build(noRuntime, noRuntime.Spec.Features[0]).Spec.AgentRuntimeUrl)
}

// A cpuOnly platform reconciles end to end with a client that has no Ray,
// Weaviate or monitoring types registered at all, so any attempt to touch them
// would fail. The child services are created, and a second reconcile of the same
// configuration changes nothing.
func TestReconcile_CPUOnlyTouchesNoRayOrWeaviateAndIsStable(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, aiApi.AddToScheme(scheme))
	require.NoError(t, corev1.AddToScheme(scheme))
	platform := buildCPUOnlyPlatform()

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(platform).
		WithStatusSubresource(&aiApi.AIPlatform{}, &aiApi.AIService{}).
		WithIndex(&aiApi.AIService{}, ownerKey, func(obj client.Object) []string {
			if o := metav1.GetControllerOfNoCopy(obj); o != nil {
				return []string{o.Name}
			}
			return nil
		}).Build()
	r := New(platform.DeepCopy(), c, scheme, record.NewFakeRecorder(50))

	reconcileOnce := func() {
		var live aiApi.AIPlatform
		require.NoError(t, c.Get(context.Background(), client.ObjectKeyFromObject(platform), &live))
		_, err := r.Reconcile(context.Background(), &live)
		require.NoError(t, err)
	}
	reconcileOnce()

	var children aiApi.AIServiceList
	require.NoError(t, c.List(context.Background(), &children, client.InNamespace("ns1")))
	require.Len(t, children.Items, 2, "slim plus the one agentruntime provider")
	resourceVersions := map[string]string{}
	for _, child := range children.Items {
		resourceVersions[child.Name] = child.ResourceVersion
	}

	var got aiApi.AIPlatform
	require.NoError(t, c.Get(context.Background(), client.ObjectKeyFromObject(platform), &got))
	assert.Equal(t, aiApi.AIPlatformProfileCPUOnly, got.Status.Profile)
	for _, cond := range got.Status.Conditions {
		assert.NotContains(t, cond.Type, "Ray", "no Ray condition is reported for cpuOnly")
		assert.NotContains(t, cond.Type, "Weaviate")
	}

	reconcileOnce()
	require.NoError(t, c.List(context.Background(), &children, client.InNamespace("ns1")))
	for _, child := range children.Items {
		assert.Equal(t, resourceVersions[child.Name], child.ResourceVersion, "a repeated reconcile must not rewrite %s", child.Name)
	}
}

// With several agentruntime features there is no single Service to point SLIM at.
// The platform controller leaves the URL empty (it does not pick one) and the SLIM
// handler then reports the ambiguity, the same as it does for the other profiles.
func TestBuildAIService_SeveralAgentRuntimeFeaturesLeaveSlimUnresolved(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, aiApi.AddToScheme(scheme))
	p := buildCPUOnlyPlatform()
	p.Spec.Features = append(p.Spec.Features, aiApi.FeatureSpec{Name: "agentruntime", Provider: "second", CheckpointDbSecretRef: "pg"})
	r := New(p, fake.NewClientBuilder().WithScheme(scheme).Build(), scheme, record.NewFakeRecorder(10))
	slim := r.buildAIService(context.Background(), p, p.Spec.Features[0], featureServiceName(p.Name, p.Spec.Features[0]))
	assert.Empty(t, slim.Spec.AgentRuntimeUrl)

	// Admission refuses it earlier, so a webhook-fronted cluster never gets here.
	errs := p.Spec.ValidateProfile(field.NewPath("spec"))
	require.NotEmpty(t, errs)
	assert.Contains(t, errs.ToAggregate().Error(), "only one agentruntime feature may be defined alongside it")
}
