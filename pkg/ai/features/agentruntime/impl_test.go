package agentruntime

import (
	"context"
	"os"
	"strings"
	"testing"

	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func buildAgentRuntimeTestScheme(t *testing.T) *runtime.Scheme {
	s := runtime.NewScheme()
	require.NoError(t, aiv1.AddToScheme(s))
	require.NoError(t, corev1.AddToScheme(s))
	require.NoError(t, appsv1.AddToScheme(s))
	require.NoError(t, autoscalingv2.AddToScheme(s))
	require.NoError(t, monitoringv1.AddToScheme(s))
	return s
}

func TestAgentRuntimeReconciler_BuildsDeploymentServiceAndHPA(t *testing.T) {
	t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_BASE", "docker.io/splunk/agent-runtime:test")
	t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_MLTK", "docker.io/splunk/agent-runtime-provider-mltk:test")
	t.Setenv("RELATED_AGENT_RUNTIME_MODULE_PROVIDER_MLTK", "agentcore_operations.loader:MLTKAgentLoader")
	defer os.Unsetenv("RELATED_IMAGE_AGENT_RUNTIME_BASE")
	defer os.Unsetenv("RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_MLTK")
	defer os.Unsetenv("RELATED_AGENT_RUNTIME_MODULE_PROVIDER_MLTK")

	scheme := buildAgentRuntimeTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "stack-agentruntime-mltk",
			Namespace: "default",
			UID:       types.UID("ai-service-uid"),
		},
		Spec: aiv1.AIServiceSpec{
			Feature: aiv1.FeatureSpec{
				Name:     "agentruntime",
				Provider: "mltk",
			},
			AIPlatformUrl:         "http://ray-head.default.svc.cluster.local:8000",
			VectorDbUrl:           "weaviate.default.svc.cluster.local",
			ServiceAccountName:    "agentruntime-sa",
			CheckpointDbSecretRef: "mltk-postgres",
			MinReplicas:           int32PtrForAgentRuntimeTest(1),
			MaxReplicas:           int32PtrForAgentRuntimeTest(4),
			TargetCPUUtilization:  int32PtrForAgentRuntimeTest(60),
			Replicas:              1,
			Metrics:               aiv1.MetricsConfig{Enabled: true, Path: "/metrics"},
		},
	}
	defaultAgentRuntimeSpec(ai)

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	reconciler := &AgentRuntimeReconciler{
		Client:   fakeClient,
		Scheme:   scheme,
		Recorder: record.NewFakeRecorder(10),
	}

	require.NoError(t, reconciler.reconcileDeployment(context.Background(), ai))
	require.NoError(t, reconciler.reconcileService(context.Background(), ai))
	require.NoError(t, reconciler.reconcileHPA(context.Background(), ai))

	deployment := &appsv1.Deployment{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "stack-agentruntime-mltk-agentruntime-deployment", Namespace: "default"}, deployment))
	require.Len(t, deployment.Spec.Template.Spec.InitContainers, 1)
	assert.Equal(t, "fetch-provider-wheel", deployment.Spec.Template.Spec.InitContainers[0].Name)
	assert.Equal(t, "docker.io/splunk/agent-runtime-provider-mltk:test", deployment.Spec.Template.Spec.InitContainers[0].Image)
	require.Len(t, deployment.Spec.Template.Spec.Containers, 1)
	container := deployment.Spec.Template.Spec.Containers[0]
	assert.Equal(t, "docker.io/splunk/agent-runtime:test", container.Image)
	assertEnv(t, container.Env, "AGENT_MODULE", "agentcore_operations.loader:MLTKAgentLoader")
	assertEnv(t, container.Env, "PYTHONPATH", sharedPackagesPath)
	assertEnv(t, container.Env, "PLATFORM_URL", "http://ray-head.default.svc.cluster.local:8000")
	assertEnv(t, container.Env, "VECTOR_DB_URL", "weaviate.default.svc.cluster.local")
	require.Len(t, deployment.Spec.Template.Spec.Volumes, 1)
	assert.Equal(t, "provider-packages", deployment.Spec.Template.Spec.Volumes[0].Name)
	assert.NotNil(t, deployment.Spec.Template.Spec.Volumes[0].EmptyDir)

	svc := &corev1.Service{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "stack-agentruntime-mltk-agentruntime-service", Namespace: "default"}, svc))
	assert.Equal(t, corev1.ServiceTypeClusterIP, svc.Spec.Type)
	assert.Equal(t, map[string]string{"app": ai.Name, "component": ai.Name}, svc.Spec.Selector)

	hpa := &autoscalingv2.HorizontalPodAutoscaler{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "stack-agentruntime-mltk-agentruntime-hpa", Namespace: "default"}, hpa))
	require.NotNil(t, hpa.Spec.MinReplicas)
	assert.Equal(t, int32(1), *hpa.Spec.MinReplicas)
	assert.Equal(t, int32(4), hpa.Spec.MaxReplicas)
	assert.Equal(t, "stack-agentruntime-mltk-agentruntime-deployment", hpa.Spec.ScaleTargetRef.Name)
	require.Len(t, hpa.Spec.Metrics, 1)
	require.NotNil(t, hpa.Spec.Metrics[0].Resource)
	require.NotNil(t, hpa.Spec.Metrics[0].Resource.Target.AverageUtilization)
	assert.Equal(t, int32(60), *hpa.Spec.Metrics[0].Resource.Target.AverageUtilization)
}

func TestAgentRuntimeReconciler_DefaultsOmittedHPAFields(t *testing.T) {
	scheme := buildAgentRuntimeTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "stack-agentruntime-mltk",
			Namespace: "default",
			UID:       types.UID("ai-service-uid"),
		},
		Spec: aiv1.AIServiceSpec{
			Feature: aiv1.FeatureSpec{
				Name:     "agentruntime",
				Provider: "mltk",
			},
			Replicas: 1,
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	reconciler := &AgentRuntimeReconciler{
		Client:   fakeClient,
		Scheme:   scheme,
		Recorder: record.NewFakeRecorder(10),
	}

	require.NoError(t, reconciler.reconcileHPA(context.Background(), ai))

	hpa := &autoscalingv2.HorizontalPodAutoscaler{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "stack-agentruntime-mltk-agentruntime-hpa", Namespace: "default"}, hpa))
	require.NotNil(t, hpa.Spec.MinReplicas)
	assert.Equal(t, defaultMinReplicas, *hpa.Spec.MinReplicas)
	assert.Equal(t, defaultMaxReplicas, hpa.Spec.MaxReplicas)
	require.Len(t, hpa.Spec.Metrics, 1)
	require.NotNil(t, hpa.Spec.Metrics[0].Resource)
	require.NotNil(t, hpa.Spec.Metrics[0].Resource.Target.AverageUtilization)
	assert.Equal(t, defaultTargetCPUUtilization, *hpa.Spec.Metrics[0].Resource.Target.AverageUtilization)
	assert.Nil(t, ai.Spec.MinReplicas)
	assert.Nil(t, ai.Spec.MaxReplicas)
	assert.Nil(t, ai.Spec.TargetCPUUtilization)
}

func TestAgentRuntimeServiceName_StaysWithinDNSLabelLimit(t *testing.T) {
	shortName := "stack-agentruntime-mltk"
	assert.Equal(t, shortName+"-agentruntime-service", agentRuntimeServiceName(shortName))

	longName := "agentruntime-dev-ai-platform-agentruntime-mltk"
	serviceName := agentRuntimeServiceName(longName)
	require.LessOrEqual(t, len(serviceName), 63)
	assert.True(t, strings.HasSuffix(serviceName, "-agentruntime-service"))
	assert.NotEqual(t, longName+"-agentruntime-service", serviceName)
}

func int32PtrForAgentRuntimeTest(value int32) *int32 {
	return &value
}

func assertEnv(t *testing.T, env []corev1.EnvVar, name, value string) {
	t.Helper()
	for _, item := range env {
		if item.Name == name {
			assert.Equal(t, value, item.Value)
			return
		}
	}
	t.Fatalf("missing env %s", name)
}
