package slim

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"reflect"
	"sort"
	"strings"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/util/validation/field"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	cmmeta "github.com/cert-manager/cert-manager/pkg/apis/meta/v1"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	common "github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	"github.com/splunk/splunk-ai-operator/pkg/splunkutils"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

type SlimReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

func (r *SlimReconciler) Reconcile(ctx context.Context, aiservice *aiv1.AIService) (retErr error) {
	log := log.FromContext(ctx)

	before := aiservice.DeepCopy().Status
	var conditions []metav1.Condition
	var route runtimeRoute
	var routeErr error
	var trust issuerTrust
	var slimReady bool
	var rejectedTrust bool
	wasManaged := meta.FindStatusCondition(before.Conditions, agentRouteAvailable) != nil
	previousTrust := meta.FindStatusCondition(before.Conditions, "IssuerTrustReady")
	previouslyRejected := previousTrust != nil && previousTrust.Reason == issuerRejectedReason
	setCondition := func(condition metav1.Condition) {
		if prior := meta.FindStatusCondition(before.Conditions, condition.Type); prior != nil && prior.Status == condition.Status {
			condition.LastTransitionTime = prior.LastTransitionTime
		}
		conditions = append(conditions, condition)
	}
	defer func() {
		if condition := meta.FindStatusCondition(aiservice.Status.Conditions, agentRouteAvailable); condition != nil {
			conditions = append(conditions, *condition)
		}
		aiservice.Status.Conditions = conditions
		aiservice.Status.ObservedGeneration = aiservice.Generation
		if !equality.Semantic.DeepEqual(before, aiservice.Status) {
			retErr = errors.Join(retErr, r.Status().Update(ctx, aiservice))
		}
	}()

	stages := []struct {
		name string
		fn   func(context.Context, *aiv1.AIService) error
	}{
		{"IssuerTrust", func(ctx context.Context, ai *aiv1.AIService) error {
			// Check trust even if Runtime or Ray prerequisites are unavailable.
			route, routeErr = r.resolveRuntimeRoute(ctx, ai)
			var err error
			trust, err = r.validateIssuerTrust(ctx, ai, route.managed || wasManaged)
			if err != nil {
				rejectedTrust = true
				return errors.Join(err, r.suspendSlimServing(ctx, ai))
			}
			if trust.hash != "" || previouslyRejected {
				trust.needsDrain, err = r.prepareSlimIssuerTrust(ctx, ai, trust.hash, previouslyRejected)
				rejectedTrust = err != nil && trust.needsDrain
				return err
			}
			return nil
		}},
		{"Validate", r.validateAIService},
		{"AgentRouteConfig", func(ctx context.Context, ai *aiv1.AIService) error {
			if routeErr != nil {
				return routeErr
			}
			if route.platform == nil && before.FeatureStatus != nil && before.FeatureStatus.Slim != nil {
				// Keep the last working Deployment configuration when a Runtime
				// feature is removed. An empty origin prevents this SLIM image from starting.
				return errors.New("the published agent route no longer has a configured AgentRuntime")
			}
			if route.managed {
				if ai.Spec.AgentRuntimeUrl != "" && strings.TrimRight(ai.Spec.AgentRuntimeUrl, "/") != route.origin() {
					return errors.New("spec.agentRuntimeUrl must match the selected internal AgentRuntime Service origin")
				}
				if err := validateAITKOrigin(ai); err != nil {
					return err
				}
			}
			return nil
		}},
		{"ServiceAccount", r.reconcileServiceAccount},
		{"SlimConfigMap", r.reconcileSlimConfigMap},
		{"FeatureConfigMap", r.reconcileFeatureConfigMap},
		{"Certificate", r.reconcileCertificate},
		{"SlimDeployment", func(ctx context.Context, ai *aiv1.AIService) error {
			// Use the same dependency snapshot for the Deployment and status.
			origin := strings.TrimRight(ai.Spec.AgentRuntimeUrl, "/")
			if origin == "" {
				origin = route.origin()
			}
			var err error
			slimReady, err = r.reconcileSlimDeploymentWithRoute(ctx, ai, origin, trust, route.managed)
			return err
		}},
		{"SlimService", func(ctx context.Context, ai *aiv1.AIService) error {
			return r.reconcileSlimServiceWithAvailability(ctx, ai, (trust.hash == "" && !trust.needsDrain) || slimReady, trust.revisionLabel())
		}},
		{"SlimMetricsService", r.reconcileSlimMetricsService},
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
			if stage.name == "IssuerTrust" && rejectedTrust {
				cond.Reason = issuerRejectedReason
			}
			cond.Message = err.Error()
		}
		setCondition(cond)
		if err != nil {
			if route.managed || wasManaged {
				setAgentRouteCondition(aiservice, metav1.ConditionFalse, "ConfigurationUnavailable", "SLIM route configuration is unavailable; inspect SLIM reconciliation conditions")
			}
			log.Error(err, "stage failed", "stage", stage.name)
			return err
		}
	}

	setCondition(metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionTrue,
		Reason:             "AllReconciled",
		Message:            "all stages completed successfully",
		LastTransitionTime: metav1.Now(),
	})

	if route.managed {
		return r.reconcileAgentRouteStatus(ctx, aiservice, route, slimReady, trust.revisionLabel())
	}
	if wasManaged {
		setAgentRouteCondition(aiservice, metav1.ConditionFalse, "RuntimeUnavailable", "The platform no longer has a managed AgentRuntime route")
	}
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

	// cpuOnly does not depend on Ray readiness or require a platform URL.
	// Preserve an explicitly supplied URL regardless of the profile.
	cpuOnly := false
	if ai.Spec.AIPlatformRef.Name != "" {
		aiPlatform, err := r.getAIPlatform(ctx, ai.Spec.AIPlatformRef)
		if err != nil {
			r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "fetching AIPlatform failed")
			return fmt.Errorf("fetching AIPlatform: %w", err)
		}
		cpuOnly = aiPlatform.Spec.ResolvedProfile() == aiv1.AIPlatformProfileCPUOnly
		if !cpuOnly {
			if err := r.validateAIPlatformReady(ctx, aiPlatform); err != nil {
				return fmt.Errorf("AIPlatform infrastructure not ready: %w", err)
			}
		}

		clusterDomain := ai.Spec.ClusterDomain
		if clusterDomain == "" {
			clusterDomain = "cluster.local"
		}
		if !cpuOnly && ai.Spec.AIPlatformUrl == "" {
			scheme := ai.Spec.AIPlatformScheme
			if scheme == "" {
				scheme = "http"
			}
			ai.Spec.AIPlatformUrl = fmt.Sprintf("%s://%s.%s.svc.%s:8000",
				scheme, aiPlatform.Status.RayServiceName, ai.Spec.AIPlatformRef.Namespace, clusterDomain)
		}
	}

	if cpuOnly {
		// cpuOnly SLIM exists to route to the AgentRuntime, so it must resolve one.
		// The URL is spec.agentRuntimeUrl when set, otherwise it is derived from the
		// platform's single agentruntime feature, the same as for every profile.
		url, err := r.agentRuntimeURL(ctx, ai)
		if err != nil {
			r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", err.Error())
			return err
		}
		if url == "" {
			r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "AI_TIER_AGENT_RUNTIME_URL cannot be resolved")
			return fmt.Errorf("profile cpuOnly routes SLIM to AgentRuntime but no agentruntime URL can be resolved: set spec.agentRuntimeUrl or add an agentruntime feature to the AIPlatform")
		}
	} else if ai.Spec.AIPlatformUrl == "" {
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

	// No negative quantities and requests within limits for every profile. Under
	// cpuOnly SLIM is a CPU workload on a cluster with no GPU use, so an
	// accelerator resource is refused there; on other platforms SLIM is an
	// existing component and its resources are left as the administrator set them.
	if errs := aiv1.ValidateWorkloadResources(field.NewPath("spec").Child("resources"), ai.Spec.Resources, false, cpuOnly); len(errs) > 0 {
		err := errs.ToAggregate()
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", err.Error())
		return fmt.Errorf("invalid slim resources: %w", err)
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

// agentRuntimeURL also resolves the runtime for fullfeature: the platform
// controller populates AgentRuntimeUrl for cpuOnly, while both profiles need
// the runtime endpoint when the agentruntime feature is present.
func (r *SlimReconciler) agentRuntimeURL(ctx context.Context, ai *aiv1.AIService) (string, error) {
	if ai.Spec.AgentRuntimeUrl != "" {
		return strings.TrimRight(ai.Spec.AgentRuntimeUrl, "/"), nil
	}
	route, err := r.resolveRuntimeRoute(ctx, ai)
	if err != nil {
		return "", err
	}
	return route.origin(), nil
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

		// Resolve the default name in memory only. Do not persist it back onto
		// ai.Spec: AIPlatform's ReconcileFeatures rebuilds this AIService's spec
		// from AIPlatform.Spec.Features[].ServiceAccountName on every reconcile,
		// so persisting a generated name here just gets it wiped back to "" on
		// the next AIPlatform pass, which re-triggers this branch — an
		// unbounded generation-bump loop between the two controllers.
		ai.Spec.ServiceAccountName = ai.Name + "-sa"
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

// buildSplunkIssuersVal computes the comma-separated SPLUNK_ISSUERS value from the AIService spec.
// The JWT issuer is the Splunk management endpoint (port 8089).
// Priority: CRRef-derived service FQDN → explicit Endpoint → TrustedIssuers only.
//
// This mirrors saia.buildSplunkIssuersVal; slim keeps its own copy so the two
// feature packages stay decoupled.
func buildSplunkIssuersVal(ai *aiv1.AIService) string {
	var issuers []string
	sc := ai.Spec.SplunkConfiguration
	switch {
	case sc.SplunkCustomResourceRef.Name != "":
		kind := sc.SplunkCustomResourceRef.Kind
		if kind == "" {
			kind = "Standalone"
		}
		instanceType := "standalone"
		if kind == "IndexerCluster" {
			instanceType = "indexer"
		}
		refNS := sc.SplunkCustomResourceRef.Namespace
		if refNS == "" {
			refNS = ai.Namespace
		}
		clusterDomain := ai.Spec.ClusterDomain
		if clusterDomain == "" {
			clusterDomain = "cluster.local"
		}
		svc := fmt.Sprintf("splunk-%s-%s-service.%s.svc.%s", sc.SplunkCustomResourceRef.Name, instanceType, refNS, clusterDomain)
		issuers = append(issuers, fmt.Sprintf("https://%s:%d", svc, splunkutils.SplunkMgmtPort))
	case sc.Endpoint != "":
		issuers = append(issuers, sc.Endpoint)
	}
	issuers = append(issuers, sc.TrustedIssuers...)
	return strings.Join(issuers, ",")
}

// reconcileSlimConfigMap manages the ConfigMap holding the slim-api boot
// configuration. The keys mirror the AITIER-mode env vars from the slim-api
// repo's `run-slim-aipod` Makefile target, trimmed to only those the service
// actually reads in an in-cluster (non-SCS) deployment:
//
//   - DEPLOYMENT_TYPE=AITIER bypasses Vault/Consul/SCS auth in the entrypoint
//     and flips the app to CMP (interactive-token) authorization.
//   - SPLUNK_ISSUERS is the JWT issuer whitelist used by CMP auth; it is derived
//     from the AIService spec (CRRef → endpoint → trustedIssuers), matching saia.
//   - SERVICE_NAME / SERVICE_INTERNAL_NAME identify the service.
//
// PLATFORM_URL is injected on the Deployment (not here) because it is derived
// per-AIService from the AIPlatform Ray endpoint.
func (r *SlimReconciler) reconcileSlimConfigMap(ctx context.Context, ai *aiv1.AIService) error {
	cmName := fmt.Sprintf("%s-slim-config", ai.Name)

	splunkIssuersVal := buildSplunkIssuersVal(ai)

	defaults := map[string]string{
		"DEPLOYMENT_TYPE":       "AITIER",
		"SERVICE_NAME":          "slim-api",
		"SERVICE_INTERNAL_NAME": "SLIM",
		"SPLUNK_ISSUERS":        splunkIssuersVal,
		"ENABLE_AUTHZ":          "false",
		"API_VERSION":           "v1alpha1",
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
	// Merge defaults: SPLUNK_ISSUERS is always recomputed from spec so that
	// removing or changing a CRRef/endpoint/trustedIssuers is reflected immediately
	// (including clearing to empty when Splunk is disabled).
	// All other keys use fill-if-missing to preserve manual overrides.
	needsUpdate := false
	for k, v := range defaults {
		if k == "SPLUNK_ISSUERS" {
			if found.Data[k] != v {
				found.Data[k] = v
				needsUpdate = true
			}
			continue
		}
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
		desired := certmanagerv1.CertificateSpec{
			SecretName: ai.Spec.MTLS.SecretName,
			IssuerRef:  ai.Spec.MTLS.IssuerRef,
			DNSNames:   ai.Spec.MTLS.DNSNames,
			Usages: []certmanagerv1.KeyUsage{
				certmanagerv1.UsageServerAuth,
				certmanagerv1.UsageClientAuth,
			},
		}
		common.PreserveCertificateIssuerDefaults(&desired, &cert.Spec)
		cert.Spec = desired
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
	origin, err := r.agentRuntimeURL(ctx, ai)
	if err != nil {
		return err
	}
	trust, err := r.validateIssuerTrust(ctx, ai, false)
	if err != nil {
		return err
	}
	_, err = r.reconcileSlimDeploymentWithRoute(ctx, ai, origin, trust, false)
	return err
}

func (r *SlimReconciler) reconcileSlimDeploymentWithRoute(ctx context.Context, ai *aiv1.AIService, agentRuntimeURL string, trust issuerTrust, managed bool) (bool, error) {
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

	// slim-api (AITIER) expects PLATFORM_URL to be a fully-qualified URL
	// pointing at the Ray head's serve root. Each model is mounted at its own
	// top-level route prefix (e.g. /gemma4_31b_it), so slim-api builds
	// {PLATFORM_URL}/{model}/... directly. The Entrypoint catch-all app
	// (.../ai-platform-models/v1) requires a leading {tenant} segment and does
	// not serve model traffic, so the suffix must NOT be present here.
	platformURL := strings.TrimRight(ai.Spec.AIPlatformUrl, "/")
	platformURL = strings.TrimSuffix(platformURL, "/ai-platform-models/v1")
	env := []corev1.EnvVar{
		{Name: "PLATFORM_URL", Value: platformURL},
		{Name: "AI_TIER_AGENT_RUNTIME_URL", Value: agentRuntimeURL},
	}
	if managed {
		// CMP token verification and the candidate's route prefix require these
		// settings even when the inherited ConfigMap contains manual overrides.
		env = append(env,
			corev1.EnvVar{Name: "DEPLOYMENT_TYPE", Value: "AITIER"},
			corev1.EnvVar{Name: "API_VERSION", Value: "v1alpha1"},
			corev1.EnvVar{Name: "SPLUNK_ISSUERS", Value: buildSplunkIssuersVal(ai)},
		)
	}
	volumes, mounts, env = appendIssuerTrust(ai.Spec.SplunkConfiguration.CACertRef, trust.hostOverride, volumes, mounts, env)

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
			Name:      slimDeploymentName(ai.Name),
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

	// The issuers hash rolls the pods whenever the derived SPLUNK_ISSUERS value
	// changes, so CMP auth picks up spec-driven issuer changes (matches saia).
	issuersVal := buildSplunkIssuersVal(ai)
	issuersChecksum := fmt.Sprintf("%x", sha256.Sum256([]byte(issuersVal)))
	annotations := map[string]string{
		"prometheus.io/port":                     "8088",
		"prometheus.io/path":                     "/metrics",
		"prometheus.io/scheme":                   "http",
		"splunk-ai-operator/splunk-issuers-hash": issuersChecksum,
	}
	for k, v := range common.FilterPropagatedAnnotations(ai.Annotations) {
		annotations[k] = v
	}
	delete(annotations, issuerTrustHashAnnotation)
	if trust.hash != "" {
		annotations[issuerTrustHashAnnotation] = trust.hash
	}

	containers := []corev1.Container{{
		Name:            ai.Name,
		Image:           os.Getenv("RELATED_IMAGE_SLIM_API"),
		ImagePullPolicy: corev1.PullIfNotPresent,
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

	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, deployment, func() error {
		if deployment.ResourceVersion != "" {
			if !metav1.IsControlledBy(deployment, ai) {
				return errors.New("SLIM Deployment is not controlled by this AIService")
			}
			stopped := deployment.Spec.Replicas != nil && *deployment.Spec.Replicas == 0
			if trust.needsDrain && !stopped {
				// The Service can record a rejection even if the first scale-down failed.
				zero := int32(0)
				deployment.Spec.Replicas = &zero
				return nil
			}
			if stopped {
				drained, err := r.slimWorkloadDrained(ctx, ai, deployment)
				if err != nil || !drained {
					return err
				}
			}
		}
		if trust.needsDrain {
			// Keep the Service blocked until the replacement rollout finishes.
			if err := r.blockSlimService(ctx, ai, slimRolloutBlocked); err != nil {
				return err
			}
		}
		if err := controllerutil.SetControllerReference(ai, deployment, r.Scheme); err != nil {
			return err
		}
		deployment.ObjectMeta.Labels = labels
		deployment.ObjectMeta.Annotations = common.PreserveDeploymentRevision(deployment, annotations)
		deployment.Spec.Replicas = &ai.Spec.Replicas

		if deployment.Spec.Selector == nil {
			deployment.Spec.Selector = &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": ai.Name, "component": ai.Name},
			}
		}

		template := corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{
				Labels:      slimServiceSelector(ai, "", trust.revisionLabel()),
				Annotations: annotations,
			},
			Spec: corev1.PodSpec{
				ServiceAccountName: ai.Spec.ServiceAccountName,
				Containers:         containers,
				Volumes:            volumes,
				// NodeSelector was never copied here, so a selector on the AIService was
				// silently dropped and SLIM could land on any node. A platform sets none
				// for fullfeature, so the default Deployment is unchanged.
				NodeSelector:     ai.Spec.NodeSelector,
				Affinity:         &ai.Spec.Affinity,
				Tolerations:      ai.Spec.Tolerations,
				ImagePullSecrets: ai.Spec.ImagePullSecrets,
			},
		}
		common.PreservePodTemplateDefaults(&template, &deployment.Spec.Template)
		deployment.Spec.Template = template
		return nil
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update Deployment failed")
		return false, fmt.Errorf("create/update Deployment: %w", err)
	}
	return slimRolloutReady(ai, deployment), nil
}

// reconcileSlimService ensures the public-facing Service, which may be exposed via
// NodePort/LoadBalancer per ServiceTemplate. It intentionally excludes the metrics
// port so that enabling public exposure never publishes /metrics or consumes an
// extra NodePort; metrics are served by reconcileSlimMetricsService instead.
func (r *SlimReconciler) reconcileSlimService(ctx context.Context, ai *aiv1.AIService) error {
	return r.reconcileSlimServiceWithAvailability(ctx, ai, true, "")
}

func (r *SlimReconciler) reconcileSlimServiceWithAvailability(ctx context.Context, ai *aiv1.AIService, serving bool, trustRevision string) error {
	serviceTemplate := ai.Spec.ServiceTemplate.DeepCopy()
	cleanServiceTemplate(serviceTemplate)

	ports := []corev1.ServicePort{
		{Name: "http", Port: 8080, TargetPort: intstr.FromInt(8080), Protocol: corev1.ProtocolTCP},
	}
	if ai.Spec.MTLS.Enabled && ai.Spec.MTLS.Termination == "operator" {
		ports = append(ports, corev1.ServicePort{
			Name: "https", Port: 8443, TargetPort: intstr.FromInt(8443), Protocol: corev1.ProtocolTCP,
		})
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

	labels := map[string]string{"app": ai.Name}
	for k, v := range ai.Labels {
		labels[k] = v
	}
	annotations := common.FilterPropagatedAnnotations(ai.Annotations)

	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      slimServiceName(ai.Name),
			Namespace: ai.Namespace,
		},
	}
	// Type, Ports, and Selector are all set inside the mutate callback because
	// CreateOrUpdate reloads the live Service from the cluster before invoking it,
	// so any values set on svc beforehand are discarded on updates.
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		if err := common.EnsureServiceControllerReference(r.Scheme, ai, svc); err != nil {
			return err
		}
		svc.ObjectMeta.Labels = labels
		svc.ObjectMeta.Annotations = annotations
		var blocked string
		if !serving {
			blocked = slimRolloutBlocked
			if svc.Spec.Selector[slimRouteDisabledLabel] == slimIssuerRejected {
				blocked = slimIssuerRejected
			}
		}
		svc.Spec.Selector = slimServiceSelector(ai, blocked, trustRevision)
		svc.Spec.PublishNotReadyAddresses = false
		common.PreserveAllocatedNodePorts(svcType, ports, svc.Spec.Ports)
		svc.Spec.Ports = ports
		svc.Spec.Type = svcType
		return nil
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update Service failed")
		return fmt.Errorf("create/update Service: %w", err)
	}
	return nil
}

// reconcileSlimMetricsService creates an internal ClusterIP-only Service carrying the
// metrics port, kept separate from the public Service so that NodePort/LoadBalancer
// exposure never publishes /metrics. It carries the "component" label so the
// ServiceMonitor's selector (app+component) matches it.
func (r *SlimReconciler) reconcileSlimMetricsService(ctx context.Context, ai *aiv1.AIService) error {
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-slim-metrics-service",
			Namespace: ai.Namespace,
		},
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		if err := common.EnsureServiceControllerReference(r.Scheme, ai, svc); err != nil {
			return err
		}
		svc.ObjectMeta.Labels = map[string]string{"app": ai.Name, "component": ai.Name}
		svc.Spec.Selector = map[string]string{"app": ai.Name, "component": ai.Name}
		svc.Spec.Ports = []corev1.ServicePort{
			{Name: "metrics", Port: 8088, TargetPort: intstr.FromInt(8088), Protocol: corev1.ProtocolTCP},
		}
		svc.Spec.Type = corev1.ServiceTypeClusterIP
		return nil
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update metrics Service failed")
		return fmt.Errorf("create/update metrics Service: %w", err)
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
