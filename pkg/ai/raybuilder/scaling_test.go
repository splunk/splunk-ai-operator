package raybuilder

import (
	"context"
	"testing"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func fixedWorkerSpec(replicas int32) rayv1.RayClusterSpec {
	return rayv1.RayClusterSpec{
		WorkerGroupSpecs: []rayv1.WorkerGroupSpec{{
			GroupName:   "l40s-1-gpu",
			Replicas:    int32Ptr(replicas),
			MinReplicas: int32Ptr(replicas),
			MaxReplicas: int32Ptr(replicas),
		}},
	}
}

func activeClusterScaleTestBuilder(
	t *testing.T,
	liveSpec, desiredSpec rayv1.RayClusterSpec,
	pendingCluster string,
) (*Builder, client.Client, *aiv1.AIPlatform) {
	t.Helper()

	scheme := runtime.NewScheme()
	require.NoError(t, aiv1.AddToScheme(scheme))
	require.NoError(t, rayv1.AddToScheme(scheme))

	platform := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "platform", Namespace: "ai-platform"},
	}
	rayService := &rayv1.RayService{
		ObjectMeta: metav1.ObjectMeta{Name: platform.Name, Namespace: platform.Namespace},
		Spec:       rayv1.RayServiceSpec{RayClusterSpec: desiredSpec},
		Status: rayv1.RayServiceStatuses{
			ActiveServiceStatus:  rayv1.RayServiceStatus{RayClusterName: "active-cluster"},
			PendingServiceStatus: rayv1.RayServiceStatus{RayClusterName: pendingCluster},
		},
	}
	rayCluster := &rayv1.RayCluster{
		ObjectMeta: metav1.ObjectMeta{Name: "active-cluster", Namespace: platform.Namespace},
		Spec:       liveSpec,
	}
	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithStatusSubresource(&rayv1.RayService{}).
		WithObjects(rayService, rayCluster).
		Build()

	return New(platform, fakeClient, scheme, nil), fakeClient, platform
}

func workerReplicas(t *testing.T, c client.Client, namespace string) int32 {
	t.Helper()
	var cluster rayv1.RayCluster
	require.NoError(t, c.Get(context.Background(), types.NamespacedName{
		Name: "active-cluster", Namespace: namespace,
	}, &cluster))
	require.NotNil(t, cluster.Spec.WorkerGroupSpecs[0].Replicas)
	return *cluster.Spec.WorkerGroupSpecs[0].Replicas
}

func TestReconcileActiveClusterScale(t *testing.T) {
	t.Run("patches a scale-only change", func(t *testing.T) {
		builder, c, platform := activeClusterScaleTestBuilder(
			t, fixedWorkerSpec(2), fixedWorkerSpec(4), "",
		)

		require.NoError(t, builder.ReconcileActiveClusterScale(context.Background(), platform))
		require.Equal(t, int32(4), workerReplicas(t, c, platform.Namespace))
	})

	t.Run("skips a non-replica change", func(t *testing.T) {
		live := fixedWorkerSpec(2)
		live.WorkerGroupSpecs[0].RayStartParams = map[string]string{"num-cpus": "4"}
		desired := fixedWorkerSpec(4)
		desired.WorkerGroupSpecs[0].RayStartParams = map[string]string{"num-cpus": "8"}
		builder, c, platform := activeClusterScaleTestBuilder(t, live, desired, "")

		require.NoError(t, builder.ReconcileActiveClusterScale(context.Background(), platform))
		require.Equal(t, int32(2), workerReplicas(t, c, platform.Namespace))
	})

	t.Run("skips while a pending cluster exists", func(t *testing.T) {
		builder, c, platform := activeClusterScaleTestBuilder(
			t, fixedWorkerSpec(2), fixedWorkerSpec(4), "pending-cluster",
		)

		require.NoError(t, builder.ReconcileActiveClusterScale(context.Background(), platform))
		require.Equal(t, int32(2), workerReplicas(t, c, platform.Namespace))
	})
}

func TestApplyDesiredWorkerSizingPreservesAutoscaledReplicas(t *testing.T) {
	live := &rayv1.RayCluster{Spec: rayv1.RayClusterSpec{
		WorkerGroupSpecs: []rayv1.WorkerGroupSpec{{
			GroupName:   "cpu",
			Replicas:    int32Ptr(3),
			MinReplicas: int32Ptr(1),
			MaxReplicas: int32Ptr(6),
		}},
	}}
	desired := []rayv1.WorkerGroupSpec{{
		GroupName:   "cpu",
		Replicas:    int32Ptr(2),
		MinReplicas: int32Ptr(2),
		MaxReplicas: int32Ptr(7),
	}}

	require.True(t, applyDesiredWorkerSizing(live, desired))
	group := live.Spec.WorkerGroupSpecs[0]
	require.Equal(t, int32(3), *group.Replicas)
	require.Equal(t, int32(2), *group.MinReplicas)
	require.Equal(t, int32(7), *group.MaxReplicas)
}
