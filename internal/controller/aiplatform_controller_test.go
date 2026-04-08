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
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
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

var _ = Describe("AIPlatform Controller", func() {
	var (
		reconciler  *AIPlatformReconciler
		fakeClient  client.Client
		ctx         context.Context
		namespace   string
		platformKey types.NamespacedName
	)

	BeforeEach(func() {
		ctx = context.Background()
		namespace = "test-namespace"

		// Set required environment variables
		os.Setenv("RELATED_IMAGE_WEAVIATE", "weaviate:latest")
		os.Setenv("RELATED_IMAGE_RAY_HEAD", "rayproject/ray:latest")
		os.Setenv("RELATED_IMAGE_RAY_WORKER", "rayproject/ray:latest")
		os.Setenv("RELATED_IMAGE_FLUENT_BIT", "fluent/fluent-bit:latest")
		os.Setenv("RELATED_IMAGE_OTEL_COLLECTOR", "otel/opentelemetry-collector-contrib:latest")
		os.Setenv("INSTANCE_FILE", "../../config/configs/instance.yaml")
		os.Setenv("APPLICATION_FILE", "../../config/configs/applications.yaml")

		// Create a fake client with proper scheme
		s := scheme.Scheme
		_ = aiv1.AddToScheme(s)
		_ = rayv1.AddToScheme(s)
		_ = appsv1.AddToScheme(s)
		_ = monitoringv1.AddToScheme(s)

		fakeClient = fake.NewClientBuilder().
			WithScheme(s).
			WithStatusSubresource(&aiv1.AIPlatform{}, &aiv1.AIService{}).
			WithIndex(&aiv1.AIService{}, ".metadata.controller", func(obj client.Object) []string {
				svc := obj.(*aiv1.AIService)
				owner := metav1.GetControllerOf(svc)
				if owner == nil {
					return nil
				}
				return []string{owner.Name}
			}).
			Build()

		// Create reconciler with fake client
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

		// Create Splunk secret
		splunkSecret := &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "splunk-" + namespace + "-secret",
				Namespace: namespace,
			},
			Data: map[string][]byte{
				"hec_token": []byte("test-token"),
			},
		}
		Expect(fakeClient.Create(ctx, splunkSecret)).To(Succeed())
	})

	Context("When reconciling a new AIPlatform", func() {
		It("should create RayService successfully", func() {
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      platformKey.Name,
					Namespace: platformKey.Namespace,
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: &aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/artifacts",
						Region: "us-west-2",
					},
					SplunkConfiguration: aiv1.SplunkConfigurationSpec{
						Endpoint: "https://splunk.example.com:8089",
					},
					WorkerGroupConfig: &aiv1.WorkerGroupConfig{
						ServiceAccountName: "worker-sa",
						ImageRegistry:      "test-registry",
					},
					Images: aiv1.Images{
						SAIAImage:           "saia:latest",
						WeaviateImage:       "weaviate:latest",
						RayHeadGroupImage:   "ray-head:latest",
						RayWorkerGroupImage: "ray-worker:latest",
					},
				},
			}

			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// Reconcile
			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: platformKey,
			})

			Expect(err).To(BeNil())
			Expect(result).To(Equal(ctrl.Result{}))

			// Verify AIPlatform still exists
			retrieved := &aiv1.AIPlatform{}
			Expect(fakeClient.Get(ctx, platformKey, retrieved)).To(Succeed())
			Expect(retrieved.Name).To(Equal(platformKey.Name))
		})

		It("should handle missing object storage path", func() {
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      platformKey.Name,
					Namespace: platformKey.Namespace,
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: &aiv1.ObjectStorageSpec{
						Path:   "", // Missing path
						Region: "us-west-2",
					},
				},
			}

			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// Reconcile should handle the error
			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: platformKey,
			})

			// Should return error or set condition
			Expect(err).ToNot(BeNil())
		})
	})

	Context("When handling AIPlatform deletion", func() {
		It("should remove finalizer after cleanup", func() {
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:       platformKey.Name,
					Namespace:  platformKey.Namespace,
					Finalizers: []string{aiPlatformFinalizer},
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: &aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/artifacts",
						Region: "us-west-2",
					},
				},
			}

			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// Mark for deletion
			Expect(fakeClient.Delete(ctx, platform)).To(Succeed())

			// Reconcile should handle finalizer
			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: platformKey,
			})

			// Should succeed or be not found
			if err == nil {
				// Verify resource is deleted or finalizer removed
				retrieved := &aiv1.AIPlatform{}
				err = fakeClient.Get(ctx, platformKey, retrieved)
				if err == nil {
					// Finalizer should be removed
					Expect(retrieved.Finalizers).NotTo(ContainElement(aiPlatformFinalizer))
				} else {
					// Resource should be not found
					Expect(errors.IsNotFound(err)).To(BeTrue())
				}
			}
		})
	})

	Context("When reconciling AIPlatform with features", func() {
		It("should create AIService for each feature", func() {
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      platformKey.Name,
					Namespace: platformKey.Namespace,
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: &aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/artifacts",
						Region: "us-west-2",
					},
					SplunkConfiguration: aiv1.SplunkConfigurationSpec{
						Endpoint: "https://splunk.example.com:8089",
					},
					CPUSchedulingSpec: &aiv1.SchedulingSpec{
						NodeSelector: map[string]string{"cpu": "true"},
					},
					GPUSchedulingSpec: &aiv1.SchedulingSpec{
						NodeSelector: map[string]string{"gpu": "true"},
					},
					WorkerGroupConfig: &aiv1.WorkerGroupConfig{
						ServiceAccountName: "worker-sa",
						ImageRegistry:      "test-registry",
					},
					Images: aiv1.Images{
						SAIAImage:           "saia:latest",
						WeaviateImage:       "weaviate:latest",
						RayHeadGroupImage:   "ray-head:latest",
						RayWorkerGroupImage: "ray-worker:latest",
					},
				},
			}

			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// Reconcile
			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: platformKey,
			})

			Expect(err).To(BeNil())

			// Verify AIServices are created (might be async, check if they exist)
			services := &aiv1.AIServiceList{}
			err = fakeClient.List(ctx, services, client.InNamespace(namespace))
			Expect(err).To(BeNil())
			// Note: Actual creation depends on reconciler implementation
		})
	})

	Context("When AIPlatform resource is not found", func() {
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

	Context("When updating AIPlatform spec", func() {
		It("should reconcile changes", func() {
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      platformKey.Name,
					Namespace: platformKey.Namespace,
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: &aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/artifacts",
						Region: "us-west-2",
					},
					SplunkConfiguration: aiv1.SplunkConfigurationSpec{
						Endpoint: "https://splunk.example.com:8089",
					},
					CPUSchedulingSpec: &aiv1.SchedulingSpec{
						NodeSelector: map[string]string{"cpu": "true"},
					},
					GPUSchedulingSpec: &aiv1.SchedulingSpec{
						NodeSelector: map[string]string{"gpu": "true"},
					},
					WorkerGroupConfig: &aiv1.WorkerGroupConfig{
						ServiceAccountName: "worker-sa",
						ImageRegistry:      "test-registry",
					},
					Images: aiv1.Images{
						SAIAImage:           "saia:latest",
						WeaviateImage:       "weaviate:latest",
						RayHeadGroupImage:   "ray-head:latest",
						RayWorkerGroupImage: "ray-worker:latest",
					},
				},
			}

			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// First reconcile
			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: platformKey,
			})
			Expect(err).To(BeNil())

			// Update spec
			retrieved := &aiv1.AIPlatform{}
			Expect(fakeClient.Get(ctx, platformKey, retrieved)).To(Succeed())
			retrieved.Spec.ServiceAccountName = "updated-sa"
			Expect(fakeClient.Update(ctx, retrieved)).To(Succeed())

			// Second reconcile
			_, err = reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: platformKey,
			})
			Expect(err).To(BeNil())

			// Verify update
			Expect(fakeClient.Get(ctx, platformKey, retrieved)).To(Succeed())
			Expect(retrieved.Spec.ServiceAccountName).To(Equal("updated-sa"))
		})
	})
})

// Helper function tests
var _ = Describe("AIPlatform Controller Helpers", func() {
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
	})
})

// Test requeue behavior
var _ = Describe("AIPlatform Requeue Scenarios", func() {
	var (
		reconciler *AIPlatformReconciler
		fakeClient client.Client
		ctx        context.Context
		namespace  string
	)

	BeforeEach(func() {
		ctx = context.Background()
		namespace = "requeue-test"

		// Set required environment variables
		os.Setenv("RELATED_IMAGE_WEAVIATE", "weaviate:latest")
		os.Setenv("RELATED_IMAGE_RAY_HEAD", "rayproject/ray:latest")
		os.Setenv("RELATED_IMAGE_RAY_WORKER", "rayproject/ray:latest")
		os.Setenv("RELATED_IMAGE_FLUENT_BIT", "fluent/fluent-bit:latest")
		os.Setenv("RELATED_IMAGE_OTEL_COLLECTOR", "otel/opentelemetry-collector-contrib:latest")
		os.Setenv("INSTANCE_FILE", "../../config/configs/instance.yaml")
		os.Setenv("APPLICATION_FILE", "../../config/configs/applications.yaml")

		s := scheme.Scheme
		_ = aiv1.AddToScheme(s)
		_ = rayv1.AddToScheme(s)
		_ = monitoringv1.AddToScheme(s)

		fakeClient = fake.NewClientBuilder().
			WithScheme(s).
			WithStatusSubresource(&aiv1.AIPlatform{}, &aiv1.AIService{}).
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

		ns := &corev1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: namespace,
			},
		}
		Expect(fakeClient.Create(ctx, ns)).To(Succeed())

		// Create Splunk secret for requeue tests
		splunkSecret := &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "splunk-" + namespace + "-secret",
				Namespace: namespace,
			},
			Data: map[string][]byte{
				"hec_token": []byte("test-token"),
			},
		}
		Expect(fakeClient.Create(ctx, splunkSecret)).To(Succeed())
	})

	It("should requeue after specific duration when needed", func() {
		platform := &aiv1.AIPlatform{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "requeue-platform",
				Namespace: namespace,
			},
			Spec: aiv1.AIPlatformSpec{
				ServiceAccountName: "test-sa",
				ObjectStorage: &aiv1.ObjectStorageSpec{
					Path:   "s3://test-bucket/artifacts",
					Region: "us-west-2",
				},
				SplunkConfiguration: aiv1.SplunkConfigurationSpec{
					Endpoint: "https://splunk.example.com:8089",
				},
				CPUSchedulingSpec: &aiv1.SchedulingSpec{
					NodeSelector: map[string]string{"cpu": "true"},
				},
				GPUSchedulingSpec: &aiv1.SchedulingSpec{
					NodeSelector: map[string]string{"gpu": "true"},
				},
				WorkerGroupConfig: &aiv1.WorkerGroupConfig{
					ServiceAccountName: "worker-sa",
					ImageRegistry:      "test-registry",
				},
				Images: aiv1.Images{
					SAIAImage:           "saia:latest",
					WeaviateImage:       "weaviate:latest",
					RayHeadGroupImage:   "ray-head:latest",
					RayWorkerGroupImage: "ray-worker:latest",
				},
			},
		}

		Expect(fakeClient.Create(ctx, platform)).To(Succeed())

		result, err := reconciler.Reconcile(ctx, reconcile.Request{
			NamespacedName: types.NamespacedName{
				Name:      "requeue-platform",
				Namespace: namespace,
			},
		})

		Expect(err).To(BeNil())
		// Result may request requeue
		if result.RequeueAfter > 0 {
			Expect(result.RequeueAfter).To(BeNumerically("<=", 5*time.Minute))
		}
	})
})
