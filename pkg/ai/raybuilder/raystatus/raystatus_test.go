package raystatus

import (
	"context"
	"testing"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	kuberayutils "github.com/ray-project/kuberay/ray-operator/controllers/ray/utils"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestCollectRaySnapshotKeepsStableRayServiceHeadName(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, rayv1.AddToScheme(scheme))
	require.NoError(t, corev1.AddToScheme(scheme))

	rayService := &rayv1.RayService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "platform",
			Namespace: "ai-platform",
		},
		Status: rayv1.RayServiceStatuses{
			ActiveServiceStatus: rayv1.RayServiceStatus{
				RayClusterName: "platform-raycluster-abc12",
				RayClusterStatus: rayv1.RayClusterStatus{
					Head: rayv1.HeadInfo{
						ServiceName: "platform-raycluster-abc12-head-svc",
						ServiceIP:   "10.0.0.10",
						PodName:     "platform-raycluster-abc12-head-pod",
					},
				},
			},
		},
	}

	client := fake.NewClientBuilder().WithScheme(scheme).WithObjects(rayService).Build()
	snapshot, err := CollectRaySnapshot(
		context.Background(),
		client,
		rayService.Namespace,
		rayService.Name,
	)

	require.NoError(t, err)
	assert.Equal(t, "platform-head-svc", snapshot.HeadServiceName)
	assert.Equal(t, "10.0.0.10", snapshot.HeadServiceIP)
	assert.Equal(t, "platform-raycluster-abc12-head-pod", snapshot.HeadPodName)
}

// TestCollectRaySnapshotNormalizesLongNames guards against a regression where
// the stable RayService names diverge from KubeRay's actual (CheckName-normalized)
// Service names once the AIPlatform name is long enough to be front-truncated.
func TestCollectRaySnapshotNormalizesLongNames(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, rayv1.AddToScheme(scheme))
	require.NoError(t, corev1.AddToScheme(scheme))

	// 45 chars: long enough that "<name>-head-svc" (54 chars) and
	// "<name>-serve-svc" (55 chars) both exceed KubeRay's 50-char CheckName limit.
	longName := "a-very-long-aiplatform-name-that-exceeds-limit"
	rayService := &rayv1.RayService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      longName,
			Namespace: "ai-platform",
		},
	}

	client := fake.NewClientBuilder().WithScheme(scheme).WithObjects(rayService).Build()
	snapshot, err := CollectRaySnapshot(
		context.Background(),
		client,
		rayService.Namespace,
		rayService.Name,
	)

	require.NoError(t, err)

	wantHead, err := kuberayutils.GenerateHeadServiceName(kuberayutils.RayServiceCRD, rayv1.RayClusterSpec{}, longName)
	require.NoError(t, err)
	wantServe := kuberayutils.GenerateServeServiceName(longName)

	// Sanity check that CheckName actually truncated these names; otherwise the
	// test isn't exercising the long-name path it's meant to guard.
	require.NotEqual(t, longName+"-head-svc", wantHead)
	require.NotEqual(t, longName+"-serve-svc", wantServe)

	assert.Equal(t, wantHead, snapshot.HeadServiceName)
	assert.Equal(t, wantServe, snapshot.ServeServiceName)
}
