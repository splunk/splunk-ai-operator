/*
Copyright 2024.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1

import (
	"reflect"
	"sort"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

// Markers that identify GPU capacity. They are the conventions used by the
// NVIDIA device plugin and by the installer's node labelling; the operator
// never invents a selector of its own, it only refuses one that contradicts
// the selected profile.
const (
	// GPUTaintKey is the key of the NoSchedule taint that keeps CPU workloads off
	// GPU nodes. A toleration for it is a GPU-only toleration.
	GPUTaintKey = "nvidia.com/gpu"

	// WorkloadTypeLabel is the node label the installer sets to "cpu" or "gpu".
	WorkloadTypeLabel = "splunk.ai/workload-type"
	// WorkloadTypeGPU is the WorkloadTypeLabel value of a GPU node.
	WorkloadTypeGPU = "gpu"
)

// IsGPUResource reports whether name is an accelerator extended resource
// (nvidia.com/gpu, nvidia.com/mig-*, amd.com/gpu, gpu.intel.com/*).
func IsGPUResource(name corev1.ResourceName) bool {
	n := string(name)
	return strings.HasPrefix(n, "nvidia.com/") ||
		strings.HasPrefix(n, "amd.com/gpu") ||
		strings.HasPrefix(n, "gpu.intel.com/")
}

// ValidateWorkloadResources checks the compute budget of one workload. It
// reports field-specific, non-secret errors and never rewrites the input.
//
//   - A quantity must not be negative.
//   - Where a request and a limit are both present, the request must not exceed
//     the limit (the API server rejects the Deployment later otherwise).
//   - With requireBudgets, the cpu, memory and ephemeral-storage entries that are
//     present must be greater than zero.
//   - With forbidGPU, no accelerator resource may appear at all.
func ValidateWorkloadResources(path *field.Path, r corev1.ResourceRequirements, requireBudgets, forbidGPU bool) field.ErrorList {
	var errs field.ErrorList
	budgetNames := []corev1.ResourceName{corev1.ResourceCPU, corev1.ResourceMemory, corev1.ResourceEphemeralStorage}

	check := func(kind string, list corev1.ResourceList) {
		names := make([]string, 0, len(list))
		for name := range list {
			names = append(names, string(name))
		}
		sort.Strings(names) // deterministic error order
		for _, n := range names {
			name := corev1.ResourceName(n)
			q := list[name]
			at := path.Child(kind).Key(n)
			if forbidGPU && IsGPUResource(name) {
				errs = append(errs, field.Forbidden(at, "this workload runs on CPU nodes and must not request "+n))
				continue
			}
			if q.Sign() < 0 {
				errs = append(errs, field.Invalid(at, q.String(), "must not be negative"))
				continue
			}
			if requireBudgets && q.IsZero() {
				for _, b := range budgetNames {
					if name == b {
						errs = append(errs, field.Invalid(at, q.String(), "must be greater than zero"))
					}
				}
			}
		}
	}
	check("requests", r.Requests)
	check("limits", r.Limits)

	names := make([]string, 0, len(r.Requests))
	for name := range r.Requests {
		names = append(names, string(name))
	}
	sort.Strings(names)
	for _, n := range names {
		name := corev1.ResourceName(n)
		req := r.Requests[name]
		lim, ok := r.Limits[name]
		if !ok || req.Sign() < 0 || lim.Sign() < 0 {
			continue // already reported, or nothing to compare
		}
		if req.Cmp(lim) > 0 {
			errs = append(errs, field.Invalid(path.Child("requests").Key(n), req.String(),
				"must not exceed limits."+n+" ("+lim.String()+")"))
		}
	}
	return errs
}

// nvidiaLabelPrefix is the prefix of every NVIDIA node label (nvidia.com/gpu,
// nvidia.com/gpu.present, nvidia.com/mig.*, ...); a selector on one pins to GPU nodes.
const nvidiaLabelPrefix = "nvidia.com/"

// requirementSelectsGPU reports whether one required node-affinity expression
// pins to GPU nodes. The operator matters: "NotIn gpu" and "DoesNotExist" are
// exactly how a CPU workload is kept off GPU nodes, so they are not a selection.
func requirementSelectsGPU(e corev1.NodeSelectorRequirement) bool {
	switch e.Operator {
	case corev1.NodeSelectorOpExists:
		return strings.HasPrefix(e.Key, nvidiaLabelPrefix)
	case corev1.NodeSelectorOpIn:
		return strings.HasPrefix(e.Key, nvidiaLabelPrefix) ||
			(e.Key == WorkloadTypeLabel && containsString(e.Values, WorkloadTypeGPU))
	}
	return false
}

// selectsGPU reports whether a scheduling spec pins workloads to GPU capacity,
// and why. It looks at the node selector, the required node affinity and the
// tolerations: the three ways a placement can depend on a GPU node. Only an
// explicit toleration of the GPU taint counts; a toleration with an empty key
// tolerates every taint but is not GPU-specific, so it is not flagged.
func selectsGPU(s *SchedulingSpec) (bool, string) {
	if s == nil {
		return false, ""
	}
	keys := make([]string, 0, len(s.NodeSelector))
	for k := range s.NodeSelector {
		keys = append(keys, k)
	}
	sort.Strings(keys) // deterministic reason
	for _, k := range keys {
		if strings.HasPrefix(k, nvidiaLabelPrefix) {
			return true, "nodeSelector " + k
		}
	}
	if s.NodeSelector[WorkloadTypeLabel] == WorkloadTypeGPU {
		return true, "nodeSelector " + WorkloadTypeLabel + "=" + WorkloadTypeGPU
	}
	if toleratesGPUTaint(s.Tolerations) {
		return true, "toleration " + GPUTaintKey
	}
	if s.Affinity != nil && s.Affinity.NodeAffinity != nil && s.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution != nil {
		for _, term := range s.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms {
			for _, e := range term.MatchExpressions {
				if requirementSelectsGPU(e) {
					return true, "node affinity on " + e.Key
				}
			}
		}
	}
	return false, ""
}

func toleratesGPUTaint(tolerations []corev1.Toleration) bool {
	for _, t := range tolerations {
		if t.Key == GPUTaintKey {
			return true
		}
	}
	return false
}

func containsString(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}

// hasGPUCapacitySelection reports whether the spec identifies where GPU
// workloads run: a GPU scheduler selector, affinity or toleration of the GPU
// taint, or an instance or accelerator type.
func (s *AIPlatformSpec) hasGPUCapacitySelection() bool {
	if s.GpuInstanceType != "" || s.DefaultAcceleratorType != "" {
		return true
	}
	g := s.GPUSchedulingSpec
	if g == nil {
		return false
	}
	return len(g.NodeSelector) > 0 ||
		(g.Affinity != nil && !reflect.DeepEqual(*g.Affinity, corev1.Affinity{})) ||
		toleratesGPUTaint(g.Tolerations)
}

// ValidatePlacement checks the CPU/GPU placement of a platform that names one of
// the canonical profiles. It returns nothing for an omitted profile or the legacy
// "full": they mean the same as fullfeature but keep the leniency they always had,
// because rejecting an existing platform for a setting that used to work would
// break upgrades.
//
//   - cpuOnly: the CPU scheduler places every workload, so it must not select GPU
//     capacity or tolerate the GPU taint. (The other cpuOnly checks on GPU
//     settings: gpuScheduler, GPU types, scaleFactor, live in ValidateProfile.)
//   - fullfeature: GPU capacity must be identifiable (a gpuScheduler selector,
//     affinity or GPU toleration, gpuInstanceType or defaultAcceleratorType); the
//     CPU scheduler, which places the agent runtime, must not select GPU capacity;
//     and the two schedulers must not place workloads identically (same selector,
//     tolerations and affinity).
//
// The admission webhook enforces these as errors when a platform is created and
// reports them as warnings when one is updated. They are deliberately not part of
// ValidateProfile, which the operator also runs on every reconcile: neither an
// update (a finalizer removal is an update) nor a reconcile may be blocked by a
// placement choice made before this rule existed.
func (s *AIPlatformSpec) ValidatePlacement(specPath *field.Path) field.ErrorList {
	var errs field.ErrorList
	switch s.Profile {
	case AIPlatformProfileCPUOnly:
		if gpu, why := selectsGPU(s.CPUSchedulingSpec); gpu {
			errs = append(errs, field.Forbidden(specPath.Child("cpuScheduler"),
				"profile cpuOnly places every workload on CPU nodes, so the CPU scheduler must not select GPU capacity ("+why+")"))
		}
	case AIPlatformProfileFullFeature:
		if !s.hasGPUCapacitySelection() {
			errs = append(errs, field.Required(specPath.Child("gpuScheduler"),
				"profile fullfeature runs hosted models on GPU capacity: set gpuScheduler.nodeSelector (or affinity), gpuInstanceType or defaultAcceleratorType"))
		}
		if gpu, why := selectsGPU(s.CPUSchedulingSpec); gpu {
			errs = append(errs, field.Forbidden(specPath.Child("cpuScheduler"),
				"the CPU scheduler places the agent runtime on CPU nodes and must not select GPU capacity ("+why+")"))
		}
		if samePlacement(s.CPUSchedulingSpec, s.GPUSchedulingSpec) {
			errs = append(errs, field.Invalid(specPath.Child("gpuScheduler"), s.GPUSchedulingSpec.NodeSelector,
				"identical to cpuScheduler (same nodeSelector, tolerations and affinity): the agent runtime and the GPU workloads would share the same nodes"))
		}
	}
	return errs
}

// samePlacement reports whether two schedulers pin workloads to exactly the same
// nodes: a non-empty node selector, and the same tolerations and affinity. The
// selector alone proves nothing, because affinity and tolerations travel with it
// to the workloads: two schedulers with the same broad selector (kubernetes.io/os)
// are disjoint when required affinity separates the pools or when only the GPU
// scheduler tolerates the GPU taint.
func samePlacement(c, g *SchedulingSpec) bool {
	if c == nil || g == nil || len(c.NodeSelector) == 0 {
		return false
	}
	emptyAffinity := corev1.Affinity{}
	affinity := func(a *corev1.Affinity) corev1.Affinity {
		if a == nil {
			return emptyAffinity
		}
		return *a
	}
	return reflect.DeepEqual(c.NodeSelector, g.NodeSelector) &&
		(len(c.Tolerations) == 0 && len(g.Tolerations) == 0 || reflect.DeepEqual(c.Tolerations, g.Tolerations)) &&
		reflect.DeepEqual(affinity(c.Affinity), affinity(g.Affinity))
}
