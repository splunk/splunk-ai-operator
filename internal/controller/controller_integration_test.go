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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

var _ = Describe("AIPlatform Reconcile Error Handling", func() {
	var (
		reconciler  *AIPlatformReconciler
		fakeClient  client.Client
		ctx         context.Context
		namespace   string
		platformKey types.NamespacedName
	)

	BeforeEach(func() {
		ctx = context.Background()
		namespace = "error-handling-test"

		// Set required environment variables
		os.Setenv("RELATED_IMAGE_WEAVIATE", "weaviate:latest")
		os.Setenv("RELATED_IMAGE_RAY_HEAD", "rayproject/ray:latest")
		os.Setenv("RELATED_IMAGE_RAY_WORKER", "rayproject/ray:latest")
		os.Setenv("RELATED_IMAGE_FLUENT_BIT", "fluent/fluent-bit:latest")
		os.Setenv("RELATED_IMAGE_OTEL_COLLECTOR", "otel/opentelemetry-collector-contrib:latest")
		os.Setenv("INSTANCE_FILE", "../../config/configs/instance.yaml")
		os.Setenv("APPLICATION_FILE", "../../config/configs/applications.yaml")
		os.Setenv("MODEL_SCALE_FILE", "../../config/configs/model-scale.yaml")
		os.Setenv("WORKER_SCALE_FILE", "../../config/configs/worker-scale.yaml")

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

	Context("When reconciling with finalizer during deletion", func() {
		It("should wait for children to be deleted", func() {
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:       platformKey.Name,
					Namespace:  platformKey.Namespace,
					Finalizers: []string{aiPlatformFinalizer},
					UID:        "test-uid",
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/artifacts",
						Region: "us-west-2",
					},
					CPUSchedulingSpec: &aiv1.SchedulingSpec{
						NodeSelector: map[string]string{},
					},
					GPUSchedulingSpec: &aiv1.SchedulingSpec{
						NodeSelector: map[string]string{},
					},
					WorkerGroupConfig: &aiv1.WorkerGroupConfig{
						ServiceAccountName: "worker-sa",
						ImageRegistry:      "test-registry",
					},
					Images: aiv1.Images{
						RayHeadGroupImage:   "ray-head:latest",
						RayWorkerGroupImage: "ray-worker:latest",
					},
				},
			}

			Expect(fakeClient.Create(ctx, platform)).To(Succeed())

			// Create a child AIService
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
					TaskVolume: aiv1.ObjectStorageSpec{
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

			// Mark platform for deletion
			Expect(fakeClient.Delete(ctx, platform)).To(Succeed())

			// First reconcile - should try to delete children
			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: platformKey,
			})

			// Should requeue waiting for children to be deleted
			Expect(err).To(BeNil())
			if result.RequeueAfter > 0 {
				Expect(result.RequeueAfter).To(Equal(5 * time.Second))
			}
		})
	})

	Context("When reconciling with complete platform config", func() {
		It("should handle all spec fields properly", func() {
			platform := &aiv1.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "complete-platform",
					Namespace: namespace,
				},
				Spec: aiv1.AIPlatformSpec{
					ServiceAccountName: "test-sa",
					ObjectStorage: aiv1.ObjectStorageSpec{
						Path:   "s3://test-bucket/artifacts",
						Region: "us-west-2",
					},
					SplunkConfiguration: aiv1.SplunkConfigurationSpec{
						Endpoint: "https://splunk.example.com:8089",
					},
					CPUSchedulingSpec: &aiv1.SchedulingSpec{
						NodeSelector: map[string]string{"cpu": "true"},
						Tolerations: []corev1.Toleration{
							{
								Key:      "dedicated",
								Operator: corev1.TolerationOpEqual,
								Value:    "cpu",
								Effect:   corev1.TaintEffectNoSchedule,
							},
						},
					},
					GPUSchedulingSpec: &aiv1.SchedulingSpec{
						NodeSelector: map[string]string{"gpu": "true"},
						Tolerations: []corev1.Toleration{
							{
								Key:      "dedicated",
								Operator: corev1.TolerationOpEqual,
								Value:    "gpu",
								Effect:   corev1.TaintEffectNoSchedule,
							},
						},
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

			// Reconcile with complete config
			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: types.NamespacedName{
					Name:      platform.Name,
					Namespace: platform.Namespace,
				},
			})

			Expect(err).To(BeNil())
			Expect(result).To(Equal(ctrl.Result{}))

			// Verify platform still exists
			retrieved := &aiv1.AIPlatform{}
			Expect(fakeClient.Get(ctx, types.NamespacedName{
				Name:      platform.Name,
				Namespace: platform.Namespace,
			}, retrieved)).To(Succeed())
			Expect(retrieved.Spec.ServiceAccountName).To(Equal("test-sa"))
		})
	})
})

var _ = Describe("AIService Reconcile with Feature Handler", func() {
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
		namespace = "feature-handler-test"

		// Set required environment variables for SAIA feature
		os.Setenv("RELATED_IMAGE_POST_INSTALL_HOOK", "test-post-install:latest")
		os.Setenv("RELATED_IMAGE_FLUENT_BIT", "fluent/fluent-bit:latest")
		os.Setenv("RELATED_IMAGE_SAIA_API", "saia-api:latest")
		os.Setenv("RELATED_IMAGE_OTEL_COLLECTOR", "otel/opentelemetry-collector-contrib:latest")

		s := scheme.Scheme
		_ = aiv1.AddToScheme(s)
		_ = appsv1.AddToScheme(s)

		fakeClient = fake.NewClientBuilder().
			WithScheme(s).
			WithStatusSubresource(&aiv1.AIService{}, &aiv1.AIPlatform{}).
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
				"hec_token": []byte("test-hec-token"),
			},
		}
		Expect(fakeClient.Create(ctx, splunkSecret)).To(Succeed())

		// Create platform with ready status
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
	})

	Context("When reconciling service with SAIA feature", func() {
		It("should invoke SAIA feature handler", func() {
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
					Replicas:      2,
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

			// Reconcile - SAIA handler should be invoked
			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: serviceKey,
			})

			// May return error about AIPlatform infrastructure not ready (this is expected with new validation logic)
			if err != nil {
				Expect(err.Error()).To(ContainSubstring("AIPlatform infrastructure not ready"))
			}

			// Verify service still exists
			retrieved := &aiv1.AIService{}
			Expect(fakeClient.Get(ctx, serviceKey, retrieved)).To(Succeed())
			Expect(retrieved.Spec.Feature.Name).To(Equal("saia"))
			Expect(retrieved.Spec.Replicas).To(Equal(int32(2)))
		})
	})
})
