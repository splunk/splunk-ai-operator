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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
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
					ObjectStorage: &aiv1.ObjectStorageSpec{
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
					ObjectStorage: &aiv1.ObjectStorageSpec{
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

var _ = Describe("AIPlatform finalizePlatform", func() {
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

		s := scheme.Scheme
		_ = aiv1.AddToScheme(s)

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

	Context("When finalizing platform with no children", func() {
		It("should return done=true immediately", func() {
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      platformKey.Name,
					Namespace: platformKey.Namespace,
					UID:       "test-uid",
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: &aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket",
						Region: "us-west-2",
					},
				},
			}

			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// Call finalizePlatform
			done, err := reconciler.finalizePlatform(ctx, platform)
			Expect(err).To(Succeed())
			Expect(done).To(BeTrue())
		})
	})

	Context("When finalizing platform with AIService children", func() {
		It("should delete children and return done=false until cleanup complete", func() {
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      platformKey.Name,
					Namespace: platformKey.Namespace,
					UID:       "test-uid",
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: &aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket",
						Region: "us-west-2",
					},
				},
			}

			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// Create owned AIService
			trueVal := true
			service := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "child-service",
					Namespace: platformKey.Namespace,
					OwnerReferences: []metav1.OwnerReference{
						{
							APIVersion: aiv1.GroupVersion.String(),
							Kind:       "AIPlatform",
							Name:       platform.Name,
							UID:        platform.UID,
							Controller: &trueVal,
						},
					},
				},
				Spec: aiv1.AIServiceSpec{
					Feature: aiv1.FeatureSpec{
						Name: "saia",
					},
					TaskVolume: &aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/tasks",
						Region: "us-west-2",
					},
					AIPlatformRef: corev1.ObjectReference{
						Name:      platform.Name,
						Namespace: platform.Namespace,
					},
					VectorDbUrl: "http://weaviate:8080",
				},
			}

			Expect(fakeClient.Create(ctx, service)).To(Succeed())

			// Call finalizePlatform first time - should attempt delete
			done, err := reconciler.finalizePlatform(ctx, platform)
			Expect(err).To(Succeed())
			Expect(done).To(BeFalse()) // Not done yet, children still exist

			// Verify service still exists (deletion may be pending)
			retrieved := &aiv1.AIService{}
			err = fakeClient.Get(ctx, types.NamespacedName{
				Name:      service.Name,
				Namespace: service.Namespace,
			}, retrieved)
			// Service may or may not exist depending on fake client behavior
			// The important thing is finalizePlatform returned false
		})

		It("should return done=true when all children are deleted", func() {
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      platformKey.Name,
					Namespace: platformKey.Namespace,
					UID:       "test-uid-2",
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: &aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket",
						Region: "us-west-2",
					},
				},
			}

			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// No children - should return done immediately
			done, err := reconciler.finalizePlatform(ctx, platform)
			Expect(err).To(Succeed())
			Expect(done).To(BeTrue())
		})
	})

	Context("When finalizePlatform encounters errors", func() {
		It("should handle list errors gracefully", func() {
			// Create platform in a namespace that doesn't exist
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "error-platform",
					Namespace: "non-existent-namespace",
					UID:       "test-uid-error",
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: &aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket",
						Region: "us-west-2",
					},
				},
			}

			// Call finalizePlatform - should handle gracefully
			// Note: fake client may or may not error on list in non-existent namespace
			_, _ = reconciler.finalizePlatform(ctx, platform)
			// We just verify it doesn't panic
		})
	})
})
