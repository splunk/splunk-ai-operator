package agentruntime

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"os"
	"regexp"
	"sort"
	"strings"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	cmmeta "github.com/cert-manager/cert-manager/pkg/apis/meta/v1"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/credentials"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/util/validation/field"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

const (
	defaultAgentRuntimeHTTPPort  int32 = 8080
	defaultAgentRuntimeMetrics   int32 = 9090
	maxDNSLabelLength                  = 63
	mtlsTerminationOperator            = "operator"
	sharedPackagesPath                 = "/shared-packages"
	schemaSetupImageEnv                = "RELATED_IMAGE_AGENT_RUNTIME_SCHEMA_SETUP"
	schemaJobInputHashAnnotation       = "ai.splunk.com/agentruntime-schema-input-hash"
	schemaJobManagedAnnotation         = "ai.splunk.com/agentruntime-schema-job"
	schemaJobManagedValue              = "true"
	schemaJobBackoffLimit        int32 = 1
	schemaJobDeadlineSeconds     int64 = 300
	schemaJobTTLSeconds          int32 = 86400
)

const schemaSetupCommand = `set -eu
export PGCONNECT_TIMEOUT=5
wait_for_postgres() {
  attempt=0
  delay=1
  until pg_isready -t 2 "$@" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 12 ]; then
      echo 'postgres unavailable after bounded wait' >&2
      return 1
    fi
    sleep "$delay"
    if [ "$delay" -lt 8 ]; then delay=$((delay * 2)); fi
  done
}
# libpq rejects an exported but empty PGSSLMODE with "no attempt". Leave it
# unset unless one of the supported settings actually supplies a value.
if [ -n "${PGSSLMODE:-}" ]; then
  export PGSSLMODE
elif [ -n "${PG_SSLMODE:-}" ]; then
  export PGSSLMODE="$PG_SSLMODE"
else
  unset PGSSLMODE
fi

if [ -n "${PG_HOST:-}" ] && [ -n "${PG_USER:-}" ] && [ -n "${PG_DBNAME:-}" ] && [ -n "${PG_PASSWORD:-}" ]; then
  wait_for_postgres -h "$PG_HOST" -p "${PG_PORT:-5432}" -U "$PG_USER" -d "$PG_DBNAME"
  PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "${PG_PORT:-5432}" -U "$PG_USER" -d "$PG_DBNAME" -v ON_ERROR_STOP=1 -f /schema.sql
elif [ -n "${DATABASE_URL:-}" ]; then
  wait_for_postgres -d "$DATABASE_URL"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f /schema.sql
else
  echo 'schema setup requires either PG_HOST/PG_USER/PG_DBNAME/PG_PASSWORD or DATABASE_URL' >&2
  exit 1
fi

echo 'Schema setup complete.'`

var agentModulePattern = regexp.MustCompile(
	`^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*:` +
		`[A-Za-z_][A-Za-z0-9_]*$`,
)

type agentRuntimeConfig struct {
	BaseImage     string
	ProviderImage string
	AgentModule   string
}

type AgentRuntimeReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

type schemaStageError struct{ reason, message string }

func (e *schemaStageError) Error() string { return e.message }

func schemaState(reason, message string) error { return &schemaStageError{reason, message} }

func ensureAgentRuntimeSchemaStatus(ai *aiv1.AIService) *aiv1.AgentRuntimeSchemaStatus {
	if ai.Status.FeatureStatus == nil {
		ai.Status.FeatureStatus = &aiv1.AIServiceFeatureStatus{}
	}
	if ai.Status.FeatureStatus.AgentRuntime == nil {
		ai.Status.FeatureStatus.AgentRuntime = &aiv1.AgentRuntimeStatus{}
	}
	if ai.Status.FeatureStatus.AgentRuntime.Schema == nil {
		ai.Status.FeatureStatus.AgentRuntime.Schema = &aiv1.AgentRuntimeSchemaStatus{}
	}
	return ai.Status.FeatureStatus.AgentRuntime.Schema
}

func (r *AgentRuntimeReconciler) Reconcile(ctx context.Context, aiservice *aiv1.AIService) (retErr error) {
	previousStatus := aiservice.DeepCopy().Status
	// Persist progress on early returns as well as success. Joining errors keeps
	// a failed status write visible without hiding the original stage failure.
	defer func() {
		aiservice.Status.ObservedGeneration = aiservice.Generation
		if !equality.Semantic.DeepEqual(previousStatus, aiservice.Status) {
			// Update retains the resourceVersion precondition: an observation of an
			// older generation must not be rebased onto a concurrently changed spec.
			retErr = errors.Join(retErr, safeRuntimeError(r.Status().Update(ctx, aiservice), "cannot persist runtime status; check API availability and operator permissions"))
		}
	}()

	stages := []struct {
		name string
		fn   func(context.Context, *aiv1.AIService) error
	}{
		{"AgentRuntimeNetworkPolicy", r.reconcileNetworkPolicies},
		{"Validate", r.validateAIService},
		{"ServiceAccount", r.reconcileServiceAccount},
		{"AgentRuntimeConfigMap", r.reconcileConfigMap},
		{"Certificate", r.reconcileCertificate},
		{"PostgresSchemaSetup", r.reconcilePostgresSchemaSetup},
		{"AgentRuntimeDeployment", r.reconcileDeployment},
		{"AgentRuntimeDisruptionBudget", r.reconcileDisruptionBudget},
		{"AgentRuntimeService", r.reconcileService},
		{"AgentRuntimeHPA", r.reconcileHPA},
		{"ServiceMonitor", r.reconcileServiceMonitor},
	}

	for index, stage := range stages {
		err := stage.fn(ctx, aiservice)
		if err != nil {
			reason, message := "ReconcileFailed", stage.name+" reconciliation failed; check configuration, operator permissions and events"
			var schemaErr *schemaStageError
			var conflict *common.OwnershipConflictError
			if errors.As(err, &schemaErr) {
				reason, message = schemaErr.reason, schemaErr.message
			} else if errors.As(err, &conflict) {
				// Names only (kind, namespace, name): never object content.
				reason, message = "OwnershipConflict", conflict.Error()
				r.Recorder.Event(aiservice, corev1.EventTypeWarning, "OwnershipConflict", message)
			}
			if stage.name == "PostgresSchemaSetup" && reason == "Pending" {
				// Keep the last terminal outcome useful during a retry without
				// presenting it as the outcome of the new schema attempt.
				if old := meta.FindStatusCondition(aiservice.Status.Conditions, schemaReady); old != nil {
					if old.Reason == "Failed" || old.Reason == "TimedOut" {
						message += "; previous outcome: " + old.Reason
					} else if _, prior, ok := strings.Cut(old.Message, "; previous outcome: "); ok && (prior == "Failed" || prior == "TimedOut") {
						message += "; previous outcome: " + prior
					}
				}
			}
			setRuntimeCondition(aiservice, stage.name+"Ready", metav1.ConditionFalse, reason, message)
			// Later gates were not evaluated for these inputs. Clear their apparent
			// success while retaining bounded context about prior failures.
			for _, later := range stages[index+1:] {
				blockRuntimeCondition(aiservice, later.name+"Ready", stage.name)
			}
			blockRuntimeCondition(aiservice, endpointReady, stage.name)
			setRuntimeCondition(aiservice, "Ready", metav1.ConditionFalse, reason, message)
			return safeRuntimeError(err, message)
		}
		// These gates are evaluated from observed health after both objects exist.
		if stage.name == "AgentRuntimeDeployment" || stage.name == "AgentRuntimeService" {
			continue
		}
		reason, message := "Reconciled", "stage succeeded"
		if stage.name == "PostgresSchemaSetup" {
			reason, message = "Succeeded", "schema setup completed for the current inputs"
		}
		setRuntimeCondition(aiservice, stage.name+"Ready", metav1.ConditionTrue, reason, message)
	}
	return safeRuntimeError(r.observeReadiness(ctx, aiservice), "cannot observe runtime readiness; check API availability and operator permissions")
}

func (r *AgentRuntimeReconciler) validateAIService(ctx context.Context, ai *aiv1.AIService) error {
	policy := aiv1.ResolveAgentRuntimeAutoscaling(ai.Spec.MinReplicas, ai.Spec.MaxReplicas, ai.Spec.TargetCPUUtilization)
	if errs := policy.Validate(field.NewPath("spec")); len(errs) != 0 {
		return schemaState("InvalidConfiguration", errs.ToAggregate().Error())
	}

	// Validate old objects as well as webhook-admitted ones. Explicit env values
	// override envFrom, even when empty, so connection keys must be Secret-only.
	for _, input := range []struct {
		values map[string]string
		path   *field.Path
	}{
		{ai.Spec.Feature.Env, field.NewPath("spec", "features", "env")},
		{ai.Spec.Env, field.NewPath("spec", "env")},
	} {
		if errs := credentials.ValidatePostgresEnvironment(input.values, input.path); len(errs) != 0 {
			return schemaState("InvalidCheckpointEnvironment", errs.ToAggregate().Error())
		}
	}
	if ai.Spec.Feature.Provider == "" {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "provider must be set for agentruntime")
		return fmt.Errorf("provider must be set for agentruntime")
	}
	if _, err := resolveAgentRuntimeConfig(ai); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", err.Error())
		return schemaState("InvalidConfiguration", err.Error())
	}
	if _, err := resolveSchemaSetupImage(); err != nil {
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

	// cpuOnly has no Ray platform and no vector database: the runtime reaches its
	// LLM and MCP endpoints directly, so it must not wait for, or require a URL
	// to, a model-serving platform that does not exist.
	cpuOnly := false
	if ai.Spec.AIPlatformRef.Name != "" {
		aiPlatform, err := r.getAIPlatform(ctx, ai.Spec.AIPlatformRef)
		if err != nil {
			r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "fetching AIPlatform failed")
			return fmt.Errorf("fetching AIPlatform: %w", err)
		}
		cpuOnly = aiPlatform.Spec.ResolvedProfile() == aiv1.AIPlatformProfileCPUOnly
		if !cpuOnly {
			if err := r.validateAIPlatformReady(aiPlatform); err != nil {
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
		if ai.Spec.VectorDbUrl == "" && aiPlatform.Status.VectorDbServiceName != "" {
			ai.Spec.VectorDbUrl = fmt.Sprintf("%s.%s.svc.%s",
				aiPlatform.Status.VectorDbServiceName, ai.Spec.AIPlatformRef.Namespace, clusterDomain)
		}
	}

	if !cpuOnly && ai.Spec.AIPlatformUrl == "" {
		return fmt.Errorf("AIPlatformUrl must be set")
	}

	defaultAgentRuntimeSpec(ai)

	// The runtime runs on CPU nodes under every profile: it needs positive CPU,
	// memory and ephemeral-storage budgets, requests within limits, and no GPU.
	// Checked after defaulting so a request above a defaulted limit is reported
	// here, with the field, instead of as a rejected Deployment.
	if errs := aiv1.ValidateWorkloadResources(field.NewPath("spec").Child("resources"), ai.Spec.Resources, true, true); len(errs) > 0 {
		err := errs.ToAggregate()
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", err.Error())
		return fmt.Errorf("invalid agentruntime resources: %w", err)
	}
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
	if ai.Spec.ServiceAccountName == "" {
		ai.Spec.ServiceAccountName = ai.Name + "-sa"
	}
	completeResourceBudgets(&ai.Spec.Resources)
}

// DefaultResources is the compute budget of the AgentRuntime container when the
// AIService does not set one. It is the single definition: the platform
// controller seeds new AIServices with it and the handler completes any budget
// left out. Every profile uses it, because the runtime always runs on CPU nodes.
func DefaultResources() corev1.ResourceRequirements {
	return corev1.ResourceRequirements{
		Requests: corev1.ResourceList{
			corev1.ResourceCPU:              resource.MustParse("500m"),
			corev1.ResourceMemory:           resource.MustParse("512Mi"),
			corev1.ResourceEphemeralStorage: resource.MustParse("1Gi"),
		},
		Limits: corev1.ResourceList{
			corev1.ResourceCPU:              resource.MustParse("1"),
			corev1.ResourceMemory:           resource.MustParse("1Gi"),
			corev1.ResourceEphemeralStorage: resource.MustParse("2Gi"),
		},
	}
}

// completeResourceBudgets makes sure the container carries an explicit cpu,
// memory and ephemeral-storage limit, without changing anything that already
// worked.
//
//   - Requests are defaulted only when the whole map is unset, exactly as before.
//     A request left out of a map the user set is not invented: Kubernetes then
//     defaults it to the limit.
//   - A missing limit is the larger of the default and the request for that
//     resource, so a default can never fall below something the user asked for.
//     (Taking the default alone would turn requests.cpu: 2 with no limit into an
//     inverted 2 > 1.)
//
// Values the user set are never changed, and an input with both maps unset ends
// up exactly as DefaultResources.
func completeResourceBudgets(r *corev1.ResourceRequirements) {
	def := DefaultResources()
	if r.Requests == nil {
		r.Requests = def.Requests
	}
	if r.Limits == nil {
		r.Limits = corev1.ResourceList{}
	}
	for _, name := range []corev1.ResourceName{corev1.ResourceCPU, corev1.ResourceMemory, corev1.ResourceEphemeralStorage} {
		if _, ok := r.Limits[name]; ok {
			continue
		}
		limit := def.Limits[name]
		if req, ok := r.Requests[name]; ok && req.Cmp(limit) > 0 {
			limit = req.DeepCopy()
		}
		r.Limits[name] = limit
	}
}

// reconcileServiceAccount creates the runtime's ServiceAccount. The default name,
// <AIService>-sa, is the operator's (the AIPlatform also fills it in): a same-named
// object it does not own is an ownership conflict. Any other name is one the user
// chose, so the ServiceAccount is the customer's and is never owned: it is used if
// it exists, and created without an owner reference if not (MPR-202).
func (r *AgentRuntimeReconciler) reconcileServiceAccount(ctx context.Context, ai *aiv1.AIService) error {
	defaultName := ai.Name + "-sa"
	serviceAccountName := ai.Spec.ServiceAccountName
	if serviceAccountName == "" {
		serviceAccountName = defaultName
	}

	if _, err := common.ReconcileServiceAccount(ctx, r.Client, r.Scheme, ai, common.ServiceAccountOptions{
		Name:            serviceAccountName,
		RefuseUnowned:   true,
		CustomerManaged: serviceAccountName != defaultName,
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update ServiceAccount failed")
		return fmt.Errorf("create/update ServiceAccount: %w", err)
	}
	return nil
}

func (r *AgentRuntimeReconciler) reconcileConfigMap(ctx context.Context, ai *aiv1.AIService) error {
	config, err := resolveAgentRuntimeConfig(ai)
	if err != nil {
		return err
	}

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-agentruntime-config",
			Namespace: ai.Namespace,
		},
	}
	_, err = controllerutil.CreateOrUpdate(ctx, r.Client, cm, func() error {
		if err := common.ClaimOrRefuse(ai, cm, r.Scheme); err != nil {
			return err
		}
		cm.Data = map[string]string{
			"provider":       ai.Spec.Feature.Provider,
			"featureVersion": ai.Spec.Version,
			"runtimeVersion": ai.Spec.RuntimeVersion,
			"agentModule":    config.AgentModule,
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
	certificateName := ai.Name + "-agentruntime-cert"

	_, _, err := common.ReconcileCertificate(ctx, r.Client, r.Scheme, ai, common.CertificateOptions{
		Name:          certificateName,
		RefuseUnowned: true,
		Spec: certmanagerv1.CertificateSpec{
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
		},
	})
	if err != nil {
		return err
	}
	if ai.Spec.MTLS.SecretName != "" {
		// A Secret the user named stays theirs: it is not removed with the AIService.
		// If it is one the operator claimed under its generated name before the user
		// named it, the claim is released.
		return r.releaseNamedSecret(ctx, ai, secretName)
	}
	return r.ownIssuedSecret(ctx, ai, secretName, certificateName)
}

// releaseNamedSecret removes this AIService's owner reference (matched by UID) from a
// Secret the user names in mtls.secretName, keeping any other owner reference, so the
// Secret survives the AIService (MPR-202).
func (r *AgentRuntimeReconciler) releaseNamedSecret(ctx context.Context, ai *aiv1.AIService, secretName string) error {
	secret := &corev1.Secret{}
	if err := r.Get(ctx, types.NamespacedName{Namespace: ai.Namespace, Name: secretName}, secret); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return fmt.Errorf("get named TLS Secret: %w", err)
	}
	refs := secret.GetOwnerReferences()
	kept := refs[:0:0]
	for _, ref := range refs {
		if ref.UID != ai.UID {
			kept = append(kept, ref)
		}
	}
	if len(kept) == len(refs) {
		return nil
	}
	patch := client.MergeFromWithOptions(secret.DeepCopy(), client.MergeFromWithOptimisticLock{})
	secret.SetOwnerReferences(kept)
	if err := r.Patch(ctx, secret, patch); err != nil {
		return fmt.Errorf("release named TLS Secret: %w", err)
	}
	return nil
}

// certManagerCertificateNameAnnotation is set by cert-manager on the Secret it issues
// for a Certificate.
const certManagerCertificateNameAnnotation = "cert-manager.io/certificate-name"

// ownIssuedSecret makes the TLS Secret cert-manager issued for the runtime's
// Certificate, under the operator-generated name, removable with the AIService
// (MPR-202). cert-manager creates it without an owner by default, so it would
// otherwise outlive the AIService. It is claimed only when cert-manager wrote it for
// this Certificate, and with a non-controller reference: cert-manager may itself be
// configured to make the Certificate its controller. The Secret appears only after
// issuance, so a later pass claims it.
func (r *AgentRuntimeReconciler) ownIssuedSecret(ctx context.Context, ai *aiv1.AIService, secretName, certificateName string) error {
	secret := &corev1.Secret{}
	if err := r.Get(ctx, types.NamespacedName{Namespace: ai.Namespace, Name: secretName}, secret); err != nil {
		if apierrors.IsNotFound(err) {
			return nil // not issued yet
		}
		return fmt.Errorf("get issued TLS Secret: %w", err)
	}
	if secret.Annotations[certManagerCertificateNameAnnotation] != certificateName {
		return nil // not written for this Certificate: not ours to remove
	}
	for _, ref := range secret.OwnerReferences {
		if ref.UID == ai.UID {
			return nil
		}
	}
	patch := client.MergeFromWithOptions(secret.DeepCopy(), client.MergeFromWithOptimisticLock{})
	if err := controllerutil.SetOwnerReference(ai, secret, r.Scheme); err != nil {
		return fmt.Errorf("owner reference on issued TLS Secret: %w", err)
	}
	if err := r.Patch(ctx, secret, patch); err != nil {
		return fmt.Errorf("claim issued TLS Secret: %w", err)
	}
	return nil
}

func (r *AgentRuntimeReconciler) reconcilePostgresSchemaSetup(ctx context.Context, ai *aiv1.AIService) error {
	schemaImage, err := resolveSchemaSetupImage()
	if err != nil {
		return err
	}

	checkpointSecret := &corev1.Secret{}
	if err := r.Get(ctx, types.NamespacedName{
		Name:      ai.Spec.CheckpointDbSecretRef,
		Namespace: ai.Namespace,
	}, checkpointSecret); err != nil {
		if apierrors.IsNotFound(err) {
			return schemaState("CheckpointSecretMissing", "checkpoint DB Secret is missing in the AIService namespace")
		}
		return safeRuntimeError(err, "cannot read checkpoint DB Secret; check operator permissions and API availability")
	}
	if err := validateSchemaSetupCredentials(checkpointSecret, ai.Spec.Feature.Env); err != nil {
		return schemaState("InvalidCheckpointSecret", err.Error())
	}
	state := ensureAgentRuntimeSchemaStatus(ai)

	inputHash := agentRuntimeSchemaInputHash(ai, schemaImage, checkpointSecret)
	jobName := dnsLabelName(ai.Name, "schema-"+inputHash)
	// An old Job must be fully removed, including its Pod, before a changed
	// input or explicit retry can start applying SQL to this service's database.
	var jobs batchv1.JobList
	if err := r.List(ctx, &jobs, client.InNamespace(ai.Namespace)); err != nil {
		return fmt.Errorf("list postgres schema setup Jobs: %w", err)
	}
	for i := range jobs.Items {
		old := &jobs.Items[i]
		if !metav1.IsControlledBy(old, ai) || old.Annotations[schemaJobManagedAnnotation] != schemaJobManagedValue {
			continue
		}
		if old.Name != jobName && (old.Status.Active > 0 || (!schemaJobSucceeded(old) && !schemaJobFailed(old))) {
			if old.DeletionTimestamp == nil {
				if err := r.Delete(ctx, old, client.PropagationPolicy(metav1.DeletePropagationForeground)); err != nil && !apierrors.IsNotFound(err) {
					return fmt.Errorf("stop superseded schema Job: %w", err)
				}
			}
			return schemaState("Superseded", "waiting for the previous schema Job to stop")
		}
	}
	job := &batchv1.Job{}
	err = r.Get(ctx, types.NamespacedName{Name: jobName, Namespace: ai.Namespace}, job)
	if err == nil {
		if !metav1.IsControlledBy(job, ai) || job.Annotations[schemaJobManagedAnnotation] != schemaJobManagedValue {
			// Another object holds the name: never adopted, rewritten or deleted (MPR-202).
			return &common.OwnershipConflictError{Kind: "Job", Namespace: ai.Namespace, Name: jobName}
		}
		if schemaJobSucceeded(job) {
			// A previously successful input can become desired again after a
			// different schema has run. Its retained Job is historical evidence,
			// not proof that the current transition has applied SQL. Remove it
			// before creating a fresh Job with the same input-derived name.
			if state.JobName != job.Name {
				if job.DeletionTimestamp == nil {
					if err := r.Delete(ctx, job, client.PropagationPolicy(metav1.DeletePropagationForeground)); err != nil && !apierrors.IsNotFound(err) {
						return fmt.Errorf("remove historical schema Job: %w", err)
					}
				}
				return schemaState("Pending", "waiting for historical schema Job removal")
			}
			state.JobName = job.Name
			state.AppliedHash = inputHash
			state.FailedHash = ""
			state.FailureReason = ""
			state.ImageDigest = strings.SplitN(schemaImage, "@", 2)[1]
			return nil
		}
		// A Job may have been created before its attempt status was persisted.
		// Observing it invalidates any success from an earlier run of this input.
		state.AppliedHash = ""
		state.ImageDigest = ""
		state.JobName = job.Name
		if schemaJobFailed(job) {
			state.FailedHash = inputHash
			for _, condition := range job.Status.Conditions {
				if condition.Type == batchv1.JobFailed && condition.Reason == "DeadlineExceeded" {
					state.FailureReason = "TimedOut"
					return schemaState("TimedOut", "schema Job exceeded its deadline; change schemaRetryNonce to retry")
				}
				if condition.Type == batchv1.JobFailed && condition.Reason == "BackoffLimitExceeded" {
					state.FailureReason = "Failed"
					return schemaState("Failed", "schema Job exhausted its retry limit; change schemaRetryNonce to retry")
				}
			}
			state.FailureReason = "Failed"
			return schemaState("Failed", "schema Job failed; change schemaRetryNonce to retry")
		}
		state.FailedHash = ""
		state.FailureReason = ""
		return schemaState("Pending", "waiting for schema Job completion")
	}
	if !apierrors.IsNotFound(err) {
		return fmt.Errorf("get postgres schema setup Job: %w", err)
	}
	if state.FailedHash == inputHash {
		if state.FailureReason == "TimedOut" {
			return schemaState("TimedOut", "schema Job exceeded its deadline; change schemaRetryNonce to retry")
		}
		return schemaState("Failed", "schema Job failed; change schemaRetryNonce to retry")
	}
	if state.AppliedHash == inputHash && (state.JobName == jobName || state.JobName == "") {
		state.JobName = ""
		return nil // The TTL controller may have removed the successful Job.
	}
	if state.JobName == jobName {
		// A Job may expire while the operator is offline. Its outcome is then
		// unknown, so require an explicit retry instead of silently reapplying SQL.
		return schemaState("Failed", "schema Job outcome was lost; change schemaRetryNonce to retry")
	}

	labels, annotations := labelsAndAnnotations(ai)
	// Keep the schema policy selector stable even when labels are supplied by the caller.
	for key, value := range SchemaSelectorLabels(ai.Name) {
		labels[key] = value
	}
	annotations[schemaJobInputHashAnnotation] = inputHash
	annotations["ai.splunk.com/agentruntime-schema-image-digest"] = strings.SplitN(schemaImage, "@", 2)[1]
	annotations[schemaJobManagedAnnotation] = schemaJobManagedValue
	job = &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:        jobName,
			Namespace:   ai.Namespace,
			Labels:      labels,
			Annotations: annotations,
		},
	}
	if err := controllerutil.SetControllerReference(ai, job, r.Scheme); err != nil {
		return fmt.Errorf("ownerref on postgres schema setup Job: %w", err)
	}

	featureEnv := buildFeatureEnv(ai.Spec.Feature.Env)
	job.Spec = batchv1.JobSpec{
		BackoffLimit:            ptr(schemaJobBackoffLimit),
		ActiveDeadlineSeconds:   ptr(schemaJobDeadlineSeconds),
		TTLSecondsAfterFinished: ptr(schemaJobTTLSeconds),
		Template: corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{Labels: labels},
			Spec: corev1.PodSpec{
				ServiceAccountName: ai.Spec.ServiceAccountName,
				RestartPolicy:      corev1.RestartPolicyNever,
				Containers: []corev1.Container{{
					Name:            "schema-setup",
					Image:           schemaImage,
					ImagePullPolicy: corev1.PullIfNotPresent,
					Command:         []string{"sh", "-c"},
					Args:            []string{schemaSetupCommand},
					Env:             featureEnv,
					EnvFrom: []corev1.EnvFromSource{{
						SecretRef: &corev1.SecretEnvSource{
							LocalObjectReference: corev1.LocalObjectReference{Name: ai.Spec.CheckpointDbSecretRef},
						},
					}},
				}},
				Affinity:         &ai.Spec.Affinity,
				Tolerations:      ai.Spec.Tolerations,
				NodeSelector:     ai.Spec.NodeSelector,
				ImagePullSecrets: ai.Spec.ImagePullSecrets,
			},
		},
	}
	if err := r.Create(ctx, job); err != nil {
		if apierrors.IsAlreadyExists(err) {
			// A cached NotFound can race with a retained historical Job. Re-read
			// it before adopting this name as the current attempt.
			return schemaState("Pending", "waiting for schema Job observation")
		}
		return fmt.Errorf("create postgres schema setup Job: %w", err)
	}
	// The new attempt is the only result eligible for reuse after Job TTL
	// cleanup. Clear historical success before recording this attempt's name.
	state.AppliedHash = ""
	state.ImageDigest = ""
	state.FailedHash = ""
	state.FailureReason = ""
	state.JobName = job.Name
	return schemaState("Pending", "waiting for schema Job completion")
}

func validateSchemaSetupCredentials(secret *corev1.Secret, featureEnv map[string]string) error {
	if errs := credentials.ValidatePostgresEnvironment(featureEnv, field.NewPath("spec", "features", "env")); len(errs) != 0 {
		return errs.ToAggregate()
	}
	return credentials.ValidatePostgresSecret(secret)
}

func buildFeatureEnv(values map[string]string) []corev1.EnvVar {
	names := make([]string, 0, len(values))
	for name := range values {
		names = append(names, name)
	}
	sort.Strings(names)
	env := make([]corev1.EnvVar, 0, len(names))
	for _, name := range names {
		env = append(env, corev1.EnvVar{Name: name, Value: values[name]})
	}
	return env
}

func agentRuntimeSchemaInputHash(ai *aiv1.AIService, schemaImage string, secret *corev1.Secret) string {
	postgresEnv := map[string]string{}
	for name, value := range ai.Spec.Feature.Env {
		if value != "" && (name == "DATABASE_URL" || strings.HasPrefix(name, "PG")) {
			postgresEnv[name] = value
		}
	}
	return stableHash(struct {
		Image           string
		SchemaSecretRef string
		SecretVersion   string
		PostgresEnv     map[string]string
		RetryNonce      string
	}{
		Image:           schemaImage,
		SchemaSecretRef: ai.Spec.CheckpointDbSecretRef,
		SecretVersion:   secret.ResourceVersion,
		PostgresEnv:     postgresEnv,
		RetryNonce:      ai.Spec.Feature.SchemaRetryNonce,
	})
}

func stableHash(value any) string {
	encoded, err := json.Marshal(value)
	if err != nil {
		return "invalid"
	}
	digest := sha256.Sum256(encoded)
	return fmt.Sprintf("%x", digest[:8])
}

func schemaJobSucceeded(job *batchv1.Job) bool {
	for _, condition := range job.Status.Conditions {
		if condition.Type == batchv1.JobComplete && condition.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

func schemaJobFailed(job *batchv1.Job) bool {
	for _, condition := range job.Status.Conditions {
		if condition.Type == batchv1.JobFailed && condition.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

func (r *AgentRuntimeReconciler) reconcileDeployment(ctx context.Context, ai *aiv1.AIService) error {
	config, err := resolveAgentRuntimeConfig(ai)
	if err != nil {
		return err
	}

	labels, annotations := labelsAndAnnotations(ai)
	selectorLabels := agentRuntimeSelectorLabels(ai)
	containerName := agentRuntimeWorkloadName(ai.Name)
	env := buildAgentRuntimeEnv(ai, config.AgentModule)
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
	if _, err := controllerutil.CreateOrPatch(ctx, r.Client, deployment, func() error {
		if err := common.ClaimOrRefuse(ai, deployment, r.Scheme); err != nil {
			return err
		}
		deployment.ObjectMeta.Labels = labels
		deployment.ObjectMeta.Annotations = common.PreserveDeploymentRevision(deployment, annotations)
		if deployment.ResourceVersion == "" {
			policy := aiv1.ResolveAgentRuntimeAutoscaling(ai.Spec.MinReplicas, ai.Spec.MaxReplicas, ai.Spec.TargetCPUUtilization)
			replicas := policy.MinReplicas
			owner := metav1.GetControllerOf(ai)
			platformManaged := owner != nil && owner.APIVersion == aiv1.GroupVersion.String() && owner.Kind == "AIPlatform"
			if !platformManaged && ai.Spec.Replicas >= policy.MinReplicas && ai.Spec.Replicas <= policy.MaxReplicas {
				replicas = ai.Spec.Replicas
			}
			deployment.Spec.Replicas = &replicas
		}
		// Once created, the Deployment's replica count belongs to the HPA.
		// Leaving it untouched in this merge patch preserves even a scale
		// change made after the Deployment was read.

		if deployment.Spec.Selector == nil {
			deployment.Spec.Selector = &metav1.LabelSelector{
				MatchLabels: selectorLabels,
			}
		}

		template := corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{
				Labels:      selectorLabels,
				Annotations: annotations,
			},
			Spec: corev1.PodSpec{
				ServiceAccountName: ai.Spec.ServiceAccountName,
				InitContainers: []corev1.Container{{
					Name:            "fetch-provider-wheel",
					Image:           config.ProviderImage,
					ImagePullPolicy: corev1.PullIfNotPresent,
					Command:         []string{"/bin/sh", "-c"},
					Args:            []string{"cp -a /payload/. " + sharedPackagesPath + "/"},
					VolumeMounts: []corev1.VolumeMount{
						{Name: "provider-packages", MountPath: sharedPackagesPath},
					},
				}},
				Containers: []corev1.Container{{
					Name:            containerName,
					Image:           config.BaseImage,
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
		common.PreservePodTemplateDefaults(&template, &deployment.Spec.Template)
		deployment.Spec.Template = template
		return nil
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update Deployment failed")
		return fmt.Errorf("create/update Deployment: %w", err)
	}
	return nil
}

func (r *AgentRuntimeReconciler) reconcileService(ctx context.Context, ai *aiv1.AIService) error {
	// AgentRuntime is an in-cluster MVP endpoint. Keep the Service ClusterIP-only
	// until a future cross-namespace/external exposure contract is defined.
	svcType := corev1.ServiceTypeClusterIP

	labels, _ := labelsAndAnnotations(ai)
	selectorLabels := agentRuntimeSelectorLabels(ai)
	annotations := common.FilterPropagatedAnnotations(ai.Annotations)
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      agentRuntimeServiceName(ai.Name),
			Namespace: ai.Namespace,
		},
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		if err := common.ClaimOrRefuse(ai, svc, r.Scheme); err != nil {
			return err
		}
		svc.ObjectMeta.Labels = labels
		svc.ObjectMeta.Annotations = annotations
		svc.Spec.Selector = selectorLabels
		svc.Spec.Ports = runtimeServicePorts()
		svc.Spec.Type = svcType
		// Do not let Service edits expose the internal runtime or bypass Pod readiness.
		svc.Spec.ExternalIPs = nil
		svc.Spec.PublishNotReadyAddresses = false
		return nil
	}); err != nil {
		r.Recorder.Event(ai, corev1.EventTypeWarning, "InvalidSpec", "create/update Service failed")
		return fmt.Errorf("create/update Service: %w", err)
	}
	return nil
}

func runtimeServicePorts() []corev1.ServicePort {
	return []corev1.ServicePort{
		{Name: "http", Port: defaultAgentRuntimeHTTPPort, TargetPort: intstr.FromInt32(defaultAgentRuntimeHTTPPort), Protocol: corev1.ProtocolTCP},
		{Name: "metrics", Port: defaultAgentRuntimeMetrics, TargetPort: intstr.FromInt32(defaultAgentRuntimeMetrics), Protocol: corev1.ProtocolTCP},
	}
}

func (r *AgentRuntimeReconciler) reconcileHPA(ctx context.Context, ai *aiv1.AIService) error {
	hpa := &autoscalingv2.HorizontalPodAutoscaler{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ai.Name + "-agentruntime-hpa",
			Namespace: ai.Namespace,
		},
	}
	policy := aiv1.ResolveAgentRuntimeAutoscaling(ai.Spec.MinReplicas, ai.Spec.MaxReplicas, ai.Spec.TargetCPUUtilization)
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, hpa, func() error {
		if err := common.ClaimOrRefuse(ai, hpa, r.Scheme); err != nil {
			return err
		}
		hpa.Spec = autoscalingv2.HorizontalPodAutoscalerSpec{
			ScaleTargetRef: autoscalingv2.CrossVersionObjectReference{
				APIVersion: "apps/v1",
				Kind:       "Deployment",
				Name:       ai.Name + "-agentruntime-deployment",
			},
			MinReplicas: &policy.MinReplicas,
			MaxReplicas: policy.MaxReplicas,
			Metrics: []autoscalingv2.MetricSpec{{
				Type: autoscalingv2.ResourceMetricSourceType,
				Resource: &autoscalingv2.ResourceMetricSource{
					Name: corev1.ResourceCPU,
					Target: autoscalingv2.MetricTarget{
						Type:               autoscalingv2.UtilizationMetricType,
						AverageUtilization: &policy.TargetCPUUtilization,
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

func (r *AgentRuntimeReconciler) reconcileServiceMonitor(ctx context.Context, ai *aiv1.AIService) error {
	name := ai.Name + "-agentruntime-metrics"
	if !ai.Spec.Metrics.Enabled {
		return r.deleteOwnedObject(ctx, ai, &monitoringv1.ServiceMonitor{}, name)
	}
	config, _, err := r.resolveNetworkPolicy(ctx, ai)
	if err != nil {
		return err
	}
	if config.MetricsDisabled {
		return r.deleteOwnedObject(ctx, ai, &monitoringv1.ServiceMonitor{}, name)
	}

	sm := &monitoringv1.ServiceMonitor{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ai.Namespace,
		},
	}
	_, err = controllerutil.CreateOrUpdate(ctx, r.Client, sm, func() error {
		if err := common.ClaimOrRefuse(ai, sm, r.Scheme); err != nil {
			return err
		}
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

// WorkloadName identifies runtime Pod labels when mapping backend events.
func WorkloadName(aiServiceName string) string { return agentRuntimeWorkloadName(aiServiceName) }

// ServiceName identifies EndpointSlices for an AgentRuntime AIService.
func ServiceName(aiServiceName string) string { return agentRuntimeServiceName(aiServiceName) }

func agentRuntimeSelectorLabels(ai *aiv1.AIService) map[string]string {
	workloadName := agentRuntimeWorkloadName(ai.Name)
	return map[string]string{"app": workloadName, "component": workloadName}
}

// ServiceURL is the in-cluster URL of the Service the AgentRuntime handler creates
// for the AIService named aiServiceName. Other components (the AIPlatform
// controller, for SLIM) use it so the Service name and port are defined in one place.
func ServiceURL(aiServiceName, namespace, clusterDomain string) string {
	if clusterDomain == "" {
		clusterDomain = "cluster.local"
	}
	return fmt.Sprintf("http://%s.%s.svc.%s:%d", agentRuntimeServiceName(aiServiceName), namespace, clusterDomain, defaultAgentRuntimeHTTPPort)
}

// FeatureServiceURL resolves a provider feature before the generated AIService
// exists, using the same DNS length bound as the AIPlatform's feature name.
func FeatureServiceURL(platformName, provider, namespace, clusterDomain string) string {
	return ServiceURL(FeatureAIServiceName(platformName, provider), namespace, clusterDomain)
}

// FeatureAIServiceName identifies the generated child for a Runtime provider.
func FeatureAIServiceName(platformName, provider string) string {
	name := platformName + "-agentruntime"
	if provider != "" {
		name += "-" + provider
	}
	return boundedDNSLabel(name)
}

func agentRuntimeServiceName(aiServiceName string) string {
	return dnsLabelName(aiServiceName, "svc")
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

func buildAgentRuntimeEnv(ai *aiv1.AIService, agentModule string) []corev1.EnvVar {
	platformURL := strings.TrimRight(ai.Spec.AIPlatformUrl, "/")
	env := []corev1.EnvVar{
		{Name: "AGENT_MODULE", Value: agentModule},
		{Name: "CHECKPOINT_DB_SECRET_REF", Value: ai.Spec.CheckpointDbSecretRef},
	}
	// PLATFORM_URL is the Ray head endpoint. It is set whenever there is one
	// (fullfeature always has one) and omitted for cpuOnly, which has no Ray.
	//
	if platformURL != "" {
		env = append(env, corev1.EnvVar{Name: "PLATFORM_URL", Value: platformURL})
	}
	env = append(env, corev1.EnvVar{Name: "PYTHONPATH", Value: sharedPackagesPath})
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
	if len(ai.Spec.Feature.Env) > 0 {
		extraNames := make([]string, 0, len(ai.Spec.Feature.Env))
		for name := range ai.Spec.Feature.Env {
			extraNames = append(extraNames, name)
		}
		sort.Strings(extraNames)
		for _, name := range extraNames {
			env = append(env, corev1.EnvVar{Name: name, Value: ai.Spec.Feature.Env[name]})
		}
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
		return resolveRequiredRuntimeEnv(envName, fmt.Sprintf(" when runtimeVersion %q is requested", ai.Spec.RuntimeVersion))
	}
	return resolveRequiredRuntimeEnv("RELATED_IMAGE_AGENT_RUNTIME_BASE", "")
}

func resolveSchemaSetupImage() (string, error) {
	image, err := resolveRequiredRuntimeEnv(schemaSetupImageEnv, "")
	if err != nil {
		return "", err
	}
	if !regexp.MustCompile(`^[^@]+@sha256:[a-f0-9]{64}$`).MatchString(image) {
		return "", schemaState("ImageDigestRequired", "schema setup image must be supplied by immutable sha256 digest")
	}
	return image, nil
}

func resolveProviderImage(ai *aiv1.AIService) (string, error) {
	envName := "RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_" + normalizeEnvKeySegment(ai.Spec.Feature.Provider)
	return resolveRequiredRuntimeEnv(envName, fmt.Sprintf(" for provider %q", ai.Spec.Feature.Provider))
}

func resolveAgentRuntimeConfig(ai *aiv1.AIService) (agentRuntimeConfig, error) {
	baseImage, err := resolveBaseImage(ai)
	if err != nil {
		return agentRuntimeConfig{}, err
	}
	providerImage, err := resolveProviderImage(ai)
	if err != nil {
		return agentRuntimeConfig{}, err
	}
	agentModule, err := resolveAgentModule(ai.Spec.Feature.Provider)
	if err != nil {
		return agentRuntimeConfig{}, err
	}
	return agentRuntimeConfig{
		BaseImage:     baseImage,
		ProviderImage: providerImage,
		AgentModule:   agentModule,
	}, nil
}

func resolveRequiredRuntimeEnv(name, context string) (string, error) {
	value := os.Getenv(name)
	if strings.TrimSpace(value) == "" {
		return "", fmt.Errorf("%s must be set%s", name, context)
	}
	if strings.ContainsAny(value, " \t\r\n") {
		return "", fmt.Errorf("%s must not contain whitespace", name)
	}
	return value, nil
}

func resolveAgentModule(provider string) (string, error) {
	envName := "RELATED_AGENT_RUNTIME_MODULE_PROVIDER_" + normalizeEnvKeySegment(provider)
	module := strings.TrimSpace(os.Getenv(envName))
	if module == "" {
		return "", fmt.Errorf("%s must be set for provider %q", envName, provider)
	}
	if !agentModulePattern.MatchString(module) {
		return "", fmt.Errorf("%s has invalid value; expected package.module:ClassName", envName)
	}
	return module, nil
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

func ptr[T any](value T) *T {
	return &value
}
