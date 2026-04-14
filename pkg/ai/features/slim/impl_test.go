package slim

import (
	"context"
	"fmt"
	"os"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
)

func buildTestScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	require.NoError(t, aiv1.AddToScheme(s))
	require.NoError(t, corev1.AddToScheme(s))
	require.NoError(t, appsv1.AddToScheme(s))
	require.NoError(t, monitoringv1.AddToScheme(s))
	return s
}

func newTestReconciler(t *testing.T, objs ...runtime.Object) (*SlimReconciler, *record.FakeRecorder) {
	t.Helper()
	s := buildTestScheme(t)
	recorder := record.NewFakeRecorder(20)
	clientObjs := make([]runtime.Object, len(objs))
	copy(clientObjs, objs)
	fakeClient := fake.NewClientBuilder().
		WithScheme(s).
		WithRuntimeObjects(clientObjs...).
		Build()
	return &SlimReconciler{
		Client:   fakeClient,
		Scheme:   s,
		Recorder: recorder,
	}, recorder
}

// ---------- validateAIService ----------

func Test_validateAIService_missingEnv(t *testing.T) {
	os.Unsetenv("RELATED_IMAGE_SLIM_API")
	r, _ := newTestReconciler(t)

	ai := &aiv1.AIService{}
	err := r.validateAIService(context.Background(), ai)
	assert.ErrorContains(t, err, "RELATED_IMAGE_SLIM_API must be set")
}

func Test_validateAIService_missingPlatformRefAndUrl(t *testing.T) {
	os.Setenv("RELATED_IMAGE_SLIM_API", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_SLIM_API")

	r, _ := newTestReconciler(t)

	ai := &aiv1.AIService{}
	err := r.validateAIService(context.Background(), ai)
	assert.ErrorContains(t, err, "either AIPlatformRef.Name or AIPlatformUrl must be set")
}

func Test_validateAIService_explicitUrl(t *testing.T) {
	os.Setenv("RELATED_IMAGE_SLIM_API", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_SLIM_API")

	r, _ := newTestReconciler(t)

	ai := &aiv1.AIService{
		Spec: aiv1.AIServiceSpec{
			AIPlatformUrl: "ray.ns.svc.cluster.local:8000",
		},
	}
	err := r.validateAIService(context.Background(), ai)
	assert.NoError(t, err)
	assert.Equal(t, int32(1), ai.Spec.Replicas)
	assert.NotNil(t, ai.Spec.Resources.Requests)
	assert.NotNil(t, ai.Spec.Resources.Limits)
}

func Test_validateAIService_defaults(t *testing.T) {
	os.Setenv("RELATED_IMAGE_SLIM_API", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_SLIM_API")

	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "plat", Namespace: "ns"},
		Status: aiv1.AIPlatformStatus{
			RayServiceName: "ray-svc",
			Conditions: []metav1.Condition{
				{Type: "RayServiceStatusReady", Status: metav1.ConditionTrue},
			},
		},
	}

	r, _ := newTestReconciler(t, plat)

	common.IsConditionTrue = func(conds []metav1.Condition, typ string) bool { return true }

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "ai", Namespace: "ns"},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat", Namespace: "ns"},
		},
	}

	err := r.validateAIService(context.Background(), ai)
	assert.NoError(t, err)
	assert.Equal(t, int32(1), ai.Spec.Replicas)
	assert.Equal(t, resource.MustParse("4"), ai.Spec.Resources.Requests[corev1.ResourceCPU])
	assert.Equal(t, resource.MustParse("5Gi"), ai.Spec.Resources.Requests[corev1.ResourceMemory])
	assert.Equal(t, "http://ray-svc.ns.svc.cluster.local:8000", ai.Spec.AIPlatformUrl)
}

func Test_validateAIService_customClusterDomain(t *testing.T) {
	os.Setenv("RELATED_IMAGE_SLIM_API", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_SLIM_API")

	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "plat", Namespace: "ns"},
		Status: aiv1.AIPlatformStatus{
			RayServiceName: "ray-svc",
		},
	}

	r, _ := newTestReconciler(t, plat)
	common.IsConditionTrue = func(conds []metav1.Condition, typ string) bool { return true }

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "ai", Namespace: "ns"},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat", Namespace: "ns"},
			ClusterDomain: "my.custom.domain",
		},
	}

	err := r.validateAIService(context.Background(), ai)
	assert.NoError(t, err)
	assert.Equal(t, "http://ray-svc.ns.svc.my.custom.domain:8000", ai.Spec.AIPlatformUrl)
}

func Test_validateAIService_preservesExistingResources(t *testing.T) {
	os.Setenv("RELATED_IMAGE_SLIM_API", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_SLIM_API")

	r, _ := newTestReconciler(t)

	ai := &aiv1.AIService{
		Spec: aiv1.AIServiceSpec{
			AIPlatformUrl: "ray.ns.svc.cluster.local:8000",
			Resources: corev1.ResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("8"),
					corev1.ResourceMemory: resource.MustParse("16Gi"),
				},
				Limits: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("8"),
					corev1.ResourceMemory: resource.MustParse("16Gi"),
				},
			},
			Replicas: 3,
		},
	}

	err := r.validateAIService(context.Background(), ai)
	assert.NoError(t, err)
	assert.Equal(t, int32(3), ai.Spec.Replicas)
	assert.Equal(t, resource.MustParse("8"), ai.Spec.Resources.Requests[corev1.ResourceCPU])
	assert.Equal(t, resource.MustParse("16Gi"), ai.Spec.Resources.Requests[corev1.ResourceMemory])
}

// ---------- getAIPlatform ----------

func Test_getAIPlatform_success(t *testing.T) {
	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "plat", Namespace: "ns"},
	}

	r, _ := newTestReconciler(t, plat)

	got, err := r.getAIPlatform(context.Background(), corev1.ObjectReference{Name: "plat", Namespace: "ns"})
	assert.NoError(t, err)
	assert.NotNil(t, got)
	assert.Equal(t, "plat", got.Name)
}

func Test_getAIPlatform_notFound(t *testing.T) {
	r, _ := newTestReconciler(t)

	got, err := r.getAIPlatform(context.Background(), corev1.ObjectReference{Name: "missing", Namespace: "ns"})
	assert.Error(t, err)
	assert.Nil(t, got)
}

// ---------- validateAIPlatformReady ----------

func Test_validateAIPlatformReady_ready(t *testing.T) {
	r, _ := newTestReconciler(t)

	origFn := common.IsConditionTrue
	defer func() { common.IsConditionTrue = origFn }()
	common.IsConditionTrue = func(conds []metav1.Condition, typ string) bool { return true }

	plat := &aiv1.AIPlatform{
		Status: aiv1.AIPlatformStatus{
			RayServiceName: "ray-svc",
		},
	}

	err := r.validateAIPlatformReady(context.Background(), plat)
	assert.NoError(t, err)
}

func Test_validateAIPlatformReady_notReady(t *testing.T) {
	r, _ := newTestReconciler(t)

	origFn := common.IsConditionTrue
	defer func() { common.IsConditionTrue = origFn }()
	common.IsConditionTrue = func(conds []metav1.Condition, typ string) bool { return false }

	plat := &aiv1.AIPlatform{
		Status: aiv1.AIPlatformStatus{
			RayServiceName: "ray-svc",
		},
	}

	err := r.validateAIPlatformReady(context.Background(), plat)
	assert.ErrorContains(t, err, "RayService is not ready")
}

func Test_validateAIPlatformReady_noServiceName(t *testing.T) {
	r, _ := newTestReconciler(t)

	origFn := common.IsConditionTrue
	defer func() { common.IsConditionTrue = origFn }()
	common.IsConditionTrue = func(conds []metav1.Condition, typ string) bool { return true }

	plat := &aiv1.AIPlatform{
		Status: aiv1.AIPlatformStatus{
			RayServiceName: "",
		},
	}

	err := r.validateAIPlatformReady(context.Background(), plat)
	assert.ErrorContains(t, err, "RayServiceName not populated")
}

// ---------- reconcileServiceAccount ----------

func Test_reconcileServiceAccount_creates(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(s).
		WithObjects(ai).
		WithStatusSubresource(ai).
		Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileServiceAccount(context.Background(), ai)
	assert.NoError(t, err)
	assert.Equal(t, "slim-svc-sa", ai.Spec.ServiceAccountName)

	sa := &corev1.ServiceAccount{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{Name: "slim-svc-sa", Namespace: "default"}, sa)
	assert.NoError(t, err)
}

func Test_reconcileServiceAccount_existingName(t *testing.T) {
	r, _ := newTestReconciler(t)

	ai := &aiv1.AIService{
		Spec: aiv1.AIServiceSpec{
			ServiceAccountName: "existing-sa",
		},
	}

	err := r.reconcileServiceAccount(context.Background(), ai)
	assert.NoError(t, err)
	assert.Equal(t, "existing-sa", ai.Spec.ServiceAccountName)
}

// ---------- reconcileSlimConfigMap ----------

func Test_reconcileSlimConfigMap_createsWithDefaults(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileSlimConfigMap(context.Background(), ai)
	assert.NoError(t, err)

	cm := &corev1.ConfigMap{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-slim-config", Namespace: "default",
	}, cm)
	assert.NoError(t, err)
	assert.Equal(t, "slim-api", cm.Data["SERVICE_NAME"])
	assert.Equal(t, "SLIM", cm.Data["SERVICE_INTERNAL_NAME"])
	assert.Equal(t, "true", cm.Data["SLIM_SERVICE_CMP"])
	assert.Equal(t, "false", cm.Data["ENABLE_AUTHZ"])
	assert.Equal(t, "false", cm.Data["ENABLE_AUTHN"])
	assert.Equal(t, "v1alpha1", cm.Data["API_VERSION"])
	assert.Equal(t, "/etc/config/features_config.yaml", cm.Data["FEATURE_CONFIG_FILE_LOCATION"])
	assert.Equal(t, "info", cm.Data["LOG_LEVEL"])
	assert.Contains(t, cm.Data["SPLUNK_ISSUERS"], "splunk-splunk-standalone")
}

func Test_reconcileSlimConfigMap_preservesUserValues(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
	}

	existingCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc-slim-config",
			Namespace: "default",
		},
		Data: map[string]string{
			"SERVICE_NAME": "my-custom-name",
			"LOG_LEVEL":    "debug",
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai, existingCM).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileSlimConfigMap(context.Background(), ai)
	assert.NoError(t, err)

	cm := &corev1.ConfigMap{}
	_ = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-slim-config", Namespace: "default",
	}, cm)
	assert.Equal(t, "my-custom-name", cm.Data["SERVICE_NAME"])
	assert.Equal(t, "debug", cm.Data["LOG_LEVEL"])
	assert.Equal(t, "true", cm.Data["SLIM_SERVICE_CMP"])
}

// ---------- reconcileFeatureConfigMap ----------

func Test_reconcileFeatureConfigMap_creates(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileFeatureConfigMap(context.Background(), ai)
	assert.NoError(t, err)

	cm := &corev1.ConfigMap{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "splunk-slim-svc-feature-config", Namespace: "default",
	}, cm)
	assert.NoError(t, err)
	assert.Contains(t, cm.Data["features_config.yaml"], "enabled_by_default: true")
}

func Test_reconcileFeatureConfigMap_preservesExisting(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
	}

	existingCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "splunk-slim-svc-feature-config",
			Namespace: "default",
			OwnerReferences: []metav1.OwnerReference{
				{UID: "test-uid", Name: "slim-svc", Kind: "AIService", APIVersion: "ai.splunk.com/v1"},
			},
		},
		Data: map[string]string{
			"features_config.yaml": "customization:\n  enabled_by_default: false\n",
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai, existingCM).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileFeatureConfigMap(context.Background(), ai)
	assert.NoError(t, err)

	cm := &corev1.ConfigMap{}
	_ = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "splunk-slim-svc-feature-config", Namespace: "default",
	}, cm)
	assert.Contains(t, cm.Data["features_config.yaml"], "enabled_by_default: false")
}

// ---------- reconcileSlimDeployment ----------

func Test_reconcileSlimDeployment_creates(t *testing.T) {
	os.Setenv("RELATED_IMAGE_SLIM_API", "splunk/slim-api:latest")
	defer os.Unsetenv("RELATED_IMAGE_SLIM_API")

	s := buildTestScheme(t)

	featureCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "splunk-slim-svc-feature-config",
			Namespace: "default",
		},
		Data: map[string]string{"features_config.yaml": "customization:\n  enabled_by_default: true\n"},
	}

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
		Spec: aiv1.AIServiceSpec{
			AIPlatformUrl:      "ray.default.svc.cluster.local:8000",
			ServiceAccountName: "slim-svc-sa",
			Replicas:           2,
			Resources: corev1.ResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("4"),
					corev1.ResourceMemory: resource.MustParse("5Gi"),
				},
				Limits: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("4"),
					corev1.ResourceMemory: resource.MustParse("5Gi"),
				},
			},
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai, featureCM).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileSlimDeployment(context.Background(), ai)
	assert.NoError(t, err)

	deploy := &appsv1.Deployment{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-slim-deployment", Namespace: "default",
	}, deploy)
	assert.NoError(t, err)
	assert.Equal(t, int32(2), *deploy.Spec.Replicas)
	assert.Equal(t, "splunk/slim-api:latest", deploy.Spec.Template.Spec.Containers[0].Image)
	assert.Equal(t, "slim-svc-sa", deploy.Spec.Template.Spec.ServiceAccountName)

	container := deploy.Spec.Template.Spec.Containers[0]
	assert.Len(t, container.Ports, 2)
	assert.Equal(t, int32(8080), container.Ports[0].ContainerPort)
	assert.Equal(t, int32(8088), container.Ports[1].ContainerPort)

	assert.NotNil(t, container.LivenessProbe)
	assert.Equal(t, "/health", container.LivenessProbe.HTTPGet.Path)
	assert.NotNil(t, container.ReadinessProbe)
	assert.NotNil(t, container.StartupProbe)
	assert.Equal(t, int32(30), container.StartupProbe.InitialDelaySeconds)
	assert.Equal(t, int32(10), container.StartupProbe.FailureThreshold)

	hasPlatformURL := false
	for _, e := range container.Env {
		if e.Name == "PLATFORM_URL" {
			hasPlatformURL = true
			assert.Equal(t, "ray.default.svc.cluster.local:8000/ai-platform-models/v1", e.Value)
		}
	}
	assert.True(t, hasPlatformURL, "PLATFORM_URL env var should be set")

	assert.Len(t, container.VolumeMounts, 1)
	assert.Equal(t, "/etc/config", container.VolumeMounts[0].MountPath)
}

func Test_reconcileSlimDeployment_mtls(t *testing.T) {
	os.Setenv("RELATED_IMAGE_SLIM_API", "splunk/slim-api:latest")
	defer os.Unsetenv("RELATED_IMAGE_SLIM_API")

	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
		Spec: aiv1.AIServiceSpec{
			AIPlatformUrl:      "ray.default.svc.cluster.local:8000",
			ServiceAccountName: "slim-svc-sa",
			Replicas:           1,
			MTLS: aiv1.MTLSConfig{
				Enabled:     true,
				Termination: "operator",
				SecretName:  "tls-secret",
			},
			Resources: corev1.ResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("1"),
					corev1.ResourceMemory: resource.MustParse("1Gi"),
				},
				Limits: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("1"),
					corev1.ResourceMemory: resource.MustParse("1Gi"),
				},
			},
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileSlimDeployment(context.Background(), ai)
	assert.NoError(t, err)

	deploy := &appsv1.Deployment{}
	_ = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-slim-deployment", Namespace: "default",
	}, deploy)

	container := deploy.Spec.Template.Spec.Containers[0]
	assert.Len(t, container.Ports, 3)

	portNames := make([]string, len(container.Ports))
	for i, p := range container.Ports {
		portNames[i] = p.Name
	}
	assert.Contains(t, portNames, "https")

	hasTLSCert := false
	for _, e := range container.Env {
		if e.Name == "TLS_CERT_FILE" {
			hasTLSCert = true
			assert.Equal(t, "/etc/tls/tls.crt", e.Value)
		}
	}
	assert.True(t, hasTLSCert, "TLS_CERT_FILE should be set when mTLS is enabled")

	assert.Len(t, container.VolumeMounts, 2)
	hasTLSMount := false
	for _, vm := range container.VolumeMounts {
		if vm.Name == "tls" {
			hasTLSMount = true
			assert.Equal(t, "/etc/tls", vm.MountPath)
			assert.True(t, vm.ReadOnly)
		}
	}
	assert.True(t, hasTLSMount, "TLS volume mount should exist")
}

// ---------- reconcileSlimService ----------

func Test_reconcileSlimService_creates(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileSlimService(context.Background(), ai)
	assert.NoError(t, err)

	svc := &corev1.Service{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-slim-service", Namespace: "default",
	}, svc)
	assert.NoError(t, err)
	assert.Equal(t, corev1.ServiceTypeClusterIP, svc.Spec.Type)
	assert.Len(t, svc.Spec.Ports, 2)
	assert.Equal(t, int32(8080), svc.Spec.Ports[0].Port)
	assert.Equal(t, int32(8088), svc.Spec.Ports[1].Port)
}

func Test_reconcileSlimService_mtls(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
		Spec: aiv1.AIServiceSpec{
			MTLS: aiv1.MTLSConfig{
				Enabled:     true,
				Termination: "operator",
				SecretName:  "tls-secret",
			},
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileSlimService(context.Background(), ai)
	assert.NoError(t, err)

	svc := &corev1.Service{}
	_ = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-slim-service", Namespace: "default",
	}, svc)
	assert.Len(t, svc.Spec.Ports, 3)

	portNames := make([]string, len(svc.Spec.Ports))
	for i, p := range svc.Spec.Ports {
		portNames[i] = p.Name
	}
	assert.Contains(t, portNames, "https")
}

func Test_reconcileSlimService_nodePort(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
		Spec: aiv1.AIServiceSpec{
			ServiceTemplate: corev1.Service{
				Spec: corev1.ServiceSpec{
					Type: corev1.ServiceTypeNodePort,
					Ports: []corev1.ServicePort{
						{Name: "http", NodePort: 30080},
					},
				},
			},
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileSlimService(context.Background(), ai)
	assert.NoError(t, err)

	svc := &corev1.Service{}
	_ = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-slim-service", Namespace: "default",
	}, svc)
	assert.Equal(t, corev1.ServiceTypeNodePort, svc.Spec.Type)
}

// ---------- reconcileServiceMonitor ----------

func Test_reconcileServiceMonitor_disabled(t *testing.T) {
	r, _ := newTestReconciler(t)

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "slim-svc", Namespace: "default"},
		Spec: aiv1.AIServiceSpec{
			Metrics: aiv1.MetricsConfig{Enabled: false},
		},
	}

	err := r.reconcileServiceMonitor(context.Background(), ai)
	assert.NoError(t, err)
}

func Test_reconcileServiceMonitor_creates(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
		Spec: aiv1.AIServiceSpec{
			Metrics: aiv1.MetricsConfig{
				Enabled: true,
				Path:    "/metrics",
			},
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileServiceMonitor(context.Background(), ai)
	assert.NoError(t, err)

	sm := &monitoringv1.ServiceMonitor{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-metrics", Namespace: "default",
	}, sm)
	assert.NoError(t, err)
	assert.Equal(t, "metrics", sm.Spec.Endpoints[0].Port)
	assert.Equal(t, "/metrics", sm.Spec.Endpoints[0].Path)
}

// ---------- helper functions ----------

func Test_cleanServiceTemplate(t *testing.T) {
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			UID:             "some-uid",
			ResourceVersion: "12345",
			Generation:      3,
		},
	}

	cleanServiceTemplate(svc)

	assert.Empty(t, string(svc.UID))
	assert.Empty(t, svc.ResourceVersion)
	assert.Equal(t, int64(0), svc.Generation)
}

func Test_cleanServiceTemplate_nil(t *testing.T) {
	cleanServiceTemplate(nil)
}

func Test_hasOwnerReference(t *testing.T) {
	owner := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{UID: "owner-uid"},
	}

	owned := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			OwnerReferences: []metav1.OwnerReference{
				{UID: "owner-uid"},
			},
		},
	}

	notOwned := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			OwnerReferences: []metav1.OwnerReference{
				{UID: "other-uid"},
			},
		},
	}

	assert.True(t, hasOwnerReference(owned, owner))
	assert.False(t, hasOwnerReference(notOwned, owner))
}

func Test_createOrUpdateConfigMap(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	data := map[string]string{"KEY": "value"}
	err := r.createOrUpdateConfigMap(context.Background(), "test-cm", data, ai)
	assert.NoError(t, err)

	cm := &corev1.ConfigMap{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{Name: "test-cm", Namespace: "default"}, cm)
	assert.NoError(t, err)
	assert.Equal(t, "value", cm.Data["KEY"])

	data["KEY"] = "updated"
	err = r.createOrUpdateConfigMap(context.Background(), "test-cm", data, ai)
	assert.NoError(t, err)

	_ = fakeClient.Get(context.Background(), types.NamespacedName{Name: "test-cm", Namespace: "default"}, cm)
	assert.Equal(t, "updated", cm.Data["KEY"])
}

// ---------- Reconcile (integration) ----------

func Test_Reconcile_failsWithoutImage(t *testing.T) {
	os.Unsetenv("RELATED_IMAGE_SLIM_API")

	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(s).
		WithObjects(ai).
		WithStatusSubresource(ai).
		Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.Reconcile(context.Background(), ai)
	assert.Error(t, err)
	assert.ErrorContains(t, err, "RELATED_IMAGE_SLIM_API must be set")

	found := false
	for _, c := range ai.Status.Conditions {
		if c.Type == "ValidateReady" {
			found = true
			assert.Equal(t, metav1.ConditionFalse, c.Status)
		}
	}
	assert.True(t, found, "ValidateReady condition should exist")
}

func Test_Reconcile_stageOrdering(t *testing.T) {
	os.Setenv("RELATED_IMAGE_SLIM_API", "splunk/slim-api:latest")
	defer os.Unsetenv("RELATED_IMAGE_SLIM_API")

	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "slim-svc",
			Namespace: "default",
			UID:       "test-uid",
		},
		Spec: aiv1.AIServiceSpec{
			AIPlatformUrl: "ray.default.svc.cluster.local:8000",
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(s).
		WithObjects(ai).
		WithStatusSubresource(ai).
		Build()
	recorder := record.NewFakeRecorder(20)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.Reconcile(context.Background(), ai)

	// mTLS is disabled so Certificate stage should pass, and metrics are disabled
	// so ServiceMonitor should pass. All stages should succeed.
	if err != nil {
		fmt.Printf("Reconcile error (may be expected): %v\n", err)
	}

	expectedStages := []string{
		"ValidateReady",
		"ServiceAccountReady",
		"SlimConfigMapReady",
		"FeatureConfigMapReady",
		"OtelConfigMapReady",
	}

	condTypes := make(map[string]bool)
	for _, c := range ai.Status.Conditions {
		condTypes[c.Type] = true
	}

	for _, stage := range expectedStages {
		assert.True(t, condTypes[stage], "Expected condition %s to be set", stage)
	}
}

// ---------- reconcileOtelConfigMap ----------

func Test_reconcileOtelConfigMap_skipsWhenOtelDisabled(t *testing.T) {
	s := buildTestScheme(t)
	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "plat", Namespace: "default"},
		Spec: aiv1.AIPlatformSpec{
			Sidecars: aiv1.SidecarSpec{Otel: false},
		},
	}

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "slim-svc", Namespace: "default", UID: "test-uid"},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat", Namespace: "default"},
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai, plat).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileOtelConfigMap(context.Background(), ai)
	assert.NoError(t, err)

	cm := &corev1.ConfigMap{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-otel-config", Namespace: "default",
	}, cm)
	assert.Error(t, err, "OTEL ConfigMap should not be created when OTEL is disabled")
}

func Test_reconcileOtelConfigMap_createsWhenOtelEnabled(t *testing.T) {
	s := buildTestScheme(t)
	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "plat", Namespace: "default"},
		Spec: aiv1.AIPlatformSpec{
			Sidecars: aiv1.SidecarSpec{Otel: true},
			SplunkConfiguration: aiv1.SplunkConfigurationSpec{
				Endpoint:  "https://splunk:8088",
				SecretRef: corev1.SecretReference{Name: "splunk-secret"},
			},
		},
	}

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "slim-svc", Namespace: "default", UID: "test-uid"},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat", Namespace: "default"},
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai, plat).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileOtelConfigMap(context.Background(), ai)
	assert.NoError(t, err)

	cm := &corev1.ConfigMap{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-otel-config", Namespace: "default",
	}, cm)
	assert.NoError(t, err)
	assert.Contains(t, cm.Data["otel-config.yaml"], "slim-api-metrics")
	assert.Contains(t, cm.Data["otel-config.yaml"], "localhost:8088")
	assert.Contains(t, cm.Data["otel-config.yaml"], "splunk_hec/metrics")
	assert.Contains(t, cm.Data["otel-config.yaml"], "splunk_hec/logs")
	assert.Contains(t, cm.Data["otel-config.yaml"], "https://splunk:8088/services/collector")
}

// ---------- OTEL sidecar in deployment ----------

func Test_reconcileSlimDeployment_withOtelSidecar(t *testing.T) {
	os.Setenv("RELATED_IMAGE_SLIM_API", "splunk/slim-api:latest")
	os.Setenv("RELATED_IMAGE_OTEL_COLLECTOR", "otel/collector:test")
	defer os.Unsetenv("RELATED_IMAGE_SLIM_API")
	defer os.Unsetenv("RELATED_IMAGE_OTEL_COLLECTOR")

	s := buildTestScheme(t)
	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "plat", Namespace: "default"},
		Spec: aiv1.AIPlatformSpec{
			Sidecars: aiv1.SidecarSpec{Otel: true},
			SplunkConfiguration: aiv1.SplunkConfigurationSpec{
				Endpoint:  "https://splunk:8088",
				SecretRef: corev1.SecretReference{Name: "splunk-secret"},
			},
		},
	}

	otelCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: "slim-svc-otel-config", Namespace: "default"},
		Data:       map[string]string{"otel-config.yaml": "receivers: {}"},
	}

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "slim-svc", Namespace: "default", UID: "test-uid"},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef:      corev1.ObjectReference{Name: "plat", Namespace: "default"},
			AIPlatformUrl:      "ray.default.svc.cluster.local:8000",
			ServiceAccountName: "slim-sa",
			Replicas:           1,
			SplunkConfiguration: aiv1.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{Name: "splunk-secret"},
			},
			Resources: corev1.ResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("1"),
					corev1.ResourceMemory: resource.MustParse("1Gi"),
				},
				Limits: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("1"),
					corev1.ResourceMemory: resource.MustParse("1Gi"),
				},
			},
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai, plat, otelCM).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileSlimDeployment(context.Background(), ai)
	assert.NoError(t, err)

	deploy := &appsv1.Deployment{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-slim-deployment", Namespace: "default",
	}, deploy)
	assert.NoError(t, err)

	assert.Len(t, deploy.Spec.Template.Spec.Containers, 2, "should have slim-api + otel-collector")

	otelContainer := deploy.Spec.Template.Spec.Containers[1]
	assert.Equal(t, "otel-collector", otelContainer.Name)
	assert.Equal(t, "otel/collector:test", otelContainer.Image)
	assert.Len(t, otelContainer.Ports, 3)

	portNames := make([]string, len(otelContainer.Ports))
	for i, p := range otelContainer.Ports {
		portNames[i] = p.Name
	}
	assert.Contains(t, portNames, "otlp-grpc")
	assert.Contains(t, portNames, "otlp-http")
	assert.Contains(t, portNames, "otel-metrics")

	hasOtelVolume := false
	for _, v := range deploy.Spec.Template.Spec.Volumes {
		if v.Name == "otel-config" {
			hasOtelVolume = true
		}
	}
	assert.True(t, hasOtelVolume, "otel-config volume should be present")
}

// ---------- OTEL port on Service ----------

func Test_reconcileSlimService_withOtelPort(t *testing.T) {
	s := buildTestScheme(t)
	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "plat", Namespace: "default"},
		Spec: aiv1.AIPlatformSpec{
			Sidecars: aiv1.SidecarSpec{Otel: true},
		},
	}

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "slim-svc", Namespace: "default", UID: "test-uid"},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat", Namespace: "default"},
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai, plat).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileSlimService(context.Background(), ai)
	assert.NoError(t, err)

	svc := &corev1.Service{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-slim-service", Namespace: "default",
	}, svc)
	assert.NoError(t, err)
	assert.Len(t, svc.Spec.Ports, 3, "should have http + metrics + otel-metrics")

	portNames := make([]string, len(svc.Spec.Ports))
	for i, p := range svc.Spec.Ports {
		portNames[i] = p.Name
	}
	assert.Contains(t, portNames, "otel-metrics")
}

// ---------- isOtelEnabled ----------

func Test_isOtelEnabled_true(t *testing.T) {
	s := buildTestScheme(t)
	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "plat", Namespace: "default"},
		Spec:       aiv1.AIPlatformSpec{Sidecars: aiv1.SidecarSpec{Otel: true}},
	}

	ai := &aiv1.AIService{
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat", Namespace: "default"},
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(plat).Build()
	r := &SlimReconciler{Client: fakeClient, Scheme: s}

	assert.True(t, r.isOtelEnabled(context.Background(), ai))
}

func Test_isOtelEnabled_false(t *testing.T) {
	s := buildTestScheme(t)
	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "plat", Namespace: "default"},
		Spec:       aiv1.AIPlatformSpec{Sidecars: aiv1.SidecarSpec{Otel: false}},
	}

	ai := &aiv1.AIService{
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat", Namespace: "default"},
		},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(plat).Build()
	r := &SlimReconciler{Client: fakeClient, Scheme: s}

	assert.False(t, r.isOtelEnabled(context.Background(), ai))
}

func Test_isOtelEnabled_noPlatformRef(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{}

	fakeClient := fake.NewClientBuilder().WithScheme(s).Build()
	r := &SlimReconciler{Client: fakeClient, Scheme: s}

	assert.False(t, r.isOtelEnabled(context.Background(), ai))
}

// ---------- ConfigMap OTEL defaults ----------

func Test_reconcileSlimConfigMap_hasOtelDefaults(t *testing.T) {
	s := buildTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "slim-svc", Namespace: "default", UID: "test-uid"},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(s).WithObjects(ai).Build()
	recorder := record.NewFakeRecorder(10)
	r := &SlimReconciler{Client: fakeClient, Scheme: s, Recorder: recorder}

	err := r.reconcileSlimConfigMap(context.Background(), ai)
	assert.NoError(t, err)

	cm := &corev1.ConfigMap{}
	_ = fakeClient.Get(context.Background(), types.NamespacedName{
		Name: "slim-svc-slim-config", Namespace: "default",
	}, cm)
	assert.Equal(t, "true", cm.Data["OTEL_ENABLED"])
	assert.Equal(t, "http://localhost:4317", cm.Data["OTEL_EXPORTER_OTLP_ENDPOINT"])
	assert.Equal(t, "slim-api", cm.Data["OTEL_SERVICE_NAME"])
	assert.Equal(t, "json", cm.Data["LOG_FORMAT"])
	assert.Equal(t, "otlp", cm.Data["OTEL_METRICS_EXPORTER"])
	assert.Equal(t, "otlp", cm.Data["OTEL_LOGS_EXPORTER"])
}
