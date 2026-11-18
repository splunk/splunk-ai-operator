package v1

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

var specPath = field.NewPath("spec")

func q(s string) resource.Quantity { return resource.MustParse(s) }

func rr(requests, limits map[corev1.ResourceName]string) corev1.ResourceRequirements {
	out := corev1.ResourceRequirements{}
	if requests != nil {
		out.Requests = corev1.ResourceList{}
		for k, v := range requests {
			out.Requests[k] = q(v)
		}
	}
	if limits != nil {
		out.Limits = corev1.ResourceList{}
		for k, v := range limits {
			out.Limits[k] = q(v)
		}
	}
	return out
}

func TestIsGPUResource(t *testing.T) {
	for _, name := range []corev1.ResourceName{"nvidia.com/gpu", "nvidia.com/mig-1g.5gb", "amd.com/gpu", "gpu.intel.com/i915"} {
		assert.True(t, IsGPUResource(name), string(name))
	}
	for _, name := range []corev1.ResourceName{"cpu", "memory", "ephemeral-storage", "hugepages-2Mi", "example.com/widget"} {
		assert.False(t, IsGPUResource(name), string(name))
	}
}

func TestValidateWorkloadResources(t *testing.T) {
	cpu, mem, eph := corev1.ResourceCPU, corev1.ResourceMemory, corev1.ResourceEphemeralStorage
	path := specPath.Child("resources")
	cases := []struct {
		name           string
		res            corev1.ResourceRequirements
		budgets, noGPU bool
		want           []string // substrings, one per expected error, in order
	}{
		{"empty is fine", corev1.ResourceRequirements{}, true, true, nil},
		{"valid budget", rr(map[corev1.ResourceName]string{cpu: "500m", mem: "512Mi", eph: "1Gi"}, map[corev1.ResourceName]string{cpu: "1", mem: "1Gi", eph: "2Gi"}), true, true, nil},
		{"request equals limit", rr(map[corev1.ResourceName]string{cpu: "1"}, map[corev1.ResourceName]string{cpu: "1"}), true, true, nil},
		{"negative request", rr(map[corev1.ResourceName]string{cpu: "-1"}, nil), false, false,
			[]string{"spec.resources.requests[cpu]: Invalid value: \"-1\": must not be negative"}},
		{"negative limit", rr(nil, map[corev1.ResourceName]string{mem: "-1Gi"}), false, false,
			[]string{"spec.resources.limits[memory]: Invalid value: \"-1Gi\": must not be negative"}},
		{"zero cpu with budgets", rr(map[corev1.ResourceName]string{cpu: "0"}, nil), true, false,
			[]string{"spec.resources.requests[cpu]: Invalid value: \"0\": must be greater than zero"}},
		{"zero cpu without budgets is allowed", rr(map[corev1.ResourceName]string{cpu: "0"}, nil), false, false, nil},
		{"zero extended resource is not a budget", rr(map[corev1.ResourceName]string{"example.com/widget": "0"}, nil), true, false, nil},
		{"inverted cpu", rr(map[corev1.ResourceName]string{cpu: "2"}, map[corev1.ResourceName]string{cpu: "1"}), true, true,
			[]string{"spec.resources.requests[cpu]: Invalid value: \"2\": must not exceed limits.cpu (1)"}},
		{"inverted memory units", rr(map[corev1.ResourceName]string{mem: "2Gi"}, map[corev1.ResourceName]string{mem: "1024Mi"}), false, false,
			[]string{"must not exceed limits.memory (1Gi)"}},
		{"request without limit is not compared", rr(map[corev1.ResourceName]string{cpu: "8"}, nil), true, true, nil},
		{"gpu request forbidden", rr(map[corev1.ResourceName]string{"nvidia.com/gpu": "1"}, nil), true, true,
			[]string{"spec.resources.requests[nvidia.com/gpu]: Forbidden: this workload runs on CPU nodes and must not request nvidia.com/gpu"}},
		{"gpu limit forbidden even when zero", rr(nil, map[corev1.ResourceName]string{"nvidia.com/gpu": "0"}), false, true,
			[]string{"spec.resources.limits[nvidia.com/gpu]: Forbidden"}},
		{"gpu allowed when not forbidden", rr(map[corev1.ResourceName]string{"nvidia.com/gpu": "1"}, map[corev1.ResourceName]string{"nvidia.com/gpu": "1"}), false, false, nil},
		{"errors are reported together and in a stable order",
			rr(map[corev1.ResourceName]string{mem: "-1", cpu: "4", "nvidia.com/gpu": "1"}, map[corev1.ResourceName]string{cpu: "1"}), true, true,
			[]string{"requests[cpu]: Invalid", "requests[memory]: Invalid", "requests[nvidia.com/gpu]: Forbidden"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// A stable order matters: the same input must give the same message.
			first := ValidateWorkloadResources(path, c.res, c.budgets, c.noGPU)
			second := ValidateWorkloadResources(path, c.res, c.budgets, c.noGPU)
			assert.Equal(t, first, second)
			if len(c.want) == 0 {
				assert.Empty(t, first)
				return
			}
			var got []string
			for _, e := range first {
				got = append(got, e.Error())
			}
			// Order-insensitive across the three groups but each expectation must appear once.
			require.Len(t, got, len(c.want), "%v", got)
			for _, w := range c.want {
				found := false
				for _, g := range got {
					if strings.Contains(g, w) {
						found = true
					}
				}
				assert.True(t, found, "missing %q in %v", w, got)
			}
		})
	}
}

func gpuSched() *SchedulingSpec {
	return &SchedulingSpec{
		NodeSelector: map[string]string{WorkloadTypeLabel: WorkloadTypeGPU},
		Tolerations:  []corev1.Toleration{{Key: GPUTaintKey, Operator: corev1.TolerationOpEqual, Value: "true", Effect: corev1.TaintEffectNoSchedule}},
	}
}

func cpuSched() *SchedulingSpec {
	return &SchedulingSpec{NodeSelector: map[string]string{WorkloadTypeLabel: "cpu"}}
}

func nodeAffinity(key string, values ...string) *corev1.Affinity {
	return nodeAffinityOp(key, corev1.NodeSelectorOpIn, values...)
}

func nodeAffinityOp(key string, op corev1.NodeSelectorOperator, values ...string) *corev1.Affinity {
	return &corev1.Affinity{NodeAffinity: &corev1.NodeAffinity{
		RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{NodeSelectorTerms: []corev1.NodeSelectorTerm{{
			MatchExpressions: []corev1.NodeSelectorRequirement{{Key: key, Operator: op, Values: values}},
		}}},
	}}
}

func TestSelectsGPU(t *testing.T) {
	cases := []struct {
		name string
		s    *SchedulingSpec
		want bool
	}{
		{"nil", nil, false},
		{"empty", &SchedulingSpec{}, false},
		{"cpu selector", cpuSched(), false},
		{"gpu workload-type selector", &SchedulingSpec{NodeSelector: map[string]string{WorkloadTypeLabel: "gpu"}}, true},
		{"gpu label selector", &SchedulingSpec{NodeSelector: map[string]string{"nvidia.com/gpu": "true"}}, true},
		{"gpu toleration", &SchedulingSpec{Tolerations: []corev1.Toleration{{Key: GPUTaintKey, Operator: corev1.TolerationOpExists}}}, true},
		{"unrelated toleration", &SchedulingSpec{Tolerations: []corev1.Toleration{{Key: "dedicated", Operator: corev1.TolerationOpExists}}}, false},
		{"gpu node affinity by label key", &SchedulingSpec{Affinity: nodeAffinity("nvidia.com/gpu", "true")}, true},
		{"gpu node affinity by workload-type value", &SchedulingSpec{Affinity: nodeAffinity(WorkloadTypeLabel, "cpu", "gpu")}, true},
		{"cpu node affinity", &SchedulingSpec{Affinity: nodeAffinity(WorkloadTypeLabel, "cpu")}, false},
		{"NotIn gpu keeps a workload OFF gpu nodes, so it is not a selection", &SchedulingSpec{Affinity: nodeAffinityOp(WorkloadTypeLabel, corev1.NodeSelectorOpNotIn, "gpu")}, false},
		{"DoesNotExist on the gpu label keeps a workload off gpu nodes", &SchedulingSpec{Affinity: nodeAffinityOp("nvidia.com/gpu", corev1.NodeSelectorOpDoesNotExist)}, false},
		{"Exists on the gpu label is a selection", &SchedulingSpec{Affinity: nodeAffinityOp("nvidia.com/gpu", corev1.NodeSelectorOpExists)}, true},
		{"In on a gpu feature-discovery label is a selection", &SchedulingSpec{Affinity: nodeAffinityOp("nvidia.com/gpu.present", corev1.NodeSelectorOpIn, "true")}, true},
		{"any nvidia.com label in a nodeSelector pins to gpu nodes", &SchedulingSpec{NodeSelector: map[string]string{"nvidia.com/gpu.present": "true"}}, true},
		{"a toleration of everything is not GPU-specific", &SchedulingSpec{Tolerations: []corev1.Toleration{{Operator: corev1.TolerationOpExists}}}, false},
		{"affinity without node affinity", &SchedulingSpec{Affinity: &corev1.Affinity{}}, false},
	}
	for _, c := range cases {
		got, why := selectsGPU(c.s)
		assert.Equal(t, c.want, got, c.name)
		assert.Equal(t, c.want, why != "", "%s: a reason iff GPU: %q", c.name, why)
	}
}

func TestCPUOnlyPlacementRejectsGPUSelectingCPUScheduler(t *testing.T) {
	for name, sched := range map[string]*SchedulingSpec{
		"selector":   {NodeSelector: map[string]string{WorkloadTypeLabel: "gpu"}},
		"toleration": {Tolerations: []corev1.Toleration{{Key: GPUTaintKey, Operator: corev1.TolerationOpExists}}},
		"affinity":   {Affinity: nodeAffinity("nvidia.com/gpu.present", "true")},
		"gpu label":  {NodeSelector: map[string]string{"nvidia.com/gpu": "true"}},
	} {
		spec := AIPlatformSpec{Profile: AIPlatformProfileCPUOnly, CPUSchedulingSpec: sched}
		errs := spec.ValidatePlacement(specPath)
		require.Len(t, errs, 1, name)
		assert.Contains(t, errs[0].Error(), "spec.cpuScheduler: Forbidden: profile cpuOnly places every workload on CPU nodes", name)
		// ValidateProfile also runs on every reconcile and must not fail one over
		// a placement choice: only the admission webhook enforces this rule.
		assert.Empty(t, spec.ValidateProfile(specPath), name)
	}
	for name, sched := range map[string]*SchedulingSpec{
		"cpu selector":               cpuSched(),
		"empty":                      {},
		"nil":                        nil,
		"kept off gpu nodes (NotIn)": {Affinity: nodeAffinityOp(WorkloadTypeLabel, corev1.NodeSelectorOpNotIn, "gpu")},
	} {
		spec := AIPlatformSpec{Profile: AIPlatformProfileCPUOnly, CPUSchedulingSpec: sched}
		assert.Empty(t, spec.ValidatePlacement(specPath), "the operator never invents a selector; %s is accepted", name)
	}
}

func TestFullFeaturePlacement(t *testing.T) {
	good := func() AIPlatformSpec {
		return AIPlatformSpec{Profile: AIPlatformProfileFullFeature, CPUSchedulingSpec: cpuSched(), GPUSchedulingSpec: gpuSched()}
	}

	g := good()
	assert.Empty(t, g.ValidatePlacement(specPath), "the live fullfeature-dev shape is accepted")

	t.Run("each way of identifying GPU capacity", func(t *testing.T) {
		for name, mutate := range map[string]func(*AIPlatformSpec){
			"selector": func(s *AIPlatformSpec) {
				s.GPUSchedulingSpec = &SchedulingSpec{NodeSelector: map[string]string{"gpu-pool": "a"}}
			},
			"affinity": func(s *AIPlatformSpec) {
				s.GPUSchedulingSpec = &SchedulingSpec{Affinity: nodeAffinity("gpu-pool", "a")}
			},
			"instance":    func(s *AIPlatformSpec) { s.GPUSchedulingSpec = nil; s.GpuInstanceType = "g6e.xlarge" },
			"accelerator": func(s *AIPlatformSpec) { s.GPUSchedulingSpec = nil; s.DefaultAcceleratorType = "L40S" },
		} {
			s := good()
			mutate(&s)
			assert.Empty(t, s.ValidatePlacement(specPath), name)
		}
	})

	t.Run("a toleration of the GPU taint identifies GPU capacity", func(t *testing.T) {
		s := AIPlatformSpec{Profile: AIPlatformProfileFullFeature, GPUSchedulingSpec: &SchedulingSpec{Tolerations: gpuSched().Tolerations}}
		assert.Empty(t, s.ValidatePlacement(specPath))
	})

	t.Run("missing GPU capacity", func(t *testing.T) {
		for name, gpu := range map[string]*SchedulingSpec{
			"nil":                nil,
			"empty":              {},
			"empty affinity":     {Affinity: &corev1.Affinity{}},
			"empty selector map": {NodeSelector: map[string]string{}},
		} {
			s := AIPlatformSpec{Profile: AIPlatformProfileFullFeature, GPUSchedulingSpec: gpu}
			errs := s.ValidatePlacement(specPath)
			require.Len(t, errs, 1, name)
			assert.Contains(t, errs[0].Error(), "spec.gpuScheduler: Required value: profile fullfeature runs hosted models on GPU capacity", name)
		}
	})

	t.Run("CPU scheduler selecting GPU", func(t *testing.T) {
		s := good()
		s.CPUSchedulingSpec = &SchedulingSpec{Tolerations: gpuSched().Tolerations}
		errs := s.ValidatePlacement(specPath)
		require.Len(t, errs, 1)
		assert.Contains(t, errs[0].Error(), "spec.cpuScheduler: Forbidden: the CPU scheduler places the agent runtime on CPU nodes")
	})

	t.Run("identical selectors", func(t *testing.T) {
		s := good()
		s.GPUSchedulingSpec = &SchedulingSpec{NodeSelector: map[string]string{WorkloadTypeLabel: "cpu"}}
		errs := s.ValidatePlacement(specPath)
		require.Len(t, errs, 1)
		assert.Contains(t, errs[0].Error(), "spec.gpuScheduler.nodeSelector: Invalid value")
		assert.Contains(t, errs[0].Error(), "identical to cpuScheduler.nodeSelector")
	})

	t.Run("problems are reported together", func(t *testing.T) {
		s := AIPlatformSpec{Profile: AIPlatformProfileFullFeature, CPUSchedulingSpec: gpuSched()}
		assert.Len(t, s.ValidatePlacement(specPath), 2)
	})

	t.Run("only an explicit fullfeature is checked", func(t *testing.T) {
		// Same contradictory spec, other spellings of the same profile: no
		// errors, because an omitted profile and legacy "full" keep the
		// leniency they always had.
		for _, p := range []AIPlatformProfile{"", AIPlatformProfileLegacyFull} {
			s := AIPlatformSpec{Profile: p, CPUSchedulingSpec: gpuSched()}
			assert.Empty(t, s.ValidatePlacement(specPath), "profile %q", p)
		}
	})

	t.Run("legacy profiles are not affected by ValidateProfile either", func(t *testing.T) {
		for _, p := range []AIPlatformProfile{"", AIPlatformProfileLegacyFull, AIPlatformProfileFullFeature} {
			s := AIPlatformSpec{Profile: p, CPUSchedulingSpec: gpuSched()}
			assert.Empty(t, s.ValidateProfile(specPath), "profile %q", p)
		}
	})
}
