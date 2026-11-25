/*
Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/config"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

var _ = Describe("AIPlatform reconcileStatus", func() {
	var (
		reconciler  *AIPlatformReconciler
		fakeClient  client.Client
		ctx         context.Context
		namespace   string
		platformKey types.NamespacedName
	)

	BeforeEach(func() {
		ctx = context.Background()
		namespace = "status-test"

		s := scheme.Scheme
		_ = aiv1.AddToScheme(s)

		fakeClient = fake.NewClientBuilder().
			WithScheme(s).
			WithStatusSubresource(&aiv1.AIPlatform{}).
			Build()

		reconciler = &AIPlatformReconciler{
			Client:   fakeClient,
			Scheme:   s,
			Recorder: record.NewFakeRecorder(100),
			Config: &config.OperatorConfig{
				Mode: config.ModeNormal,
			},
		}

		platformKey = types.NamespacedName{
			Name:      "test-platform",
			Namespace: namespace,
		}

		// Create namespace
		ns := &corev1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: namespace,
			},
		}
		Expect(fakeClient.Create(ctx, ns)).To(Succeed())
	})

	Context("When updating platform status", func() {
		It("should update observedGeneration and conditions", func() {
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:       platformKey.Name,
					Namespace:  platformKey.Namespace,
					Generation: 5,
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket",
						Region: "us-west-2",
					},
				},
			}

			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// Call reconcileStatus
			err := reconciler.reconcileStatus(ctx, platform)
			Expect(err).To(Succeed())

			// Verify status was updated
			retrieved := &aiv1.AIPlatform{}
			Expect(fakeClient.Get(ctx, platformKey, retrieved)).To(Succeed())
			Expect(retrieved.Status.ObservedGeneration).To(Equal(int64(5)))
			Expect(retrieved.Status.Conditions).NotTo(BeEmpty())

			// Verify Ready condition is set
			var readyCondition *metav1.Condition
			for i, cond := range retrieved.Status.Conditions {
				if cond.Type == "Ready" {
					readyCondition = &retrieved.Status.Conditions[i]
					break
				}
			}
			Expect(readyCondition).NotTo(BeNil())
			Expect(readyCondition.Status).To(Equal(metav1.ConditionTrue))
			Expect(readyCondition.Reason).To(Equal("Reconciled"))
		})

		It("should handle status update failures gracefully", func() {
			// Create platform with mismatched generation
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:       "conflict-platform",
					Namespace:  namespace,
					Generation: 1,
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket",
						Region: "us-west-2",
					},
				},
			}

			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// Update platform's status to simulate a condition already exists
			platform.Status.ObservedGeneration = 1
			Expect(fakeClient.Status().Update(ctx, platform)).To(Succeed())

			// Call reconcileStatus again (should succeed even if status already set)
			err := reconciler.reconcileStatus(ctx, platform)
			Expect(err).To(Succeed())
		})
	})
})

var _ = Describe("AIPlatform deletion (MPR-202): no finalizer, owner references only", func() {
	var (
		reconciler  *AIPlatformReconciler
		fakeClient  client.Client
		ctx         context.Context
		namespace   string
		platformKey types.NamespacedName
	)

	BeforeEach(func() {
		ctx = context.Background()
		namespace = "finalize-test"

		// A private scheme: writing the shared client-go scheme here races with event
		// recorders that envtest specs leave running.
		s := runtime.NewScheme()
		Expect(clientgoscheme.AddToScheme(s)).To(Succeed())
		Expect(aiv1.AddToScheme(s)).To(Succeed())

		fakeClient = fake.NewClientBuilder().
			WithScheme(s).
			WithStatusSubresource(&aiv1.AIService{}).
			WithIndex(&aiv1.AIService{}, ".metadata.controller", func(obj client.Object) []string {
				svc := obj.(*aiv1.AIService)
				owner := metav1.GetControllerOf(svc)
				if owner == nil {
					return nil
				}
				return []string{owner.Name}
			}).
			Build()

		reconciler = &AIPlatformReconciler{
			Client:   fakeClient,
			Scheme:   s,
			Recorder: record.NewFakeRecorder(100),
			Config: &config.OperatorConfig{
				Mode: config.ModeNormal,
			},
		}

		platformKey = types.NamespacedName{
			Name:      "test-platform",
			Namespace: namespace,
		}

		// Create namespace
		ns := &corev1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: namespace,
			},
		}
		Expect(fakeClient.Create(ctx, ns)).To(Succeed())
	})

	newPlatform := func(finalizers ...string) *aiv1.AIPlatform {
		return &aiv1.AIPlatform{
			ObjectMeta: metav1.ObjectMeta{Name: platformKey.Name, Namespace: platformKey.Namespace, UID: "platform-uid", Finalizers: finalizers},
			Spec:       aiv1.AIPlatformSpec{ObjectStorage: aiv1.ObjectStorageSpec{Path: "s3://test-bucket", Region: "us-west-2"}},
		}
	}
	newChild := func(platform *aiv1.AIPlatform) *aiv1.AIService {
		controller := true
		return &aiv1.AIService{
			ObjectMeta: metav1.ObjectMeta{Name: "child-service", Namespace: platformKey.Namespace,
				OwnerReferences: []metav1.OwnerReference{{APIVersion: aiv1.GroupVersion.String(), Kind: "AIPlatform",
					Name: platform.Name, UID: platform.UID, Controller: &controller}}},
			Spec: aiv1.AIServiceSpec{Feature: aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk"},
				TaskVolume: aiv1.ObjectStorageSpec{Path: "s3://test-bucket/tasks", Region: "us-west-2"}},
		}
	}

	It("releases the finalizer an early build added at once, without deleting anything itself", func() {
		platform := newPlatform(aiPlatformFinalizer)
		Expect(fakeClient.Create(ctx, platform)).To(Succeed())
		child := newChild(platform)
		Expect(fakeClient.Create(ctx, child)).To(Succeed())
		Expect(fakeClient.Delete(ctx, platform)).To(Succeed())

		result, err := reconciler.Reconcile(ctx, reconcile.Request{NamespacedName: platformKey})
		Expect(err).NotTo(HaveOccurred())
		Expect(result).To(Equal(ctrl.Result{}), "nothing to wait for")
		Expect(errors.IsNotFound(fakeClient.Get(ctx, platformKey, &aiv1.AIPlatform{}))).To(BeTrue(), "the platform is deleted, not held")
		// Its AIServices are removed by garbage collection through their owner
		// references (the fake client has none), not by the operator.
		Expect(fakeClient.Get(ctx, client.ObjectKeyFromObject(child), &aiv1.AIService{})).To(Succeed())
	})

	It("never adds a finalizer", func() {
		platform := newPlatform()
		platform.Spec.Profile = aiv1.AIPlatformProfileCPUOnly // a complete reconcile without a Ray fixture
		Expect(fakeClient.Create(ctx, platform)).To(Succeed())
		_, _ = reconciler.Reconcile(ctx, reconcile.Request{NamespacedName: platformKey})
		got := &aiv1.AIPlatform{}
		Expect(fakeClient.Get(ctx, platformKey, got)).To(Succeed())
		Expect(got.Finalizers).To(BeEmpty())
	})

	It("keeps another controller's finalizer", func() {
		platform := newPlatform(aiPlatformFinalizer, "example.com/other")
		Expect(fakeClient.Create(ctx, platform)).To(Succeed())
		Expect(fakeClient.Delete(ctx, platform)).To(Succeed())
		_, err := reconciler.Reconcile(ctx, reconcile.Request{NamespacedName: platformKey})
		Expect(err).NotTo(HaveOccurred())
		got := &aiv1.AIPlatform{}
		Expect(fakeClient.Get(ctx, platformKey, got)).To(Succeed())
		Expect(got.Finalizers).To(Equal([]string{"example.com/other"}))
	})
})
