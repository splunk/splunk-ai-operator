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
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

var _ = Describe("AIService reconcileStatus", func() {
	var (
		reconciler *AIServiceReconciler
		fakeClient client.Client
		ctx        context.Context
		namespace  string
		serviceKey types.NamespacedName
	)

	BeforeEach(func() {
		ctx = context.Background()
		namespace = "status-test-aiservice"

		s := scheme.Scheme
		_ = aiv1.AddToScheme(s)

		fakeClient = fake.NewClientBuilder().
			WithScheme(s).
			WithStatusSubresource(&aiv1.AIService{}).
			Build()

		reconciler = &AIServiceReconciler{
			Client:   fakeClient,
			Scheme:   s,
			Recorder: record.NewFakeRecorder(100),
			Config: &config.OperatorConfig{
				Mode: config.ModeNormal,
			},
		}

		serviceKey = types.NamespacedName{
			Name:      "test-service",
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

	Context("When updating service status", func() {
		It("should update observedGeneration and conditions", func() {
			service := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:       serviceKey.Name,
					Namespace:  serviceKey.Namespace,
					Generation: 3,
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
						Name:      "test-platform",
						Namespace: namespace,
					},
					VectorDbUrl: "http://weaviate:8080",
				},
			}

			Expect(fakeClient.Create(ctx, service)).To(Succeed())

			// Call reconcileStatus
			err := reconciler.reconcileStatus(ctx, service)
			Expect(err).To(Succeed())

			// Verify status was updated
			retrieved := &aiv1.AIService{}
			Expect(fakeClient.Get(ctx, serviceKey, retrieved)).To(Succeed())
			Expect(retrieved.Status.ObservedGeneration).To(Equal(int64(3)))
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
			Expect(readyCondition.Message).To(Equal("All resources are up-to-date"))
		})

		It("should handle multiple status updates", func() {
			service := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:       "multi-update-service",
					Namespace:  namespace,
					Generation: 1,
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
						Name:      "test-platform",
						Namespace: namespace,
					},
					VectorDbUrl: "http://weaviate:8080",
				},
			}

			Expect(fakeClient.Create(ctx, service)).To(Succeed())

			// First status update
			err := reconciler.reconcileStatus(ctx, service)
			Expect(err).To(Succeed())

			// Verify first update
			retrieved := &aiv1.AIService{}
			Expect(fakeClient.Get(ctx, types.NamespacedName{
				Name:      service.Name,
				Namespace: service.Namespace,
			}, retrieved)).To(Succeed())
			Expect(retrieved.Status.ObservedGeneration).To(Equal(int64(1)))

			// Update generation
			retrieved.Generation = 2
			Expect(fakeClient.Update(ctx, retrieved)).To(Succeed())

			// Second status update
			err = reconciler.reconcileStatus(ctx, retrieved)
			Expect(err).To(Succeed())

			// Verify second update
			Expect(fakeClient.Get(ctx, types.NamespacedName{
				Name:      service.Name,
				Namespace: service.Namespace,
			}, retrieved)).To(Succeed())
			Expect(retrieved.Status.ObservedGeneration).To(Equal(int64(2)))
		})
	})
})

var _ = Describe("AIService Reconcile Edge Cases", func() {
	var (
		reconciler *AIServiceReconciler
		fakeClient client.Client
		ctx        context.Context
		namespace  string
	)

	BeforeEach(func() {
		ctx = context.Background()
		namespace = "edge-case-test"

		s := scheme.Scheme
		_ = aiv1.AddToScheme(s)

		fakeClient = fake.NewClientBuilder().
			WithScheme(s).
			WithStatusSubresource(&aiv1.AIService{}).
			Build()

		reconciler = &AIServiceReconciler{
			Client:   fakeClient,
			Scheme:   s,
			Recorder: record.NewFakeRecorder(100),
			Config: &config.OperatorConfig{
				Mode: config.ModeNormal,
			},
		}

		// Create namespace
		ns := &corev1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: namespace,
			},
		}
		Expect(fakeClient.Create(ctx, ns)).To(Succeed())
	})

	Context("When feature name is unknown", func() {
		It("should handle unregistered feature gracefully", func() {
			service := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "unknown-feature-service",
					Namespace: namespace,
				},
				Spec: aiv1.AIServiceSpec{
					Feature: aiv1.FeatureSpec{
						Name: "non-existent-feature",
					},
					TaskVolume: &aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/tasks",
						Region: "us-west-2",
					},
					AIPlatformRef: corev1.ObjectReference{
						Name:      "test-platform",
						Namespace: namespace,
					},
					VectorDbUrl: "http://weaviate:8080",
				},
			}

			Expect(fakeClient.Create(ctx, service)).To(Succeed())

			// Reconcile should handle unknown feature
			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: types.NamespacedName{
					Name:      service.Name,
					Namespace: service.Namespace,
				},
			})

			// Should requeue after delay (no error, but requeue to avoid hot loop)
			Expect(err).To(BeNil())
			Expect(result.RequeueAfter).To(BeNumerically(">", 0))
		})
	})

	Context("When feature name is empty", func() {
		It("should use 'unknown' as feature name", func() {
			service := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "empty-feature-service",
					Namespace: namespace,
				},
				Spec: aiv1.AIServiceSpec{
					Feature: aiv1.FeatureSpec{
						Name: "", // Empty feature name
					},
					TaskVolume: &aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/tasks",
						Region: "us-west-2",
					},
					AIPlatformRef: corev1.ObjectReference{
						Name:      "test-platform",
						Namespace: namespace,
					},
					VectorDbUrl: "http://weaviate:8080",
				},
			}

			Expect(fakeClient.Create(ctx, service)).To(Succeed())

			// Reconcile should handle empty feature name
			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: types.NamespacedName{
					Name:      service.Name,
					Namespace: service.Namespace,
				},
			})

			// Should requeue after delay
			Expect(err).To(BeNil())
			Expect(result.RequeueAfter).To(BeNumerically(">", 0))
		})
	})

	Context("When service is being deleted without finalizer", func() {
		It("should complete deletion immediately", func() {
			service := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "no-finalizer-service",
					Namespace: namespace,
					// No finalizers set
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
						Name:      "test-platform",
						Namespace: namespace,
					},
					VectorDbUrl: "http://weaviate:8080",
				},
			}

			Expect(fakeClient.Create(ctx, service)).To(Succeed())

			// Mark for deletion
			Expect(fakeClient.Delete(ctx, service)).To(Succeed())

			// Reconcile should complete without error
			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: types.NamespacedName{
					Name:      service.Name,
					Namespace: service.Namespace,
				},
			})

			Expect(err).To(BeNil())
			Expect(result).To(Equal(ctrl.Result{}))
		})
	})
})

var _ = Describe("AIService Helper Functions", func() {
	Describe("containsString", func() {
		It("should return true when string is in slice", func() {
			slice := []string{"one", "two", "three"}
			Expect(containsString(slice, "two")).To(BeTrue())
		})

		It("should return false when string is not in slice", func() {
			slice := []string{"one", "two", "three"}
			Expect(containsString(slice, "four")).To(BeFalse())
		})

		It("should return false for empty slice", func() {
			slice := []string{}
			Expect(containsString(slice, "test")).To(BeFalse())
		})

		It("should return false for nil slice", func() {
			var slice []string
			Expect(containsString(slice, "test")).To(BeFalse())
		})
	})

	Describe("removeString", func() {
		It("should remove string from middle of slice", func() {
			slice := []string{"one", "two", "three"}
			result := removeString(slice, "two")
			Expect(result).To(Equal([]string{"one", "three"}))
		})

		It("should remove string from beginning of slice", func() {
			slice := []string{"one", "two", "three"}
			result := removeString(slice, "one")
			Expect(result).To(Equal([]string{"two", "three"}))
		})

		It("should remove string from end of slice", func() {
			slice := []string{"one", "two", "three"}
			result := removeString(slice, "three")
			Expect(result).To(Equal([]string{"one", "two"}))
		})

		It("should handle string not in slice", func() {
			slice := []string{"one", "two", "three"}
			result := removeString(slice, "four")
			Expect(result).To(Equal([]string{"one", "two", "three"}))
		})

		It("should handle empty slice", func() {
			slice := []string{}
			result := removeString(slice, "test")
			Expect(result).To(Equal([]string{}))
		})

		It("should handle nil slice", func() {
			var slice []string
			result := removeString(slice, "test")
			Expect(result).To(Equal([]string{}))
		})

		It("should remove multiple occurrences", func() {
			slice := []string{"one", "two", "two", "three"}
			result := removeString(slice, "two")
			Expect(result).To(Equal([]string{"one", "three"}))
		})
	})
})
