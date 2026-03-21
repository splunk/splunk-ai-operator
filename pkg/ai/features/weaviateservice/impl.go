package weaviateservice

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	defaultServiceName     = "splunk_ai_weaviate_service"
	defaultServiceInternal = "WEAVIATE_SERVICE"
	defaultSplunkIssuer    = "https://splunk-splunk-standalone-standalone-service:8089"
)

type WeaviateServiceReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

// Reconcile runs reconciliation stages for the weaviate-service feature.
func (r *WeaviateServiceReconciler) Reconcile(ctx context.Context, aiservice *aiv1.AIService) error {
	logger := log.FromContext(ctx)

	var conditions []metav1.Condition
	defer func() {
		aiservice.Status.Conditions = conditions
		aiservice.Status.ObservedGeneration = aiservice.Generation
		_ = r.Status().Update(ctx, aiservice)
	}()

	stages := []struct {
		name string
		fn   func(context.Context, *aiv1.AIService) error
	}{
		{"Validate", r.validateAIService},
		{"ServiceAccount", r.reconcileServiceAccount},
		{"WeaviateProxyDeployment", r.reconcileDeployment},
		{"WeaviateProxyService", r.reconcileService},
	}

	for _, stage := range stages {
		err := stage.fn(ctx, aiservice)

		cond := metav1.Condition{
			Type:               stage.name + "Ready",
			Status:             metav1.ConditionTrue,
			Reason:             "Reconciled",
			Message:            "stage succeeded",
			LastTransitionTime: metav1.Now(),
		}
		if err != nil {
			cond.Status = metav1.ConditionFalse
			cond.Reason = "Error"
			cond.Message = err.Error()
		}
		conditions = append(conditions, cond)

		if err != nil {
			logger.Error(err, "stage failed", "stage", stage.name)
			return err
		}
	}

	conditions = append(conditions, metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionTrue,
		Reason:             "AllReconciled",
		Message:            "all stages completed successfully",
		LastTransitionTime: metav1.Now(),
	})

	return nil
}

func (r *WeaviateServiceReconciler) validateAIService(ctx context.Context, ai *aiv1.AIService) error {
	image := resolveWeaviateProxyImage()
	if image == "" {
		return fmt.Errorf("RELATED_IMAGE_WEAVIATE_PROXY or RELATED_IMAGE_WEAVIATE must be set")
	}

	if ai.Spec.VectorDbUrl == "" && ai.Spec.AIPlatformRef.Name != "" {
		platform := &aiv1.AIPlatform{}
		key := types.NamespacedName{Name: ai.Spec.AIPlatformRef.Name, Namespace: ai.Spec.AIPlatformRef.Namespace}
		if key.Namespace == "" {
			key.Namespace = ai.Namespace
		}
		if err := r.Get(ctx, key, platform); err != nil {
			return fmt.Errorf("fetching AIPlatform: %w", err)
		}
		if platform.Status.VectorDbServiceName == "" {
			return fmt.Errorf("VectorDbServiceName not populated in AIPlatform status")
		}
		clusterDomain := ai.Spec.ClusterDomain
		if clusterDomain == "" {
			clusterDomain = "cluster.local"
		}
		ai.Spec.VectorDbUrl = fmt.Sprintf("%s.%s.svc.%s", platform.Status.VectorDbServiceName, key.Namespace, clusterDomain)
	}

	if ai.Spec.VectorDbUrl == "" {
		return fmt.Errorf("vectorDbUrl must be set (either from AIPlatformRef or explicitly)")
	}

	if ai.Spec.Replicas == 0 {
		ai.Spec.Replicas = 1
	}
	if ai.Spec.Resources.Requests == nil {
		ai.Spec.Resources.Requests = corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("250m"),
			corev1.ResourceMemory: resource.MustParse("512Mi"),
		}
	}
	if ai.Spec.Resources.Limits == nil {
		ai.Spec.Resources.Limits = corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("1"),
			corev1.ResourceMemory: resource.MustParse("1Gi"),
		}
	}

	return nil
}

func (r *WeaviateServiceReconciler) reconcileServiceAccount(ctx context.Context, ai *aiv1.AIService) error {
	if ai.Spec.ServiceAccountName == "" {
		ai.Spec.ServiceAccountName = ai.Name + "-sa"
		if err := r.Update(ctx, ai); err != nil {
			return fmt.Errorf("updating serviceAccountName: %w", err)
		}
	}

	sa := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Spec.ServiceAccountName,
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, sa, r.Scheme); err != nil {
		return err
	}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, sa, func() error {
		return nil
	})
	return err
}

func (r *WeaviateServiceReconciler) reconcileDeployment(ctx context.Context, ai *aiv1.AIService) error {
	deployName := ai.Name + "-weaviate-service-deployment"
	appLabel := ai.Name + "-weaviate-service"

	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      deployName,
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, deploy, r.Scheme); err != nil {
		return err
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, deploy, func() error {
		labels := map[string]string{
			"app":     appLabel,
			"feature": "weaviate-service",
		}

		deploy.Spec.Replicas = &ai.Spec.Replicas
		deploy.Spec.Selector = &metav1.LabelSelector{MatchLabels: labels}
		deploy.Spec.Template.ObjectMeta.Labels = labels
		deploy.Spec.Template.Spec.ServiceAccountName = ai.Spec.ServiceAccountName
		deploy.Spec.Template.Spec.ImagePullSecrets = ai.Spec.ImagePullSecrets
		deploy.Spec.Template.Spec.Tolerations = ai.Spec.Tolerations
		deploy.Spec.Template.Spec.Affinity = &ai.Spec.Affinity

		container := corev1.Container{
			Name:            "weaviate-proxy",
			Image:           resolveWeaviateProxyImage(),
			ImagePullPolicy: corev1.PullAlways,
			Resources:       ai.Spec.Resources,
			Ports: []corev1.ContainerPort{
				{Name: "http", ContainerPort: 8080},
			},
			Env: r.buildEnv(ai),
			ReadinessProbe: &corev1.Probe{
				ProbeHandler: corev1.ProbeHandler{
					HTTPGet: &corev1.HTTPGetAction{
						Path: "/v1/.well-known/ready",
						Port: intstr.FromInt(8080),
					},
				},
			},
			LivenessProbe: &corev1.Probe{
				ProbeHandler: corev1.ProbeHandler{
					HTTPGet: &corev1.HTTPGetAction{
						Path: "/v1/.well-known/ready",
						Port: intstr.FromInt(8080),
					},
				},
			},
		}

		deploy.Spec.Template.Spec.Containers = []corev1.Container{container}
		return nil
	})
	if err != nil {
		return fmt.Errorf("create/update deployment: %w", err)
	}
	return nil
}

func (r *WeaviateServiceReconciler) reconcileService(ctx context.Context, ai *aiv1.AIService) error {
	serviceName := ai.Name + "-weaviate-service"
	appLabel := ai.Name + "-weaviate-service"

	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      serviceName,
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, svc, r.Scheme); err != nil {
		return err
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Spec.Selector = map[string]string{"app": appLabel}
		svc.Spec.Ports = []corev1.ServicePort{
			{
				Name:       "http",
				Port:       80,
				TargetPort: intstr.FromInt(8080),
			},
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("create/update service: %w", err)
	}
	return nil
}

func (r *WeaviateServiceReconciler) buildEnv(ai *aiv1.AIService) []corev1.EnvVar {
	clusterDomain := ai.Spec.ClusterDomain
	if clusterDomain == "" {
		clusterDomain = "cluster.local"
	}

	weaviateURL := normalizeWeaviateURL(ai.Spec.VectorDbUrl, ai.Namespace, clusterDomain)
	envMap := map[string]string{
		"SERVICE_NAME":          defaultServiceName,
		"SERVICE_INTERNAL_NAME": defaultServiceInternal,
		"SPLUNK_ISSUERS":        defaultSplunkIssuer,
		"WEAVIATE_URL":          weaviateURL,
	}

	for k, v := range ai.Spec.Env {
		envMap[k] = v
	}

	keys := make([]string, 0, len(envMap))
	for k := range envMap {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	out := make([]corev1.EnvVar, 0, len(keys))
	for _, k := range keys {
		out = append(out, corev1.EnvVar{Name: k, Value: envMap[k]})
	}
	return out
}

func resolveWeaviateProxyImage() string {
	if image := os.Getenv("RELATED_IMAGE_WEAVIATE_PROXY"); image != "" {
		return image
	}
	return os.Getenv("RELATED_IMAGE_WEAVIATE")
}

func normalizeWeaviateURL(vectorDBURL, namespace, clusterDomain string) string {
	url := strings.TrimSpace(vectorDBURL)
	if strings.HasPrefix(url, "http://") || strings.HasPrefix(url, "https://") {
		return url
	}
	if strings.Contains(url, ".") || strings.Contains(url, ":") {
		return "http://" + url
	}
	return fmt.Sprintf("http://%s.%s.svc.%s:80", url, namespace, clusterDomain)
}
