package ai_platform

import (
	"context"
	"os"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	//"sigs.k8s.io/controller-runtime/pkg/scheme"
)

func setupSchemeForTests() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = corev1.AddToScheme(s)
	_ = appsv1.AddToScheme(s)
	_ = aiApi.AddToScheme(s)
	return s
}

func TestReconcileWeaviateDatabaseStatus(t *testing.T) {
	ctx := context.Background()
	ns := "test-ns"
	platformName := "test-platform"
	stsName := platformName + "-weaviate"

	s := setupSchemeForTests()

	t.Run("StatefulSet not ready", func(t *testing.T) {
		sts := &appsv1.StatefulSet{
			ObjectMeta: metav1.ObjectMeta{
				Name:      stsName,
				Namespace: ns,
			},
			Spec: appsv1.StatefulSetSpec{
				Replicas: int32Ptr(1),
			},
			Status: appsv1.StatefulSetStatus{
				ReadyReplicas: 0,
			},
		}

		fc := fake.NewClientBuilder().WithScheme(s).WithObjects(sts).Build()
		r := &AIPlatformReconciler{Client: fc}

		p := &aiApi.AIPlatform{
			ObjectMeta: metav1.ObjectMeta{
				Name:      platformName,
				Namespace: ns,
			},
		}

		err := r.ReconcileWeaviateDatabaseStatus(ctx, p)
		assert.NoError(t, err)

		cond := getCondition(p.Status.Conditions, "WeaviateReady")
		assert.NotNil(t, cond)
		assert.Equal(t, metav1.ConditionFalse, cond.Status)
		assert.Equal(t, "WeaviateNotReady", cond.Reason)
		assert.Equal(t, platformName+"-weaviate", p.Status.VectorDbServiceName)
	})

	t.Run("StatefulSet ready", func(t *testing.T) {
		sts := &appsv1.StatefulSet{
			ObjectMeta: metav1.ObjectMeta{
				Name:      stsName,
				Namespace: ns,
			},
			Spec: appsv1.StatefulSetSpec{
				Replicas: int32Ptr(1),
			},
			Status: appsv1.StatefulSetStatus{
				ReadyReplicas: 1,
			},
		}

		fc := fake.NewClientBuilder().WithScheme(s).WithObjects(sts).Build()
		r := &AIPlatformReconciler{Client: fc}

		p := &aiApi.AIPlatform{
			ObjectMeta: metav1.ObjectMeta{
				Name:      platformName,
				Namespace: ns,
			},
		}

		err := r.ReconcileWeaviateDatabaseStatus(ctx, p)
		assert.NoError(t, err)

		cond := getCondition(p.Status.Conditions, "WeaviateReady")
		assert.NotNil(t, cond)
		assert.Equal(t, metav1.ConditionTrue, cond.Status)
		assert.Equal(t, "WeaviateReady", cond.Reason)
		assert.Equal(t, platformName+"-weaviate", p.Status.VectorDbServiceName)
	})
}

func TestReconcileWeaviateDatabase(t *testing.T) {
	ctx := context.Background()
	ns := "test-ns"
	platformName := "test-platform"
	instance := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      platformName,
			Namespace: ns,
		},
		Spec: aiApi.AIPlatformSpec{
			CPUSchedulingSpec: &aiApi.SchedulingSpec{
				NodeSelector: map[string]string{"role": "weaviate"},
				Tolerations:  []corev1.Toleration{},
				Affinity:     &corev1.Affinity{},
			},
		},
	}

	s := setupSchemeForTests()
	fc := fake.NewClientBuilder().WithScheme(s).Build()
	recorder := record.NewFakeRecorder(10)
	r := &AIPlatformReconciler{Client: fc, Scheme: s, Recorder: recorder}

	t.Run("fails when RELATED_IMAGE_WEAVIATE is missing", func(t *testing.T) {
		os.Unsetenv("RELATED_IMAGE_WEAVIATE")
		err := r.ReconcileWeaviateDatabase(ctx, instance)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "RELATED_IMAGE_WEAVIATE environment variable is required")
	})

	t.Run("succeeds when RELATED_IMAGE_WEAVIATE is set", func(t *testing.T) {
		os.Setenv("RELATED_IMAGE_WEAVIATE", "weaviate:test")
		defer os.Unsetenv("RELATED_IMAGE_WEAVIATE")

		err := r.ReconcileWeaviateDatabase(ctx, instance)
		assert.NoError(t, err)

		// Verify ServiceAccount created
		sa := &corev1.ServiceAccount{}
		err = fc.Get(ctx, types.NamespacedName{Name: platformName + "-weaviate", Namespace: ns}, sa)
		assert.NoError(t, err)

		// Verify StatefulSet created
		sts := &appsv1.StatefulSet{}
		err = fc.Get(ctx, types.NamespacedName{Name: platformName + "-weaviate", Namespace: ns}, sts)
		assert.NoError(t, err)
		assert.Equal(t, "weaviate:test", sts.Spec.Template.Spec.Containers[0].Image)

		// Verify container exposes both http (8080) and grpc (50051) ports
		containerPorts := sts.Spec.Template.Spec.Containers[0].Ports
		portNames := map[string]int32{}
		for _, p := range containerPorts {
			portNames[p.Name] = p.ContainerPort
		}
		assert.Equal(t, int32(8080), portNames["http"])
		assert.Equal(t, int32(50051), portNames["grpc"])

		// Verify container has GRPC_PORT env var (gRPC server is enabled by default in
		// Weaviate v1.19+, GRPC_PORT is set explicitly to make the port contract clear).
		envMap := map[string]string{}
		for _, e := range sts.Spec.Template.Spec.Containers[0].Env {
			envMap[e.Name] = e.Value
		}
		assert.Equal(t, "50051", envMap["GRPC_PORT"])

		// Verify Service created with both http and grpc ports
		svc := &corev1.Service{}
		err = fc.Get(ctx, types.NamespacedName{Name: platformName + "-weaviate", Namespace: ns}, svc)
		assert.NoError(t, err)
		svcPorts := map[string]int32{}
		for _, p := range svc.Spec.Ports {
			svcPorts[p.Name] = p.Port
		}
		assert.Equal(t, int32(80), svcPorts["http"])
		assert.Equal(t, int32(50051), svcPorts["grpc"])
	})
}

func int32Ptr(v int32) *int32 { return &v }

func getCondition(conds []metav1.Condition, condType string) *metav1.Condition {
	for _, c := range conds {
		if c.Type == condType {
			return &c
		}
	}
	return nil
}
