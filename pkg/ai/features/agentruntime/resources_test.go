package agentruntime

import (
	"context"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func str(l corev1.ResourceList, name corev1.ResourceName) string {
	q := l[name]
	return q.String()
}

func quantities(kv map[corev1.ResourceName]string) corev1.ResourceList {
	out := corev1.ResourceList{}
	for k, v := range kv {
		out[k] = resource.MustParse(v)
	}
	return out
}

// The default budget is part of the contract: three explicit entries each for
// requests and limits, CPU nodes only, no accelerator.
func TestDefaultResources_ArePinnedAndGPUFree(t *testing.T) {
	d := DefaultResources()
	want := corev1.ResourceRequirements{
		Requests: quantities(map[corev1.ResourceName]string{"cpu": "500m", "memory": "512Mi", "ephemeral-storage": "1Gi"}),
		Limits:   quantities(map[corev1.ResourceName]string{"cpu": "1", "memory": "1Gi", "ephemeral-storage": "2Gi"}),
	}
	assert.Equal(t, want, d)
	for name := range d.Requests {
		assert.False(t, aiv1.IsGPUResource(name))
	}
	for name := range d.Limits {
		assert.False(t, aiv1.IsGPUResource(name))
	}
	assert.Empty(t, aiv1.ValidateWorkloadResources(nil, d, true, true), "the defaults satisfy the rules they are checked against")

	// Callers get their own copy: changing one must not change the next.
	d.Requests[corev1.ResourceCPU] = resource.MustParse("64")
	assert.Equal(t, "500m", str(DefaultResources().Requests, corev1.ResourceCPU))
}

func TestCompleteResourceBudgets(t *testing.T) {
	cpu, mem, eph := corev1.ResourceCPU, corev1.ResourceMemory, corev1.ResourceEphemeralStorage
	d := DefaultResources()

	t.Run("nothing set gives exactly the defaults (existing behaviour)", func(t *testing.T) {
		var r corev1.ResourceRequirements
		completeResourceBudgets(&r)
		assert.Equal(t, DefaultResources(), r)
	})

	t.Run("requests set, limits unset: requests untouched, limits are the defaults (existing behaviour)", func(t *testing.T) {
		r := corev1.ResourceRequirements{Requests: quantities(map[corev1.ResourceName]string{cpu: "250m"})}
		completeResourceBudgets(&r)
		assert.Equal(t, quantities(map[corev1.ResourceName]string{cpu: "250m"}), r.Requests, "no request is invented")
		assert.Equal(t, d.Limits, r.Limits)
	})

	t.Run("a missing limit is never below the request for that resource", func(t *testing.T) {
		// requests.cpu: 2 with no limit used to be rejected by the API server
		// (2 > the defaulted 1); the limit is now raised to the request.
		r := corev1.ResourceRequirements{Requests: quantities(map[corev1.ResourceName]string{cpu: "2"})}
		completeResourceBudgets(&r)
		assert.Equal(t, "2", str(r.Limits, cpu))
		assert.Equal(t, str(d.Limits, mem), str(r.Limits, mem))
		assert.Empty(t, aiv1.ValidateWorkloadResources(nil, r, true, true))
	})

	t.Run("partial limits: the missing ones are added, user values and requests are kept", func(t *testing.T) {
		r := corev1.ResourceRequirements{Limits: quantities(map[corev1.ResourceName]string{mem: "4Gi"})}
		completeResourceBudgets(&r)
		assert.Equal(t, d.Requests, r.Requests, "requests unset: defaulted as before")
		assert.Equal(t, "4Gi", str(r.Limits, mem), "user limit kept")
		assert.Equal(t, str(d.Limits, cpu), str(r.Limits, cpu))
		assert.Equal(t, str(d.Limits, eph), str(r.Limits, eph))
	})

	t.Run("partial limits with a request above the default limit (finding: used to work)", func(t *testing.T) {
		r := corev1.ResourceRequirements{
			Requests: quantities(map[corev1.ResourceName]string{cpu: "2"}),
			Limits:   quantities(map[corev1.ResourceName]string{mem: "4Gi"}),
		}
		completeResourceBudgets(&r)
		assert.Equal(t, "2", str(r.Limits, cpu), "no inverted request/limit is created")
		assert.Empty(t, aiv1.ValidateWorkloadResources(nil, r, true, true))
	})

	t.Run("an empty requests map is the user's choice and is left alone", func(t *testing.T) {
		r := corev1.ResourceRequirements{Requests: corev1.ResourceList{}, Limits: corev1.ResourceList{}}
		completeResourceBudgets(&r)
		assert.Empty(t, r.Requests)
		assert.Equal(t, d.Limits, r.Limits)
	})

	t.Run("other resources are left alone", func(t *testing.T) {
		r := corev1.ResourceRequirements{Requests: quantities(map[corev1.ResourceName]string{"hugepages-2Mi": "64Mi"})}
		completeResourceBudgets(&r)
		assert.Equal(t, "64Mi", str(r.Requests, "hugepages-2Mi"))
		assert.NotContains(t, r.Limits, corev1.ResourceName("hugepages-2Mi"))
	})

	t.Run("completing twice changes nothing", func(t *testing.T) {
		r := corev1.ResourceRequirements{Requests: quantities(map[corev1.ResourceName]string{cpu: "2"})}
		completeResourceBudgets(&r)
		once := r.DeepCopy()
		completeResourceBudgets(&r)
		assert.Equal(t, once, &r)
	})

	t.Run("the shared defaults are never aliased", func(t *testing.T) {
		var r corev1.ResourceRequirements
		completeResourceBudgets(&r)
		r.Requests[cpu] = resource.MustParse("64")
		assert.Equal(t, "500m", str(DefaultResources().Requests, cpu))
	})
}

func TestValidateAIService_ResourceRules(t *testing.T) {
	profileTestEnv(t)
	cases := []struct {
		name string
		res  corev1.ResourceRequirements
		want string // "" = accepted
	}{
		{"nothing set: defaults apply", corev1.ResourceRequirements{}, ""},
		{"cpu request only: limits are completed", corev1.ResourceRequirements{Requests: quantities(map[corev1.ResourceName]string{"cpu": "250m"})}, ""},
		{"request above the default limit: the limit follows it", corev1.ResourceRequirements{Requests: quantities(map[corev1.ResourceName]string{"cpu": "2"})}, ""},
		{"partial limits with a larger request keep working",
			corev1.ResourceRequirements{
				Requests: quantities(map[corev1.ResourceName]string{"cpu": "2"}),
				Limits:   quantities(map[corev1.ResourceName]string{"memory": "4Gi"})}, ""},
		{"a GPU limit is refused on CPU nodes", corev1.ResourceRequirements{Limits: quantities(map[corev1.ResourceName]string{"nvidia.com/gpu": "1"})},
			"spec.resources.limits[nvidia.com/gpu]: Forbidden"},
		{"a request above an explicit limit is reported with the field",
			corev1.ResourceRequirements{
				Requests: quantities(map[corev1.ResourceName]string{"cpu": "2"}),
				Limits:   quantities(map[corev1.ResourceName]string{"cpu": "1"})},
			"spec.resources.requests[cpu]: Invalid value: \"2\": must not exceed limits.cpu (1)"},
		{"a zero budget is refused", corev1.ResourceRequirements{Limits: quantities(map[corev1.ResourceName]string{"memory": "0"})},
			"spec.resources.limits[memory]: Invalid value: \"0\": must be greater than zero"},
	}
	for _, profile := range []aiv1.AIPlatformProfile{aiv1.AIPlatformProfileCPUOnly, aiv1.AIPlatformProfileFullFeature} {
		for _, c := range cases {
			scheme := buildAgentRuntimeTestScheme(t)
			ai := profileAIService()
			ai.Spec.Resources = c.res
			if profile != aiv1.AIPlatformProfileCPUOnly {
				ai.Spec.AIPlatformUrl = "http://ray.default.svc:8000" // fullfeature waits for Ray otherwise
			}
			platform := platformWith(profile, profile != aiv1.AIPlatformProfileCPUOnly)
			rec := record.NewFakeRecorder(10)
			r := &AgentRuntimeReconciler{Client: fake.NewClientBuilder().WithScheme(scheme).WithObjects(platform).Build(), Scheme: scheme, Recorder: rec}
			err := r.validateAIService(context.Background(), ai)
			if c.want == "" {
				require.NoError(t, err, "%s / %s", profile, c.name)
				// Every container carries an explicit cpu, memory and ephemeral-storage
				// limit afterwards, and never a request above it.
				for _, n := range []corev1.ResourceName{"cpu", "memory", "ephemeral-storage"} {
					assert.Contains(t, ai.Spec.Resources.Limits, n, "%s / %s", profile, c.name)
				}
				assert.Empty(t, aiv1.ValidateWorkloadResources(nil, ai.Spec.Resources, true, true), "%s / %s", profile, c.name)
				continue
			}
			require.Error(t, err, "%s / %s", profile, c.name)
			assert.Contains(t, err.Error(), c.want, "%s / %s", profile, c.name)
			select {
			case ev := <-rec.Events:
				assert.Contains(t, ev, "InvalidSpec", "the user sees it as an event too")
			default:
				t.Errorf("%s / %s: no event recorded", profile, c.name)
			}
		}
	}
}

// What the Deployment really carries, for each profile: the CPU budget, the CPU
// placement, and nothing GPU.
func TestRenderedDeployment_BudgetAndPlacementAreIdenticalForBothProfiles(t *testing.T) {
	profileTestEnv(t)
	selector := map[string]string{"splunk.ai/workload-type": "cpu"}
	tolerations := []corev1.Toleration{{Key: "dedicated", Operator: corev1.TolerationOpEqual, Value: "cpu", Effect: corev1.TaintEffectNoSchedule}}

	render := func(t *testing.T, profile aiv1.AIPlatformProfile) *appsv1.Deployment {
		t.Helper()
		scheme := buildAgentRuntimeTestScheme(t)
		ai := profileAIService()
		ai.Spec.NodeSelector = selector
		ai.Spec.Tolerations = tolerations
		if profile != aiv1.AIPlatformProfileCPUOnly {
			ai.Spec.AIPlatformUrl = "http://ray.default.svc:8000"
		}
		platform := platformWith(profile, profile != aiv1.AIPlatformProfileCPUOnly)
		c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(platform, ai).Build()
		r := &AgentRuntimeReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}
		require.NoError(t, r.validateAIService(context.Background(), ai))
		require.NoError(t, r.reconcileDeployment(context.Background(), ai))
		d := &appsv1.Deployment{}
		require.NoError(t, c.Get(context.Background(), types.NamespacedName{Name: ai.Name + "-agentruntime-deployment", Namespace: ai.Namespace}, d))
		return d
	}

	cpuOnly := render(t, aiv1.AIPlatformProfileCPUOnly)
	full := render(t, aiv1.AIPlatformProfileFullFeature)
	for name, d := range map[string]*appsv1.Deployment{"cpuOnly": cpuOnly, "fullfeature": full} {
		spec := d.Spec.Template.Spec
		require.Len(t, spec.Containers, 1, name)
		res := spec.Containers[0].Resources
		assert.Equal(t, DefaultResources(), res, "%s: explicit CPU, memory and ephemeral-storage budgets", name)
		assert.Equal(t, selector, spec.NodeSelector, name)
		assert.Equal(t, tolerations, spec.Tolerations, name)
		for _, c := range append(append([]corev1.Container{}, spec.InitContainers...), spec.Containers...) {
			for rn := range c.Resources.Requests {
				assert.False(t, aiv1.IsGPUResource(rn), "%s: container %s requests %s", name, c.Name, rn)
			}
			for rn := range c.Resources.Limits {
				assert.False(t, aiv1.IsGPUResource(rn), "%s: container %s limits %s", name, c.Name, rn)
			}
		}
		for _, tol := range spec.Tolerations {
			assert.NotEqual(t, aiv1.GPUTaintKey, tol.Key, "%s: no GPU-only toleration", name)
		}
	}
	// The budget and placement do not depend on the profile.
	assert.Equal(t, full.Spec.Template.Spec.Containers[0].Resources, cpuOnly.Spec.Template.Spec.Containers[0].Resources)
	assert.Equal(t, full.Spec.Template.Spec.NodeSelector, cpuOnly.Spec.Template.Spec.NodeSelector)
}

// Reconciling the same input twice produces the same Deployment: the second pass
// writes nothing, so a settled platform generates no churn and no rollout.
func TestRenderedDeployment_SecondReconcileWritesNothing(t *testing.T) {
	profileTestEnv(t)
	for _, profile := range []aiv1.AIPlatformProfile{aiv1.AIPlatformProfileCPUOnly, aiv1.AIPlatformProfileFullFeature} {
		scheme := buildAgentRuntimeTestScheme(t)
		ai := profileAIService()
		ai.Spec.NodeSelector = map[string]string{"splunk.ai/workload-type": "cpu"}
		ai.Spec.Resources = corev1.ResourceRequirements{Requests: quantities(map[corev1.ResourceName]string{"cpu": "250m"})} // completed on first pass
		if profile != aiv1.AIPlatformProfileCPUOnly {
			ai.Spec.AIPlatformUrl = "http://ray.default.svc:8000"
		}
		c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(platformWith(profile, profile != aiv1.AIPlatformProfileCPUOnly), ai).Build()
		r := &AgentRuntimeReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(20)}
		key := types.NamespacedName{Name: ai.Name + "-agentruntime-deployment", Namespace: ai.Namespace}

		pass := func() *appsv1.Deployment {
			// Each pass starts from the stored AIService, as a real reconcile does.
			live := &aiv1.AIService{}
			require.NoError(t, c.Get(context.Background(), types.NamespacedName{Name: ai.Name, Namespace: ai.Namespace}, live))
			require.NoError(t, r.validateAIService(context.Background(), live))
			require.NoError(t, r.reconcileDeployment(context.Background(), live))
			d := &appsv1.Deployment{}
			require.NoError(t, c.Get(context.Background(), key, d))
			return d
		}
		first := pass()
		second := pass()
		assert.Equal(t, first.ResourceVersion, second.ResourceVersion, "%s: the second reconcile rewrote the Deployment", profile)
		assert.Equal(t, first.Spec.Template.Spec, second.Spec.Template.Spec, profile)
	}
}
