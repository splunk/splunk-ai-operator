package ai_platform

import (
	"context"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	//corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	//"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	//"sigs.k8s.io/controller-runtime/pkg/client"
	corev1 "k8s.io/api/core/v1"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

/*
func buildTestScheme(t *testing.T) *runtime.Scheme {
	s := runtime.NewScheme()
	err := aiApi.AddToScheme(s)
	assert.NoError(t, err)
	err = corev1.AddToScheme(s)
	assert.NoError(t, err)
	return s
} */

func TestBuildAIService_PopulatesExpectedFields(t *testing.T) {
	scheme := buildTestScheme(t)

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-ai",
			Namespace: "default",
		},
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: aiApi.ObjectStorageSpec{Path: "/data"},
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				Endpoint: "splunk-endpoint",
			},
			MTLS: aiApi.MTLSConfig{Enabled: true, Termination: "operator"},
		},
		Status: aiApi.AIPlatformStatus{
			RayServiceName:      "ray-head",
			VectorDbServiceName: "weaviate-db",
		},
	}

	feature := aiApi.FeatureSpec{
		Name:               "feature1",
		Version:            "v1",
		ServiceAccountName: "svc-account",
	}

	r := &AIPlatformReconciler{Scheme: scheme}

	service := r.buildAIService(context.Background(), platform, feature, "my-ai-feature1")

	assert.Equal(t, "my-ai-feature1", service.Name)
	assert.Equal(t, "default", service.Namespace)
	assert.Equal(t, "feature1", service.Spec.Feature.Name)
	assert.Equal(t, "svc-account", service.Spec.ServiceAccountName)
	assert.Equal(t, "weaviate-db", service.Spec.VectorDbUrl)
	assert.Equal(t, int32(1), service.Spec.Replicas)
	assert.True(t, service.Spec.Metrics.Enabled)
	assert.Equal(t, "/metrics", service.Spec.Metrics.Path)

	// Labels should include platform and feature
	assert.Equal(t, "my-ai", service.Labels["aiplatform"])
	assert.Equal(t, "feature1", service.Labels["feature"])
}

func TestBuildAIService_PropagatesServiceTemplate(t *testing.T) {
	// Customers configure public exposure (NodePort / LoadBalancer) at the
	// AIPlatform level. Without propagation, the setting is silently dropped
	// and SAIA is never reachable outside the cluster. This test locks in the
	// contract that AIPlatform.spec.serviceTemplate flows into AIService.
	scheme := buildTestScheme(t)

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "my-ai", Namespace: "default"},
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: aiApi.ObjectStorageSpec{Path: "/data"},
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				Endpoint: "splunk-endpoint",
			},
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
	feature := aiApi.FeatureSpec{Name: "saia", Version: "v1"}
	r := &AIPlatformReconciler{Scheme: scheme}

	service := r.buildAIService(context.Background(), platform, feature, "my-ai-saia")

	assert.Equal(t, corev1.ServiceTypeNodePort, service.Spec.ServiceTemplate.Spec.Type,
		"NodePort selection must propagate so customers can expose SAIA")
	if assert.Len(t, service.Spec.ServiceTemplate.Spec.Ports, 1) {
		assert.Equal(t, int32(30080), service.Spec.ServiceTemplate.Spec.Ports[0].NodePort,
			"explicit NodePort must propagate")
	}

	// Mutating the child spec must not affect the parent (deep-copy check).
	service.Spec.ServiceTemplate.Spec.Ports[0].NodePort = 31234
	assert.Equal(t, int32(30080), platform.Spec.ServiceTemplate.Spec.Ports[0].NodePort,
		"buildAIService must deep-copy ServiceTemplate to avoid shared state")
}

func TestReconcileFeatures_CreatesNewAIService(t *testing.T) {
	ctx := context.Background()
	scheme := buildTestScheme(t)

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-ai",
			Namespace: "default",
			UID:       types.UID("test-ai-uid"), // set a stable UID for owner lookups
		},
		Spec: aiApi.AIPlatformSpec{
			Features: []aiApi.FeatureSpec{
				{Name: "feature1", Version: "v1", ServiceAccountName: "svc-account"},
			},
			ObjectStorage: aiApi.ObjectStorageSpec{Path: "/data"},
		},
		Status: aiApi.AIPlatformStatus{
			RayServiceName:      "ray-head",
			VectorDbServiceName: "weaviate-db",
		},
	}

	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(corev1.AddToScheme(scheme))
	utilruntime.Must(aiApi.AddToScheme(scheme))

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(platform).
		// if your reconciler updates status for AIService in tests, include this line
		WithStatusSubresource(&aiApi.AIService{}).
		// register the controller owner index used by MatchingFields(".metadata.controller", <UID>)
		WithIndex(&aiApi.AIService{}, ".metadata.controller", func(obj client.Object) []string {
			// use the apimachinery helper to read the controller OwnerRef
			if owner := metav1.GetControllerOfNoCopy(obj); owner != nil {
				// only index when this owner is marked as controller
				if owner.Controller != nil && *owner.Controller {
					return []string{string(owner.UID)}
				}
			}
			return nil
		}).
		Build()

	reconciler := &AIPlatformReconciler{
		Client: fakeClient,
		Scheme: scheme,
	}

	// Act
	err := reconciler.ReconcileFeatures(ctx, platform)
	assert.NoError(t, err)

	// Assert
	created := &aiApi.AIService{}
	serviceKey := types.NamespacedName{Name: "my-ai-feature1", Namespace: "default"}
	err = fakeClient.Get(ctx, serviceKey, created)
	assert.NoError(t, err, "AIService should have been created")

	assert.Equal(t, "feature1", created.Spec.Feature.Name)
	assert.Equal(t, "my-ai", created.Spec.AIPlatformRef.Name)
	assert.Equal(t, "weaviate-db", created.Spec.VectorDbUrl)
}

func TestReconcileFeatures_CreatesAgentRuntimeServicePerProvider(t *testing.T) {
	ctx := context.Background()
	scheme := buildTestScheme(t)

	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(corev1.AddToScheme(scheme))
	utilruntime.Must(aiApi.AddToScheme(scheme))

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-ai",
			Namespace: "default",
			UID:       types.UID("test-ai-uid"),
		},
		Spec: aiApi.AIPlatformSpec{
			Features: []aiApi.FeatureSpec{
				{
					Name:                  "agentruntime",
					Provider:              "mltk",
					Version:               "0.1.0",
					RuntimeVersion:        "v2.0.0",
					MinReplicas:           int32PtrForReconcilerTest(1),
					MaxReplicas:           int32PtrForReconcilerTest(4),
					TargetCPUUtilization:  int32PtrForReconcilerTest(60),
					CheckpointDbSecretRef: "mltk-postgres",
					ServiceAccountName:    "mltk-sa",
				},
				{
					Name:                  "agentruntime",
					Provider:              "seca",
					Version:               "0.2.0",
					MinReplicas:           int32PtrForReconcilerTest(2),
					MaxReplicas:           int32PtrForReconcilerTest(5),
					TargetCPUUtilization:  int32PtrForReconcilerTest(70),
					CheckpointDbSecretRef: "seca-postgres",
				},
			},
			ObjectStorage: aiApi.ObjectStorageSpec{Path: "/data"},
			CPUSchedulingSpec: &aiApi.SchedulingSpec{
				NodeSelector: map[string]string{"splunk.ai/workload-type": "cpu"},
			},
		},
		Status: aiApi.AIPlatformStatus{
			RayServiceName:      "ray-head",
			VectorDbServiceName: "weaviate-db",
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(platform).
		WithStatusSubresource(&aiApi.AIService{}).
		WithIndex(&aiApi.AIService{}, ".metadata.controller", func(obj client.Object) []string {
			if owner := metav1.GetControllerOfNoCopy(obj); owner != nil {
				if owner.Controller != nil && *owner.Controller {
					return []string{string(owner.UID)}
				}
			}
			return nil
		}).
		Build()

	reconciler := &AIPlatformReconciler{
		Client: fakeClient,
		Scheme: scheme,
	}

	require.NoError(t, reconciler.ReconcileFeatures(ctx, platform))

	mltk := &aiApi.AIService{}
	require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Name: "my-ai-agentruntime-mltk", Namespace: "default"}, mltk))
	assert.Equal(t, "agentruntime", mltk.Spec.Feature.Name)
	assert.Equal(t, "mltk", mltk.Spec.Feature.Provider)
	assert.Equal(t, "mltk", mltk.Labels["provider"])
	assert.Equal(t, "v2.0.0", mltk.Spec.RuntimeVersion)
	assert.Equal(t, "mltk-postgres", mltk.Spec.CheckpointDbSecretRef)
	require.NotNil(t, mltk.Spec.TargetCPUUtilization)
	assert.Equal(t, int32(60), *mltk.Spec.TargetCPUUtilization)
	assert.Equal(t, int32(1), mltk.Spec.Replicas)
	assert.Equal(t, int32(80), mltk.Spec.Port)
	assert.Equal(t, "http", mltk.Spec.AIPlatformScheme)
	assert.Equal(t, "http://ray-head.default.svc.cluster.local:8000", mltk.Spec.AIPlatformUrl)
	assert.Equal(t, "cluster.local", mltk.Spec.ClusterDomain)
	assert.Equal(t, "mltk-sa", mltk.Spec.ServiceAccountName)
	assert.Equal(t, map[string]string{"splunk.ai/workload-type": "cpu"}, mltk.Spec.NodeSelector)
	assert.True(t, resourceRequirementsNonEmpty(mltk.Spec.Resources))
	assert.Equal(t, int32(1), mltk.Spec.V2.Replicas)
	assert.Equal(t, int32(1), mltk.Spec.V2Worker.Replicas)

	seca := &aiApi.AIService{}
	require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Name: "my-ai-agentruntime-seca", Namespace: "default"}, seca))
	assert.Equal(t, "seca", seca.Spec.Feature.Provider)
	assert.Equal(t, int32(2), seca.Spec.Replicas)
	assert.Equal(t, "seca-postgres", seca.Spec.CheckpointDbSecretRef)
	assert.Equal(t, "my-ai-agentruntime-seca-sa", seca.Spec.ServiceAccountName)
}

func TestFeatureServiceName_BoundsLongAgentRuntimeName(t *testing.T) {
	shortName := featureServiceName("my-ai", aiApi.FeatureSpec{Name: "agentruntime", Provider: "mltk"})
	assert.Equal(t, "my-ai-agentruntime-mltk", shortName)

	longPlatformName := "very-long-ai-platform-name-for-agent-runtime-provider-name-bounds"
	longName := featureServiceName(longPlatformName, aiApi.FeatureSpec{Name: "agentruntime", Provider: "mltk"})
	require.LessOrEqual(t, len(longName), maxDNSLabelLength)
	assert.NotEqual(t, longPlatformName+"-agentruntime-mltk", longName)
}

func TestBuildAIService_BoundsLongAIPlatformLabel(t *testing.T) {
	scheme := buildTestScheme(t)
	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "very-long-ai-platform-name-for-agent-runtime-provider-name-bounds",
			Namespace: "default",
		},
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: aiApi.ObjectStorageSpec{Path: "/data"},
		},
	}
	feature := aiApi.FeatureSpec{Name: "agentruntime", Provider: "mltk"}
	r := &AIPlatformReconciler{Scheme: scheme}

	service := r.buildAIService(context.Background(), platform, feature, featureServiceName(platform.Name, feature))

	require.LessOrEqual(t, len(service.Labels["aiplatform"]), maxDNSLabelLength)
	assert.NotEqual(t, platform.Name, service.Labels["aiplatform"])
}

func int32PtrForReconcilerTest(value int32) *int32 {
	return &value
}

func TestReconcileFeatures_DoesNotRecreateExistingAIService(t *testing.T) {
	ctx := context.Background()
	scheme := buildTestScheme(t)

	// Register schemes
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(corev1.AddToScheme(scheme))
	utilruntime.Must(aiApi.AddToScheme(scheme))

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-ai",
			Namespace: "default",
			UID:       types.UID("test-ai-uid"),
		},
		Spec: aiApi.AIPlatformSpec{
			Features: []aiApi.FeatureSpec{
				{Name: "feature1", Version: "v1", ServiceAccountName: "svc-account"},
			},
			ObjectStorage: aiApi.ObjectStorageSpec{Path: "/data"},
		},
		Status: aiApi.AIPlatformStatus{
			VectorDbServiceName: "weaviate-db",
		},
	}

	// Existing AIService that is already owned by the platform
	existingService := &aiApi.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-ai-feature1",
			Namespace: "default",
		},
	}
	// Set controller owner reference so the indexer can find it
	require.NoError(t, controllerutil.SetControllerReference(platform, existingService, scheme))

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(platform, existingService).
		// If your reconcile touches status on AIService, keep this
		WithStatusSubresource(&aiApi.AIService{}).
		// Register the field index used by MatchingFields(".metadata.controller", ownerUID)
		WithIndex(&aiApi.AIService{}, ".metadata.controller", func(obj client.Object) []string {
			if owner := metav1.GetControllerOfNoCopy(obj); owner != nil {
				if owner.Controller != nil && *owner.Controller {
					return []string{string(owner.UID)}
				}
			}
			return nil
		}).
		Build()

	reconciler := &AIPlatformReconciler{
		Client: fakeClient,
		Scheme: scheme,
	}

	// Act, should not recreate the service
	err := reconciler.ReconcileFeatures(ctx, platform)
	assert.NoError(t, err)

	// Assert, still exactly one AIService with the same name
	fetched := &aiApi.AIService{}
	serviceKey := types.NamespacedName{Name: "my-ai-feature1", Namespace: "default"}
	err = fakeClient.Get(ctx, serviceKey, fetched)
	assert.NoError(t, err)
	assert.Equal(t, "my-ai-feature1", fetched.Name)
}

func TestCheckAIServiceStatus_SuccessWhenAllServicesHealthy(t *testing.T) {
	ctx := context.Background()
	scheme := buildTestScheme(t)

	// Register schemes
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(corev1.AddToScheme(scheme))
	utilruntime.Must(aiApi.AddToScheme(scheme))

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-ai",
			Namespace: "default",
			UID:       types.UID("test-ai-uid"),
		},
	}

	// Healthy AIService with all conditions True
	healthyService := &aiApi.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-ai-feature1",
			Namespace: "default",
		},
		Status: aiApi.AIServiceStatus{
			Conditions: []metav1.Condition{
				{
					Type:   "ValidateReady",
					Status: metav1.ConditionTrue,
					Reason: "Reconciled",
				},
				{
					Type:   "ServiceAccountReady",
					Status: metav1.ConditionTrue,
					Reason: "Reconciled",
				},
			},
		},
	}
	require.NoError(t, controllerutil.SetControllerReference(platform, healthyService, scheme))

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(platform, healthyService).
		WithStatusSubresource(&aiApi.AIService{}).
		WithIndex(&aiApi.AIService{}, ".metadata.controller", func(obj client.Object) []string {
			if owner := metav1.GetControllerOfNoCopy(obj); owner != nil {
				if owner.Controller != nil && *owner.Controller {
					return []string{owner.Name}
				}
			}
			return nil
		}).
		Build()

	reconciler := &AIPlatformReconciler{
		Client: fakeClient,
		Scheme: scheme,
	}

	// Act
	err := reconciler.CheckAIServiceStatus(ctx, platform)

	// Assert - should succeed when all services are healthy
	assert.NoError(t, err)
}

func TestCheckAIServiceStatus_FailsWhenServiceHasFailedCondition(t *testing.T) {
	ctx := context.Background()
	scheme := buildTestScheme(t)

	// Register schemes
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(corev1.AddToScheme(scheme))
	utilruntime.Must(aiApi.AddToScheme(scheme))

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-ai",
			Namespace: "default",
			UID:       types.UID("test-ai-uid"),
		},
	}

	// AIService with a failed condition
	failedService := &aiApi.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-ai-feature1",
			Namespace: "default",
		},
		Status: aiApi.AIServiceStatus{
			Conditions: []metav1.Condition{
				{
					Type:   "ValidateReady",
					Status: metav1.ConditionTrue,
					Reason: "Reconciled",
				},
				{
					Type:    "PostInstallHookReady",
					Status:  metav1.ConditionFalse,
					Reason:  "Error",
					Message: "job \"splunk-ai-stack-saia-vector-db-setup-posthook\" is still running",
				},
			},
		},
	}
	require.NoError(t, controllerutil.SetControllerReference(platform, failedService, scheme))

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(platform, failedService).
		WithStatusSubresource(&aiApi.AIService{}).
		WithIndex(&aiApi.AIService{}, ".metadata.controller", func(obj client.Object) []string {
			if owner := metav1.GetControllerOfNoCopy(obj); owner != nil {
				if owner.Controller != nil && *owner.Controller {
					return []string{owner.Name}
				}
			}
			return nil
		}).
		Build()

	reconciler := &AIPlatformReconciler{
		Client: fakeClient,
		Scheme: scheme,
	}

	// Act
	err := reconciler.CheckAIServiceStatus(ctx, platform)

	// Assert - should fail when service has failed condition
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "my-ai-feature1")
	assert.Contains(t, err.Error(), "PostInstallHookReady")
	assert.Contains(t, err.Error(), "still running")
}
