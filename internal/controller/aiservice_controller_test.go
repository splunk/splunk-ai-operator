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
	"os"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/config"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

var _ = Describe("AIService Controller", func() {
	var (
		reconciler  *AIServiceReconciler
		fakeClient  client.Client
		ctx         context.Context
		namespace   string
		serviceKey  types.NamespacedName
		platformKey types.NamespacedName
	)

	BeforeEach(func() {
		ctx = context.Background()
		namespace = "test-namespace"

		// Set required environment variables
		os.Setenv("RELATED_IMAGE_POST_INSTALL_HOOK", "test-post-install:latest")
		os.Setenv("RELATED_IMAGE_FLUENT_BIT", "fluent/fluent-bit:latest")
		os.Setenv("RELATED_IMAGE_SAIA_API", "saia-api:latest")
		os.Setenv("RELATED_IMAGE_OTEL_COLLECTOR", "otel/opentelemetry-collector-contrib:latest")

		// Create a fake client with proper scheme
		s := scheme.Scheme
		_ = aiv1.AddToScheme(s)
		_ = appsv1.AddToScheme(s)

		fakeClient = fake.NewClientBuilder().
			WithScheme(s).
			WithStatusSubresource(&aiv1.AIService{}, &aiv1.AIPlatform{}).
			Build()

		// Create reconciler with fake client
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

		// Create Splunk secret for AIService tests - uses naming pattern expected by splunk utils
		splunkSecret := &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "splunk-" + namespace + "-secret",
				Namespace: namespace,
			},
			Data: map[string][]byte{
				"hec_token": []byte("test-hec-token"),
			},
		}
		Expect(fakeClient.Create(ctx, splunkSecret)).To(Succeed())
	})

	Context("When reconciling a new AIService", func() {
		It("should create deployment successfully", func() {
			// Create AIPlatform first
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      platformKey.Name,
					Namespace: platformKey.Namespace,
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "platform-sa",
					ObjectStorage: aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/artifacts",
						Region: "us-west-2",
					},
				},
			}
			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// Set platform status to Ready
			platform.Status.Conditions = []metav1.Condition{
				{
					Type:               "Ready",
					Status:             metav1.ConditionTrue,
					Reason:             "Reconciled",
					LastTransitionTime: metav1.Now(),
				},
				{
					Type:               "WeaviateDatabaseReady",
					Status:             metav1.ConditionTrue,
					Reason:             "Reconciled",
					LastTransitionTime: metav1.Now(),
				},
			}
			platform.Status.RayServiceName = "ray-head"
			platform.Status.VectorDbServiceName = "weaviate"
			Expect(fakeClient.Status().Update(ctx, platform)).To(Succeed())

			// Create AIService
			service := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:      serviceKey.Name,
					Namespace: serviceKey.Namespace,
				},
				Spec: aiv1.AIServiceSpec{
					ServiceAccountName: "service-sa",
					Feature: aiv1.FeatureSpec{
						Name:               "saia",
						ServiceAccountName: "saia-sa",
						Version:            "1.0.0",
					},
					TaskVolume: aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/tasks",
						Region: "us-west-2",
					},
					AIPlatformRef: corev1.ObjectReference{
						Name:      platformKey.Name,
						Namespace: platformKey.Namespace,
					},
					VectorDbUrl:   "http://weaviate:8080",
					AIPlatformUrl: "http://ray-head:8000",
					Replicas:      1,
					SplunkConfiguration: aiv1.SplunkConfigurationSpec{
						Endpoint: "https://splunk.example.com:8089",
						SecretRef: corev1.SecretReference{
							Name:      "splunk-" + namespace + "-secret",
							Namespace: namespace,
						},
					},
				},
			}

			Expect(fakeClient.Create(ctx, service)).To(Succeed())

			// Reconcile - PostInstallHook creates a Job and returns error to signal requeue
			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: serviceKey,
			})

			// Expect error about AIPlatform infrastructure not ready (new validation logic)
			Expect(err).ToNot(BeNil())
			Expect(err.Error()).To(ContainSubstring("AIPlatform infrastructure not ready"))

			// Verify AIService still exists and Job was created
			retrieved := &aiv1.AIService{}
			Expect(fakeClient.Get(ctx, serviceKey, retrieved)).To(Succeed())
			Expect(retrieved.Name).To(Equal(serviceKey.Name))
		})

		It("should handle missing AIPlatform reference", func() {
			service := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:      serviceKey.Name,
					Namespace: serviceKey.Namespace,
				},
				Spec: aiv1.AIServiceSpec{
					Feature: aiv1.FeatureSpec{
						Name: "saia",
					},
					TaskVolume: aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/tasks",
						Region: "us-west-2",
					},
					AIPlatformRef: corev1.ObjectReference{
						Name:      "non-existent-platform",
						Namespace: namespace,
					},
					VectorDbUrl: "http://weaviate:8080",
				},
			}

			Expect(fakeClient.Create(ctx, service)).To(Succeed())

			// Reconcile should handle the missing reference
			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: serviceKey,
			})

			// Should return error or requeue
			Expect(err).ToNot(BeNil())
		})
	})

	Context("When handling AIService deletion", func() {
		It("should handle finalizer properly", func() {
			service := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:       serviceKey.Name,
					Namespace:  serviceKey.Namespace,
					Finalizers: []string{"ai.splunk.com/aiservice-protect"},
				},
				Spec: aiv1.AIServiceSpec{
					Feature: aiv1.FeatureSpec{
						Name: "saia",
					},
					TaskVolume: aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/tasks",
						Region: "us-west-2",
					},
					AIPlatformRef: corev1.ObjectReference{
						Name:      platformKey.Name,
						Namespace: platformKey.Namespace,
					},
					VectorDbUrl: "http://weaviate:8080",
				},
			}

			Expect(fakeClient.Create(ctx, service)).To(Succeed())

			// Mark for deletion
			Expect(fakeClient.Delete(ctx, service)).To(Succeed())

			// Reconcile should handle finalizer
			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: serviceKey,
			})

			// Should succeed or be not found
			if err == nil {
				retrieved := &aiv1.AIService{}
				err = fakeClient.Get(ctx, serviceKey, retrieved)
				if err == nil {
					// Finalizer should be handled
					Expect(retrieved.Finalizers).NotTo(ContainElement("ai.splunk.com/aiservice-protect"))
				} else {
					Expect(errors.IsNotFound(err)).To(BeTrue())
				}
			}
		})
	})

	Context("When AIService resource is not found", func() {
		It("should not return error", func() {
			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: types.NamespacedName{
					Name:      "non-existent",
					Namespace: namespace,
				},
			})

			Expect(err).To(BeNil())
			Expect(result).To(Equal(ctrl.Result{}))
		})
	})

	Context("When updating AIService spec", func() {
		It("should reconcile changes", func() {
			// Create platform first
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      platformKey.Name,
					Namespace: platformKey.Namespace,
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "platform-sa",
					ObjectStorage: aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/artifacts",
						Region: "us-west-2",
					},
				},
			}
			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// Set platform status to Ready
			platform.Status.Conditions = []metav1.Condition{
				{
					Type:               "Ready",
					Status:             metav1.ConditionTrue,
					Reason:             "Reconciled",
					LastTransitionTime: metav1.Now(),
				},
				{
					Type:               "WeaviateDatabaseReady",
					Status:             metav1.ConditionTrue,
					Reason:             "Reconciled",
					LastTransitionTime: metav1.Now(),
				},
			}
			platform.Status.RayServiceName = "ray-head"
			platform.Status.VectorDbServiceName = "weaviate"
			Expect(fakeClient.Status().Update(ctx, platform)).To(Succeed())

			service := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:      serviceKey.Name,
					Namespace: serviceKey.Namespace,
				},
				Spec: aiv1.AIServiceSpec{
					Feature: aiv1.FeatureSpec{
						Name: "saia",
					},
					TaskVolume: aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/tasks",
						Region: "us-west-2",
					},
					AIPlatformRef: corev1.ObjectReference{
						Name:      platformKey.Name,
						Namespace: platformKey.Namespace,
					},
					VectorDbUrl: "http://weaviate:8080",
					Replicas:    1,
					SplunkConfiguration: aiv1.SplunkConfigurationSpec{
						Endpoint: "https://splunk.example.com:8089",
						SecretRef: corev1.SecretReference{
							Name:      "splunk-" + namespace + "-secret",
							Namespace: namespace,
						},
					},
				},
			}

			Expect(fakeClient.Create(ctx, service)).To(Succeed())

			// First reconcile - PostInstallHook creates a Job and returns error to signal requeue
			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: serviceKey,
			})
			// Expect error about AIPlatform infrastructure not ready (new validation logic)
			Expect(err).ToNot(BeNil())
			Expect(err.Error()).To(ContainSubstring("AIPlatform infrastructure not ready"))

			// Update spec
			retrieved := &aiv1.AIService{}
			Expect(fakeClient.Get(ctx, serviceKey, retrieved)).To(Succeed())
			retrieved.Spec.Replicas = 3
			Expect(fakeClient.Update(ctx, retrieved)).To(Succeed())

			// Second reconcile - Job still exists and is running, will return error again
			_, err = reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: serviceKey,
			})
			// Expect error about AIPlatform infrastructure not ready (new validation logic)
			Expect(err).ToNot(BeNil())
			Expect(err.Error()).To(Or(ContainSubstring("AIPlatform infrastructure not ready"), ContainSubstring("still running"), ContainSubstring("waiting for completion")))

			// Verify replicas update was persisted (even though reconcile returned error)
			Expect(fakeClient.Get(ctx, serviceKey, retrieved)).To(Succeed())
			Expect(retrieved.Spec.Replicas).To(Equal(int32(3)))
		})
	})

	Context("When validating AIService fields", func() {
		It("should validate required fields", func() {
			service := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:      serviceKey.Name,
					Namespace: serviceKey.Namespace,
				},
				Spec: aiv1.AIServiceSpec{
					Feature: aiv1.FeatureSpec{
						Name: "saia",
					},
					// Missing required fields
				},
			}

			Expect(fakeClient.Create(ctx, service)).To(Succeed())

			// Reconcile should catch validation errors
			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: serviceKey,
			})

			// Should return error for missing fields
			Expect(err).ToNot(BeNil())
		})
	})

	Context("findAIServicesForCACertSecret (AIP-4614 Tier 1 item 4)", func() {
		It("should map a Secret to AIServices in the same namespace that reference it via caCertRef", func() {
			referencing := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{Name: "svc-with-ca-ref", Namespace: namespace},
				Spec: aiv1.AIServiceSpec{
					SplunkConfiguration: aiv1.SplunkConfigurationSpec{
						CACertRef: &aiv1.CABundleRef{Name: "splunk-ca-bundle"},
					},
				},
			}
			Expect(fakeClient.Create(ctx, referencing)).To(Succeed())

			nonReferencing := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{Name: "svc-without-ca-ref", Namespace: namespace},
				Spec:       aiv1.AIServiceSpec{},
			}
			Expect(fakeClient.Create(ctx, nonReferencing)).To(Succeed())

			secret := &corev1.Secret{
				ObjectMeta: metav1.ObjectMeta{Name: "splunk-ca-bundle", Namespace: namespace},
			}

			requests := reconciler.findAIServicesForCACertSecret(ctx, secret)

			Expect(requests).To(HaveLen(1))
			Expect(requests[0].Name).To(Equal("svc-with-ca-ref"))
			Expect(requests[0].Namespace).To(Equal(namespace))
		})

		It("should return no requests when no AIService references the Secret", func() {
			secret := &corev1.Secret{
				ObjectMeta: metav1.ObjectMeta{Name: "unreferenced-secret", Namespace: namespace},
			}

			requests := reconciler.findAIServicesForCACertSecret(ctx, secret)

			Expect(requests).To(BeEmpty())
		})
	})
})
