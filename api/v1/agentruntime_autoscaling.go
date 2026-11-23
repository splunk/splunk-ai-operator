package v1

import "k8s.io/apimachinery/pkg/util/validation/field"

// AgentRuntimeAutoscaling is the effective CPU HPA policy for a runtime.
// +kubebuilder:object:generate=false
type AgentRuntimeAutoscaling struct {
	MinReplicas          int32
	MaxReplicas          int32
	TargetCPUUtilization int32
}

// ResolveAgentRuntimeAutoscaling fills omitted settings without coercing overrides.
func ResolveAgentRuntimeAutoscaling(minReplicas, maxReplicas, targetCPUUtilization *int32) AgentRuntimeAutoscaling {
	policy := AgentRuntimeAutoscaling{MinReplicas: 1, MaxReplicas: 4, TargetCPUUtilization: 60}
	if minReplicas != nil {
		policy.MinReplicas = *minReplicas
	}
	if maxReplicas != nil {
		policy.MaxReplicas = *maxReplicas
	}
	if targetCPUUtilization != nil {
		policy.TargetCPUUtilization = *targetCPUUtilization
	}
	return policy
}

// Validate checks the effective settings, including interactions with defaults.
func (p AgentRuntimeAutoscaling) Validate(path *field.Path) field.ErrorList {
	var errs field.ErrorList
	if p.MinReplicas < 1 {
		errs = append(errs, field.Invalid(path.Child("minReplicas"), p.MinReplicas, "must be at least 1 for CPU autoscaling"))
	}
	if p.MaxReplicas < 1 {
		errs = append(errs, field.Invalid(path.Child("maxReplicas"), p.MaxReplicas, "must be at least 1"))
	} else if p.MaxReplicas < p.MinReplicas {
		errs = append(errs, field.Invalid(path.Child("maxReplicas"), p.MaxReplicas, "must be greater than or equal to minReplicas after defaults"))
	}
	if p.TargetCPUUtilization < 1 || p.TargetCPUUtilization > 100 {
		errs = append(errs, field.Invalid(path.Child("targetCPUUtilization"), p.TargetCPUUtilization, "must be between 1 and 100"))
	}
	return errs
}
