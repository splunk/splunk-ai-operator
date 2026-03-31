package slim

import (
	"context"
	"fmt"
	"os"
	"reflect"
	"sort"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	cmmeta "github.com/cert-manager/cert-manager/pkg/apis/meta/v1"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	common "github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	"github.com/splunk/splunk-ai-operator/pkg/ai/sidecars"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

type SlimReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

func (r *SlimReconciler) Reconcile(ctx context.Context, aiservice *aiv1.AIService) error {
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
		{"SlimConfigMap", r.reconcileSlimConfigMap},
		{"FeatureConfigMap", r.reconcileFeatureConfigMap},
		{"OtelConfigMap", r.reconcileOtelConfigMap},
		{"Certificate", r.reconcileCertificate},
		{"SlimDeployment", r.reconcileSlimDeployment},
		{"SlimService", r.reconcileSlimService},
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
		Message:            "all stages completed successfully",
		LastTransitionTime: metav1.Now(),
	})

	return nil
}

func (r *SlimReconciler) validateAIService(ctx context.Context, ai *aiv1.AIService) error {
	cleanServiceTemplate(&ai.Spec.ServiceTemplate)

	if os.Getenv("RELATED_IMAGE_SLIM_API") == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "RELATED_IMAGE_SLIM_API must be set")
		return fmt.Errorf("RELATED_IMAGE_SLIM_API must be set")
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

		if err := r.validateAIPlatformReady(ctx, aiPlatform); err != nil {
			return fmt.Errorf("AIPlatform infrastructure not ready: %w", err)
		}

		clusterDomain := ai.Spec.ClusterDomain
		if clusterDomain == "" {
			clusterDomain = "cluster.local"
		}
		if ai.Spec.AIPlatformUrl == "" {
			ai.Spec.AIPlatformUrl = fmt.Sprintf("%s.%s.svc.%s:8000",
				aiPlatform.Status.RayServiceName, ai.Spec.AIPlatformRef.Namespace, clusterDomain)
		}
	}

	if ai.Spec.AIPlatformUrl == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "AIPlatformUrl is not set")
		return fmt.Errorf("AIPlatformUrl must be set (either from AIPlatformRef or explicitly)")
	}

	if ai.Spec.Resources.Requests == nil {
		ai.Spec.Resources.Requests = corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("4"),
			corev1.ResourceMemory: resource.MustParse("5Gi"),
		}
	}
	if ai.Spec.Resources.Limits == nil {
		ai.Spec.Resources.Limits = corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("4"),
			corev1.ResourceMemory: resource.MustParse("5Gi"),
		}
	}
	if ai.Spec.Replicas == 0 {
		ai.Spec.Replicas = 1
	}

	return nil
}

func (r *SlimReconciler) getAIPlatform(ctx context.Context, ref corev1.ObjectReference) (*aiv1.AIPlatform, error) {
	var aiPlatform aiv1.AIPlatform
	key := types.NamespacedName{
		Name:      ref.Name,
		Namespace: ref.Namespace,
	}
	if err := r.Client.Get(ctx, key, &aiPlatform); err != nil {
		return nil, err
	}
	return &aiPlatform, nil
}

func (r *SlimReconciler) validateAIPlatformReady(ctx context.Context, aiPlatform *aiv1.AIPlatform) error {
	if !common.IsConditionTrue(aiPlatform.Status.Conditions, "RayServiceStatusReady") {
		return fmt.Errorf("RayService is not ready")
	}
	if aiPlatform.Status.RayServiceName == "" {
		return fmt.Errorf("RayServiceName not populated in AIPlatform status")
	}
	return nil
}

func (r *SlimReconciler) reconcileServiceAccount(ctx context.Context, ai *aiv1.AIService) error {
	if ai.Spec.ServiceAccountName == "" {
		cleanServiceTemplate(&ai.Spec.ServiceTemplate)

		ai.Spec.ServiceAccountName = ai.Name + "-sa"
		if err := r.Update(ctx, ai); err != nil {
			return fmt.Errorf("updating SA name in spec: %w", err)
		}
		sa := &corev1.ServiceAccount{
			ObjectMeta: metav1.ObjectMeta{
				Name:      ai.Spec.ServiceAccountName,
				Namespace: ai.Namespace,
			},
		}
		if err := controllerutil.SetControllerReference(ai, sa, r.Scheme); err != nil {
			r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "ownerref on SA failed")
			return fmt.Errorf("ownerref on SA: %w", err)
		}
		if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, sa, func() error {
			return nil
		}); err != nil {
			r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update SA failed")
			return fmt.Errorf("create/update SA: %w", err)
		}
	}
	return nil
}

func (r *SlimReconciler) reconcileSlimConfigMap(ctx context.Context, ai *aiv1.AIService) error {
	cmName := fmt.Sprintf("%s-slim-config", ai.Name)

	defaults := map[string]string{
		"SERVICE_NAME":                 "slim-api",
		"SERVICE_INTERNAL_NAME":        "SLIM",
		"SLIM_SERVICE_CMP":             "true",
		"SPLUNK_ISSUERS":               "https://splunk-splunk-standalone-standalone-service:8089",
		"ENABLE_AUTHZ":                 "false",
		"ENABLE_AUTHN":                 "false",
		"API_VERSION":                  "v1alpha1",
		"FEATURE_CONFIG_FILE_LOCATION": "/etc/config/features_config.yaml",
		"LOG_LEVEL":                    "info",
		"LOG_FORMAT":                   "json",
		"OTEL_ENABLED":                 "true",
		"OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4317",
		"OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
		"OTEL_SERVICE_NAME":           "slim-api",
		"OTEL_RESOURCE_ATTRIBUTES":    "service.namespace=ai-platform,service.version=v1alpha1",
		"OTEL_METRICS_EXPORTER":       "otlp",
		"OTEL_LOGS_EXPORTER":          "otlp",
		"OTEL_TRACES_EXPORTER":        "otlp",
	}

	found := &corev1.ConfigMap{}
	err := r.Get(ctx, types.NamespacedName{Name: cmName, Namespace: ai.Namespace}, found)
	if apierrors.IsNotFound(err) {
		return r.createOrUpdateConfigMap(ctx, cmName, defaults, ai)
	} else if err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec",
			fmt.Sprintf("failed to retrieve ConfigMap %q: %v", cmName, err))
		return fmt.Errorf("fetching Slim ConfigMap %q: %w", cmName, err)
	}

	if found.Data == nil {
		found.Data = map[string]string{}
	}
	needsUpdate := false
	for k, v := range defaults {
		if _, ok := found.Data[k]; !ok || found.Data[k] == "" {
			found.Data[k] = v
			needsUpdate = true
		}
	}
	if needsUpdate {
		if err := controllerutil.SetControllerReference(ai, found, r.Scheme); err != nil {
			return fmt.Errorf("ownerref on ConfigMap: %w", err)
		}
		return r.Update(ctx, found)
	}
	return nil
}

func (r *SlimReconciler) reconcileFeatureConfigMap(ctx context.Context, ai *aiv1.AIService) error {
	cmName := fmt.Sprintf("splunk-%s-feature-config", ai.Name)

	found := &corev1.ConfigMap{}
	err := r.Get(ctx, types.NamespacedName{Name: cmName, Namespace: ai.Namespace}, found)

	if err == nil {
		if !hasOwnerReference(found, ai) {
			if err := controllerutil.SetControllerReference(ai, found, r.Scheme); err != nil {
				r.Recorder.Event(ai, corev1.EventTypeWarning, "FeatureConfigMapError",
					fmt.Sprintf("Failed to set owner reference on ConfigMap %q", cmName))
				return fmt.Errorf("failed to set owner reference on ConfigMap %q: %w", cmName, err)
			}
			if err := r.Update(ctx, found); err != nil {
				return fmt.Errorf("failed to update owner reference on ConfigMap %q: %w", cmName, err)
			}
			r.Recorder.Event(ai, corev1.EventTypeNormal, "FeatureConfigMapUpdated",
				fmt.Sprintf("Added owner reference to existing ConfigMap %q", cmName))
		}
		return nil
	}

	if !apierrors.IsNotFound(err) {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "FeatureConfigMapError",
			fmt.Sprintf("Failed to retrieve ConfigMap %q", cmName))
		return fmt.Errorf("failed to get ConfigMap %q: %w", cmName, err)
	}

	defaultData := map[string]string{
		"features_config.yaml": `customization:
  enabled_by_default: true
`,
	}

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cmName,
			Namespace: ai.Namespace,
		},
		Data: defaultData,
	}

	if err := controllerutil.SetControllerReference(ai, cm, r.Scheme); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "FeatureConfigMapError",
			fmt.Sprintf("Failed to set owner reference on ConfigMap %q", cmName))
		return fmt.Errorf("failed to set owner reference on ConfigMap %q: %w", cmName, err)
	}

	if err := r.Create(ctx, cm); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "FeatureConfigMapError",
			fmt.Sprintf("Failed to create ConfigMap %q", cmName))
		return fmt.Errorf("failed to create ConfigMap %q: %w", cmName, err)
	}

	r.Recorder.Event(ai, corev1.EventTypeNormal, "FeatureConfigMapCreated",
		fmt.Sprintf("Created feature-config ConfigMap %q with default content", cmName))

	return nil
}

func hasOwnerReference(obj metav1.Object, owner metav1.Object) bool {
	for _, ref := range obj.GetOwnerReferences() {
		if ref.UID == owner.GetUID() {
			return true
		}
	}
	return false
}

func (r *SlimReconciler) reconcileOtelConfigMap(ctx context.Context, ai *aiv1.AIService) error {
	cmName := fmt.Sprintf("%s-otel-config", ai.Name)

	aiPlatform, err := r.getAIPlatform(ctx, ai.Spec.AIPlatformRef)
	if err != nil {
		return fmt.Errorf("fetching AIPlatform for OTEL config: %w", err)
	}

	if !aiPlatform.Spec.Sidecars.Otel {
		return nil
	}

	otelConfig := r.renderSlimOtelConfig(ctx, ai, aiPlatform)

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cmName,
			Namespace: ai.Namespace,
		},
	}

	_, err = controllerutil.CreateOrUpdate(ctx, r.Client, cm, func() error {
		if cm.Data == nil {
			cm.Data = map[string]string{}
		}
		cm.Data["otel-config.yaml"] = otelConfig
		return controllerutil.SetControllerReference(ai, cm, r.Scheme)
	})
	if err != nil {
		return fmt.Errorf("create/update OTEL ConfigMap %q: %w", cmName, err)
	}
	return nil
}

func (r *SlimReconciler) renderSlimOtelConfig(_ context.Context, ai *aiv1.AIService, aiPlatform *aiv1.AIPlatform) string {
	hecEndpoint := fmt.Sprintf("%s/services/collector", aiPlatform.Spec.SplunkConfiguration.Endpoint)
	secretName := aiPlatform.Spec.SplunkConfiguration.SecretRef.Name

	_ = secretName // used only as reference; actual token injected via env var

	return fmt.Sprintf(`receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"
  prometheus:
    config:
      scrape_configs:
        - job_name: "slim-api-metrics"
          scrape_interval: 15s
          metrics_path: /metrics
          static_configs:
            - targets: ["localhost:8088"]
              labels:
                service: "slim-api"
                component: "%s"
                namespace: "${NAMESPACE}"
                pod: "${POD_NAME}"

processors:
  batch:
    send_batch_size: 512
    timeout: 5s
  attributes:
    actions:
      - key: service.name
        value: "slim-api"
        action: upsert
      - key: service.namespace
        value: "%s"
        action: upsert
      - key: deployment.environment
        value: "production"
        action: upsert
  resource:
    attributes:
      - key: k8s.namespace.name
        value: "%s"
        action: upsert
      - key: k8s.pod.name
        value: "${POD_NAME}"
        action: upsert

exporters:
  splunk_hec/metrics:
    token: "${SPLUNK_ACCESS_TOKEN}"
    endpoint: "%s"
    source: "slim-api"
    sourcetype: "slim-api:metrics"
    index: "_metrics"
    disable_compression: false
    timeout: 10s
    tls:
      insecure_skip_verify: true
  splunk_hec/logs:
    token: "${SPLUNK_ACCESS_TOKEN}"
    endpoint: "%s"
    source: "slim-api"
    sourcetype: "slim-api:logs"
    index: "main"
    disable_compression: false
    timeout: 10s
    tls:
      insecure_skip_verify: true

service:
  pipelines:
    metrics:
      receivers: [otlp, prometheus]
      processors: [batch, attributes, resource]
      exporters: [splunk_hec/metrics]
    logs:
      receivers: [otlp]
      processors: [batch, attributes, resource]
      exporters: [splunk_hec/logs]
  telemetry:
    metrics:
      readers:
        - pull:
            exporter:
              prometheus:
                host: "0.0.0.0"
                port: 8889
`,
		ai.Name,
		ai.Namespace,
		ai.Namespace,
		hecEndpoint,
		hecEndpoint,
	)
}

func (r *SlimReconciler) reconcileCertificate(ctx context.Context, ai *aiv1.AIService) error {
	if !ai.Spec.MTLS.Enabled || ai.Spec.MTLS.Termination != "operator" {
		return nil
	}

	certExists := true
	existingCert := &certmanagerv1.Certificate{}
	certKey := types.NamespacedName{Name: ai.Name + "-tls", Namespace: ai.Namespace}
	if err := r.Get(ctx, certKey, existingCert); err != nil {
		if apierrors.IsNotFound(err) {
			certExists = false
			r.Recorder.Event(ai, corev1.EventTypeNormal, "MTLSCertificateCreating", "Creating mTLS certificate")
		}
	}

	cert := &certmanagerv1.Certificate{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-tls",
			Namespace: ai.Namespace,
		},
		Spec: certmanagerv1.CertificateSpec{
			SecretName: ai.Spec.MTLS.SecretName,
			IssuerRef:  ai.Spec.MTLS.IssuerRef,
			DNSNames:   ai.Spec.MTLS.DNSNames,
			Usages: []certmanagerv1.KeyUsage{
				certmanagerv1.UsageServerAuth,
				certmanagerv1.UsageClientAuth,
			},
		},
	}
	if err := controllerutil.SetControllerReference(ai, cert, r.Scheme); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "MTLSCertificateError", "Failed to set owner reference on Certificate")
		return fmt.Errorf("ownerref on Certificate: %w", err)
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, cert, func() error {
		cert.Spec = certmanagerv1.CertificateSpec{
			SecretName: ai.Spec.MTLS.SecretName,
			IssuerRef:  ai.Spec.MTLS.IssuerRef,
			DNSNames:   ai.Spec.MTLS.DNSNames,
			Usages: []certmanagerv1.KeyUsage{
				certmanagerv1.UsageServerAuth,
				certmanagerv1.UsageClientAuth,
			},
		}
		return nil
	}); err != nil {
		r.Recorder.Eventf(ai, corev1.EventTypeWarning, "MTLSCertificateCreationFailed", "Failed to create/update Certificate: %v", err)
		return fmt.Errorf("create/update Certificate: %w", err)
	}

	if !certExists {
		r.Recorder.Event(ai, corev1.EventTypeNormal, "MTLSCertificateCreated", "mTLS Certificate created successfully")
	}

	certReady := false
	for _, cond := range cert.Status.Conditions {
		if cond.Type == certmanagerv1.CertificateConditionReady && cond.Status == cmmeta.ConditionTrue {
			certReady = true
			break
		}
	}

	if !certReady {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "MTLSCertificateNotReady", "Waiting for cert-manager to issue certificate")
		return fmt.Errorf("waiting for Certificate %q to become Ready", cert.Name)
	}

	r.Recorder.Event(ai, corev1.EventTypeNormal, "MTLSCertificateReady", "mTLS certificate issued successfully")
	return nil
}

func (r *SlimReconciler) reconcileSlimDeployment(ctx context.Context, ai *aiv1.AIService) error {
	featureConfigName := fmt.Sprintf("splunk-%s-feature-config", ai.Name)

	volumes := []corev1.Volume{
		{
			Name: "config-volume",
			VolumeSource: corev1.VolumeSource{
				ConfigMap: &corev1.ConfigMapVolumeSource{
					LocalObjectReference: corev1.LocalObjectReference{Name: featureConfigName},
				},
			},
		},
	}

	ports := []corev1.ContainerPort{
		{Name: "http", ContainerPort: 8080},
		{Name: "metrics", ContainerPort: 8088},
	}
	mounts := []corev1.VolumeMount{
		{Name: "config-volume", MountPath: "/etc/config"},
	}

	env := []corev1.EnvVar{
		{Name: "PLATFORM_URL", Value: ai.Spec.AIPlatformUrl},
	}

	if ai.Spec.MTLS.Enabled && ai.Spec.MTLS.Termination == "operator" {
		volumes = append(volumes, corev1.Volume{
			Name: "tls",
			VolumeSource: corev1.VolumeSource{
				Secret: &corev1.SecretVolumeSource{SecretName: ai.Spec.MTLS.SecretName},
			},
		})
		mounts = append(mounts, corev1.VolumeMount{Name: "tls", MountPath: "/etc/tls", ReadOnly: true})
		env = append(env,
			corev1.EnvVar{Name: "TLS_CERT_FILE", Value: "/etc/tls/tls.crt"},
			corev1.EnvVar{Name: "TLS_KEY_FILE", Value: "/etc/tls/tls.key"},
		)
		ports = append(ports, corev1.ContainerPort{Name: "https", ContainerPort: 8443})
	} else {
		env = append(env, corev1.EnvVar{Name: "TLS_DISABLED", Value: "true"})
	}

	envFrom := []corev1.EnvFromSource{
		{
			ConfigMapRef: &corev1.ConfigMapEnvSource{
				LocalObjectReference: corev1.LocalObjectReference{
					Name: fmt.Sprintf("%s-slim-config", ai.Name),
				},
			},
		},
	}

	sort.Slice(env, func(i, j int) bool { return env[i].Name < env[j].Name })

	deployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-slim-deployment",
			Namespace: ai.Namespace,
		},
	}

	labels := map[string]string{
		"app":       ai.Name,
		"component": ai.Name,
		"area":      "ml",
		"team":      "ml",
	}
	for k, v := range ai.Labels {
		labels[k] = v
	}

	annotations := map[string]string{
		"prometheus.io/port":   "8088",
		"prometheus.io/path":   "/metrics",
		"prometheus.io/scheme": "http",
	}
	for k, v := range ai.Annotations {
		if k == "kubectl.kubernetes.io/last-applied-configuration" || k == "kubectl.kubernetes.io/restartedAt" {
			continue
		}
		annotations[k] = v
	}

	if err := controllerutil.SetControllerReference(ai, deployment, r.Scheme); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "ownerref on Deployment failed")
		return fmt.Errorf("ownerref on Deployment: %w", err)
	}

	otelEnabled := r.isOtelEnabled(ctx, ai)

	containers := []corev1.Container{{
		Name:            ai.Name,
		Image:           os.Getenv("RELATED_IMAGE_SLIM_API"),
		ImagePullPolicy: corev1.PullAlways,
		Ports:           ports,
		VolumeMounts:    mounts,
		Resources:       ai.Spec.Resources,
		Env:             env,
		EnvFrom:         envFrom,
		LivenessProbe: &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{
				HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromInt(8080)},
			},
			PeriodSeconds:    30,
			FailureThreshold: 10,
		},
		ReadinessProbe: &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{
				HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromInt(8080)},
			},
			PeriodSeconds:    30,
			FailureThreshold: 10,
		},
		StartupProbe: &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{
				HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromInt(8080)},
			},
			InitialDelaySeconds: 30,
			PeriodSeconds:       30,
			FailureThreshold:    10,
		},
	}}

	if otelEnabled {
		otelConfigName := fmt.Sprintf("%s-otel-config", ai.Name)
		volumes = append(volumes, corev1.Volume{
			Name: "otel-config",
			VolumeSource: corev1.VolumeSource{
				ConfigMap: &corev1.ConfigMapVolumeSource{
					LocalObjectReference: corev1.LocalObjectReference{Name: otelConfigName},
				},
			},
		})

		otelContainer := r.buildOtelSidecar(ctx, ai)
		containers = append(containers, otelContainer)
	}

	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, deployment, func() error {
		deployment.ObjectMeta.Labels = labels
		deployment.ObjectMeta.Annotations = annotations
		deployment.Spec.Replicas = &ai.Spec.Replicas

		if deployment.Spec.Selector == nil {
			deployment.Spec.Selector = &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": ai.Name, "component": ai.Name},
			}
		}

		deployment.Spec.Template = corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{
				Labels:      map[string]string{"app": ai.Name, "component": ai.Name},
				Annotations: annotations,
			},
			Spec: corev1.PodSpec{
				ServiceAccountName: ai.Spec.ServiceAccountName,
				Containers:         containers,
				Volumes:            volumes,
				Affinity:           &ai.Spec.Affinity,
				Tolerations:        ai.Spec.Tolerations,
				ImagePullSecrets:   ai.Spec.ImagePullSecrets,
			},
		}
		return nil
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update Deployment failed")
		return fmt.Errorf("create/update Deployment: %w", err)
	}
	return nil
}

func (r *SlimReconciler) isOtelEnabled(ctx context.Context, ai *aiv1.AIService) bool {
	if ai.Spec.AIPlatformRef.Name == "" {
		return false
	}
	aiPlatform, err := r.getAIPlatform(ctx, ai.Spec.AIPlatformRef)
	if err != nil {
		return false
	}
	return aiPlatform.Spec.Sidecars.Otel
}

func (r *SlimReconciler) buildOtelSidecar(_ context.Context, ai *aiv1.AIService) corev1.Container {
	otelImage := sidecars.ResolveImage("RELATED_IMAGE_OTEL_COLLECTOR", "")

	return corev1.Container{
		Name:            "otel-collector",
		Image:           otelImage,
		ImagePullPolicy: corev1.PullIfNotPresent,
		Args:            []string{"--config=/etc/otel/otel-config.yaml"},
		Ports: []corev1.ContainerPort{
			{Name: "otlp-grpc", ContainerPort: 4317, Protocol: corev1.ProtocolTCP},
			{Name: "otlp-http", ContainerPort: 4318, Protocol: corev1.ProtocolTCP},
			{Name: "otel-metrics", ContainerPort: 8889, Protocol: corev1.ProtocolTCP},
		},
		Env: []corev1.EnvVar{
			{Name: "SPLUNK_ACCESS_TOKEN", ValueFrom: &corev1.EnvVarSource{
				SecretKeyRef: &corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: ai.Spec.SplunkConfiguration.SecretRef.Name},
					Key:                  "hec_token",
				},
			}},
			{Name: "POD_NAME", ValueFrom: &corev1.EnvVarSource{
				FieldRef: &corev1.ObjectFieldSelector{FieldPath: "metadata.name"},
			}},
			{Name: "NAMESPACE", ValueFrom: &corev1.EnvVarSource{
				FieldRef: &corev1.ObjectFieldSelector{FieldPath: "metadata.namespace"},
			}},
		},
		VolumeMounts: []corev1.VolumeMount{
			{Name: "otel-config", MountPath: "/etc/otel", ReadOnly: true},
		},
		Resources: corev1.ResourceRequirements{
			Requests: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("100m"),
				corev1.ResourceMemory: resource.MustParse("128Mi"),
			},
			Limits: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("500m"),
				corev1.ResourceMemory: resource.MustParse("256Mi"),
			},
		},
		LivenessProbe: &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{
				HTTPGet: &corev1.HTTPGetAction{Path: "/", Port: intstr.FromInt(13133)},
			},
			PeriodSeconds:    30,
			FailureThreshold: 5,
		},
		ReadinessProbe: &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{
				HTTPGet: &corev1.HTTPGetAction{Path: "/", Port: intstr.FromInt(13133)},
			},
			PeriodSeconds:    10,
			FailureThreshold: 3,
		},
	}
}

func (r *SlimReconciler) reconcileSlimService(ctx context.Context, ai *aiv1.AIService) error {
	serviceTemplate := ai.Spec.ServiceTemplate.DeepCopy()
	cleanServiceTemplate(serviceTemplate)

	ports := []corev1.ServicePort{
		{Name: "http", Port: 8080, TargetPort: intstr.FromInt(8080)},
		{Name: "metrics", Port: 8088, TargetPort: intstr.FromInt(8088)},
	}
	if ai.Spec.MTLS.Enabled && ai.Spec.MTLS.Termination == "operator" {
		ports = append(ports, corev1.ServicePort{
			Name: "https", Port: 8443, TargetPort: intstr.FromInt(8443),
		})
	}
	if r.isOtelEnabled(ctx, ai) {
		ports = append(ports, corev1.ServicePort{
			Name: "otel-metrics", Port: 8889, TargetPort: intstr.FromInt(8889),
		})
	}
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-slim-service",
			Namespace: ai.Namespace,
			Labels:    map[string]string{"app": ai.Name},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": ai.Name, "component": ai.Name},
			Ports:    ports,
			Type:     corev1.ServiceTypeClusterIP,
		},
	}
	for k, v := range ai.Labels {
		svc.ObjectMeta.Labels[k] = v
	}
	for k, v := range ai.Annotations {
		if k == "kubectl.kubernetes.io/last-applied-configuration" {
			continue
		}
		if k == "kubectl.kubernetes.io/restartedAt" {
			continue
		}
		svc.ObjectMeta.Annotations[k] = v
	}

	switch serviceTemplate.Spec.Type {
	case corev1.ServiceTypeLoadBalancer:
		svc.Spec.Type = corev1.ServiceTypeLoadBalancer
	case corev1.ServiceTypeNodePort:
		svc.Spec.Type = corev1.ServiceTypeNodePort
		for i, port := range svc.Spec.Ports {
			for _, tplPort := range serviceTemplate.Spec.Ports {
				if port.Name == tplPort.Name && tplPort.NodePort != 0 {
					svc.Spec.Ports[i].NodePort = tplPort.NodePort
				}
			}
		}
	default:
		svc.Spec.Type = corev1.ServiceTypeClusterIP
	}

	if err := controllerutil.SetControllerReference(ai, svc, r.Scheme); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "ownerref on Service failed")
		return fmt.Errorf("ownerref on Service: %w", err)
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Spec.Selector = map[string]string{"app": ai.Name, "component": ai.Name}
		svc.Spec.Ports = ports
		return nil
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update Service failed")
		return fmt.Errorf("create/update Service: %w", err)
	}
	return nil
}

func (r *SlimReconciler) reconcileServiceMonitor(ctx context.Context, ai *aiv1.AIService) error {
	if !ai.Spec.Metrics.Enabled {
		return nil
	}

	endpoints := []monitoringv1.Endpoint{
		{Port: "metrics", Path: ai.Spec.Metrics.Path, Scheme: "http"},
	}

	if r.isOtelEnabled(ctx, ai) {
		endpoints = append(endpoints, monitoringv1.Endpoint{
			Port:   "otel-metrics",
			Path:   "/metrics",
			Scheme: "http",
		})
	}

	sm := &monitoringv1.ServiceMonitor{
		ObjectMeta: metav1.ObjectMeta{Name: ai.Name + "-metrics", Namespace: ai.Namespace},
		Spec: monitoringv1.ServiceMonitorSpec{
			Selector: metav1.LabelSelector{
				MatchLabels: map[string]string{"app": ai.Name, "component": ai.Name},
			},
			Endpoints: endpoints,
		},
	}
	if err := controllerutil.SetControllerReference(ai, sm, r.Scheme); err != nil {
		return err
	}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, sm, func() error {
		sm.Spec = monitoringv1.ServiceMonitorSpec{
			Selector: metav1.LabelSelector{
				MatchLabels: map[string]string{"app": ai.Name, "component": ai.Name},
			},
			Endpoints: endpoints,
		}
		return nil
	})
	return err
}

func (r *SlimReconciler) createOrUpdateConfigMap(
	ctx context.Context,
	name string,
	data map[string]string,
	ai *aiv1.AIService,
) error {
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ai.Namespace,
		},
		Data: data,
	}
	if err := controllerutil.SetControllerReference(ai, cm, r.Scheme); err != nil {
		return err
	}

	found := &corev1.ConfigMap{}
	err := r.Get(ctx, types.NamespacedName{Name: name, Namespace: ai.Namespace}, found)
	if apierrors.IsNotFound(err) {
		return r.Create(ctx, cm)
	} else if err != nil {
		return err
	}

	if !reflect.DeepEqual(found.Data, data) {
		found.Data = data
		return r.Update(ctx, found)
	}
	return nil
}

func cleanServiceTemplate(template *corev1.Service) {
	if template == nil {
		return
	}
	template.ObjectMeta.CreationTimestamp = metav1.Time{}
	template.ObjectMeta.DeletionTimestamp = nil
	template.ObjectMeta.DeletionGracePeriodSeconds = nil
	template.ObjectMeta.UID = ""
	template.ObjectMeta.ResourceVersion = ""
	template.ObjectMeta.Generation = 0
	template.ObjectMeta.SelfLink = ""
	template.ObjectMeta.ManagedFields = nil
	template.Status = corev1.ServiceStatus{}
}
