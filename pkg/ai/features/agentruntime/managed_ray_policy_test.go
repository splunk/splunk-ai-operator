package agentruntime

import (
	"context"
	"testing"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	rayoutils "github.com/ray-project/kuberay/ray-operator/controllers/ray/utils"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestManagedRayPolicyTracksStableHeadService(t *testing.T) {
	ctx := context.Background()
	scheme := buildAgentRuntimeTestScheme(t)
	require.NoError(t, rayv1.AddToScheme(scheme))
	const platformNamespace = "model-serving"
	const headName = "models-head-svc"
	platform := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "models", Namespace: platformNamespace, UID: "platform"},
		Spec:       aiv1.AIPlatformSpec{Profile: aiv1.AIPlatformProfileFullFeature},
		Status:     aiv1.AIPlatformStatus{RayServiceName: headName},
	}
	ray := &rayv1.RayService{
		ObjectMeta: metav1.ObjectMeta{Name: platform.Name, Namespace: platformNamespace, UID: "ray",
			OwnerReferences: []metav1.OwnerReference{{APIVersion: aiv1.GroupVersion.String(), Kind: "AIPlatform", Name: platform.Name, UID: platform.UID}}},
	}
	owner := *metav1.NewControllerRef(ray, rayv1.GroupVersion.WithKind("RayService"))
	active := &rayv1.RayCluster{ObjectMeta: metav1.ObjectMeta{Name: "models-active", Namespace: platformNamespace}}
	pending := &rayv1.RayCluster{ObjectMeta: metav1.ObjectMeta{Name: "models-pending", Namespace: platformNamespace, OwnerReferences: []metav1.OwnerReference{owner}}}
	ray.Status.PendingServiceStatus.RayClusterName = pending.Name
	headLabels := func(cluster string) map[string]string {
		return map[string]string{
			"ray.io/cluster": cluster, "ray.io/node-type": "head", "ray.io/identifier": cluster + "-head",
			"app.kubernetes.io/name": "kuberay", "app.kubernetes.io/created-by": "kuberay-operator",
		}
	}
	head := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: headName, Namespace: platformNamespace, OwnerReferences: []metav1.OwnerReference{owner}},
		Spec: corev1.ServiceSpec{
			Selector: headLabels(active.Name),
			Ports:    []corev1.ServicePort{{Port: 8000, Protocol: corev1.ProtocolTCP, TargetPort: intstr.FromInt32(8000)}},
		},
	}
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Namespace: "application"},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Namespace: platformNamespace, Name: platform.Name},
			AIPlatformUrl: "http://models-head-svc.model-serving.svc.cluster.local:8000",
		},
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(platform, ray, head).Build()
	r := &AgentRuntimeReconciler{Client: c, Scheme: scheme}
	rules, err := r.managedRayNetworkRules(ctx, ai)
	require.NoError(t, err)
	require.Len(t, rules, 1, "a pending name alone does not authorize egress")
	require.NoError(t, c.Create(ctx, pending))

	rules, err = r.managedRayNetworkRules(ctx, ai)
	require.NoError(t, err)
	require.Len(t, rules, 2)
	for i, cluster := range []*rayv1.RayCluster{active, pending} {
		require.Len(t, rules[i].To, 1)
		peer := rules[i].To[0]
		require.Equal(t, headLabels(cluster.Name), peer.PodSelector.MatchLabels)
		require.Equal(t, string(rayv1.HeadNode), peer.PodSelector.MatchLabels[rayoutils.RayNodeTypeLabelKey])
		require.Equal(t, map[string]string{corev1.LabelMetadataName: platformNamespace}, peer.NamespaceSelector.MatchLabels)
		require.Equal(t, int32(8000), rules[i].Ports[0].Port.IntVal)
	}

	head.Spec.Selector = headLabels(pending.Name)
	require.NoError(t, c.Update(ctx, head))
	rules, err = r.managedRayNetworkRules(ctx, ai)
	require.NoError(t, err)
	require.Len(t, rules, 1, "stop authorizing the outgoing head once the Service switches")
	require.Equal(t, head.Spec.Selector, rules[0].To[0].PodSelector.MatchLabels)

	ai.Spec.AIPlatformUrl = "http://models-serve-svc.model-serving.svc.cluster.local:8000"
	_, err = r.managedRayNetworkRules(ctx, ai)
	require.ErrorContains(t, err, "head Service on port 8000")
	ai.Spec.AIPlatformUrl = ""

	head.OwnerReferences = nil
	require.NoError(t, c.Update(ctx, head))
	_, err = r.managedRayNetworkRules(ctx, ai)
	require.ErrorContains(t, err, "RayService-owned head Service")
}
