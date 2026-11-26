// Package podsecurity holds the pod security settings that the operator
// applies to every workload pod it creates: Ray head and workers, SAIA (v1, v2,
// v2 worker, NGINX, vector DB setup job), SLIM, SECA and Weaviate.
package podsecurity

import corev1 "k8s.io/api/core/v1"

// RuntimeDefaultSeccomp returns a pod security context with the RuntimeDefault
// seccomp profile. The pod-level profile applies to every container in the
// pod, including init containers and the sidecars that KubeRay and the
// OpenTelemetry Operator add.
//
// PSB SEC-RUN-ASLR (FR3): the RuntimeDefault profile of the container runtime
// rejects personality(ADDR_NO_RANDOMIZE), so a process in the pod cannot start
// a program with address space layout randomization turned off (for example
// with "setarch -R"). A pod without a seccomp profile runs unconfined unless
// the kubelet sets --seccomp-default.
//
// On OpenShift the built-in anyuid SCC rejects a pod that sets a seccomp
// profile. The OpenShift installer creates an anyuid copy that allows
// runtime/default (see AI_SECCOMP_SCC in
// tools/ai-tier-cluster-setup/openshift_with_stack.sh).
func RuntimeDefaultSeccomp() *corev1.PodSecurityContext {
	return &corev1.PodSecurityContext{
		SeccompProfile: &corev1.SeccompProfile{
			Type: corev1.SeccompProfileTypeRuntimeDefault,
		},
	}
}
