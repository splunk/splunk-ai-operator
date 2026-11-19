package ai_platform

import (
	"context"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func cpuScheduler(selector string) *aiApi.SchedulingSpec {
	return &aiApi.SchedulingSpec{
		NodeSelector: map[string]string{"splunk.ai/workload-type": selector},
		Tolerations:  []corev1.Toleration{{Key: "dedicated", Operator: corev1.TolerationOpEqual, Value: "cpu", Effect: corev1.TaintEffectNoSchedule}},
	}
}

func newBuilder(t *testing.T, p *aiApi.AIPlatform) *AIPlatformReconciler {
	t.Helper()
	scheme := runtime.NewScheme()
	require.NoError(t, aiApi.AddToScheme(scheme))
	return New(p, fake.NewClientBuilder().WithScheme(scheme).Build(), scheme, record.NewFakeRecorder(10))
}

// Which features follow the platform's CPU scheduler, per profile. The agent
// runtime always does. SLIM does only under cpuOnly, where every workload is a
// CPU workload; under fullfeature it is left unplaced exactly as before, so an
// operator upgrade does not roll SLIM. SAIA and SECA are never placed.
func TestBuildAIService_CPUSchedulerReachesOnlyTheRightFeatures(t *testing.T) {
	for _, tc := range []struct {
		profile aiApi.AIPlatformProfile
		placed  map[string]bool
	}{
		{aiApi.AIPlatformProfileCPUOnly, map[string]bool{"agentruntime": true, "slim": true}},
		{aiApi.AIPlatformProfileFullFeature, map[string]bool{"agentruntime": true}},
		{aiApi.AIPlatformProfileLegacyFull, map[string]bool{"agentruntime": true}},
		{"", map[string]bool{"agentruntime": true}},
	} {
		p := buildCPUOnlyPlatform()
		p.Spec.Profile = tc.profile
		p.Spec.CPUSchedulingSpec = cpuScheduler("cpu")
		p.Spec.Features = []aiApi.FeatureSpec{
			{Name: "slim", Version: "1.0.0"},
			{Name: "agentruntime", Provider: "launchpad", CheckpointDbSecretRef: "pg"},
			{Name: "saia", Version: "1.0.0"},
		}
		r := newBuilder(t, p)
		for _, f := range p.Spec.Features {
			svc := r.buildAIService(context.Background(), p, f, featureServiceName(p.Name, f))
			if tc.placed[f.Name] {
				assert.Equal(t, p.Spec.CPUSchedulingSpec.NodeSelector, svc.Spec.NodeSelector, "profile %q feature %s", tc.profile, f.Name)
				assert.Equal(t, p.Spec.CPUSchedulingSpec.Tolerations, svc.Spec.Tolerations, "profile %q feature %s", tc.profile, f.Name)
			} else {
				assert.Empty(t, svc.Spec.NodeSelector, "profile %q feature %s must stay unplaced", tc.profile, f.Name)
				assert.Empty(t, svc.Spec.Tolerations, "profile %q feature %s must stay unplaced", tc.profile, f.Name)
			}
		}
	}
}

// With no CPU scheduler the operator invents nothing: a CPU-only host without
// node labels still places every workload.
func TestBuildAIService_NoCPUSchedulerMeansNoInventedSelector(t *testing.T) {
	p := buildCPUOnlyPlatform()
	p.Spec.CPUSchedulingSpec = nil
	r := newBuilder(t, p)
	for _, f := range p.Spec.Features {
		svc := r.buildAIService(context.Background(), p, f, featureServiceName(p.Name, f))
		assert.Empty(t, svc.Spec.NodeSelector, f.Name)
		assert.Empty(t, svc.Spec.Tolerations, f.Name)
	}
}

// The agent runtime's budget is the shared default under both profiles, and the
// platform never seeds a GPU resource into any service.
func TestBuildAIService_RuntimeBudgetIsTheSharedDefaultAndNoServiceGetsAGPU(t *testing.T) {
	for _, profile := range []aiApi.AIPlatformProfile{aiApi.AIPlatformProfileCPUOnly, aiApi.AIPlatformProfileFullFeature} {
		p := buildCPUOnlyPlatform()
		p.Spec.Profile = profile
		r := newBuilder(t, p)
		for _, f := range p.Spec.Features {
			svc := r.buildAIService(context.Background(), p, f, featureServiceName(p.Name, f))
			if f.Name == "agentruntime" {
				assert.Equal(t, agentruntime.DefaultResources(), svc.Spec.Resources, "profile %q", profile)
			}
			for _, rl := range []corev1.ResourceList{svc.Spec.Resources.Requests, svc.Spec.Resources.Limits} {
				for name := range rl {
					assert.False(t, aiApi.IsGPUResource(name), "profile %q feature %s seeds %s", profile, f.Name, name)
				}
			}
		}
	}
}

// A changed placement reaches every placed child, a value an administrator set
// directly on a child (its resources) is kept, and an unchanged reconcile
// rewrites nothing.
func TestReconcile_ChangedPlacementPropagatesWithoutRevertingUserResources(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, aiApi.AddToScheme(scheme))
	require.NoError(t, corev1.AddToScheme(scheme))
	platform := buildCPUOnlyPlatform()
	platform.Spec.Features = platform.Spec.Features[:2] // slim + one agentruntime
	platform.Spec.CPUSchedulingSpec = cpuScheduler("cpu")

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(platform).
		WithStatusSubresource(&aiApi.AIPlatform{}, &aiApi.AIService{}).
		WithIndex(&aiApi.AIService{}, ownerKey, func(obj client.Object) []string {
			if o := metav1.GetControllerOfNoCopy(obj); o != nil {
				return []string{o.Name}
			}
			return nil
		}).Build()
	r := New(platform.DeepCopy(), c, scheme, record.NewFakeRecorder(50))
	ctx := context.Background()

	reconcileOnce := func() {
		var live aiApi.AIPlatform
		require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(platform), &live))
		_, err := r.Reconcile(ctx, &live)
		require.NoError(t, err)
	}
	children := func() map[string]aiApi.AIService {
		var l aiApi.AIServiceList
		require.NoError(t, c.List(ctx, &l, client.InNamespace("ns1")))
		out := map[string]aiApi.AIService{}
		for _, s := range l.Items {
			out[s.Name] = s
		}
		return out
	}

	reconcileOnce()
	got := children()
	require.Len(t, got, 2)
	for name, s := range got {
		assert.Equal(t, "cpu", s.Spec.NodeSelector["splunk.ai/workload-type"], name)
	}

	// An administrator raises the runtime's memory limit directly on its AIService.
	var rt aiApi.AIService
	require.NoError(t, c.Get(ctx, client.ObjectKey{Namespace: "ns1", Name: "lp-agentruntime-launchpad"}, &rt))
	rt.Spec.Resources.Limits[corev1.ResourceMemory] = resource.MustParse("4Gi")
	require.NoError(t, c.Update(ctx, &rt))

	// Nothing about the platform changed: the reconcile must leave both untouched.
	before := children()
	reconcileOnce()
	for name, s := range children() {
		assert.Equal(t, before[name].ResourceVersion, s.ResourceVersion, "an unchanged reconcile rewrote %s", name)
	}

	// The placement changes: it reaches both children, the user's limit survives.
	var live aiApi.AIPlatform
	require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(platform), &live))
	live.Spec.CPUSchedulingSpec = cpuScheduler("cpu-large")
	require.NoError(t, c.Update(ctx, &live))
	r = New(live.DeepCopy(), c, scheme, record.NewFakeRecorder(50))
	reconcileOnce()
	after := children()
	for name, s := range after {
		assert.Equal(t, "cpu-large", s.Spec.NodeSelector["splunk.ai/workload-type"], name)
	}
	mem := after["lp-agentruntime-launchpad"].Spec.Resources.Limits[corev1.ResourceMemory]
	assert.Equal(t, "4Gi", mem.String(), "the administrator's limit must survive a placement change")

	// And the new state is stable.
	steady := children()
	reconcileOnce()
	for name, s := range children() {
		assert.Equal(t, steady[name].ResourceVersion, s.ResourceVersion, "the second reconcile of the new placement rewrote %s", name)
	}
}
