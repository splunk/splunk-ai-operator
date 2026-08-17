package agentruntime

import (
	"context"
	"fmt"
	"hash/fnv"
	"os"
	"sort"
	"strings"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	cmmeta "github.com/cert-manager/cert-manager/pkg/apis/meta/v1"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
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
	defaultMinReplicas          int32 = 1
	defaultMaxReplicas          int32 = 4
	defaultTargetCPUUtilization int32 = 60
	defaultAgentRuntimeHTTPPort int32 = 8080
	defaultAgentRuntimeMetrics  int32 = 9090
	maxDNSLabelLength                 = 63
	mtlsTerminationOperator           = "operator"
	sharedPackagesPath                = "/shared-packages"
)

var defaultAgentModules = map[string]string{
	"mltk": "agentcore_operations.loader:MLTKAgentLoader",
}

type AgentRuntimeReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

func (r *AgentRuntimeReconciler) Reconcile(ctx context.Context, aiservice *aiv1.AIService) error {
	log := log.FromContext(ctx)

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
		{"AgentRuntimeConfigMap", r.reconcileConfigMap},
		{"Certificate", r.reconcileCertificate},
		{"AgentRuntimeDeployment", r.reconcileDeployment},
		{"AgentRuntimeService", r.reconcileService},
		{"AgentRuntimeHPA", r.reconcileHPA},
		{"ServiceMonitor", r.reconcileServiceMonitor},
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
			log.Error(err, "stage failed", "stage", stage.name)
			return err
		}
	}

	conditions = append(conditions, metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionTrue,
		Reason:             "AllReconciled",
		Message:            "all resources are up-to-date",
		LastTransitionTime: metav1.Now(),
	})

	return nil
}

func (r *AgentRuntimeReconciler) validateAIService(ctx context.Context, ai *aiv1.AIService) error {
	if ai.Spec.Feature.Provider == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "provider must be set for agentruntime")
		return fmt.Errorf("provider must be set for agentruntime")
	}
	if _, err := resolveBaseImage(ai); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", err.Error())
		return err
	}
	if _, err := resolveProviderImage(ai); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", err.Error())
		return err
	}
	if ai.Spec.CheckpointDbSecretRef == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "checkpointDbSecretRef must be set")
		return fmt.Errorf("checkpointDbSecretRef must be set")
	}

	if ai.Spec.AIPlatformRef.Name == "" && ai.Spec.AIPlatformUrl == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "AIPlatformRef.Name or AIPlatformUrl must be set")
		return fmt.Errorf("either AIPlatformRef.Name or AIPlatformUrl must be set")
	}

	if ai.Spec.AIPlatformRef.Name != "" {
		aiPlatform, err := r.getAIPlatform(ctx, ai.Spec.AIPlatformRef)
		if err != nil {
			r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "fetching AIPlatform failed")
			return fmt.Errorf("fetching AIPlatform: %w", err)
		}
		if err := r.validateAIPlatformReady(aiPlatform); err != nil {
			return fmt.Errorf("AIPlatform infrastructure not ready: %w", err)
		}

		clusterDomain := ai.Spec.ClusterDomain
		if clusterDomain == "" {
			clusterDomain = "cluster.local"
		}
		if ai.Spec.AIPlatformUrl == "" {
			scheme := ai.Spec.AIPlatformScheme
			if scheme == "" {
				scheme = "http"
			}
			ai.Spec.AIPlatformUrl = fmt.Sprintf("%s://%s.%s.svc.%s:8000",
				scheme, aiPlatform.Status.RayServiceName, ai.Spec.AIPlatformRef.Namespace, clusterDomain)
		}
		if ai.Spec.VectorDbUrl == "" && aiPlatform.Status.VectorDbServiceName != "" {
			ai.Spec.VectorDbUrl = fmt.Sprintf("%s.%s.svc.%s",
				aiPlatform.Status.VectorDbServiceName, ai.Spec.AIPlatformRef.Namespace, clusterDomain)
		}
	}

	if ai.Spec.AIPlatformUrl == "" {
		return fmt.Errorf("AIPlatformUrl must be set")
	}

	defaultAgentRuntimeSpec(ai)
	return nil
}

func (r *AgentRuntimeReconciler) getAIPlatform(ctx context.Context, ref corev1.ObjectReference) (*aiv1.AIPlatform, error) {
	var aiPlatform aiv1.AIPlatform
	key := types.NamespacedName{Name: ref.Name, Namespace: ref.Namespace}
	if err := r.Client.Get(ctx, key, &aiPlatform); err != nil {
		return nil, err
	}
	return &aiPlatform, nil
}

func (r *AgentRuntimeReconciler) validateAIPlatformReady(aiPlatform *aiv1.AIPlatform) error {
	if !common.IsConditionTrue(aiPlatform.Status.Conditions, "RayServiceStatusReady") {
		return fmt.Errorf("RayService is not ready")
	}
	if aiPlatform.Status.RayServiceName == "" {
		return fmt.Errorf("RayServiceName not populated in AIPlatform status")
	}
	return nil
}

func defaultAgentRuntimeSpec(ai *aiv1.AIService) {
	if ai.Spec.Replicas == 0 {
		ai.Spec.Replicas = resolvedMinReplicas(ai)
	}
	if ai.Spec.ServiceAccountName == "" {
		ai.Spec.ServiceAccountName = ai.Name + "-sa"
	}
	if ai.Spec.Resources.Requests == nil {
		ai.Spec.Resources.Requests = corev1.ResourceList{
			corev1.ResourceCPU:              resource.MustParse("500m"),
			corev1.ResourceMemory:           resource.MustParse("512Mi"),
			corev1.ResourceEphemeralStorage: resource.MustParse("1Gi"),
		}
	}
	if ai.Spec.Resources.Limits == nil {
		ai.Spec.Resources.Limits = corev1.ResourceList{
			corev1.ResourceCPU:              resource.MustParse("1"),
			corev1.ResourceMemory:           resource.MustParse("1Gi"),
			corev1.ResourceEphemeralStorage: resource.MustParse("2Gi"),
		}
	}
}

func (r *AgentRuntimeReconciler) reconcileServiceAccount(ctx context.Context, ai *aiv1.AIService) error {
	serviceAccountName := ai.Spec.ServiceAccountName
	if serviceAccountName == "" {
		serviceAccountName = ai.Name + "-sa"
	}

	sa := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{
			Name:      serviceAccountName,
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, sa, r.Scheme); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "ownerref on ServiceAccount failed")
		return fmt.Errorf("ownerref on ServiceAccount: %w", err)
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, sa, func() error { return nil }); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update ServiceAccount failed")
		return fmt.Errorf("create/update ServiceAccount: %w", err)
	}
	return nil
}

func (r *AgentRuntimeReconciler) reconcileConfigMap(ctx context.Context, ai *aiv1.AIService) error {
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-agentruntime-config",
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, cm, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on ConfigMap: %w", err)
	}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, cm, func() error {
		cm.Data = map[string]string{
			"provider":       ai.Spec.Feature.Provider,
			"featureVersion": ai.Spec.Version,
			"runtimeVersion": ai.Spec.RuntimeVersion,
			"agentModule":    resolveAgentModule(ai.Spec.Feature.Provider),
		}
		return nil
	})
	return err
}

func (r *AgentRuntimeReconciler) reconcileCertificate(ctx context.Context, ai *aiv1.AIService) error {
	if !ai.Spec.MTLS.Enabled || ai.Spec.MTLS.Termination != mtlsTerminationOperator {
		return nil
	}

	secretName := ai.Spec.MTLS.SecretName
	if secretName == "" {
		secretName = ai.Name + "-tls"
	}
	workloadName := agentRuntimeWorkloadName(ai.Name)
	serviceName := agentRuntimeServiceName(ai.Name)

	cert := &certmanagerv1.Certificate{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-agentruntime-cert",
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, cert, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on Certificate: %w", err)
	}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, cert, func() error {
		cert.Spec = certmanagerv1.CertificateSpec{
			SecretName: secretName,
			DNSNames: []string{
				workloadName,
				serviceName,
				fmt.Sprintf("%s.%s.svc", serviceName, ai.Namespace),
			},
			IssuerRef: cmmeta.ObjectReference{
				Name:  ai.Spec.MTLS.IssuerRef.Name,
				Kind:  ai.Spec.MTLS.IssuerRef.Kind,
				Group: ai.Spec.MTLS.IssuerRef.Group,
			},
		}
		return nil
	})
	return err
}

func (r *AgentRuntimeReconciler) reconcileDeployment(ctx context.Context, ai *aiv1.AIService) error {
	baseImage, err := resolveBaseImage(ai)
	if err != nil {
		return err
	}
	providerImage, err := resolveProviderImage(ai)
	if err != nil {
		return err
	}

	labels, annotations := labelsAndAnnotations(ai)
	selectorLabels := agentRuntimeSelectorLabels(ai)
	containerName := agentRuntimeWorkloadName(ai.Name)
	env := buildAgentRuntimeEnv(ai)
	sort.Slice(env, func(i, j int) bool { return env[i].Name < env[j].Name })
	volumes := []corev1.Volume{{
		Name: "provider-packages",
		VolumeSource: corev1.VolumeSource{
			EmptyDir: &corev1.EmptyDirVolumeSource{},
		},
	}}
	mounts := []corev1.VolumeMount{
		{Name: "provider-packages", MountPath: sharedPackagesPath, ReadOnly: true},
	}
	if ai.Spec.MTLS.Enabled && ai.Spec.MTLS.Termination == mtlsTerminationOperator {
		secretName := ai.Spec.MTLS.SecretName
		if secretName == "" {
			secretName = ai.Name + "-tls"
		}
		volumes = append(volumes, corev1.Volume{
			Name: "tls",
			VolumeSource: corev1.VolumeSource{
				Secret: &corev1.SecretVolumeSource{SecretName: secretName},
			},
		})
		mounts = append(mounts, corev1.VolumeMount{Name: "tls", MountPath: "/etc/tls", ReadOnly: true})
	}

	deployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-agentruntime-deployment",
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, deployment, r.Scheme); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "ownerref on Deployment failed")
		return fmt.Errorf("ownerref on Deployment: %w", err)
	}

	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, deployment, func() error {
		deployment.ObjectMeta.Labels = labels
		deployment.ObjectMeta.Annotations = annotations
		deployment.Spec.Replicas = &ai.Spec.Replicas

		if deployment.Spec.Selector == nil {
			deployment.Spec.Selector = &metav1.LabelSelector{
				MatchLabels: selectorLabels,
			}
		}

		deployment.Spec.Template = corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{
				Labels:      selectorLabels,
				Annotations: annotations,
			},
			Spec: corev1.PodSpec{
				ServiceAccountName: ai.Spec.ServiceAccountName,
				InitContainers: []corev1.Container{{
					Name:            "fetch-provider-wheel",
					Image:           providerImage,
					ImagePullPolicy: corev1.PullIfNotPresent,
					Command:         []string{"/bin/sh", "-c"},
					Args:            []string{"cp -a /payload/. " + sharedPackagesPath + "/"},
					VolumeMounts: []corev1.VolumeMount{
						{Name: "provider-packages", MountPath: sharedPackagesPath},
					},
				}},
				Containers: []corev1.Container{{
					Name:            containerName,
					Image:           baseImage,
					ImagePullPolicy: corev1.PullIfNotPresent,
					Ports: []corev1.ContainerPort{
						{Name: "http", ContainerPort: defaultAgentRuntimeHTTPPort},
						{Name: "metrics", ContainerPort: defaultAgentRuntimeMetrics},
					},
					Resources: ai.Spec.Resources,
					Env:       env,
					EnvFrom: []corev1.EnvFromSource{{
						SecretRef: &corev1.SecretEnvSource{
							LocalObjectReference: corev1.LocalObjectReference{Name: ai.Spec.CheckpointDbSecretRef},
						},
					}},
					VolumeMounts:   mounts,
					LivenessProbe:  httpProbe("/health", defaultAgentRuntimeHTTPPort),
					ReadinessProbe: httpProbe("/health", defaultAgentRuntimeHTTPPort),
					StartupProbe:   httpProbe("/health", defaultAgentRuntimeHTTPPort),
				}},
				Volumes:          volumes,
				Affinity:         &ai.Spec.Affinity,
				Tolerations:      ai.Spec.Tolerations,
				NodeSelector:     ai.Spec.NodeSelector,
				ImagePullSecrets: ai.Spec.ImagePullSecrets,
			},
		}
		return nil
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update Deployment failed")
		return fmt.Errorf("create/update Deployment: %w", err)
	}
	return nil
}

func (r *AgentRuntimeReconciler) reconcileService(ctx context.Context, ai *aiv1.AIService) error {
	serviceTemplate := ai.Spec.ServiceTemplate.DeepCopy()
	cleanServiceTemplate(serviceTemplate)

	ports := []corev1.ServicePort{
		{Name: "http", Port: defaultAgentRuntimeHTTPPort, TargetPort: intstr.FromInt(int(defaultAgentRuntimeHTTPPort))},
		{Name: "metrics", Port: defaultAgentRuntimeMetrics, TargetPort: intstr.FromInt(int(defaultAgentRuntimeMetrics))},
	}

	svcType := corev1.ServiceTypeClusterIP
	switch serviceTemplate.Spec.Type {
	case corev1.ServiceTypeLoadBalancer:
		svcType = corev1.ServiceTypeLoadBalancer
	case corev1.ServiceTypeNodePort:
		svcType = corev1.ServiceTypeNodePort
		for i, port := range ports {
			for _, tplPort := range serviceTemplate.Spec.Ports {
				if port.Name == tplPort.Name && tplPort.NodePort != 0 {
					ports[i].NodePort = tplPort.NodePort
				}
			}
		}
	}

	labels, _ := labelsAndAnnotations(ai)
	selectorLabels := agentRuntimeSelectorLabels(ai)
	annotations := common.FilterPropagatedAnnotations(ai.Annotations)
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      agentRuntimeServiceName(ai.Name),
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, svc, r.Scheme); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "ownerref on Service failed")
		return fmt.Errorf("ownerref on Service: %w", err)
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.ObjectMeta.Labels = labels
		svc.ObjectMeta.Annotations = annotations
		svc.Spec.Selector = selectorLabels
		svc.Spec.Ports = ports
		svc.Spec.Type = svcType
		return nil
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update Service failed")
		return fmt.Errorf("create/update Service: %w", err)
	}
	return nil
}

func (r *AgentRuntimeReconciler) reconcileHPA(ctx context.Context, ai *aiv1.AIService) error {
	hpa := &autoscalingv2.HorizontalPodAutoscaler{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-agentruntime-hpa",
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, hpa, r.Scheme); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "ownerref on HPA failed")
		return fmt.Errorf("ownerref on HPA: %w", err)
	}

	minReplicas := resolvedMinReplicas(ai)
	maxReplicas := resolvedMaxReplicas(ai)
	targetCPU := resolvedTargetCPUUtilization(ai)
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, hpa, func() error {
		hpa.Spec = autoscalingv2.HorizontalPodAutoscalerSpec{
			ScaleTargetRef: autoscalingv2.CrossVersionObjectReference{
				APIVersion: "apps/v1",
				Kind:       "Deployment",
				Name:       ai.Name + "-agentruntime-deployment",
			},
			MinReplicas: &minReplicas,
			MaxReplicas: maxReplicas,
			Metrics: []autoscalingv2.MetricSpec{{
				Type: autoscalingv2.ResourceMetricSourceType,
				Resource: &autoscalingv2.ResourceMetricSource{
					Name: corev1.ResourceCPU,
					Target: autoscalingv2.MetricTarget{
						Type:               autoscalingv2.UtilizationMetricType,
						AverageUtilization: &targetCPU,
					},
				},
			}},
		}
		return nil
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update HPA failed")
		return fmt.Errorf("create/update HPA: %w", err)
	}
	return nil
}

func resolvedMinReplicas(ai *aiv1.AIService) int32 {
	if ai.Spec.MinReplicas != nil {
		return *ai.Spec.MinReplicas
	}
	return defaultMinReplicas
}

func resolvedMaxReplicas(ai *aiv1.AIService) int32 {
	maxReplicas := defaultMaxReplicas
	if ai.Spec.MaxReplicas != nil {
		maxReplicas = *ai.Spec.MaxReplicas
	}
	minReplicas := resolvedMinReplicas(ai)
	if maxReplicas < minReplicas {
		return minReplicas
	}
	return maxReplicas
}

func resolvedTargetCPUUtilization(ai *aiv1.AIService) int32 {
	if ai.Spec.TargetCPUUtilization != nil {
		return *ai.Spec.TargetCPUUtilization
	}
	return defaultTargetCPUUtilization
}

func (r *AgentRuntimeReconciler) reconcileServiceMonitor(ctx context.Context, ai *aiv1.AIService) error {
	if !ai.Spec.Metrics.Enabled {
		return nil
	}

	sm := &monitoringv1.ServiceMonitor{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-agentruntime-metrics",
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, sm, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on ServiceMonitor: %w", err)
	}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, sm, func() error {
		sm.Spec = monitoringv1.ServiceMonitorSpec{
			Selector: metav1.LabelSelector{
				MatchLabels: agentRuntimeSelectorLabels(ai),
			},
			Endpoints: []monitoringv1.Endpoint{
				{Port: "metrics", Path: ai.Spec.Metrics.Path, Scheme: "http"},
			},
		}
		return nil
	})
	return err
}

func agentRuntimeWorkloadName(aiServiceName string) string {
	return boundedDNSLabel(aiServiceName)
}

func agentRuntimeSelectorLabels(ai *aiv1.AIService) map[string]string {
	workloadName := agentRuntimeWorkloadName(ai.Name)
	return map[string]string{"app": workloadName, "component": workloadName}
}

func agentRuntimeServiceName(aiServiceName string) string {
	return dnsLabelName(aiServiceName, "agentruntime-service")
}

func boundedDNSLabel(name string) string {
	if len(name) <= maxDNSLabelLength {
		return name
	}
	hash := shortHash(name)
	maxPrefixLength := maxDNSLabelLength - len(hash) - 1
	truncated := strings.TrimRight(name[:maxPrefixLength], "-")
	if truncated == "" {
		truncated = name[:maxPrefixLength]
	}
	return truncated + "-" + hash
}

func dnsLabelName(base, suffix string) string {
	name := base + "-" + suffix
	if len(name) <= maxDNSLabelLength {
		return name
	}

	hash := shortHash(name)
	maxBaseLength := maxDNSLabelLength - len(suffix) - len(hash) - 2
	if maxBaseLength < 1 {
		return hash + "-" + suffix
	}
	truncated := strings.TrimRight(base[:maxBaseLength], "-")
	if truncated == "" {
		truncated = base[:maxBaseLength]
	}
	return truncated + "-" + hash + "-" + suffix
}

func shortHash(value string) string {
	h := fnv.New32a()
	_, _ = h.Write([]byte(value))
	return fmt.Sprintf("%08x", h.Sum32())
}

func buildAgentRuntimeEnv(ai *aiv1.AIService) []corev1.EnvVar {
	platformURL := strings.TrimRight(ai.Spec.AIPlatformUrl, "/")
	env := []corev1.EnvVar{
		{Name: "AGENT_MODULE", Value: resolveAgentModule(ai.Spec.Feature.Provider)},
		{Name: "CHECKPOINT_DB_SECRET_REF", Value: ai.Spec.CheckpointDbSecretRef},
		{Name: "PLATFORM_URL", Value: platformURL},
		{Name: "PYTHONPATH", Value: sharedPackagesPath},
	}
	if ai.Spec.MTLS.Enabled && ai.Spec.MTLS.Termination == mtlsTerminationOperator {
		env = append(env,
			corev1.EnvVar{Name: "TLS_CERT_FILE", Value: "/etc/tls/tls.crt"},
			corev1.EnvVar{Name: "TLS_KEY_FILE", Value: "/etc/tls/tls.key"},
		)
	} else {
		env = append(env, corev1.EnvVar{Name: "TLS_DISABLED", Value: "true"})
	}
	if ai.Spec.VectorDbUrl != "" {
		env = append(env, corev1.EnvVar{Name: "VECTOR_DB_URL", Value: ai.Spec.VectorDbUrl})
	}
	return env
}

func labelsAndAnnotations(ai *aiv1.AIService) (map[string]string, map[string]string) {
	workloadName := agentRuntimeWorkloadName(ai.Name)
	labels := map[string]string{
		"app":       workloadName,
		"component": workloadName,
		"feature":   "agentruntime",
		"provider":  ai.Spec.Feature.Provider,
		"area":      "ml",
		"team":      "ml",
	}
	for k, v := range ai.Labels {
		labels[k] = v
	}

	annotations := map[string]string{
		"prometheus.io/port":   fmt.Sprintf("%d", defaultAgentRuntimeMetrics),
		"prometheus.io/path":   "/metrics",
		"prometheus.io/scheme": "http",
	}
	for k, v := range common.FilterPropagatedAnnotations(ai.Annotations) {
		annotations[k] = v
	}
	return labels, annotations
}

func httpProbe(path string, port int32) *corev1.Probe {
	return &corev1.Probe{
		ProbeHandler: corev1.ProbeHandler{
			HTTPGet: &corev1.HTTPGetAction{
				Path: path,
				Port: intstr.FromInt(int(port)),
			},
		},
		InitialDelaySeconds: 10,
		PeriodSeconds:       30,
		FailureThreshold:    10,
	}
}

func resolveBaseImage(ai *aiv1.AIService) (string, error) {
	if ai.Spec.RuntimeVersion != "" {
		envName := "RELATED_IMAGE_AGENT_RUNTIME_BASE_" + normalizeEnvKeySegment(ai.Spec.RuntimeVersion)
		if image := os.Getenv(envName); image != "" {
			return image, nil
		}
		return "", fmt.Errorf("%s must be set when runtimeVersion %q is requested", envName, ai.Spec.RuntimeVersion)
	}
	if image := os.Getenv("RELATED_IMAGE_AGENT_RUNTIME_BASE"); image != "" {
		return image, nil
	}
	return "", fmt.Errorf("RELATED_IMAGE_AGENT_RUNTIME_BASE must be set")
}

func resolveProviderImage(ai *aiv1.AIService) (string, error) {
	envName := "RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_" + normalizeEnvKeySegment(ai.Spec.Feature.Provider)
	if image := os.Getenv(envName); image != "" {
		return image, nil
	}
	return "", fmt.Errorf("%s must be set", envName)
}

func resolveAgentModule(provider string) string {
	envName := "RELATED_AGENT_RUNTIME_MODULE_PROVIDER_" + normalizeEnvKeySegment(provider)
	if module := os.Getenv(envName); module != "" {
		return module
	}
	if module, ok := defaultAgentModules[provider]; ok {
		return module
	}
	return fmt.Sprintf("%s.loader:AgentLoader", provider)
}

func normalizeEnvKeySegment(value string) string {
	value = strings.ToUpper(value)
	var b strings.Builder
	lastUnderscore := false
	for _, r := range value {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			lastUnderscore = false
			continue
		}
		if !lastUnderscore {
			b.WriteByte('_')
			lastUnderscore = true
		}
	}
	return strings.Trim(b.String(), "_")
}

func cleanServiceTemplate(svc *corev1.Service) {
	if svc == nil {
		return
	}
	svc.TypeMeta = metav1.TypeMeta{}
	svc.ObjectMeta = metav1.ObjectMeta{}
	svc.Status = corev1.ServiceStatus{}
}
