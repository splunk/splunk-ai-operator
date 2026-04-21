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
		{"SAIAv2Deployment", r.reconcileSAIAv2Deployment},
		{"SAIAv2Worker", r.reconcileSAIAv2Worker},
		{"NginxConfigMap", r.reconcileNginxConfigMap},
		{"NginxDeployment", r.reconcileNginxDeployment},
		{"SAIAv1Service", r.reconcileSAIAv1Service},
		{"SAIAv2Service", r.reconcileSAIAv2Service},
		{"SAIAService", r.reconcileSAIAService},
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
			scheme := ai.Spec.AIPlatformScheme
			if scheme == "" {
				scheme = "http"
			}
			ai.Spec.AIPlatformUrl = fmt.Sprintf("%s://%s.%s.svc.%s:8000",
				scheme, aiPlatform.Status.RayServiceName, ai.Spec.AIPlatformRef.Namespace, clusterDomain)
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

	// V2 image is required (v2 is always deployed alongside v1)
	if ai.Spec.V2.Image == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "v2.image must be set for SAIA v2 deployment")
		return fmt.Errorf("v2.image must be set for SAIA v2 deployment")
	}
	if ai.Spec.V2.Replicas == 0 {
		ai.Spec.V2.Replicas = 1
	}
	if ai.Spec.V2Worker.Replicas == 0 {
		ai.Spec.V2Worker.Replicas = 1
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
	//
	// ENABLE_AUTHZ MUST be "true" for SAIAAuthorizer.authorize() to run its
	// CMP interactive-token validation branch, which is the ONLY code path
	// that sets request.state.cmp_splunk_url on a successful token. The admin
	// endpoints (AdminCapabilityAuthorizer) read that attribute to bridge the
	// Splunk.interactive bearer into an EC-equivalent token. With "false" the
	// main authorizer early-returns, the attribute is never set, and every
	// /admin/* request fails with:
	//   403 {"detail":"Admin endpoints require an authenticated EC user token."}
	// There is no authorization-skip value that also preserves CMP bridging —
	// the value IS "true" even in airgap CMP mode.
	defaults := map[string]string{
		// previously hardcoded
		"SERVICE_NAME":                    "splunk_ai_assistant",
		"SERVICE_INTERNAL_NAME":           "SAIA",
		"SPLUNK_ISSUERS":                  "https://splunk-splunk-standalone-standalone-service:8089",
		"SPLUNK_AI_ASSISTANT_SERVICE_CMP": "true",
		"ENABLE_AUTHZ":                    "true",
		"FEATURE_CONFIG_FILE_LOCATION":    "/etc/config/features_config.yaml",
		"PLATFORM_VERSION":                "0.3.0",    // TODO make configurable
		"SAIA_API_VERSION":                "0.3.1",    // TODO make configurable
		"TELEMETRY_ENV":                   "NOTLOCAL", // TODO make configurable
		"LOG_LEVEL":                       "info",
		"USE_GPT_OSS":                     "true",
		"SCS_TOKEN":                       "no-auth-required",
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
							ImagePullPolicy: corev1.PullIfNotPresent,
							// The v2 data-loader image (>= v2.0.4-13-g3b677604) uses the
							// Weaviate v4 Python client, which performs a gRPC health
							// check on connect and requires explicit gRPC host/port. Its
							// URL-compat shim defaults to the Splunk production naming
							// (grpc.<host>:443 TLS) if these are unset — wrong for k0s
							// airgap where Weaviate exposes gRPC on the same Service
							// (port 50051, plaintext). Always set these explicitly so
							// the shim's setdefault() calls are no-ops.
							Env: []corev1.EnvVar{
								{Name: "VECTOR_DB_URL", Value: uri},
								{Name: "VECTOR_DB_HOST", Value: ai.Spec.VectorDbUrl},
								{Name: "VECTOR_DB_PORT", Value: "80"},
								{Name: "VECTOR_DB_GRPC_HOST", Value: ai.Spec.VectorDbUrl},
								{Name: "VECTOR_DB_GRPC_PORT", Value: "50051"},
								{Name: "VECTOR_DB_SECURE", Value: "false"},
								{Name: "VECTOR_DB_AUTH_ENABLED", Value: "false"},
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

// buildSAIABaseEnv returns the common environment variables shared across all SAIA pods
// (v1 API, v1 worker, v2 API, v2 worker). Callers append pod-specific vars.
func buildSAIABaseEnv(ai *aiv1.AIService) []corev1.EnvVar {
	bucketName := extractBucketName(ai.Spec.TaskVolume.Path)
	env := []corev1.EnvVar{
		{Name: "PLATFORM_URL", Value: ai.Spec.AIPlatformUrl},
		{Name: "VECTOR_DB_URL", Value: ai.Spec.VectorDbUrl},
		{Name: "S3_BUCKET", Value: bucketName},
	}

	if ai.Spec.TaskVolume.Endpoint != "" {
		env = append(env,
			corev1.EnvVar{Name: "S3COMPAT_OBJECT_STORE_ENDPOINT_URL", Value: ai.Spec.TaskVolume.Endpoint},
			corev1.EnvVar{Name: "S3COMPAT_OBJECT_STORE_BUCKET", Value: bucketName},
		)
	}

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

	return env
}

// buildV2ExtraEnv returns additional env vars needed by the SAIA v2 image.
// v2 uses different env var names: VECTOR_DB_HOST (not VECTOR_DB_URL),
// ML_PLATFORM_URL (not PLATFORM_URL), and needs vector DB TLS/auth disabled.
//
// SAIA V2 FieldDescription backend selection (required by both v2 API and v2
// worker, else FieldDescriptionRepositoryFactory.get() raises ValueError at
// startup and the worker enters a restart loop).
//
// Per Confluence ERD "ERD - AI Tier v0.2 - Bare Metal - SAIA 2.0", section
// 3.8.1.2 + decision A.3: Option B (clean architecture) — use the new `s3`
// backend that reads the global field-descriptions JSON from the same
// S3-compatible object store (SeaweedFS/MinIO/CVFS) that SAIA already uses
// for tenant data. The alternatives:
//   - `dynamodb` — ERD assumption 2.1 explicitly disallows DynamoDB in AI Tier.
//   - `file`     — requires the saia-v2 Dockerfile to `COPY dataset/`, which
//     the current image (v2.0.4-31-g9efe1fc) does NOT do.
//
// The JSON object must be pre-uploaded to S3_BUCKET/FIELD_DESCRIPTION_S3_KEY
// before the worker runs; the data-loader Job is the canonical bootstrap step
// for this (see scripts/data_loader/ in saia-service).
//
// AWS_ENDPOINT_URL / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY: the v2
// S3StorageAdapter (used by S3FieldDescriptionRepository, see
// app/repositories/field_description/factory.py) constructs boto3 directly and
// reads the canonical AWS_* names. v1's S3COMPAT_OBJECT_STORE_* env vars are
// already set in buildSAIABaseEnv but are NOT read by boto3, so without
// AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY the worker would silently fall back
// to no-credentials (NoCredentialsError caught by the repository as
// StorageAdapterError, returning an empty cache and degraded search results).
// Sourcing them from the same secret keys as the S3-compat creds keeps a
// single source of truth for object-store auth.
func buildV2ExtraEnv(ai *aiv1.AIService) []corev1.EnvVar {
	env := []corev1.EnvVar{
		{Name: "ML_PLATFORM_URL", Value: ai.Spec.AIPlatformUrl},
		{Name: "VECTOR_DB_AUTH_ENABLED", Value: "false"},
		{Name: "VECTOR_DB_GRPC_HOST", Value: ai.Spec.VectorDbUrl},
		{Name: "VECTOR_DB_GRPC_PORT", Value: "50051"},
		{Name: "VECTOR_DB_HOST", Value: ai.Spec.VectorDbUrl},
		{Name: "VECTOR_DB_PORT", Value: "80"},
		{Name: "VECTOR_DB_SECURE", Value: "false"},
		// FieldDescription S3 backend (see doc-comment above).
		{Name: "FIELD_DESCRIPTION_BACKEND", Value: "s3"},
		{Name: "FIELD_DESCRIPTION_S3_KEY", Value: "field-descriptions/global-field-descriptions.json"},
	}
	// Only expose AWS_ENDPOINT_URL when the operator was configured with an
	// explicit S3-compatible endpoint (SeaweedFS/MinIO). Omitting it lets the
	// v2 adapter use the default AWS S3 endpoint when running in a real cloud
	// deployment.
	if ai.Spec.TaskVolume.Endpoint != "" {
		env = append(env, corev1.EnvVar{
			Name:  "AWS_ENDPOINT_URL",
			Value: ai.Spec.TaskVolume.Endpoint,
		})
	}
	// boto3-canonical credentials for the v2 S3StorageAdapter. Mirrors the
	// S3COMPAT_OBJECT_STORE_ACCESS_KEY/_SECRET_KEY plumbing in buildSAIABaseEnv;
	// see s3compat secret schema in raybuilder/builder.go and ai.Spec.TaskVolume.SecretRef.
	if ai.Spec.TaskVolume.SecretRef != "" {
		env = append(env,
			corev1.EnvVar{
				Name: "AWS_ACCESS_KEY_ID",
				ValueFrom: &corev1.EnvVarSource{
					SecretKeyRef: &corev1.SecretKeySelector{
						LocalObjectReference: corev1.LocalObjectReference{Name: ai.Spec.TaskVolume.SecretRef},
						Key:                  "s3_access_key",
					},
				},
			},
			corev1.EnvVar{
				Name: "AWS_SECRET_ACCESS_KEY",
				ValueFrom: &corev1.EnvVarSource{
					SecretKeyRef: &corev1.SecretKeySelector{
						LocalObjectReference: corev1.LocalObjectReference{Name: ai.Spec.TaskVolume.SecretRef},
						Key:                  "s3_secret_key",
					},
				},
			},
		)
	}
	return env
}

// buildSAIATLSEnv appends TLS-related env vars and returns updated env, volumes, and mounts.
func buildSAIATLSEnv(ai *aiv1.AIService, env []corev1.EnvVar, volumes []corev1.Volume, mounts []corev1.VolumeMount, ports []corev1.ContainerPort) ([]corev1.EnvVar, []corev1.Volume, []corev1.VolumeMount, []corev1.ContainerPort) {
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
	return env, volumes, mounts, ports
}

// saiaEnvFrom returns the EnvFromSource for the SAIA ConfigMap.
func saiaEnvFrom(ai *aiv1.AIService) []corev1.EnvFromSource {
	return []corev1.EnvFromSource{
		{
			ConfigMapRef: &corev1.ConfigMapEnvSource{
				LocalObjectReference: corev1.LocalObjectReference{
					Name: fmt.Sprintf("%s-saia-config", ai.Name),
				},
			},
		},
	}
}

// saiaVolumes returns the standard config volume and mount for SAIA pods.
func saiaVolumes(ai *aiv1.AIService) ([]corev1.Volume, []corev1.VolumeMount) {
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
	mounts := []corev1.VolumeMount{
		{Name: "config-volume", MountPath: "/etc/config"},
	}
	return volumes, mounts
}

// saiaLabelsAndAnnotations returns the labels and annotations for SAIA pods.
func saiaLabelsAndAnnotations(ai *aiv1.AIService, component string) (map[string]string, map[string]string) {
	labels := map[string]string{
		"app":       ai.Name,
		"component": component,
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
	return labels, annotations
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

	// S3-compatible object store: set S3COMPAT_OBJECT_STORE_ENDPOINT_URL and S3COMPAT_OBJECT_STORE_BUCKET for custom endpoint (MinIO, SeaweedFS, etc.).
	if ai.Spec.TaskVolume.Endpoint != "" {
		env = append(env,
			corev1.EnvVar{Name: "S3COMPAT_OBJECT_STORE_ENDPOINT_URL", Value: ai.Spec.TaskVolume.Endpoint},
			corev1.EnvVar{Name: "S3COMPAT_OBJECT_STORE_BUCKET", Value: extractBucketName(ai.Spec.TaskVolume.Path)},
		)
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
					ImagePullPolicy: corev1.PullIfNotPresent,
					Command:         []string{"/bin/sh", "-c"},
					Args:            []string{"python -m uvicorn --host 0.0.0.0 server.main:metrics_app --port 8088 & exec python -m uvicorn --host 0.0.0.0 server.main:app --port 8080"},
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

// reconcileSAIAv2Deployment creates the v2 API Deployment and its internal Service.
func (r *SaiaReconciler) reconcileSAIAv2Deployment(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	volumes, mounts := saiaVolumes(ai)
	ports := []corev1.ContainerPort{
		{Name: "http", ContainerPort: 8000},
		{Name: "metrics", ContainerPort: 8088},
	}

	env := buildSAIABaseEnv(ai)
	env = append(env, buildV2ExtraEnv(ai)...)
	env = append(env, corev1.EnvVar{Name: "VAULT_TEMPLATE_DISABLED", Value: "true"})
	env, volumes, mounts, ports = buildSAIATLSEnv(ai, env, volumes, mounts, ports)
	sort.Slice(env, func(i, j int) bool { return env[i].Name < env[j].Name })

	component := ai.Name + "-v2-api"
	labels, annotations := saiaLabelsAndAnnotations(ai, component)

	deployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-saia-v2-deployment",
			Namespace: ai.Namespace,
		},
	}

	if err := controllerutil.SetControllerReference(ai, deployment, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on v2 Deployment: %w", err)
	}

	v2Resources := ai.Spec.V2.Resources
	if v2Resources.Requests == nil {
		v2Resources = ai.Spec.Resources
	}

	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, deployment, func() error {
		deployment.ObjectMeta.Labels = labels
		deployment.ObjectMeta.Annotations = annotations
		deployment.Spec.Replicas = &ai.Spec.V2.Replicas

		if deployment.Spec.Selector == nil {
			deployment.Spec.Selector = &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": ai.Name, "component": component},
			}
		}

		deployment.Spec.Template = corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{
				Labels:      map[string]string{"app": ai.Name, "component": component},
				Annotations: annotations,
			},
			Spec: corev1.PodSpec{
				ServiceAccountName: ai.Spec.ServiceAccountName,
				Containers: []corev1.Container{{
					Name:            "saia-v2-api",
					Image:           ai.Spec.V2.Image,
					ImagePullPolicy: corev1.PullIfNotPresent,
					Command:         []string{"/bin/sh", "-c"},
					Args:            []string{". /home/splunk/init-prometheus.sh && python -m uvicorn --host 0.0.0.0 app.main:metrics_app --port 8088 & exec python -m uvicorn --host 0.0.0.0 app.main:app --port 8000"},
					Ports:           ports,
					VolumeMounts:    mounts,
					Resources:       v2Resources,
					Env:             env,
					EnvFrom:         saiaEnvFrom(ai),
					LivenessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromInt(8000)},
						},
						PeriodSeconds:    30,
						FailureThreshold: 5,
					},
					ReadinessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromInt(8000)},
						},
						PeriodSeconds:    30,
						FailureThreshold: 5,
					},
					StartupProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromInt(8000)},
						},
						InitialDelaySeconds: 10,
						PeriodSeconds:       30,
						FailureThreshold:    5,
					},
				}},
				Volumes:          volumes,
				Affinity:         &ai.Spec.Affinity,
				Tolerations:      ai.Spec.Tolerations,
				ImagePullSecrets: ai.Spec.ImagePullSecrets,
			},
		}
		return nil
	}); err != nil {
		return fmt.Errorf("create/update v2 Deployment: %w", err)
	}
	return nil
}

// reconcileSAIAv2Worker creates the v2 worker Deployment (same v2 image, command=run-worker.sh).
func (r *SaiaReconciler) reconcileSAIAv2Worker(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	volumes, mounts := saiaVolumes(ai)
	ports := []corev1.ContainerPort{
		{Name: "metrics", ContainerPort: 8088},
	}

	env := buildSAIABaseEnv(ai)
	env = append(env, buildV2ExtraEnv(ai)...)
	// Keep heartbeat path in sync with saia-v2's default (app/core/config.py:
	// worker_heartbeat_path = "/tmp/ingestion_worker_heartbeat"). The ingestion
	// worker writes a floating-point unix timestamp to this file every poll cycle.
	//
	// RUN_TASKS_DELAY_S (run_tasks_delay_s) is the per-iteration sleep in
	// IngestionWorker.run() when the queue is empty OR the tenant lock is busy.
	// The heartbeat is written only at the top of process_next(), so this sleep
	// directly controls heartbeat cadence. The liveness probe rejects heartbeats
	// older than 120s, so we MUST keep this well under that threshold — 10s
	// matches the saia-v2 default (see Settings.run_tasks_delay_s). Do NOT
	// conflate with the v1 worker APScheduler cron (which uses 600s for weekly
	// jobs); v2 reuses the same env name for a different purpose.
	env = append(env,
		corev1.EnvVar{Name: "RUN_TASKS_DELAY_S", Value: "10"},
		corev1.EnvVar{Name: "VAULT_TEMPLATE_DISABLED", Value: "true"},
		corev1.EnvVar{Name: "WORKER_HEARTBEAT_PATH", Value: "/tmp/ingestion_worker_heartbeat"},
	)
	env, volumes, mounts, _ = buildSAIATLSEnv(ai, env, volumes, mounts, nil)
	sort.Slice(env, func(i, j int) bool { return env[i].Name < env[j].Name })

	component := ai.Name + "-v2-worker"
	labels, annotations := saiaLabelsAndAnnotations(ai, component)

	deployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-saia-v2-worker",
			Namespace: ai.Namespace,
		},
	}

	if err := controllerutil.SetControllerReference(ai, deployment, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on v2 worker Deployment: %w", err)
	}

	v2WorkerResources := ai.Spec.V2Worker.Resources
	if v2WorkerResources.Requests == nil {
		v2WorkerResources = ai.Spec.Resources
	}

	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, deployment, func() error {
		deployment.ObjectMeta.Labels = labels
		deployment.ObjectMeta.Annotations = annotations
		deployment.Spec.Replicas = &ai.Spec.V2Worker.Replicas

		if deployment.Spec.Selector == nil {
			deployment.Spec.Selector = &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": ai.Name, "component": component},
			}
		}

		deployment.Spec.Template = corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{
				Labels:      map[string]string{"app": ai.Name, "component": component},
				Annotations: annotations,
			},
			Spec: corev1.PodSpec{
				ServiceAccountName: ai.Spec.ServiceAccountName,
				Containers: []corev1.Container{{
					Name:            "saia-v2-worker",
					Image:           ai.Spec.V2.Image,
					ImagePullPolicy: corev1.PullIfNotPresent,
					Command:         []string{"/bin/sh", "-c"},
					Args:            []string{". /home/splunk/init-prometheus.sh && python -m uvicorn --host 0.0.0.0 app.main:metrics_app --port 8088 & exec python -m app.workers.ingestion_worker"},
					Ports:           ports,
					VolumeMounts:    mounts,
					Resources:       v2WorkerResources,
					Env:             env,
					EnvFrom:         saiaEnvFrom(ai),
					LivenessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							Exec: &corev1.ExecAction{
								// The saia-v2 base image (python3-debian13-vault:4.1.3) is a minimal
								// Python runtime that lacks coreutils like `date`, `cat`, `cut`. Use
								// python3 directly, which is guaranteed to exist. The heartbeat file
								// contains a float "secs.usec\n" written by ingestion_worker.
								Command: []string{
									"python3", "-c",
									"import os,sys,time\n" +
										"p=os.environ.get('WORKER_HEARTBEAT_PATH','/tmp/ingestion_worker_heartbeat')\n" +
										"sys.exit(0 if os.path.exists(p) and (time.time()-float(open(p).read().strip()))<120 else 1)",
								},
							},
						},
						PeriodSeconds:       60,
						FailureThreshold:    3,
						InitialDelaySeconds: 30,
					},
				}},
				Volumes:          volumes,
				Affinity:         &ai.Spec.Affinity,
				Tolerations:      ai.Spec.Tolerations,
				ImagePullSecrets: ai.Spec.ImagePullSecrets,
			},
		}
		return nil
	}); err != nil {
		return fmt.Errorf("create/update v2 worker Deployment: %w", err)
	}
	return nil
}

// reconcileNginxConfigMap creates the ConfigMap with nginx.conf for path-based routing.
func (r *SaiaReconciler) reconcileNginxConfigMap(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	v1ServiceName := ai.Name + "-saia-v1-service"
	v2ServiceName := ai.Name + "-saia-v2-service"

	nginxConf := fmt.Sprintf(`worker_processes auto;
error_log /dev/stderr warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format routing '$remote_addr - [$time_local] "$request" '
                       'status=$status upstream=$upstream_addr '
                       'rt=$request_time uct=$upstream_connect_time urt=$upstream_response_time';

    access_log /dev/stdout routing;

    upstream saia_v1 {
        server %s:8080;
    }

    upstream saia_v2 {
        server %s:8000;
    }

    # Reflect Access-Control-Request-Headers back on preflight. If the browser
    # didn't send any (rare), fall back to a broad default. Safer than a
    # hardcoded allowlist because spl-copilot (and future clients) may add
    # custom headers like x-requested-with, x-csrf-token, x-splunk-*, etc.
    map $http_access_control_request_headers $cors_allow_headers {
        default $http_access_control_request_headers;
        ""      "authorization, content-type, x-ec-token, x-es-tenant-bearer, x-stack-url, x-stack-url-legacy, splunk-client, x-conversation-key, x-request-id, x-admin-preferences-filename, x-requested-with";
    }

    server {
        listen 8080;

        # Nginx health/status endpoints MUST be declared before the v2 regex
        # match; otherwise nginx's longest-prefix-before-regex rule would let
        # exact matches win only if explicitly marked with "^~" or "=", and we
        # don't want a stray /saia-api-v2/nginx_status to ever hit the backend.
        location = /nginx_health {
            return 200 'ok';
            add_header Content-Type text/plain;
        }

        location = /nginx_status {
            # stub_status exposes counters (active connections, reqs/s, etc.).
            # k8s probes use /nginx_health — NOT /nginx_status — so restricting
            # this to the nginx pod's loopback is safe. Operators needing to
            # scrape should exec into the pod (kubectl exec curl 127.0.0.1/nginx_status).
            stub_status on;
            allow 127.0.0.1;
            deny all;
        }

        # v2: any path containing /saia-api-v2/ (with or without a tenant
        # prefix). Using "search anywhere" avoids the ^/<tenant>/ requirement
        # that would silently fall through to v1 for tenant-less callers.
        # Word boundary via "/saia-api-v2/" (not "saia-api-v2" substring)
        # prevents accidental matches like /foo/saia-api-v2-legacy/.
        location ~ /saia-api-v2/ {
            # CORS preflight short-circuit. Browser preflights are
            # unauthenticated by spec; SAIA v2's TenantConversationKeyMiddleware
            # rejects them with 400 before FastAPI's CORSMiddleware can respond,
            # which makes the browser block the real request with "No
            # Access-Control-Allow-Origin header present". Answer preflight
            # here and never proxy OPTIONS upstream.
            #
            # IMPORTANT: Do NOT emit Access-Control-Allow-Origin on non-OPTIONS
            # responses — FastAPI's CORSMiddleware already sets it on real
            # responses. A second ACAO from nginx would produce duplicate
            # "*, http://origin" values that browsers reject.
            if ($request_method = OPTIONS) {
                add_header Access-Control-Allow-Origin $http_origin always;
                add_header Access-Control-Allow-Credentials true always;
                add_header Access-Control-Allow-Methods 'GET, POST, PUT, DELETE, PATCH, OPTIONS' always;
                add_header Access-Control-Allow-Headers $cors_allow_headers always;
                add_header Access-Control-Max-Age 3600 always;
                add_header Content-Length 0 always;
                add_header Content-Type 'text/plain charset=UTF-8' always;
                return 204;
            }

            proxy_pass http://saia_v2;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
            proxy_buffering off;
            chunked_transfer_encoding on;
        }

        # v1: everything else (including /health, /{tenant}/saia-api/v1alpha1/...)
        location / {
            # Mirror the CORS preflight short-circuit for v1 routes; spl-copilot's
            # Pattern B (direct browser fetch) may hit v1 admin endpoints too. Same
            # rationale as v2: SAIA v1 middlewares authenticate on OPTIONS and would
            # reject the preflight before CORS headers are emitted.
            if ($request_method = OPTIONS) {
                add_header Access-Control-Allow-Origin $http_origin always;
                add_header Access-Control-Allow-Credentials true always;
                add_header Access-Control-Allow-Methods 'GET, POST, PUT, DELETE, PATCH, OPTIONS' always;
                add_header Access-Control-Allow-Headers $cors_allow_headers always;
                add_header Access-Control-Max-Age 3600 always;
                add_header Content-Length 0 always;
                add_header Content-Type 'text/plain charset=UTF-8' always;
                return 204;
            }

            proxy_pass http://saia_v1;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
            proxy_buffering off;
        }
    }
}
`, v1ServiceName, v2ServiceName)

	cmName := ai.Name + "-saia-nginx-config"
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cmName,
			Namespace: ai.Namespace,
		},
	}

	if err := controllerutil.SetControllerReference(ai, cm, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on nginx ConfigMap: %w", err)
	}

	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, cm, func() error {
		cm.Data = map[string]string{"nginx.conf": nginxConf}
		return nil
	}); err != nil {
		return fmt.Errorf("create/update nginx ConfigMap: %w", err)
	}
	return nil
}

// reconcileNginxDeployment creates the nginx reverse proxy Deployment.
func (r *SaiaReconciler) reconcileNginxDeployment(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	component := ai.Name + "-nginx"
	labels, annotations := saiaLabelsAndAnnotations(ai, component)

	deployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-saia-nginx",
			Namespace: ai.Namespace,
		},
	}

	if err := controllerutil.SetControllerReference(ai, deployment, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on nginx Deployment: %w", err)
	}

	var replicas int32 = 1

	// Resolve nginx image. Allow an override via RELATED_IMAGE_NGINX so airgapped
	// installs can pull the image from a private mirror. Fall back to a stable
	// upstream tag so `make run` / default helm deploys still work.
	nginxImage := os.Getenv("RELATED_IMAGE_NGINX")
	if nginxImage == "" {
		nginxImage = "nginx:1.27-alpine"
	}

	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, deployment, func() error {
		deployment.ObjectMeta.Labels = labels
		deployment.ObjectMeta.Annotations = annotations
		deployment.Spec.Replicas = &replicas

		if deployment.Spec.Selector == nil {
			deployment.Spec.Selector = &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": ai.Name, "component": component},
			}
		}

		deployment.Spec.Template = corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{
				Labels:      map[string]string{"app": ai.Name, "component": component},
				Annotations: annotations,
			},
			Spec: corev1.PodSpec{
				Containers: []corev1.Container{{
					Name:            "nginx",
					Image:           nginxImage,
					ImagePullPolicy: corev1.PullIfNotPresent,
					Ports: []corev1.ContainerPort{
						{Name: "http", ContainerPort: 8080},
					},
					VolumeMounts: []corev1.VolumeMount{
						{Name: "nginx-config", MountPath: "/etc/nginx/nginx.conf", SubPath: "nginx.conf"},
					},
					Resources: corev1.ResourceRequirements{
						Requests: corev1.ResourceList{
							corev1.ResourceCPU:    resource.MustParse("100m"),
							corev1.ResourceMemory: resource.MustParse("64Mi"),
						},
						Limits: corev1.ResourceList{
							corev1.ResourceCPU:    resource.MustParse("500m"),
							corev1.ResourceMemory: resource.MustParse("128Mi"),
						},
					},
					LivenessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{Path: "/nginx_health", Port: intstr.FromInt(8080)},
						},
						PeriodSeconds:    30,
						FailureThreshold: 3,
					},
					ReadinessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{Path: "/nginx_health", Port: intstr.FromInt(8080)},
						},
						PeriodSeconds:    10,
						FailureThreshold: 3,
					},
				}},
				Volumes: []corev1.Volume{
					{
						Name: "nginx-config",
						VolumeSource: corev1.VolumeSource{
							ConfigMap: &corev1.ConfigMapVolumeSource{
								LocalObjectReference: corev1.LocalObjectReference{
									Name: ai.Name + "-saia-nginx-config",
								},
							},
						},
					},
				},
				ImagePullSecrets: ai.Spec.ImagePullSecrets,
			},
		}
		return nil
	}); err != nil {
		return fmt.Errorf("create/update nginx Deployment: %w", err)
	}
	return nil
}

// reconcileSAIAv1Service creates the internal v1 ClusterIP Service.
func (r *SaiaReconciler) reconcileSAIAv1Service(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	component := ai.Name // v1 API uses "app: {name}, component: {name}" from reconcileSAIADeployment
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-saia-v1-service",
			Namespace: ai.Namespace,
			Labels:    map[string]string{"app": ai.Name},
		},
	}

	if err := controllerutil.SetControllerReference(ai, svc, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on v1 Service: %w", err)
	}

	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Spec.Selector = map[string]string{"app": ai.Name, "component": component}
		svc.Spec.Ports = []corev1.ServicePort{
			{Name: "http", Port: 8080, TargetPort: intstr.FromInt(8080)},
			{Name: "metrics", Port: 8088, TargetPort: intstr.FromInt(8088)},
		}
		svc.Spec.Type = corev1.ServiceTypeClusterIP
		return nil
	}); err != nil {
		return fmt.Errorf("create/update v1 Service: %w", err)
	}
	return nil
}

// reconcileSAIAv2Service creates the internal v2 ClusterIP Service.
func (r *SaiaReconciler) reconcileSAIAv2Service(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	component := ai.Name + "-v2-api"
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-saia-v2-service",
			Namespace: ai.Namespace,
			Labels:    map[string]string{"app": ai.Name},
		},
	}

	if err := controllerutil.SetControllerReference(ai, svc, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on v2 Service: %w", err)
	}

	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Spec.Selector = map[string]string{"app": ai.Name, "component": component}
		svc.Spec.Ports = []corev1.ServicePort{
			{Name: "http", Port: 8000, TargetPort: intstr.FromInt(8000)},
			{Name: "metrics", Port: 8088, TargetPort: intstr.FromInt(8088)},
		}
		svc.Spec.Type = corev1.ServiceTypeClusterIP
		return nil
	}); err != nil {
		return fmt.Errorf("create/update v2 Service: %w", err)
	}
	return nil
}

// reconcileSAIAService ensures the public-facing Service routes to nginx.
func (r *SaiaReconciler) reconcileSAIAService(
	ctx context.Context,
	ai *aiv1.AIService,
) error {
	// Clean the ServiceTemplate to remove server-generated fields
	serviceTemplate := ai.Spec.ServiceTemplate.DeepCopy()
	cleanServiceTemplate(serviceTemplate)

	// Public service points to nginx (which routes to v1/v2 by path)
	nginxComponent := ai.Name + "-nginx"

	ports := []corev1.ServicePort{
		{Name: "http", Port: 8080, TargetPort: intstr.FromInt(8080)},
	}
	if ai.Spec.MTLS.Enabled && ai.Spec.MTLS.Termination == "operator" {
		ports = append(ports, corev1.ServicePort{
			Name: "https", Port: 8443, TargetPort: intstr.FromInt(8443),
		})
	}
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:        ai.Name + "-saia-service",
			Namespace:   ai.Namespace,
			Labels:      map[string]string{"app": ai.Name},
			Annotations: map[string]string{},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": ai.Name, "component": nginxComponent},
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
		svc.Spec.Selector = map[string]string{"app": ai.Name, "component": nginxComponent}
		svc.Spec.Ports = ports
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
