package v1

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
)

func gpuNodeSched() *aiv1.SchedulingSpec {
	return &aiv1.SchedulingSpec{NodeSelector: map[string]string{aiv1.WorkloadTypeLabel: aiv1.WorkloadTypeGPU}}
}

// An explicit fullfeature must identify its GPU capacity when it is created, and
// the error names the field.
func TestAIPlatformWebhook_FullFeatureCreateRequiresGPUCapacity(t *testing.T) {
	v := &AIPlatformCustomValidator{}
	_, err := v.ValidateCreate(context.Background(), profilePlatform(aiv1.AIPlatformProfileFullFeature))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "spec.gpuScheduler: Required value")

	p := profilePlatform(aiv1.AIPlatformProfileFullFeature)
	p.Spec.GPUSchedulingSpec = gpuNodeSched()
	_, err = v.ValidateCreate(context.Background(), p)
	assert.NoError(t, err)

	// A CPU scheduler that tolerates the GPU taint puts the runtime on GPU nodes.
	p.Spec.CPUSchedulingSpec = &aiv1.SchedulingSpec{Tolerations: []corev1.Toleration{{Key: aiv1.GPUTaintKey, Operator: corev1.TolerationOpExists}}}
	_, err = v.ValidateCreate(context.Background(), p)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "spec.cpuScheduler: Forbidden")
}

// Codex review finding: two schedulers that share a broad selector are not in
// conflict when required affinity or a taint separates their nodes, so creating
// such a platform must work. Only fully identical placement is refused.
func TestAIPlatformWebhook_FullFeatureSharedSelectorIsFineUnlessPlacementIsIdentical(t *testing.T) {
	v := &AIPlatformCustomValidator{}
	linux := func() map[string]string { return map[string]string{"kubernetes.io/os": "linux"} }
	affinityFor := func(pool string) *corev1.Affinity {
		return &corev1.Affinity{NodeAffinity: &corev1.NodeAffinity{RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{
			NodeSelectorTerms: []corev1.NodeSelectorTerm{{MatchExpressions: []corev1.NodeSelectorRequirement{
				{Key: "pool", Operator: corev1.NodeSelectorOpIn, Values: []string{pool}}}}}}}}
	}
	create := func(cpu, gpu *aiv1.SchedulingSpec) error {
		p := profilePlatform(aiv1.AIPlatformProfileFullFeature)
		p.Spec.CPUSchedulingSpec, p.Spec.GPUSchedulingSpec = cpu, gpu
		_, err := v.ValidateCreate(context.Background(), p)
		return err
	}

	assert.NoError(t, create(
		&aiv1.SchedulingSpec{NodeSelector: linux(), Affinity: affinityFor("cpu")},
		&aiv1.SchedulingSpec{NodeSelector: linux(), Affinity: affinityFor("gpu")}),
		"required affinity separates the pools")
	assert.NoError(t, create(
		&aiv1.SchedulingSpec{NodeSelector: linux()},
		&aiv1.SchedulingSpec{NodeSelector: linux(), Tolerations: []corev1.Toleration{{Key: aiv1.GPUTaintKey, Operator: corev1.TolerationOpExists}}}),
		"only the GPU scheduler tolerates the GPU taint")

	err := create(&aiv1.SchedulingSpec{NodeSelector: linux()}, &aiv1.SchedulingSpec{NodeSelector: linux()})
	require.Error(t, err, "truly identical placement is still refused")
	assert.Contains(t, err.Error(), "identical to cpuScheduler")
}

// The same problems never block an update: an existing platform stays editable
// (the operator's own finalizer and metadata writes go through this webhook),
// and the user is told instead.
func TestAIPlatformWebhook_FullFeatureUpdateOnlyWarns(t *testing.T) {
	v := &AIPlatformCustomValidator{}
	old := profilePlatform(aiv1.AIPlatformProfileFullFeature)
	updated := profilePlatform(aiv1.AIPlatformProfileFullFeature)
	warnings, err := v.ValidateUpdate(context.Background(), old, updated)
	require.NoError(t, err)
	require.Len(t, warnings, 1)
	assert.Contains(t, warnings[0], "spec.gpuScheduler: Required value")

	// A platform that meets the rules gets no warning.
	updated.Spec.GPUSchedulingSpec = gpuNodeSched()
	old.Spec.GPUSchedulingSpec = gpuNodeSched()
	warnings, err = v.ValidateUpdate(context.Background(), old, updated)
	require.NoError(t, err)
	assert.Empty(t, warnings)
}

// An omitted profile and legacy "full" are the same profile as fullfeature but
// are never checked, on create or update, so existing platforms keep working;
// and relabelling one as fullfeature is an update, so it is not refused.
func TestAIPlatformWebhook_LegacyProfilesKeepTheirLeniency(t *testing.T) {
	v := &AIPlatformCustomValidator{}
	for _, profile := range []aiv1.AIPlatformProfile{"", aiv1.AIPlatformProfileLegacyFull} {
		p := profilePlatform(profile)
		p.Spec.CPUSchedulingSpec = &aiv1.SchedulingSpec{Tolerations: []corev1.Toleration{{Key: aiv1.GPUTaintKey, Operator: corev1.TolerationOpExists}}}
		warnings, err := v.ValidateCreate(context.Background(), p)
		assert.NoError(t, err, "profile %q", profile)
		assert.Empty(t, warnings)
		warnings, err = v.ValidateUpdate(context.Background(), p, p)
		assert.NoError(t, err, "profile %q", profile)
		assert.Empty(t, warnings)

		relabelled := p.DeepCopy()
		relabelled.Spec.Profile = aiv1.AIPlatformProfileFullFeature
		_, err = v.ValidateUpdate(context.Background(), p, relabelled)
		assert.NoError(t, err, "relabelling %q as fullfeature must stay an update, not a rejection", profile)
	}
}

// cpuOnly is rejected at creation, but an existing cpuOnly platform whose CPU
// scheduler selects GPU nodes (made before this rule) stays editable: the update
// gets a warning, not a denial.
func TestAIPlatformWebhook_CPUOnlyGPUSchedulerIsAnErrorOnCreateAndAWarningOnUpdate(t *testing.T) {
	v := &AIPlatformCustomValidator{}
	p := profilePlatform(aiv1.AIPlatformProfileCPUOnly)
	p.Spec.CPUSchedulingSpec = gpuNodeSched()
	_, err := v.ValidateCreate(context.Background(), p)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "spec.cpuScheduler: Forbidden: profile cpuOnly places every workload on CPU nodes")

	warnings, err := v.ValidateUpdate(context.Background(), p, p)
	require.NoError(t, err, "an existing platform must stay editable")
	require.Len(t, warnings, 1)
	assert.Contains(t, warnings[0], "spec.cpuScheduler: Forbidden")

	p.Spec.CPUSchedulingSpec = &aiv1.SchedulingSpec{NodeSelector: map[string]string{aiv1.WorkloadTypeLabel: "cpu"}}
	_, err = v.ValidateCreate(context.Background(), p)
	assert.NoError(t, err)
}

// An object that is being deleted is never refused: removing the finalizer is an
// update, and a denial would leave the object stuck in Terminating whatever its
// spec says.
func TestWebhooks_NeverBlockAnObjectBeingDeleted(t *testing.T) {
	now := metav1.Now()

	pv := &AIPlatformCustomValidator{}
	broken := profilePlatform(aiv1.AIPlatformProfileCPUOnly)
	broken.Spec.DefaultAcceleratorType = "L40S" // contradicts cpuOnly: refused on create
	_, err := pv.ValidateCreate(context.Background(), broken)
	require.Error(t, err)
	_, err = pv.ValidateUpdate(context.Background(), broken, broken)
	require.Error(t, err, "while alive, the contradiction is still refused on update")
	broken.DeletionTimestamp = &now
	warnings, err := pv.ValidateUpdate(context.Background(), broken, broken)
	assert.NoError(t, err, "a platform being deleted must be allowed to drop its finalizer")
	assert.Empty(t, warnings)

	sv := aiServiceValidator(t, aiv1.AIPlatformProfileFullFeature, true)
	bad := serviceWithResources("agentruntime", corev1.ResourceRequirements{Limits: list(map[corev1.ResourceName]string{"nvidia.com/gpu": "1"})})
	_, err = sv.ValidateUpdate(context.Background(), bad, bad)
	require.Error(t, err)
	bad.DeletionTimestamp = &now
	_, err = sv.ValidateUpdate(context.Background(), bad, bad)
	assert.NoError(t, err, "a service being deleted must be allowed to drop its finalizer")
}

func serviceWithResources(feature string, res corev1.ResourceRequirements) *aiv1.AIService {
	s := serviceForPlatform("v")
	s.Spec.Feature = aiv1.FeatureSpec{Name: feature}
	if feature == "agentruntime" {
		s.Spec.Feature.Provider = "mltk"
		s.Spec.CheckpointDbSecretRef = "checkpoint-db"
	}
	s.Spec.Resources = res
	return s
}

func list(kv map[corev1.ResourceName]string) corev1.ResourceList {
	out := corev1.ResourceList{}
	for k, v := range kv {
		out[k] = resource.MustParse(v)
	}
	return out
}

func TestAIServiceWebhook_WorkloadResources(t *testing.T) {
	v := aiServiceValidator(t, aiv1.AIPlatformProfileFullFeature, true)
	cases := []struct {
		name    string
		feature string
		res     corev1.ResourceRequirements
		want    string // substring of the error, "" for accepted
	}{
		{"agentruntime defaults-sized budget", "agentruntime", corev1.ResourceRequirements{
			Requests: list(map[corev1.ResourceName]string{"cpu": "500m", "memory": "512Mi", "ephemeral-storage": "1Gi"}),
			Limits:   list(map[corev1.ResourceName]string{"cpu": "1", "memory": "1Gi", "ephemeral-storage": "2Gi"})}, ""},
		{"agentruntime with nothing set", "agentruntime", corev1.ResourceRequirements{}, ""},
		{"agentruntime GPU request", "agentruntime", corev1.ResourceRequirements{Limits: list(map[corev1.ResourceName]string{"nvidia.com/gpu": "1"})},
			"spec.resources.limits[nvidia.com/gpu]: Forbidden"},
		{"agentruntime inverted", "agentruntime", corev1.ResourceRequirements{
			Requests: list(map[corev1.ResourceName]string{"memory": "2Gi"}), Limits: list(map[corev1.ResourceName]string{"memory": "1Gi"})},
			"spec.resources.requests[memory]: Invalid value"},
		{"agentruntime zero budget", "agentruntime", corev1.ResourceRequirements{Limits: list(map[corev1.ResourceName]string{"cpu": "0"})},
			"must be greater than zero"},
		{"slim zero cpu is not a budget rule", "slim", corev1.ResourceRequirements{Requests: list(map[corev1.ResourceName]string{"cpu": "0"})}, ""},
		{"slim negative", "slim", corev1.ResourceRequirements{Requests: list(map[corev1.ResourceName]string{"cpu": "-1"})}, "must not be negative"},
		{"saia keeps its own resource ownership: GPU key untouched", "saia", corev1.ResourceRequirements{Limits: list(map[corev1.ResourceName]string{"nvidia.com/gpu": "1"})}, ""},
		{"saia inverted is still wrong", "saia", corev1.ResourceRequirements{
			Requests: list(map[corev1.ResourceName]string{"cpu": "4"}), Limits: list(map[corev1.ResourceName]string{"cpu": "2"})},
			"must not exceed limits.cpu"},
	}
	for _, c := range cases {
		_, err := v.ValidateCreate(context.Background(), serviceWithResources(c.feature, c.res))
		if c.want == "" {
			assert.NoError(t, err, c.name)
			continue
		}
		require.Error(t, err, c.name)
		assert.Contains(t, err.Error(), c.want, c.name)
	}

	t.Run("SLIM refuses an accelerator only under a cpuOnly platform", func(t *testing.T) {
		gpu := corev1.ResourceRequirements{Requests: list(map[corev1.ResourceName]string{"nvidia.com/gpu": "1"})}
		for _, profile := range []aiv1.AIPlatformProfile{"", aiv1.AIPlatformProfileLegacyFull, aiv1.AIPlatformProfileFullFeature} {
			_, err := aiServiceValidator(t, profile, true).ValidateCreate(context.Background(), serviceWithResources("slim", gpu))
			assert.NoError(t, err, "platform profile %q: an existing component's resources are not second-guessed", profile)
		}
		_, err := aiServiceValidator(t, aiv1.AIPlatformProfileCPUOnly, true).ValidateCreate(context.Background(), serviceWithResources("slim", gpu))
		require.Error(t, err)
		assert.Contains(t, err.Error(), "spec.resources.requests[nvidia.com/gpu]: Forbidden")
	})

	t.Run("v2 and worker budgets are checked for inversion", func(t *testing.T) {
		s := serviceWithResources("saia", corev1.ResourceRequirements{})
		s.Spec.V2.Resources = corev1.ResourceRequirements{Requests: list(map[corev1.ResourceName]string{"cpu": "4"}), Limits: list(map[corev1.ResourceName]string{"cpu": "2"})}
		s.Spec.V2Worker.Resources = corev1.ResourceRequirements{Requests: list(map[corev1.ResourceName]string{"memory": "-1"})}
		_, err := v.ValidateCreate(context.Background(), s)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "spec.v2.resources.requests[cpu]")
		assert.Contains(t, err.Error(), "spec.v2Worker.resources.requests[memory]")
	})

	t.Run("update runs the same checks", func(t *testing.T) {
		old := serviceWithResources("agentruntime", corev1.ResourceRequirements{})
		bad := serviceWithResources("agentruntime", corev1.ResourceRequirements{Limits: list(map[corev1.ResourceName]string{"nvidia.com/gpu": "1"})})
		_, err := v.ValidateUpdate(context.Background(), old, bad)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "Forbidden")
	})
}
