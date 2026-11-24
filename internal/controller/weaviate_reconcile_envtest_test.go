package controller

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	aiplatform "github.com/splunk/splunk-ai-operator/pkg/ai"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type weaviateUpdateClient struct {
	client.Client
	statefulSetUpdates int
	serviceUpdates     int
}

func (c *weaviateUpdateClient) Update(ctx context.Context, obj client.Object, opts ...client.UpdateOption) error {
	switch obj.(type) {
	case *appsv1.StatefulSet:
		c.statefulSetUpdates++
	case *corev1.Service:
		c.serviceUpdates++
	}
	return c.Client.Update(ctx, obj, opts...)
}

var _ = Describe("Weaviate resource reconciliation", func() {
	It("does not rewrite API-defaulted resources and still rolls out an image change", func() {
		GinkgoT().Setenv("RELATED_IMAGE_WEAVIATE", "weaviate:v1")
		platform := &aiv1.AIPlatform{
			ObjectMeta: metav1.ObjectMeta{Name: "weaviate-idempotence", Namespace: "default"},
			Spec: aiv1.AIPlatformSpec{
				CPUSchedulingSpec: &aiv1.SchedulingSpec{},
				ObjectStorage:     aiv1.ObjectStorageSpec{Path: "s3://weaviate-fixture", Region: "us-west-2"},
			},
		}
		Expect(k8sClient.Create(ctx, platform)).To(Succeed())
		key := client.ObjectKey{Name: platform.Name + "-weaviate", Namespace: platform.Namespace}
		sts := &appsv1.StatefulSet{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}}
		svc := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}}
		sa := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}}
		DeferCleanup(func() {
			for _, obj := range []client.Object{sts, svc, sa, platform} {
				Expect(client.IgnoreNotFound(k8sClient.Delete(ctx, obj))).To(Succeed())
			}
		})
		writes := &weaviateUpdateClient{Client: k8sClient}
		r := aiplatform.New(platform, writes, writes.Scheme(), record.NewFakeRecorder(20))
		reconcile := func() { Expect(r.ReconcileWeaviateDatabase(ctx, platform)).To(Succeed()) }
		reconcile()
		Expect(k8sClient.Get(ctx, key, sts)).To(Succeed())
		Expect(k8sClient.Get(ctx, key, svc)).To(Succeed())
		Expect(sts.Spec.Template.Spec.Containers[0].TerminationMessagePath).To(Equal(corev1.TerminationMessagePathDefault))
		Expect(svc.Spec.Ports[0].Protocol).To(Equal(corev1.ProtocolTCP))
		initialGeneration, initialSetVersion, initialServiceVersion := sts.Generation, sts.ResourceVersion, svc.ResourceVersion

		for range 3 {
			reconcile()
		}
		// Comparing stored versions alone would miss redundant PUTs when the
		// API server restores the omitted default and skips the storage write.
		Expect([]int{writes.statefulSetUpdates, writes.serviceUpdates}).To(Equal([]int{0, 0}), "updates to the StatefulSet and Service")
		Expect(k8sClient.Get(ctx, key, sts)).To(Succeed())
		Expect(k8sClient.Get(ctx, key, svc)).To(Succeed())
		Expect(sts.Generation).To(Equal(initialGeneration))
		Expect(sts.ResourceVersion).To(Equal(initialSetVersion))
		Expect(svc.ResourceVersion).To(Equal(initialServiceVersion))

		GinkgoT().Setenv("RELATED_IMAGE_WEAVIATE", "weaviate:v2")
		reconcile()
		reconcile()
		Expect(writes.statefulSetUpdates).To(Equal(1))
		Expect(writes.serviceUpdates).To(BeZero())
		Expect(k8sClient.Get(ctx, key, sts)).To(Succeed())
		Expect(sts.Generation).To(Equal(initialGeneration + 1))
		Expect(sts.Spec.Template.Spec.Containers[0].Image).To(Equal("weaviate:v2"))
	})
})
