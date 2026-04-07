package ai_platform

import (
	"context"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestReconcileIngress_Disabled(t *testing.T) {
	ctx := context.Background()
	ns := "test-ns"
	platformName := "test-platform"

	instance := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      platformName,
			Namespace: ns,
		},
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: aiApi.ObjectStorageSpec{
				Path:   "s3://test-bucket/models",
				Region: "us-west-2",
			},
			// Ingress is nil (disabled by default)
		},
	}

	s := setupSchemeForTests()
	// Add networkingv1 to scheme (needed for delete operation)
	_ = networkingv1.AddToScheme(s)

	fc := fake.NewClientBuilder().WithScheme(s).WithObjects(instance).Build()
	recorder := record.NewFakeRecorder(10)
	r := &AIPlatformReconciler{Client: fc, Scheme: s, Recorder: recorder}

	// Reconcile with ingress disabled
	err := r.ReconcileIngress(ctx, instance)
	assert.NoError(t, err)

	// Verify no Ingress was created
	ingress := &networkingv1.Ingress{}
	err = fc.Get(ctx, types.NamespacedName{Name: platformName, Namespace: ns}, ingress)
	assert.Error(t, err, "Ingress should not exist when disabled")
}

func TestReconcileIngress_Enabled(t *testing.T) {
	ctx := context.Background()
	ns := "test-ns"
	platformName := "test-platform"

	instance := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      platformName,
			Namespace: ns,
			UID:       types.UID("test-uid"),
		},
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: aiApi.ObjectStorageSpec{
				Path:   "s3://test-bucket/models",
				Region: "us-west-2",
			},
			Ingress: &aiApi.IngressSpec{
				Enabled:   true,
				ClassName: "nginx",
				Hosts: []aiApi.IngressHost{
					{
						Host: "ai-test.example.com",
						Paths: []aiApi.IngressPath{
							{
								Path:     "/",
								PathType: "Prefix",
							},
						},
					},
				},
				TLS: []aiApi.IngressTLS{
					{
						Hosts:      []string{"ai-test.example.com"},
						SecretName: "ai-test-tls",
					},
				},
			},
		},
		Status: aiApi.AIPlatformStatus{
			RayServiceName:      "test-ray-service",
			VectorDbServiceName: "test-weaviate",
		},
	}

	s := setupSchemeForTests()
	// Add networkingv1 to scheme
	_ = networkingv1.AddToScheme(s)

	fc := fake.NewClientBuilder().WithScheme(s).WithObjects(instance).Build()
	recorder := record.NewFakeRecorder(10)
	r := &AIPlatformReconciler{Client: fc, Scheme: s, Recorder: recorder}

	// Reconcile with ingress enabled
	err := r.ReconcileIngress(ctx, instance)
	assert.NoError(t, err)

	// Verify Ingress was created
	ingress := &networkingv1.Ingress{}
	err = fc.Get(ctx, types.NamespacedName{Name: platformName, Namespace: ns}, ingress)
	assert.NoError(t, err, "Ingress should be created when enabled")

	// Verify Ingress configuration
	assert.Equal(t, "nginx", *ingress.Spec.IngressClassName)
	assert.Len(t, ingress.Spec.Rules, 1)
	assert.Equal(t, "ai-test.example.com", ingress.Spec.Rules[0].Host)
	assert.Len(t, ingress.Spec.Rules[0].HTTP.Paths, 1)
	assert.Equal(t, "/", ingress.Spec.Rules[0].HTTP.Paths[0].Path)
	assert.Equal(t, networkingv1.PathTypePrefix, *ingress.Spec.Rules[0].HTTP.Paths[0].PathType)

	// Verify TLS configuration
	assert.Len(t, ingress.Spec.TLS, 1)
	assert.Equal(t, []string{"ai-test.example.com"}, ingress.Spec.TLS[0].Hosts)
	assert.Equal(t, "ai-test-tls", ingress.Spec.TLS[0].SecretName)

	// Verify event was recorded
	select {
	case event := <-recorder.Events:
		assert.Contains(t, event, "IngressCreating")
	default:
		t.Error("Expected IngressCreating event to be recorded")
	}
}

func TestReconcileIngress_MultipleHosts(t *testing.T) {
	ctx := context.Background()
	ns := "test-ns"
	platformName := "test-platform"

	instance := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      platformName,
			Namespace: ns,
			UID:       types.UID("test-uid"),
		},
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: aiApi.ObjectStorageSpec{
				Path:   "s3://test-bucket/models",
				Region: "us-west-2",
			},
			Ingress: &aiApi.IngressSpec{
				Enabled:   true,
				ClassName: "nginx",
				Hosts: []aiApi.IngressHost{
					{
						Host: "ai-api.example.com",
						Paths: []aiApi.IngressPath{
							{
								Path:     "/",
								PathType: "Prefix",
							},
						},
					},
					{
						Host: "ai-dashboard.example.com",
						Paths: []aiApi.IngressPath{
							{
								Path:     "/dashboard",
								PathType: "Prefix",
							},
						},
					},
				},
			},
		},
		Status: aiApi.AIPlatformStatus{
			RayServiceName:      "test-ray-service",
			VectorDbServiceName: "test-weaviate",
		},
	}

	s := setupSchemeForTests()
	_ = networkingv1.AddToScheme(s)

	fc := fake.NewClientBuilder().WithScheme(s).WithObjects(instance).Build()
	recorder := record.NewFakeRecorder(10)
	r := &AIPlatformReconciler{Client: fc, Scheme: s, Recorder: recorder}

	// Reconcile
	err := r.ReconcileIngress(ctx, instance)
	assert.NoError(t, err)

	// Verify Ingress was created with multiple hosts
	ingress := &networkingv1.Ingress{}
	err = fc.Get(ctx, types.NamespacedName{Name: platformName, Namespace: ns}, ingress)
	assert.NoError(t, err)

	assert.Len(t, ingress.Spec.Rules, 2)
	assert.Equal(t, "ai-api.example.com", ingress.Spec.Rules[0].Host)
	assert.Equal(t, "ai-dashboard.example.com", ingress.Spec.Rules[1].Host)
}

func TestReconcileIngress_RaylessWeaviatePath(t *testing.T) {
	ctx := context.Background()
	ns := "test-ns"
	platformName := "test-platform"

	instance := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      platformName,
			Namespace: ns,
			UID:       types.UID("test-uid"),
		},
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: aiApi.ObjectStorageSpec{
				Path:   "s3://test-bucket/models",
				Region: "us-west-2",
			},
			Features: []aiApi.FeatureSpec{
				{Name: "weaviate-service"},
			},
			Ingress: &aiApi.IngressSpec{
				Enabled: true,
				Hosts: []aiApi.IngressHost{
					{
						Host: "weaviate.example.com",
						Paths: []aiApi.IngressPath{
							{
								Path:     "/weaviate",
								PathType: "Prefix",
							},
						},
					},
				},
			},
		},
		Status: aiApi.AIPlatformStatus{
			VectorDbServiceName: "test-weaviate",
		},
	}

	s := setupSchemeForTests()
	_ = networkingv1.AddToScheme(s)

	fc := fake.NewClientBuilder().WithScheme(s).WithObjects(instance).Build()
	recorder := record.NewFakeRecorder(10)
	r := &AIPlatformReconciler{Client: fc, Scheme: s, Recorder: recorder}

	err := r.ReconcileIngress(ctx, instance)
	assert.NoError(t, err)

	ingress := &networkingv1.Ingress{}
	err = fc.Get(ctx, types.NamespacedName{Name: platformName, Namespace: ns}, ingress)
	assert.NoError(t, err)
	assert.Equal(t, "test-platform-weaviate-service-weaviate-service", ingress.Spec.Rules[0].HTTP.Paths[0].Backend.Service.Name)
}

func TestReconcileIngress_WeaviatePathFallsBackToRawWeaviateWithoutFeature(t *testing.T) {
	ctx := context.Background()
	ns := "test-ns"
	platformName := "test-platform"

	instance := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      platformName,
			Namespace: ns,
			UID:       types.UID("test-uid"),
		},
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: aiApi.ObjectStorageSpec{
				Path:   "s3://test-bucket/models",
				Region: "us-west-2",
			},
			Ingress: &aiApi.IngressSpec{
				Enabled: true,
				Hosts: []aiApi.IngressHost{
					{
						Host: "weaviate.example.com",
						Paths: []aiApi.IngressPath{
							{
								Path:     "/weaviate",
								PathType: "Prefix",
							},
						},
					},
				},
			},
		},
		Status: aiApi.AIPlatformStatus{
			VectorDbServiceName: "test-weaviate",
		},
	}

	s := setupSchemeForTests()
	_ = networkingv1.AddToScheme(s)

	fc := fake.NewClientBuilder().WithScheme(s).WithObjects(instance).Build()
	recorder := record.NewFakeRecorder(10)
	r := &AIPlatformReconciler{Client: fc, Scheme: s, Recorder: recorder}

	err := r.ReconcileIngress(ctx, instance)
	assert.NoError(t, err)

	ingress := &networkingv1.Ingress{}
	err = fc.Get(ctx, types.NamespacedName{Name: platformName, Namespace: ns}, ingress)
	assert.NoError(t, err)
	assert.Equal(t, "test-weaviate", ingress.Spec.Rules[0].HTTP.Paths[0].Backend.Service.Name)
}

func TestReconcileIngress_RaylessDefaultPathFails(t *testing.T) {
	ctx := context.Background()
	ns := "test-ns"
	platformName := "test-platform"

	instance := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      platformName,
			Namespace: ns,
			UID:       types.UID("test-uid"),
		},
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: aiApi.ObjectStorageSpec{
				Path:   "s3://test-bucket/models",
				Region: "us-west-2",
			},
			Features: []aiApi.FeatureSpec{
				{Name: "weaviate-service"},
			},
			Ingress: &aiApi.IngressSpec{
				Enabled: true,
				Hosts: []aiApi.IngressHost{
					{
						Host: "ai.example.com",
						Paths: []aiApi.IngressPath{
							{
								Path:     "/",
								PathType: "Prefix",
							},
						},
					},
				},
			},
		},
		Status: aiApi.AIPlatformStatus{
			VectorDbServiceName: "test-weaviate",
		},
	}

	s := setupSchemeForTests()
	_ = networkingv1.AddToScheme(s)

	fc := fake.NewClientBuilder().WithScheme(s).WithObjects(instance).Build()
	recorder := record.NewFakeRecorder(10)
	r := &AIPlatformReconciler{Client: fc, Scheme: s, Recorder: recorder}

	err := r.ReconcileIngress(ctx, instance)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "requires Ray")

	ingress := &networkingv1.Ingress{}
	err = fc.Get(ctx, types.NamespacedName{Name: platformName, Namespace: ns}, ingress)
	assert.Error(t, err, "Ingress should not be created when the backend is invalid")
}

func TestUpdateIngressStatus_NotEnabled(t *testing.T) {
	ctx := context.Background()
	ns := "test-ns"
	platformName := "test-platform"

	instance := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      platformName,
			Namespace: ns,
		},
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: aiApi.ObjectStorageSpec{
				Path:   "s3://test-bucket/models",
				Region: "us-west-2",
			},
			// Ingress disabled
		},
		Status: aiApi.AIPlatformStatus{
			Conditions: []metav1.Condition{
				{
					Type:   "IngressReady",
					Status: metav1.ConditionTrue,
				},
			},
		},
	}

	s := setupSchemeForTests()
	fc := fake.NewClientBuilder().WithScheme(s).WithObjects(instance).Build()
	recorder := record.NewFakeRecorder(10)
	r := &AIPlatformReconciler{Client: fc, Scheme: s, Recorder: recorder}

	// Update status with ingress disabled
	err := r.UpdateIngressStatus(ctx, instance)
	assert.NoError(t, err)

	// Verify IngressReady condition was removed
	hasIngressCondition := false
	for _, cond := range instance.Status.Conditions {
		if cond.Type == "IngressReady" {
			hasIngressCondition = true
		}
	}
	assert.False(t, hasIngressCondition, "IngressReady condition should be removed when Ingress is disabled")
}

func TestParsePathType(t *testing.T) {
	tests := []struct {
		input    string
		expected networkingv1.PathType
	}{
		{"Exact", networkingv1.PathTypeExact},
		{"Prefix", networkingv1.PathTypePrefix},
		{"ImplementationSpecific", networkingv1.PathTypeImplementationSpecific},
		{"invalid", networkingv1.PathTypePrefix}, // Default
		{"", networkingv1.PathTypePrefix},        // Default
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result := parsePathType(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func setupSchemeForTestsWithIngress() *runtime.Scheme {
	s := setupSchemeForTests()
	_ = networkingv1.AddToScheme(s)
	return s
}
