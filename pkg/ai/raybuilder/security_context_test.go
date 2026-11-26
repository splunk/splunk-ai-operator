package raybuilder

import (
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// PSB SEC-RUN-ASLR: Ray pods must run with the RuntimeDefault seccomp profile,
// which blocks personality(ADDR_NO_RANDOMIZE) ("setarch -R").
func TestRayPodTemplatesUseRuntimeDefaultSeccomp(t *testing.T) {
	t.Setenv("RELATED_IMAGE_RAY_HEAD", "rayproject/ray:latest")
	t.Setenv("RELATED_IMAGE_RAY_WORKER", "rayproject/ray:latest")

	s := scheme.Scheme
	_ = aiv1.AddToScheme(s)

	platform := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "test-platform", Namespace: "default"},
		Spec: aiv1.AIPlatformSpec{
			DefaultAcceleratorType: "L40S",
			CPUSchedulingSpec:      &aiv1.SchedulingSpec{},
			GPUSchedulingSpec:      &aiv1.SchedulingSpec{},
			WorkerGroupConfig:      &aiv1.WorkerGroupConfig{},
		},
	}
	builder := New(platform, fake.NewClientBuilder().WithScheme(s).Build(), s, record.NewFakeRecorder(10))

	worker := InstanceDetail{
		Tier:       "tier-1",
		GPUsPerPod: 1,
		Resources: corev1.ResourceRequirements{
			Limits: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
		},
	}

	templates := map[string]corev1.PodTemplateSpec{
		"head":   builder.makeHeadTemplate(),
		"worker": builder.makeWorkerTemplate(worker),
	}
	for name, template := range templates {
		t.Run(name, func(t *testing.T) {
			sc := template.Spec.SecurityContext
			require.NotNil(t, sc, "pod security context")
			require.NotNil(t, sc.SeccompProfile, "pod seccomp profile")
			assert.Equal(t, corev1.SeccompProfileTypeRuntimeDefault, sc.SeccompProfile.Type)
			assert.Nil(t, sc.SeccompProfile.LocalhostProfile)

			// No container may override the pod profile.
			for _, c := range template.Spec.Containers {
				if c.SecurityContext != nil {
					assert.Nil(t, c.SecurityContext.SeccompProfile, "container %s seccomp profile", c.Name)
				}
			}
		})
	}
}
