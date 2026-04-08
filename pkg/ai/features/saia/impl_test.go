package saia

import (
	"context"
	//"errors"
	"os"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	"github.com/stretchr/testify/assert"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func buildTestScheme(t *testing.T) *runtime.Scheme {
	s := runtime.NewScheme()
	err := aiv1.AddToScheme(s)
	assert.NoError(t, err)
	err = corev1.AddToScheme(s)
	assert.NoError(t, err)
	return s
}

func Test_validateAIService_missingEnv(t *testing.T) {
	os.Unsetenv("RELATED_IMAGE_POST_INSTALL_HOOK")
	recorder := record.NewFakeRecorder(10)

	// Fake client not needed here since it fails early
	r := &SaiaReconciler{
		Recorder: recorder,
		Client:   fake.NewClientBuilder().WithScheme(buildTestScheme(t)).Build(),
	}

	ai := &aiv1.AIService{}
	err := r.validateAIService(context.Background(), ai)
	assert.ErrorContains(t, err, "RELATED_IMAGE_POST_INSTALL_HOOK must be set")
}

func Test_validateAIService_missingPlatformRefAndUrl(t *testing.T) {
	os.Setenv("RELATED_IMAGE_POST_INSTALL_HOOK", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_POST_INSTALL_HOOK")

	recorder := record.NewFakeRecorder(10)
	r := &SaiaReconciler{
		Recorder: recorder,
		Client:   fake.NewClientBuilder().WithScheme(buildTestScheme(t)).Build(),
	}

	ai := &aiv1.AIService{}
	err := r.validateAIService(context.Background(), ai)
	assert.ErrorContains(t, err, "either AIPlatformRef.Name or AIPlatformUrl must be set")
}

func Test_validateAIService_defaults(t *testing.T) {
	os.Setenv("RELATED_IMAGE_POST_INSTALL_HOOK", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_POST_INSTALL_HOOK")

	scheme := buildTestScheme(t)

	// Create a fake AIPlatform that is Ready
	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "plat",
			Namespace: "ns",
		},
		Status: aiv1.AIPlatformStatus{
			RayServiceName:      "ray",
			VectorDbServiceName: "vec",
			Conditions: []metav1.Condition{
				{Type: "Ready", Status: metav1.ConditionTrue},
				{Type: "WeaviateDatabaseReady", Status: metav1.ConditionTrue},
			},
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(plat).
		Build()

	recorder := record.NewFakeRecorder(10)
	r := &SaiaReconciler{
		Recorder: recorder,
		Client:   fakeClient,
		Scheme:   scheme,
	}

	// Patch common checks to always succeed
	common.IsConditionTrue = func(conds []metav1.Condition, typ string) bool { return true }
	common.CheckRayHeadService = func(ctx context.Context, endpoint string) error { return nil }
	common.CheckWeaviateService = func(ctx context.Context, endpoint string) error { return nil }

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "ai",
			Namespace: "ns",
		},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat", Namespace: "ns"},
			TaskVolume:    &aiv1.ObjectStorageSpec{Path: "/data"},
		},
	}

	// Should succeed and fill defaults
	err := r.validateAIService(context.Background(), ai)
	assert.NoError(t, err)
	assert.Equal(t, int32(1), ai.Spec.Replicas)
	assert.NotNil(t, ai.Spec.Resources.Requests)
	assert.NotNil(t, ai.Spec.Resources.Limits)
	assert.Equal(t, "ray.ns.svc.cluster.local:8000", ai.Spec.AIPlatformUrl)
	assert.Equal(t, "vec.ns.svc.cluster.local", ai.Spec.VectorDbUrl)
}

func Test_getAIPlatform_success(t *testing.T) {
	scheme := buildTestScheme(t)

	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "plat",
			Namespace: "ns",
		},
	}
	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(plat).
		Build()

	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme}

	ref := corev1.ObjectReference{Name: "plat", Namespace: "ns"}

	got, err := r.getAIPlatform(context.Background(), ref)
	assert.NoError(t, err)
	assert.NotNil(t, got)
	assert.Equal(t, "plat", got.Name)
}

func Test_getAIPlatform_error(t *testing.T) {
	scheme := buildTestScheme(t)

	// No AIPlatform created → should return error
	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		Build()

	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme}

	ref := corev1.ObjectReference{Name: "plat", Namespace: "ns"}
	got, err := r.getAIPlatform(context.Background(), ref)
	assert.Error(t, err)
	assert.Nil(t, got)
}
