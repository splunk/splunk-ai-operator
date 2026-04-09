package saia

import (
	"context"
	"strings"

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
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	common "github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	"github.com/splunk/splunk-ai-operator/pkg/splunkutils"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

type SaiaReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

// Reconcile runs reconciliation stages for the CR.
func (r *SaiaReconciler) Reconcile(ctx context.Context, aiservice *aiv1.AIService) error {
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
		{"SAIAConfigMap", r.reconcileSAIAConfigMap},
		{"FeatureConfigMap", r.reconcileFeatureConfigMap},
		{"Certificate", r.reconcileCertificate},
		{"PostInstallHook", r.reconcilePostInstallHook},
		{"SAIADeployment", r.reconcileSAIADeployment},
		{"SAIAService", r.reconcileSAIAService},
		{"NginxProxyConfigMap", r.reconcileNginxProxyConfigMap},
		{"NginxProxyDeployment", r.reconcileNginxProxyDeployment},
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
			//r.Recorder.Event(ai, corev1.EventTypeWarning, stage.name+"Failed", err.Error())
		} else {
			//		r.Recorder.Event(ai, corev1.EventTypeNormal, stage.name+"Succeeded", "stage succeeded")
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

// validateAIService ensures required fields are set and defaults.
func (r *SaiaReconciler) validateAIService(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	// Clean ServiceTemplate at the start to remove any server-generated fields
	cleanServiceTemplate(&ai.Spec.ServiceTemplate)

	if os.Getenv("RELATED_IMAGE_POST_INSTALL_HOOK") == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "RELATED_IMAGE_POST_INSTALL_HOOK must be set")
		return fmt.Errorf("RELATED_IMAGE_POST_INSTALL_HOOK must be set")
	}
	// Validate that either AIPlatformRef or explicit URLs are provided
	if ai.Spec.AIPlatformRef.Name == "" && ai.Spec.AIPlatformUrl == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "AIPlatformRef.Name or AIPlatformUrl must be set")
		return fmt.Errorf("either AIPlatformRef.Name or AIPlatformUrl must be set")
	}

	// Fetch and validate AIPlatform if using AIPlatformRef
	if ai.Spec.AIPlatformRef.Name != "" {
		aiPlatform, err := r.getAIPlatform(ctx, ai.Spec.AIPlatformRef)
		if err != nil {
			r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "fetching AIPlatform failed")
			return fmt.Errorf("fetching AIPlatform: %w", err)
		}

		// Validate AIPlatform infrastructure is ready before using its status fields
		if err := r.validateAIPlatformReady(ctx, aiPlatform); err != nil {
			return fmt.Errorf("AIPlatform infrastructure not ready: %w", err)
		}

		// Validate Vector Database readiness
		if err := r.validateVectorDatabaseReady(ctx, aiPlatform); err != nil {
			return fmt.Errorf("vector database not ready: %w", err)
		}

		// Only populate URLs if not already set (preserve explicit user values)
		clusterDomain := ai.Spec.ClusterDomain
		if clusterDomain == "" {
			clusterDomain = "cluster.local"
		}
		if ai.Spec.AIPlatformUrl == "" {
			ai.Spec.AIPlatformUrl = fmt.Sprintf("%s.%s.svc.%s:8000",
				aiPlatform.Status.RayServiceName, ai.Spec.AIPlatformRef.Namespace, clusterDomain)
		}
		if ai.Spec.VectorDbUrl == "" {
			ai.Spec.VectorDbUrl = fmt.Sprintf("%s.%s.svc.%s",
				aiPlatform.Status.VectorDbServiceName, ai.Spec.AIPlatformRef.Namespace, clusterDomain)
		}
	}

	// Final validation that URLs are populated (either from AIPlatform or provided explicitly)
	if ai.Spec.AIPlatformUrl == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "AIPlatformUrl is not set")
		return fmt.Errorf("AIPlatformUrl must be set (either from AIPlatformRef or explicitly)")
	}
	if ai.Spec.VectorDbUrl == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "VectorDbUrl is not set")
		return fmt.Errorf("VectorDbUrl must be set (either from AIPlatformRef or explicitly)")
	}

	// Default resources — SAIA API needs headroom beyond 2Gi or the kubelet OOMKills during startup.
	if ai.Spec.Resources.Requests == nil {
		ai.Spec.Resources.Requests = corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("500m"),
			corev1.ResourceMemory: resource.MustParse("2Gi"),
		}
	}
	if ai.Spec.Resources.Limits == nil {
		ai.Spec.Resources.Limits = corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("2"),
			corev1.ResourceMemory: resource.MustParse("4Gi"),
		}
	}
	if ai.Spec.TaskVolume.Path == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "task volume path must be set")
		return fmt.Errorf("task volume path must be set")
	}
	if ai.Spec.Replicas == 0 {
		ai.Spec.Replicas = 1
	}

	if ai.Spec.SplunkConfiguration.Endpoint == "" && ai.Spec.SplunkConfiguration.SplunkCustomResourceRef.Name == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "SplunkConfigMissing", "Splunk configuration is missing assuming no logging")
		return nil
	}

	var resolver splunkutils.SplunkSecretResolver

	switch ai.Spec.SplunkConfiguration.SecretSource {
	case aiv1.SecretSourceVault:
		resolver = &splunkutils.VaultFileResolver{} // Read from /vault/secrets/splunk
	default:
		resolver = &splunkutils.KubernetesSecretResolver{Client: r.Client} // Default
	}

	return splunkutils.ValidateAndEnrichSplunkConfig(
		ctx,
		r.Client,
		ai.Namespace,
		ai.Spec.ClusterDomain,
		&ai.Spec.SplunkConfiguration,
		resolver,
	)
}

func (r *SaiaReconciler) getAIPlatform(ctx context.Context, ref corev1.ObjectReference) (*aiv1.AIPlatform, error) {
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

func (r *SaiaReconciler) validateAIPlatformReady(ctx context.Context, aiPlatform *aiv1.AIPlatform) error {
	// Check if RayService infrastructure is ready (not the overall Ready condition to avoid circular dependency)
	if !common.IsConditionTrue(aiPlatform.Status.Conditions, "RayServiceStatusReady") {
		return fmt.Errorf("RayService is not ready")
	}

	// Verify RayService endpoint name is populated in status
	if aiPlatform.Status.RayServiceName == "" {
		return fmt.Errorf("RayServiceName not populated in AIPlatform status")
	}

	// Check RayService endpoint is reachable
	// TODO: Re-enable once we have a way to skip in test environments
	// if err := common.CheckRayHeadService(ctx, aiPlatform.Status.RayServiceName); err != nil {
	// 	return fmt.Errorf("RayService endpoint %s is not reachable: %w", aiPlatform.Status.RayServiceName, err)
	// }

	return nil
}

func (r *SaiaReconciler) validateVectorDatabaseReady(ctx context.Context, aiPlatform *aiv1.AIPlatform) error {
	// Check VectorDatabase status condition (not just the creation condition to ensure it's actually running)
	if !common.IsConditionTrue(aiPlatform.Status.Conditions, "WeaviateDatabaseStatusReady") {
		return fmt.Errorf("vector database is not ready")
	}

	// Verify VectorDB service name is populated in status
	if aiPlatform.Status.VectorDbServiceName == "" {
		return fmt.Errorf("VectorDbServiceName not populated in AIPlatform status")
	}

	// Check if VectorDB service endpoint is accessible
	// TODO: Re-enable once we have a way to skip in test environments
	// if err := common.CheckWeaviateService(ctx, aiPlatform.Status.VectorDbServiceName); err != nil {
	// 	return fmt.Errorf("vector database endpoint %s is not reachable: %w", aiPlatform.Status.VectorDbServiceName, err)
	// }

	return nil
}

// reconcileServiceAccount creates or reuses a ServiceAccount.
func (r *SaiaReconciler) reconcileServiceAccount(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	if ai.Spec.ServiceAccountName == "" {
		// Clean ServiceTemplate before updating the spec
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

// reconcileSAIAConfigMap manages the SAIA config ConfigMap for SPLUNK_ISSUERS.
func (r *SaiaReconciler) reconcileSAIAConfigMap(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	cmName := fmt.Sprintf("%s-saia-config", ai.Name)

	// Defaults for static keys (override in user-managed CM if desired).
	defaults := map[string]string{
		// previously hardcoded
		"SERVICE_NAME":                    "splunk_ai_assistant",
		"SERVICE_INTERNAL_NAME":           "SAIA",
		"SPLUNK_ISSUERS":                  "https://splunk-splunk-standalone-standalone-service:8089",
		"SPLUNK_AI_ASSISTANT_SERVICE_CMP": "true",
		"ENABLE_AUTHZ":                    "false", // FIXME remove when ready
		"FEATURE_CONFIG_FILE_LOCATION":    "/etc/config/features_config.yaml",
		"PLATFORM_VERSION":                "0.3.0",    // TODO make configurable
		"SAIA_API_VERSION":                "0.3.1",    // TODO make configurable
		"TELEMETRY_ENV":                   "NOTLOCAL", // TODO make configurable
		"LOG_LEVEL":                       "info",
	}

	found := &corev1.ConfigMap{}
	err := r.Get(ctx, types.NamespacedName{Name: cmName, Namespace: ai.Namespace}, found)
	if apierrors.IsNotFound(err) {
		// Create new with defaults
		return r.createOrUpdateConfigMap(ctx, cmName, defaults, ai)
	} else if err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec",
			fmt.Sprintf("failed to retrieve ConfigMap %q: %v", cmName, err))
		return fmt.Errorf("fetching SAIA ConfigMap %q: %w", cmName, err)
	}

	// Merge defaults for any missing keys, but don't override user-set values.
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

// reconcileFeatureConfigMap manages the feature-config ConfigMap with default content.
// This ConfigMap is used by SAIA deployment for feature flags and customization.
// If the ConfigMap doesn't exist, it creates it with default values.
// If it exists, it preserves user modifications.
func (r *SaiaReconciler) reconcileFeatureConfigMap(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	cmName := fmt.Sprintf("splunk-%s-feature-config", ai.Name)

	// Check if ConfigMap already exists
	found := &corev1.ConfigMap{}
	err := r.Get(ctx, types.NamespacedName{Name: cmName, Namespace: ai.Namespace}, found)

	if err == nil {
		// ConfigMap exists - check if it has owner reference
		if !hasOwnerReference(found, ai) {
			// Add owner reference to existing ConfigMap
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
		// ConfigMap exists and has owner reference - preserve user modifications
		return nil
	}

	if !apierrors.IsNotFound(err) {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "FeatureConfigMapError",
			fmt.Sprintf("Failed to retrieve ConfigMap %q", cmName))
		return fmt.Errorf("failed to get ConfigMap %q: %w", cmName, err)
	}

	// ConfigMap doesn't exist - create it with default content
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

	// Set owner reference so it gets deleted with AIService
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

// hasOwnerReference checks if the object has an owner reference to the given owner
func hasOwnerReference(obj metav1.Object, owner metav1.Object) bool {
	for _, ref := range obj.GetOwnerReferences() {
		if ref.UID == owner.GetUID() {
			return true
		}
	}
	return false
}

// reconcileCertificate manages cert-manager Certificate for mTLS.
func (r *SaiaReconciler) reconcileCertificate(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	if !ai.Spec.MTLS.Enabled || ai.Spec.MTLS.Termination != "operator" {
		return nil
	}

	// Check if Certificate already exists to emit creation event
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
		// Update Certificate spec
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

	// Wait until Certificate is Ready
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

	// Emit success event when certificate becomes ready
	r.Recorder.Event(ai, corev1.EventTypeNormal, "MTLSCertificateReady", "mTLS certificate issued successfully")
	return nil
}

// reconcilePostInstallHook creates and watches the schema setup Job.
func (r *SaiaReconciler) reconcilePostInstallHook(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	hookImage := os.Getenv("RELATED_IMAGE_POST_INSTALL_HOOK")
	if ai.Spec.VectorDbUrl == "" {
		return nil
	}
	if ai.Status.SchemaJobId != "" {
		job := &batchv1.Job{}
		err := r.Get(
			ctx,
			client.ObjectKey{Namespace: ai.Namespace, Name: ai.Status.SchemaJobId},
			job,
		)
		if apierrors.IsNotFound(err) {
			ai.Status.SchemaJobId = ""
		} else if err != nil {
			r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "fetching Job failed")
			return fmt.Errorf("fetching Job: %w", err)
		} else {
			for _, c := range job.Status.Conditions {
				if c.Type == batchv1.JobComplete && c.Status == corev1.ConditionTrue {
					return nil
				}
				if c.Type == batchv1.JobFailed && c.Status == corev1.ConditionTrue {
					r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", fmt.Sprintf("Job %q failed", job.Name))
					return fmt.Errorf("job %q failed", job.Name)
				}
			}
			return fmt.Errorf("job %q is still running", job.Name)
		}
	}
	uri := fmt.Sprintf("http://%s:80", ai.Spec.VectorDbUrl)
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-vector-db-setup-posthook",
			Namespace: ai.Namespace,
		},
		Spec: batchv1.JobSpec{
			Template: corev1.PodTemplateSpec{
				Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					Containers: []corev1.Container{
						{
							Name:            "vector-db-setup-container",
							Image:           hookImage,
							ImagePullPolicy: corev1.PullAlways,
							Env: []corev1.EnvVar{
								{Name: "VECTOR_DB_URL", Value: uri},
								{Name: "SPLUNK_AI_ASSISTANT_SERVICE_CMP", Value: "true"},
							},
						},
					},
					Tolerations: ai.Spec.Tolerations,
					Affinity:    &ai.Spec.Affinity,
					// Propagate imagePullSecrets from AIService spec
					ImagePullSecrets: ai.Spec.ImagePullSecrets,
				},
			},
		},
	}
	if err := controllerutil.SetControllerReference(ai, job, r.Scheme); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "ownerref on Job failed")
		return fmt.Errorf("ownerref on Job: %w", err)
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, job, func() error { return nil }); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update Job failed")
		return fmt.Errorf("create/update Job: %w", err)
	}
	ai.Status.SchemaJobId = job.Name
	return fmt.Errorf("created Job %q, waiting for completion", job.Name)
}

// reconcileSAIADeployment ensures the main Deployment exists and is configured.
func (r *SaiaReconciler) reconcileSAIADeployment(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	// Use standardized ConfigMap name: splunk-<aiservice-name>-feature-config
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

	// Base env: keep ONLY dynamic values here.
	env := []corev1.EnvVar{
		// Dynamic or runtime-derived values:
		{Name: "PLATFORM_URL", Value: ai.Spec.AIPlatformUrl},
		{Name: "VECTOR_DB_URL", Value: ai.Spec.VectorDbUrl},
		// SAIA uses /tasks subdirectory within its feature path
		// Extract just the bucket name from the full path (e.g., "s3://bucket-name" -> "bucket-name")
		{Name: "S3_BUCKET", Value: extractBucketName(ai.Spec.TaskVolume.Path)},
	}

	// S3-compatible object store: set S3COMPAT_OBJECT_STORE_ENDPOINT_URL for custom endpoint (MinIO, SeaweedFS, etc.).
	if ai.Spec.TaskVolume.Endpoint != "" {
		env = append(env, corev1.EnvVar{Name: "S3COMPAT_OBJECT_STORE_ENDPOINT_URL", Value: ai.Spec.TaskVolume.Endpoint})
	}

	// S3-compatible object store credentials from secretRef (S3COMPAT_OBJECT_STORE_ACCESS_KEY, S3COMPAT_OBJECT_STORE_SECRET_KEY).
	if ai.Spec.TaskVolume.SecretRef != "" {
		env = append(env,
			corev1.EnvVar{
				Name: "S3COMPAT_OBJECT_STORE_ACCESS_KEY",
				ValueFrom: &corev1.EnvVarSource{
					SecretKeyRef: &corev1.SecretKeySelector{
						LocalObjectReference: corev1.LocalObjectReference{Name: ai.Spec.TaskVolume.SecretRef},
						Key:                  "s3_access_key",
					},
				},
			},
			corev1.EnvVar{
				Name: "S3COMPAT_OBJECT_STORE_SECRET_KEY",
				ValueFrom: &corev1.EnvVarSource{
					SecretKeyRef: &corev1.SecretKeySelector{
						LocalObjectReference: corev1.LocalObjectReference{Name: ai.Spec.TaskVolume.SecretRef},
						Key:                  "s3_secret_key",
					},
				},
			},
		)
	}

	// mTLS handling (dynamic)
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

	// Import ALL static keys from the SAIA ConfigMap as env vars.
	envFrom := []corev1.EnvFromSource{
		{
			ConfigMapRef: &corev1.ConfigMapEnvSource{
				LocalObjectReference: corev1.LocalObjectReference{
					Name: fmt.Sprintf("%s-saia-config", ai.Name),
				},
				// Optional: set Optional: &truePtr if you prefer soft-fail
			},
		},
	}

	// Sort only the explicit envs (envFrom remains as-is)
	sort.Slice(env, func(i, j int) bool { return env[i].Name < env[j].Name })

	deployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-saia-deployment",
			Namespace: ai.Namespace,
		},
	}

	// Merge labels/annotations from AIService
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

	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, deployment, func() error {
		// Set mutable fields that can be updated
		deployment.ObjectMeta.Labels = labels
		deployment.ObjectMeta.Annotations = annotations
		deployment.Spec.Replicas = &ai.Spec.Replicas

		// Set selector only on creation (immutable field)
		if deployment.Spec.Selector == nil {
			deployment.Spec.Selector = &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": ai.Name, "component": ai.Name},
			}
		}

		// Always update the pod template
		deployment.Spec.Template = corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{
				Labels:      map[string]string{"app": ai.Name, "component": ai.Name},
				Annotations: annotations,
			},
			Spec: corev1.PodSpec{
				ServiceAccountName: ai.Spec.ServiceAccountName,
				Containers: []corev1.Container{{
					Name:            ai.Name,
					Image:           os.Getenv("RELATED_IMAGE_SAIA_API"),
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
						FailureThreshold: 5,
					},
					ReadinessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromInt(8080)},
						},
						PeriodSeconds:    30,
						FailureThreshold: 5,
					},
					StartupProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromInt(8080)},
						},
						InitialDelaySeconds: 10,
						PeriodSeconds:       30,
						FailureThreshold:    5,
					},
				}},
				Volumes:     volumes,
				Affinity:    &ai.Spec.Affinity,
				Tolerations: ai.Spec.Tolerations,
				// Propagate imagePullSecrets from AIService spec
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

// reconcileSAIAService ensures the Service for SAIA is created/updated. // remove me
func (r *SaiaReconciler) reconcileSAIAService(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	// Clean the ServiceTemplate to remove server-generated fields
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
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-saia-service",
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
		} // Ignore last-applied-configuration annotation
		if k == "kubectl.kubernetes.io/restartedAt" {
			continue
		} // Ignore restartedAt annotation
		svc.ObjectMeta.Annotations[k] = v
	}

	switch serviceTemplate.Spec.Type {
	case corev1.ServiceTypeLoadBalancer:
		svc.Spec.Type = corev1.ServiceTypeLoadBalancer
	case corev1.ServiceTypeNodePort:
		svc.Spec.Type = corev1.ServiceTypeNodePort
		// If NodePort values are specified, set them
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
		// Update mutable fields
		svc.Spec.Selector = map[string]string{"app": ai.Name, "component": ai.Name}
		svc.Spec.Ports = ports
		// Type is already set above based on ServiceTemplate
		return nil
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update Service failed")
		return fmt.Errorf("create/update Service: %w", err)
	}
	return nil
}

// reconcileServiceMonitor creates a Prometheus ServiceMonitor if metrics are enabled.
func (r *SaiaReconciler) reconcileServiceMonitor(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	if !ai.Spec.Metrics.Enabled {
		return nil
	}
	sm := &monitoringv1.ServiceMonitor{
		ObjectMeta: metav1.ObjectMeta{Name: ai.Name + "-metrics", Namespace: ai.Namespace},
		Spec: monitoringv1.ServiceMonitorSpec{
			Selector: metav1.LabelSelector{
				MatchLabels: map[string]string{"app": ai.Name, "component": ai.Name},
			},
			Endpoints: []monitoringv1.Endpoint{
				{Port: "metrics", Path: ai.Spec.Metrics.Path, Scheme: "http"},
			},
		},
	}
	if err := controllerutil.SetControllerReference(ai, sm, r.Scheme); err != nil {
		return err
	}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, sm, func() error {
		// Update ServiceMonitor spec
		sm.Spec = monitoringv1.ServiceMonitorSpec{
			Selector: metav1.LabelSelector{
				MatchLabels: map[string]string{"app": ai.Name, "component": ai.Name},
			},
			Endpoints: []monitoringv1.Endpoint{
				{Port: "metrics", Path: ai.Spec.Metrics.Path, Scheme: "http"},
			},
		}
		return nil
	})
	return err
}

// createOrUpdateConfigMap is a helper to create or patch a ConfigMap // remove me
func (r *SaiaReconciler) createOrUpdateConfigMap(
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

// extractBucketName extracts the bucket name from an object storage path.
// Supports s3://, s3compat://, minio://, seaweedfs://, gs://, and azure:// prefixes.
// Examples:
//   - "s3://my-bucket/path/to/dir" -> "my-bucket"
//   - "s3compat://bucket-name" -> "bucket-name"
//   - "minio://bucket-name" -> "bucket-name"
//   - "seaweedfs://my-bucket/prefix" -> "my-bucket"
//   - "gs://my-bucket" -> "my-bucket"
func extractBucketName(path string) string {
	// Remove supported prefixes
	prefixes := []string{"s3://", "s3compat://", "minio://", "seaweedfs://", "gs://", "azure://"}
	for _, prefix := range prefixes {
		if strings.HasPrefix(path, prefix) {
			path = strings.TrimPrefix(path, prefix)
			break
		}
	}

	// Extract just the bucket name (first part before any slash)
	if idx := strings.Index(path, "/"); idx > 0 {
		return path[:idx]
	}

	return path
}

// reconcileNginxProxyConfigMap creates or updates the Nginx ConfigMap when the proxy is enabled.
func (r *SaiaReconciler) reconcileNginxProxyConfigMap(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	if !ai.Spec.NginxProxy.Enabled {
		return nil
	}

	nginxConf := fmt.Sprintf(`server {
    listen 8080;

    location /saia/v1/ {
        proxy_pass %s/;
        proxy_pass_request_headers on;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /saia/v2/ {
        proxy_pass %s/;
        proxy_pass_request_headers on;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}`, ai.Spec.NginxProxy.V1Upstream, ai.Spec.NginxProxy.V2Upstream)

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-nginx-proxy-config",
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, cm, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on Nginx ConfigMap: %w", err)
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, cm, func() error {
		cm.Data = map[string]string{"default.conf": nginxConf}
		return nil
	}); err != nil {
		return fmt.Errorf("create/update Nginx ConfigMap: %w", err)
	}
	return nil
}

// reconcileNginxProxyDeployment creates or updates the Nginx Deployment and Service when the proxy is enabled.
func (r *SaiaReconciler) reconcileNginxProxyDeployment(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	if !ai.Spec.NginxProxy.Enabled {
		return nil
	}

	replicas := ai.Spec.NginxProxy.Replicas
	if replicas == 0 {
		replicas = 2
	}

	nginxImage := "nginx:1.27-alpine"

	deployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-nginx-proxy",
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, deployment, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on Nginx Deployment: %w", err)
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, deployment, func() error {
		deployment.Labels = map[string]string{"app": ai.Name + "-nginx-proxy"}
		deployment.Spec.Replicas = &replicas
		if deployment.Spec.Selector == nil {
			deployment.Spec.Selector = &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": ai.Name + "-nginx-proxy"},
			}
		}
		deployment.Spec.Template = corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{
				Labels: map[string]string{"app": ai.Name + "-nginx-proxy"},
			},
			Spec: corev1.PodSpec{
				Containers: []corev1.Container{{
					Name:            "nginx",
					Image:           nginxImage,
					ImagePullPolicy: corev1.PullIfNotPresent,
					Ports:           []corev1.ContainerPort{{ContainerPort: 8080}},
					VolumeMounts: []corev1.VolumeMount{{
						Name:      "nginx-config",
						MountPath: "/etc/nginx/conf.d",
					}},
				}},
				Volumes: []corev1.Volume{{
					Name: "nginx-config",
					VolumeSource: corev1.VolumeSource{
						ConfigMap: &corev1.ConfigMapVolumeSource{
							LocalObjectReference: corev1.LocalObjectReference{
								Name: ai.Name + "-nginx-proxy-config",
							},
						},
					},
				}},
				ImagePullSecrets: ai.Spec.ImagePullSecrets,
			},
		}
		return nil
	}); err != nil {
		return fmt.Errorf("create/update Nginx Deployment: %w", err)
	}

	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-nginx-proxy-svc",
			Namespace: ai.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(ai, svc, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on Nginx Service: %w", err)
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Spec.Selector = map[string]string{"app": ai.Name + "-nginx-proxy"}
		svc.Spec.Ports = []corev1.ServicePort{{
			Name:       "http",
			Port:       8080,
			TargetPort: intstr.FromInt(8080),
			Protocol:   corev1.ProtocolTCP,
		}}
		svc.Spec.Type = corev1.ServiceTypeClusterIP
		return nil
	}); err != nil {
		return fmt.Errorf("create/update Nginx Service: %w", err)
	}
	return nil
}

// cleanServiceTemplate removes server-generated metadata fields that shouldn't be set during updates.
// This prevents "unknown field" warnings in logs.
func cleanServiceTemplate(template *corev1.Service) {
	if template == nil {
		return
	}

	// Clear server-generated metadata fields
	template.ObjectMeta.CreationTimestamp = metav1.Time{}
	template.ObjectMeta.DeletionTimestamp = nil
	template.ObjectMeta.DeletionGracePeriodSeconds = nil
	template.ObjectMeta.UID = ""
	template.ObjectMeta.ResourceVersion = ""
	template.ObjectMeta.Generation = 0
	template.ObjectMeta.SelfLink = ""
	template.ObjectMeta.ManagedFields = nil

	// Clear status - it's not used in templates
	template.Status = corev1.ServiceStatus{}
}
