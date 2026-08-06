package raybuilder

import (
	"context"
	"crypto/sha256"
	"fmt"
	"path/filepath"
	"testing"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

const rayOtelCAHashAnnotation = "splunk-ai-operator/splunk-ca-hash"

func TestBuildClusterConfig_RollsRayTemplatesOnOtelCARotation(t *testing.T) {
	ctx := context.Background()
	platform := rayOtelCATestPlatform(true)
	caSecret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "splunk-ca", Namespace: platform.Namespace},
		Data:       map[string][]byte{"ca.crt": []byte("first-ca")},
	}
	builder, fakeClient := newRayOtelCATestBuilder(t, platform, caSecret)

	firstSpec, err := builder.buildClusterConfig(ctx)
	require.NoError(t, err)
	firstHash := fmt.Sprintf("%x", sha256.Sum256([]byte("first-ca")))
	requireRayTemplatesHaveCAHash(t, firstSpec, firstHash)
	require.Equal(t, "kept", firstSpec.HeadGroupSpec.Template.Annotations["example.com/preserved"])

	stored := &corev1.Secret{}
	require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Namespace: platform.Namespace, Name: caSecret.Name}, stored))
	stored.Data["ca.crt"] = []byte("rotated-ca")
	require.NoError(t, fakeClient.Update(ctx, stored))

	rotatedSpec, err := builder.buildClusterConfig(ctx)
	require.NoError(t, err)
	rotatedHash := fmt.Sprintf("%x", sha256.Sum256([]byte("rotated-ca")))
	require.NotEqual(t, firstHash, rotatedHash)
	requireRayTemplatesHaveCAHash(t, rotatedSpec, rotatedHash)
}

func TestBuildClusterConfig_DoesNotRollRayTemplatesForCAWhenOtelDisabled(t *testing.T) {
	platform := rayOtelCATestPlatform(false)
	caSecret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "splunk-ca", Namespace: platform.Namespace},
		Data:       map[string][]byte{"ca.crt": []byte("ca-data")},
	}
	builder, _ := newRayOtelCATestBuilder(t, platform, caSecret)

	spec, err := builder.buildClusterConfig(context.Background())
	require.NoError(t, err)
	require.NotContains(t, spec.HeadGroupSpec.Template.Annotations, rayOtelCAHashAnnotation)
	for _, worker := range spec.WorkerGroupSpecs {
		require.NotContains(t, worker.Template.Annotations, rayOtelCAHashAnnotation)
	}
}

func newRayOtelCATestBuilder(t *testing.T, platform *aiv1.AIPlatform, objects ...runtime.Object) (*Builder, client.Client) {
	t.Helper()
	instanceFile, err := filepath.Abs("../../../config/configs/instance.yaml")
	require.NoError(t, err)
	workerScaleFile, err := filepath.Abs("../../../config/configs/worker-scale.yaml")
	require.NoError(t, err)
	t.Setenv("INSTANCE_FILE", instanceFile)
	t.Setenv("WORKER_SCALE_FILE", workerScaleFile)
	t.Setenv("RELATED_IMAGE_RAY_HEAD", "rayproject/ray:latest")
	t.Setenv("RELATED_IMAGE_RAY_WORKER", "rayproject/ray:latest")
	t.Setenv("RELATED_IMAGE_FLUENT_BIT", "fluent/fluent-bit:latest")
	t.Setenv("RAY_VERSION", "2.9.0")

	s := runtime.NewScheme()
	require.NoError(t, corev1.AddToScheme(s))
	require.NoError(t, aiv1.AddToScheme(s))
	require.NoError(t, rayv1.AddToScheme(s))
	fakeClient := fake.NewClientBuilder().WithScheme(s).WithRuntimeObjects(objects...).Build()
	return New(platform, fakeClient, s, record.NewFakeRecorder(10)), fakeClient
}

func rayOtelCATestPlatform(otelEnabled bool) *aiv1.AIPlatform {
	return &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:        "otel-ca-rollout",
			Namespace:   "default",
			Annotations: map[string]string{"example.com/preserved": "kept"},
		},
		Spec: aiv1.AIPlatformSpec{
			Sidecars: aiv1.SidecarSpec{Otel: otelEnabled},
			SplunkConfiguration: aiv1.SplunkConfigurationSpec{
				Endpoint:    "https://splunk.example.com:8089",
				HECEndpoint: "https://splunk.example.com:8088",
				CACertRef:   &aiv1.CABundleRef{Name: "splunk-ca"},
			},
			CPUSchedulingSpec: &aiv1.SchedulingSpec{},
			GPUSchedulingSpec: &aiv1.SchedulingSpec{},
			WorkerGroupConfig: &aiv1.WorkerGroupConfig{},
		},
	}
}

func requireRayTemplatesHaveCAHash(t *testing.T, spec *rayv1.RayClusterSpec, expected string) {
	t.Helper()
	require.Equal(t, expected, spec.HeadGroupSpec.Template.Annotations[rayOtelCAHashAnnotation])
	require.NotEmpty(t, spec.WorkerGroupSpecs)
	for _, worker := range spec.WorkerGroupSpecs {
		require.Equal(t, expected, worker.Template.Annotations[rayOtelCAHashAnnotation], "worker group %s", worker.GroupName)
	}
}
