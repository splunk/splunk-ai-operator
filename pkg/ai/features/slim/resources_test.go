package slim

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
)

func list(kv map[corev1.ResourceName]string) corev1.ResourceList {
	out := corev1.ResourceList{}
	for k, v := range kv {
		out[k] = resource.MustParse(v)
	}
	return out
}

// SLIM is a CPU workload under both profiles: an accelerator request or an
// impossible budget is refused with the field, and the refusal is an event.
func TestValidateAIService_SlimResourceRules(t *testing.T) {
	cases := []struct {
		name string
		res  corev1.ResourceRequirements
		want string
	}{
		{"defaults", corev1.ResourceRequirements{}, ""},
		{"explicit CPU budget", corev1.ResourceRequirements{
			Requests: list(map[corev1.ResourceName]string{"cpu": "2", "memory": "2Gi"}),
			Limits:   list(map[corev1.ResourceName]string{"cpu": "4", "memory": "4Gi"})}, ""},
		{"inverted", corev1.ResourceRequirements{
			Requests: list(map[corev1.ResourceName]string{"cpu": "8"}), Limits: list(map[corev1.ResourceName]string{"cpu": "4"})},
			"must not exceed limits.cpu (4)"},
		{"negative", corev1.ResourceRequirements{Requests: list(map[corev1.ResourceName]string{"memory": "-1"})}, "must not be negative"},
	}
	for _, profile := range []aiv1.AIPlatformProfile{aiv1.AIPlatformProfileCPUOnly, aiv1.AIPlatformProfileFullFeature} {
		for _, c := range cases {
			r, _ := slimReconciler(t, slimPlatform(profile, profile != aiv1.AIPlatformProfileCPUOnly))
			url := ""
			if profile == aiv1.AIPlatformProfileCPUOnly {
				url = testAgentRuntimeURL
			}
			ai := slimService(url)
			ai.Spec.Resources = c.res
			err := r.validateAIService(context.Background(), ai)
			if c.want == "" {
				assert.NoError(t, err, "%s / %s", profile, c.name)
				continue
			}
			require.Error(t, err, "%s / %s", profile, c.name)
			assert.Contains(t, err.Error(), c.want, "%s / %s", profile, c.name)
		}
	}
}

// An accelerator is refused for SLIM only under cpuOnly; on any other platform it
// is an existing component whose resources are left as the administrator set them.
func TestValidateAIService_SlimGPUIsRefusedOnlyUnderCPUOnly(t *testing.T) {
	gpu := corev1.ResourceRequirements{Requests: list(map[corev1.ResourceName]string{"nvidia.com/gpu": "1"})}

	r, _ := slimReconciler(t, slimPlatform(aiv1.AIPlatformProfileCPUOnly, false))
	ai := slimService(testAgentRuntimeURL)
	ai.Spec.Resources = gpu
	err := r.validateAIService(context.Background(), ai)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "spec.resources.requests[nvidia.com/gpu]: Forbidden")

	for _, profile := range []aiv1.AIPlatformProfile{"", aiv1.AIPlatformProfileLegacyFull, aiv1.AIPlatformProfileFullFeature} {
		r, _ := slimReconciler(t, slimPlatform(profile, true))
		ai := slimService("")
		ai.Spec.Resources = *gpu.DeepCopy()
		assert.NoError(t, r.validateAIService(context.Background(), ai), "platform profile %q", profile)
	}
}

// The SLIM defaults are unchanged: they are what existing fullfeature Deployments
// were built with, and changing them would roll every SLIM pod on upgrade.
func TestSlimDefaultResourcesAreUnchanged(t *testing.T) {
	r, _ := slimReconciler(t, slimPlatform(aiv1.AIPlatformProfileFullFeature, true))
	ai := slimService("")
	require.NoError(t, r.validateAIService(context.Background(), ai))
	want := corev1.ResourceRequirements{
		Requests: list(map[corev1.ResourceName]string{"cpu": "4", "memory": "5Gi"}),
		Limits:   list(map[corev1.ResourceName]string{"cpu": "4", "memory": "5Gi"}),
	}
	assert.Equal(t, want, ai.Spec.Resources)
}

// The placement the AIService carries is what the Deployment gets.
func TestSlimDeploymentCarriesPlacementAndNoGPU(t *testing.T) {
	r, _ := slimReconciler(t, slimPlatform(aiv1.AIPlatformProfileCPUOnly, false))
	ai := slimService(testAgentRuntimeURL)
	ai.Spec.NodeSelector = map[string]string{"splunk.ai/workload-type": "cpu"}
	ai.Spec.Tolerations = []corev1.Toleration{{Key: "dedicated", Operator: corev1.TolerationOpExists}}
	require.NoError(t, r.validateAIService(context.Background(), ai))
	require.NoError(t, r.reconcileSlimDeployment(context.Background(), ai))

	var dep appsv1.Deployment
	require.NoError(t, r.Client.Get(context.Background(), types.NamespacedName{Namespace: ai.Namespace, Name: ai.Name + "-slim-deployment"}, &dep))
	spec := dep.Spec.Template.Spec
	assert.Equal(t, ai.Spec.NodeSelector, spec.NodeSelector)
	assert.Equal(t, ai.Spec.Tolerations, spec.Tolerations)
	for _, c := range spec.Containers {
		for rn := range c.Resources.Requests {
			assert.False(t, aiv1.IsGPUResource(rn), "container %s requests %s", c.Name, rn)
		}
		for rn := range c.Resources.Limits {
			assert.False(t, aiv1.IsGPUResource(rn), "container %s limits %s", c.Name, rn)
		}
	}
}

func TestSlimDeployment_SecondReconcileWritesNothing(t *testing.T) {
	const deploymentRevisionAnnotation = "deployment.kubernetes.io/revision"
	r, _ := slimReconciler(t, slimPlatform(aiv1.AIPlatformProfileCPUOnly, false))
	ai := slimService(testAgentRuntimeURL)
	ai.Spec.NodeSelector = map[string]string{"splunk.ai/workload-type": "cpu"}
	require.NoError(t, r.validateAIService(context.Background(), ai))
	key := types.NamespacedName{Namespace: ai.Namespace, Name: ai.Name + "-slim-deployment"}

	require.NoError(t, r.reconcileSlimDeployment(context.Background(), ai))
	var first appsv1.Deployment
	require.NoError(t, r.Client.Get(context.Background(), key, &first))
	first.Annotations[deploymentRevisionAnnotation] = "3"
	require.NoError(t, r.Client.Update(context.Background(), &first))
	ai.Annotations = map[string]string{deploymentRevisionAnnotation: "999"}

	require.NoError(t, r.reconcileSlimDeployment(context.Background(), ai))
	var second appsv1.Deployment
	require.NoError(t, r.Client.Get(context.Background(), key, &second))
	assert.Equal(t, "3", second.Annotations[deploymentRevisionAnnotation])
	assert.NotContains(t, second.Spec.Template.Annotations, deploymentRevisionAnnotation)
	assert.Equal(t, first.ResourceVersion, second.ResourceVersion, "the second reconcile rewrote the Deployment")
}
