/*
File: controllers/raybuilder/builder.go
*/
package raybuilder

import (
	"bytes"
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"text/template"
	"time"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	enterpriseApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/internal/telemetry"
	"github.com/splunk/splunk-ai-operator/pkg/ai/raybuilder/raystatus"
	"gopkg.in/yaml.v2"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"k8s.io/client-go/util/retry"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	k8syaml "sigs.k8s.io/yaml"
)

// Builder encapsulates RayService generation logic.
type Builder struct {
	ai *enterpriseApi.AIPlatform
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

type ApplicationParams struct {
	ArtifactBucketName             string           `yaml:"ARTIFACTS_S3_BUCKET"`
	ArtifactsProvider              string           `yaml:"ARTIFACTS_PROVIDER"`
	CloudProvider                  string           `yaml:"CLOUD_PROVIDER"`
	Region                         string           `yaml:"AWS_REGION"`
	S3CompatObjectStoreEndpointUrl string           `yaml:"S3COMPAT_OBJECT_STORE_ENDPOINT_URL"`
	S3CompatObjectStoreAccessKey   string           `yaml:"S3COMPAT_OBJECT_STORE_ACCESS_KEY"`
	S3CompatObjectStoreSecretKey   string           `yaml:"S3COMPAT_OBJECT_STORE_SECRET_KEY"`
	Replicas                       map[string]int32 `yaml:"REPLICAS"`
	ModelVersion                   string           `yaml:"MODEL_VERSION"`
	AcceleratorType                string           `yaml:"ACCELERATOR_TYPE"`
}

// classifyObjectStorage maps an AIPlatform objectStorage URL scheme + endpoint
// pair to the (cloudProvider, artifactsProvider, needsS3CompatCreds) tuple
// expected by the SAIA / ML-platform SDK that runs inside Ray Serve replicas.
//
// SDK contract (see /home/ray/sdk/storage/factory.py in the ai-platform-models
// image): CLOUD_PROVIDER accepts the values emitted below, including
// "s3compat" for S3-compatible backends such as MinIO and SeaweedFS. When
// CLOUD_PROVIDER is "s3compat", the SDK uses the S3COMPAT_OBJECT_STORE_*
// env vars for endpoint and credentials while still speaking the S3 API with
// SigV4-compatible request signing.
//
// Decision table:
//
//	scheme=s3, endpoint empty            → ("aws",      "s3",    needsCreds=true)   ← AWS S3 default URL
//	scheme=s3, endpoint matches AWS host → ("aws",      "s3",    needsCreds=true)   ← installer-set regional URL
//	scheme=s3, endpoint set to non-AWS   → ("s3compat", "s3",    needsCreds=true)   ← MinIO/SeaweedFS behind s3://
//	scheme=s3compat|minio|seaweedfs      → ("s3compat", "s3",    needsCreds=true)
//	scheme=gs|gcs                        → ("gcp",      "gcs",   needsCreds=false)
//	scheme=azure                         → ("azure",    "azure", needsCreds=false)
//	other / unknown                      → ("azure",    "azure", needsCreds=false)
//
// `needsS3CompatCreds` is true whenever the resolved provider can use the
// S3COMPAT_*/AWS_* credential set in the ObjectStorage Secret. Callers gate
// secret loading on it AND on a non-empty SecretRef.
func classifyObjectStorage(scheme, endpoint string) (cloudProvider, artifactsProvider string, needsS3CompatCreds bool) {
	switch scheme {
	case "s3":
		artifactsProvider = "s3"
		ep := strings.TrimSpace(endpoint)
		if ep == "" || isAWSRegionalEndpoint(ep) {
			// Real AWS S3 — either no endpoint (boto3 derives from region) or an
			// AWS regional URL (e.g. https://s3.us-east-2.amazonaws.com, which
			// the k0s installer requires non-empty even for type=aws).
			cloudProvider = "aws"
		} else {
			// s3:// against a non-AWS endpoint = S3-compatible store (MinIO,
			// SeaweedFS, etc.). Keep the s3compat code path so the SDK reads
			// S3COMPAT_* env vars.
			cloudProvider = "s3compat"
		}
		needsS3CompatCreds = true
	case "s3compat", "minio", "seaweedfs":
		cloudProvider = "s3compat"
		artifactsProvider = "s3"
		needsS3CompatCreds = true
	case "gs", "gcs":
		cloudProvider = "gcp"
		artifactsProvider = "gcs"
	case "azure":
		cloudProvider = "azure"
		artifactsProvider = "azure"
	default:
		// Unknown scheme: preserve the legacy default (azure) rather than
		// failing — the operator hasn't validated this scheme until now and a
		// hard error here would break running clusters during upgrade.
		cloudProvider = "azure"
		artifactsProvider = "azure"
	}
	return
}

// isAWSRegionalEndpoint returns true for AWS S3 regional endpoints such as:
//
//	https://s3.us-east-2.amazonaws.com
//	https://s3-fips.us-east-1.amazonaws.com
//	https://bucket-name.s3.us-east-2.amazonaws.com  (virtual-hosted-style)
//	https://s3.dualstack.us-east-1.amazonaws.com
//
// We need this because the k0s installer requires a non-empty
// objectStore.endpoint even for type=aws (see preflight in
// tools/cluster_setup/k0s_cluster_with_stack.sh:434), so an empty-endpoint
// check alone is not sufficient to identify real AWS S3.
//
// The match is intentionally narrow: host must end in `.amazonaws.com` AND
// contain `s3` somewhere in the host (case-insensitive). This catches every
// AWS S3 endpoint pattern documented by AWS but rejects unrelated AWS hosts
// (e.g. `lambda.us-east-1.amazonaws.com`) and any third-party impostor whose
// host doesn't end in `.amazonaws.com`. Returns false on parse error or empty
// host (caller already handles the empty-endpoint case).
func isAWSRegionalEndpoint(endpoint string) bool {
	u, err := url.Parse(strings.TrimSpace(endpoint))
	if err != nil || u.Hostname() == "" {
		return false
	}
	host := strings.ToLower(u.Hostname())
	return strings.HasSuffix(host, ".amazonaws.com") && strings.Contains(host, "s3")
}

type WorkerConfigs map[string][]InstanceDetail

type InstanceDetail struct {
	Tier       string                      `yaml:"tier"`
	GPUsPerPod int32                       `yaml:"gpusPerPod"`
	Env        map[string]string           `yaml:"env,omitempty"`
	Resources  corev1.ResourceRequirements `yaml:"resources"`
}

// ScaleConfig models the two global scale files. model-scale.yaml supplies
// applicationScale (model name -> base replica count); worker-scale.yaml
// supplies instanceScale (accelerator -> tier -> base pod count). Each file
// populates only its own field.
type ScaleConfig struct {
	ApplicationScale map[string]int32            `yaml:"applicationScale"`
	InstanceScale    map[string]map[string]int32 `yaml:"instanceScale"`
}

// New returns a new Builder for the given AIPlatform instance.
func New(ai *enterpriseApi.AIPlatform, client client.Client, scheme *runtime.Scheme, recorder record.EventRecorder) *Builder {
	return &Builder{
		ai:       ai,
		Client:   client,
		Scheme:   scheme,
		Recorder: recorder,
	}
}

// effectiveAcceleratorType returns spec.defaultAcceleratorType or L40S when unset, matching instance.yaml keys (L40S, H100_NVL).
func (b *Builder) effectiveAcceleratorType() string {
	if s := strings.TrimSpace(b.ai.Spec.DefaultAcceleratorType); s != "" {
		return s
	}
	return "L40S"
}

// effectiveScaleFactor returns the platform-wide capacity multiplier from
// spec.scaleFactor, defaulting to 1 when unset. It uniformly multiplies both
// model (Serve) replicas and GPU worker-pool pod counts so the two stay in
// lockstep on the shared, fixed GPU pool.
func (b *Builder) effectiveScaleFactor() int32 {
	if b.ai.Spec.ScaleFactor != nil && *b.ai.Spec.ScaleFactor >= 1 {
		return *b.ai.Spec.ScaleFactor
	}
	return 1
}

// loadScaleConfig reads a global scale file (model-scale.yaml or
// worker-scale.yaml) from the path in the given env var, falling back to
// defaultFile in the working directory when the env var is unset (e.g. local
// or test runs; in the operator image the env vars are always set).
func loadScaleConfig(envVar, defaultFile string) (ScaleConfig, error) {
	var cfg ScaleConfig
	file := os.Getenv(envVar)
	if file == "" {
		file = defaultFile
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return cfg, fmt.Errorf("failed to read scale file %s: %w", file, err)
	}
	if err := yaml.UnmarshalStrict(data, &cfg); err != nil {
		return cfg, fmt.Errorf("failed to parse scale file %s: %w", file, err)
	}
	return cfg, nil
}

// --- 7️⃣ ReconcileRayService: build & create/update the RayService CR ---
func (b *Builder) ReconcileRayService(ctx context.Context, p *enterpriseApi.AIPlatform) error {
	logger := log.FromContext(ctx) // Define logger
	rs, err := b.Build(ctx)
	if err != nil {
		logger.Error(err, "Failed to build RayService")
		return err
	}

	// Load applications.yaml and parameterize ARTIFACTS_S3_BUCKET
	u, err := url.Parse(p.Spec.ObjectStorage.Path)
	if err != nil {
		fmt.Println("Error parsing URL:", err)
		return err
	}

	// Classify object-storage URL into the (CLOUD_PROVIDER, ARTIFACTS_PROVIDER,
	// needsCreds) tuple the SAIA / ai-platform SDK consumes via runtime_env
	// env vars. See classifyObjectStorage doc-comment for the full decision
	// table, including AWS regional-endpoint detection.
	cloudProvider, artifactsProvider, needsS3CompatCreds := classifyObjectStorage(u.Scheme, p.Spec.ObjectStorage.Endpoint)

	// Build the model replica map from the global model-scale.yaml, scaled by
	// the platform-wide scaleFactor. Every model in the catalog is always
	// deployed; sizing no longer depends on spec.Features (which now drives
	// only AIService creation in ReconcileFeatures).
	modelScale, err := loadScaleConfig("MODEL_SCALE_FILE", "model-scale.yaml")
	if err != nil {
		logger.Error(err, "Failed to load model scale config")
		return err
	}
	scaleFactor := b.effectiveScaleFactor()
	logger.V(1).Info("Loaded model scale config", "scaleFactor", scaleFactor, "models", len(modelScale.ApplicationScale))

	replicasMap := make(map[string]int32, len(modelScale.ApplicationScale))
	for appName, baseReplicas := range modelScale.ApplicationScale {
		replicasMap[appName] = baseReplicas * scaleFactor
	}

	// S3-compatible endpoint is only meaningful when the classifier picked the
	// s3compat code path. For real AWS (cloudProvider=aws) we leave it empty so
	// boto3 falls through to the default regional URL derived from AWS_REGION.
	s3CompatObjectStoreEndpoint := ""
	if cloudProvider == "s3compat" && p.Spec.ObjectStorage.Endpoint != "" {
		s3CompatObjectStoreEndpoint = p.Spec.ObjectStorage.Endpoint
	}

	// Load S3 credentials from the operator-managed Secret whenever the chosen
	// provider can use them (aws OR s3compat). The Secret is the single
	// source of truth — `s3_access_key`/`s3_secret_key` populate both the
	// boto3-standard AWS_* env vars (consumed by the AWS code path) and the
	// S3COMPAT_* env vars (consumed by the s3compat shim). Templating both
	// pairs is safe because each code path only reads its own set.
	//
	// Previously this block was gated behind s3CompatScheme, which silently
	// skipped credential injection for real-AWS deployments and produced
	// `botocore.exceptions.NoCredentialsError` inside every Serve replica
	// when the cluster lacked IRSA / EC2 instance-profile credentials (true
	// for k0s on bare-metal / non-EKS deployments).
	var s3CompatObjectStoreAccessKey, s3CompatObjectStoreSecretKey string
	if p.Spec.ObjectStorage.SecretRef != "" && needsS3CompatCreds {
		var secret corev1.Secret
		secretRef := types.NamespacedName{Namespace: p.Namespace, Name: p.Spec.ObjectStorage.SecretRef}
		if err := b.Get(ctx, secretRef, &secret); err != nil {
			logger.Error(err, "Failed to get object storage credentials Secret",
				"secret", p.Spec.ObjectStorage.SecretRef,
				"cloudProvider", cloudProvider)
			return err
		}
		if raw, ok := secret.Data["s3_access_key"]; ok {
			s3CompatObjectStoreAccessKey = string(raw)
		}
		if raw, ok := secret.Data["s3_secret_key"]; ok {
			s3CompatObjectStoreSecretKey = string(raw)
		}
	}

	param := ApplicationParams{
		ArtifactBucketName:             u.Host,
		ArtifactsProvider:              artifactsProvider,
		CloudProvider:                  cloudProvider,
		Region:                         p.Spec.ObjectStorage.Region,
		S3CompatObjectStoreEndpointUrl: s3CompatObjectStoreEndpoint,
		S3CompatObjectStoreAccessKey:   s3CompatObjectStoreAccessKey,
		S3CompatObjectStoreSecretKey:   s3CompatObjectStoreSecretKey,
		Replicas:                       replicasMap,
		ModelVersion:                   os.Getenv("MODEL_VERSION"),
		AcceleratorType:                b.effectiveAcceleratorType(),
	}

	// Use embedded applications.yaml content
	applicationFile := os.Getenv("APPLICATION_FILE")
	if applicationFile == "" {
		applicationFile = "applications.yaml" // default when APPLICATION_FILE is unset (local/test runs)
	}
	templateData, err := os.ReadFile(applicationFile)
	if err != nil {
		logger.Error(err, "Failed to read embedded applications.yaml")
		return err
	}

	// Create a new template and parse the embedded YAML as a template
	tmpl, err := template.New("applications").Parse(string(templateData))
	if err != nil {
		logger.Error(err, "Failed to parse template")
		return err
	}

	// Execute the template with the provided parameters
	var serveConfig bytes.Buffer
	if err := tmpl.Execute(&serveConfig, param); err != nil {
		logger.Error(err, "Failed to execute template")
		return err
	}

	annotations, labels := buildHeadAnnotationsAndLabels(p)
	rayService := &rayv1.RayService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      p.Name,
			Namespace: p.Namespace,
		},
	}
	err = b.Client.Get(ctx, types.NamespacedName{Namespace: p.Namespace, Name: p.Name}, rayService)
	if errors.IsNotFound(err) {
		rayService = &rayv1.RayService{
			ObjectMeta: metav1.ObjectMeta{
				Name:        p.Name,
				Namespace:   p.Namespace,
				Annotations: annotations,
				Labels:      labels,
			},
		}
	}

	// Set the parameterized serve config
	rs.Spec.ServeConfigV2 = serveConfig.String()

	// Create or update ConfigMap with serveConfig for debugging
	configMap := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      p.Name + "-serve-config",
			Namespace: p.Namespace,
		},
	}
	_, err = controllerutil.CreateOrUpdate(ctx, b.Client, configMap, func() error {
		if configMap.Data == nil {
			configMap.Data = make(map[string]string)
		}
		configMap.Data["serve-config.yaml"] = serveConfig.String()
		configMap.Data["cloud-provider"] = cloudProvider
		configMap.Data["artifact-bucket"] = u.Host
		// Set owner reference for garbage collection
		return controllerutil.SetControllerReference(p, configMap, b.Scheme)
	})
	if err != nil {
		logger.Error(err, "Failed to create/update serve config ConfigMap")
		// Don't fail the reconciliation for ConfigMap creation failure
	}

	// Clean server-generated metadata from RayService spec to avoid "unknown field" warnings
	cleanRayServiceSpec(&rs.Spec)

	rayService.Spec = rs.Spec
	key := types.NamespacedName{Namespace: rayService.Namespace, Name: rayService.Name}
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var current rayv1.RayService
		if err := b.Client.Get(ctx, key, &current); err != nil {
			if errors.IsNotFound(err) {
				// Emit event for new RayService creation
				b.Recorder.Event(p, corev1.EventTypeNormal, "RayServiceCreating", "Creating RayService resource")
				controllerutil.SetOwnerReference(p, rayService, b.Scheme)
				if err := b.Client.Create(ctx, rayService); err != nil {
					return err
				}
				b.Recorder.Event(p, corev1.EventTypeNormal, "RayServiceCreated", "RayService resource created successfully")
				return nil
			}
			b.Recorder.Eventf(p, corev1.EventTypeWarning, "ReconcileFailed", "Failed to reconcile RayService %v", err)
			return err
		}

		// mutate current.Spec to match desired svc.Spec
		current.Spec = rs.Spec
		// now try update
		controllerutil.SetOwnerReference(p, &current, b.Scheme)
		return b.Client.Update(ctx, &current)
	})
}

// FIXME work with @shang to find if rayserve support this internally
func (b *Builder) ReconcileRayAutoscalerRBAC(ctx context.Context, p *enterpriseApi.AIPlatform) error {
	logger := log.FromContext(ctx)
	saName := p.Spec.ServiceAccountName
	if saName == "" {
		logger.Info("No ServiceAccount specified for Ray head group, skipping RBAC reconciliation")
		return nil
	}

	role := &rbacv1.Role{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "ray-autoscaler",
			Namespace: p.Namespace,
		},
	}

	if _, err := controllerutil.CreateOrUpdate(ctx, b.Client, role, func() error {
		// Update Role rules
		role.Rules = []rbacv1.PolicyRule{
			{
				APIGroups: []string{"ray.io"},
				Resources: []string{"rayclusters", "rayservices", "rayjobs"},
				Verbs:     []string{"get", "list", "watch", "patch", "update", "delete"},
			},
		}
		return controllerutil.SetOwnerReference(p, role, b.Scheme)
	}); err != nil {
		return fmt.Errorf("failed to create/update Role: %w", err)
	}

	roleBinding := &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "ray-autoscaler-binding-" + p.Namespace + "-" + saName,
			Namespace: p.Namespace,
		},
	}

	if _, err := controllerutil.CreateOrUpdate(ctx, b.Client, roleBinding, func() error {
		// Set immutable RoleRef only on creation
		if roleBinding.RoleRef.Name == "" {
			roleBinding.RoleRef = rbacv1.RoleRef{
				APIGroup: "rbac.authorization.k8s.io",
				Kind:     "Role",
				Name:     "ray-autoscaler",
			}
		}
		// Update Subjects (mutable field)
		roleBinding.Subjects = []rbacv1.Subject{
			{
				Kind:      "ServiceAccount",
				Name:      saName,
				Namespace: p.Namespace,
			},
		}
		return controllerutil.SetOwnerReference(p, roleBinding, b.Scheme)
	}); err != nil {
		return fmt.Errorf("failed to create/update RoleBinding: %w", err)
	}
	return nil
}

// ApplyNormalizedConditions collects Ray signals and rolls them up into AIPlatform conditions.
// Signature matches your state-machine call sites.
func (b *Builder) ApplyNormalizedConditions(ctx context.Context, p *enterpriseApi.AIPlatform) error {
	logger := log.FromContext(ctx)

	snap, err := raystatus.CollectRaySnapshot(ctx, b.Client, p.Namespace, p.Name)
	if err != nil {
		now := metav1.NewTime(time.Now())
		errMsg := fmt.Sprintf("Failed to collect Ray snapshot: %v", err)

		meta.SetStatusCondition(&p.Status.Conditions, metav1.Condition{
			Type:               "RayServiceReady",
			Status:             metav1.ConditionFalse,
			Reason:             "RayServiceFetchError",
			Message:            errMsg,
			LastTransitionTime: now,
		})
		meta.SetStatusCondition(&p.Status.Conditions, metav1.Condition{
			Type:               "Ready",
			Status:             metav1.ConditionFalse,
			Reason:             "RayUnhealthy",
			Message:            errMsg,
			LastTransitionTime: now,
		})

		// Emit warning event
		b.Recorder.Event(p, corev1.EventTypeWarning, "RayServiceError",
			fmt.Sprintf("Failed to get Ray status: %v", err))

		telemetry.ObserveReconcileError(ctx, "ray_snapshot")
		return err
	}

	// Collect detailed Ray errors
	rayErrors := raystatus.ExtractRayErrors(ctx, b.Client, p.Namespace, p.Name)
	if rayErrors.HasError {
		logger.Info("Ray errors detected", "summary", rayErrors.Summary)

		// Emit warning event with summary (only once per unique error)
		b.Recorder.Event(p, corev1.EventTypeWarning, "RayComponentErrors", rayErrors.Summary)

		// Log detailed errors for troubleshooting
		if len(rayErrors.ServiceErrors) > 0 {
			logger.Info("RayService errors", "errors", rayErrors.ServiceErrors)
		}
		if len(rayErrors.ApplicationErrors) > 0 {
			logger.Info("Ray application errors", "errors", rayErrors.ApplicationErrors)
			// Emit consolidated event for application errors (avoid spam)
			if len(rayErrors.ApplicationErrors) == 1 {
				for appName, appError := range rayErrors.ApplicationErrors {
					b.Recorder.Eventf(p, corev1.EventTypeWarning, "RayApplicationError",
						"Application %s: %s", appName, appError)
					break
				}
			} else {
				appNames := []string{}
				for appName := range rayErrors.ApplicationErrors {
					appNames = append(appNames, appName)
					if len(appNames) >= 3 {
						break
					}
				}
				b.Recorder.Eventf(p, corev1.EventTypeWarning, "RayApplicationErrors",
					"%d applications failing: %v (see logs for details)", len(rayErrors.ApplicationErrors), appNames)
			}
		}
		if len(rayErrors.ClusterErrors) > 0 {
			logger.Info("RayCluster errors", "errors", rayErrors.ClusterErrors)
		}
		if len(rayErrors.PodErrors) > 0 {
			logger.Info("Ray pod errors", "count", len(rayErrors.PodErrors), "errors", rayErrors.PodErrors)
		}
	}

	if snap.HeadServiceName != "" {
		p.Status.RayServiceName = snap.HeadServiceName
	}
	// keep a textual status, reflect Running when rsReady:
	rsReady := snap.ServiceReady || snap.ServiceStatusRunning
	if rsReady {
		p.Status.RayServiceStatus = "Running"
	} else {
		p.Status.RayServiceStatus = "Pending"
	}

	now := metav1.NewTime(time.Now())
	set := func(t, reason, msg string, ok bool) {
		meta.SetStatusCondition(&p.Status.Conditions, metav1.Condition{
			Type:               t,
			Status:             boolToCond(ok),
			Reason:             reason,
			Message:            msg,
			LastTransitionTime: now,
		})
	}

	// Helper to check if condition status changed
	getConditionStatus := func(condType string) metav1.ConditionStatus {
		for _, cond := range p.Status.Conditions {
			if cond.Type == condType {
				return cond.Status
			}
		}
		return metav1.ConditionUnknown
	}

	// RayService readiness (prefer Conditions; fallback to ServiceStatus)
	rayServiceMsg := fmt.Sprintf("UpgradeInProgress=%t", snap.UpgradeInProgress)
	if !rsReady && rayErrors.HasError && len(rayErrors.ServiceErrors) > 0 {
		rayServiceMsg = rayErrors.ServiceErrors[0]
	}

	// Only emit event if state changed
	prevRSReady := getConditionStatus("RayServiceReady")
	if rsReady && prevRSReady != metav1.ConditionTrue {
		b.Recorder.Event(p, corev1.EventTypeNormal, "RayServiceReady", "RayService is ready and running")
	} else if !rsReady && prevRSReady == metav1.ConditionTrue {
		b.Recorder.Event(p, corev1.EventTypeWarning, "RayServiceNotReady", rayServiceMsg)
	}

	set("RayServiceReady",
		map[bool]string{true: "Ready", false: "NotReady"}[rsReady],
		rayServiceMsg,
		rsReady,
	)

	// Upgrade status
	set("RayServiceUpgradeInProgress",
		map[bool]string{true: "Upgrading", false: "Idle"}[snap.UpgradeInProgress],
		"Zero-downtime upgrade status as reported by KubeRay",
		snap.UpgradeInProgress,
	)

	// Endpoint discovery (map[string]string on RayClusterStatus.Endpoints)
	hasEndpoints := len(snap.EndpointMap) > 0
	set("RayEndpointsDiscovered",
		map[bool]string{true: "Found", false: "Missing"}[hasEndpoints],
		fmt.Sprintf("keys=%v", keysOf(snap.EndpointMap)),
		hasEndpoints,
	)

	// Cluster readiness: head ready AND all workers ready (tune if you want thresholds)
	clusterReady := snap.HeadPodReady && snap.DesiredWorkerReplicas == snap.AvailableWorkerReplicas
	clusterMsg := fmt.Sprintf("workers %d/%d headReady=%t", snap.AvailableWorkerReplicas, snap.DesiredWorkerReplicas, snap.HeadPodReady)
	if !clusterReady && rayErrors.HasError && len(rayErrors.ClusterErrors) > 0 {
		clusterMsg = fmt.Sprintf("%s; %s", clusterMsg, rayErrors.ClusterErrors[0])
	}

	// Only emit event if state changed
	prevClusterReady := getConditionStatus("RayClusterReady")
	if clusterReady && prevClusterReady != metav1.ConditionTrue {
		b.Recorder.Event(p, corev1.EventTypeNormal, "RayClusterReady", "Ray cluster pods are ready")
	} else if !clusterReady && prevClusterReady == metav1.ConditionTrue {
		b.Recorder.Event(p, corev1.EventTypeWarning, "RayClusterNotReady", clusterMsg)
	}

	set("RayClusterReady",
		map[bool]string{true: "AllPodsReady", false: "PodsNotReady"}[clusterReady],
		clusterMsg,
		clusterReady,
	)

	// Serve route (is the k8s Service backed by endpoints?)
	serveMsg := fmt.Sprintf("service=%s backed=%t", snap.ServeServiceName, snap.ServeServiceHasBackend)
	if !snap.ServeServiceHasBackend && rayErrors.HasError && len(rayErrors.ApplicationErrors) > 0 {
		// Add first application error to message
		for _, appErr := range rayErrors.ApplicationErrors {
			serveMsg = fmt.Sprintf("%s; %s", serveMsg, appErr)
			break
		}
	}

	// Only emit event if state changed
	prevServeReady := getConditionStatus("RayServeRouteReady")
	if snap.ServeServiceHasBackend && prevServeReady != metav1.ConditionTrue {
		b.Recorder.Event(p, corev1.EventTypeNormal, "RayServeReady", "Ray Serve applications are ready")
	} else if !snap.ServeServiceHasBackend && prevServeReady == metav1.ConditionTrue {
		b.Recorder.Event(p, corev1.EventTypeWarning, "RayServeNotReady", serveMsg)
	}

	set("RayServeRouteReady",
		map[bool]string{true: "EndpointsAvailable", false: "NoEndpoints"}[snap.ServeServiceHasBackend],
		serveMsg,
		snap.ServeServiceHasBackend,
	)

	// Check Weaviate status
	weaviateErrors := raystatus.ExtractWeaviateErrors(ctx, b.Client, p.Namespace, p.Name)
	weaviateReady := !weaviateErrors.HasError
	weaviateMsg := "Weaviate database is running"
	if weaviateErrors.HasError {
		weaviateMsg = weaviateErrors.Summary
		logger.Info("Weaviate errors detected", "summary", weaviateErrors.Summary)

		if len(weaviateErrors.PodErrors) > 0 {
			logger.Info("Weaviate pod errors", "errors", weaviateErrors.PodErrors)
		}
	}

	// Only emit event if state changed
	prevWeaviateReady := getConditionStatus("WeaviateDatabaseReady")
	if weaviateReady && prevWeaviateReady != metav1.ConditionTrue {
		b.Recorder.Event(p, corev1.EventTypeNormal, "WeaviateReady", "Weaviate database is ready")
	} else if !weaviateReady && prevWeaviateReady == metav1.ConditionTrue {
		b.Recorder.Event(p, corev1.EventTypeWarning, "WeaviateNotReady", weaviateErrors.Summary)
	}

	set("WeaviateDatabaseReady",
		map[bool]string{true: "Ready", false: "NotReady"}[weaviateReady],
		weaviateMsg,
		weaviateReady,
	)

	// Top-level Ready rollup
	platformReady := rsReady && clusterReady && snap.ServeServiceHasBackend && weaviateReady
	readyMsg := "All components healthy: Ray, RayServe, and Weaviate"
	if !platformReady {
		failedComponents := []string{}
		if !rsReady {
			failedComponents = append(failedComponents, "RayService")
		}
		if !clusterReady {
			failedComponents = append(failedComponents, "RayCluster")
		}
		if !snap.ServeServiceHasBackend {
			failedComponents = append(failedComponents, "RayServe")
		}
		if !weaviateReady {
			failedComponents = append(failedComponents, "Weaviate")
		}
		readyMsg = fmt.Sprintf("Degraded components: %v", failedComponents)
	}

	// Only emit event if overall platform state changed
	prevPlatformReady := getConditionStatus("Ready")
	if platformReady && prevPlatformReady != metav1.ConditionTrue {
		b.Recorder.Event(p, corev1.EventTypeNormal, "PlatformReady", "AI Platform is fully ready")
	} else if !platformReady && prevPlatformReady == metav1.ConditionTrue {
		b.Recorder.Eventf(p, corev1.EventTypeWarning, "PlatformDegraded", "Platform degraded: %v", readyMsg)
	}

	set("Ready",
		map[bool]string{true: "AllHealthy", false: "Degraded"}[platformReady],
		readyMsg,
		platformReady,
	)

	telemetry.SetCondition(ctx, "RayServiceReady", string(boolToCond(rsReady)))
	telemetry.SetCondition(ctx, "RayClusterReady", string(boolToCond(clusterReady)))
	telemetry.SetCondition(ctx, "RayServeRouteReady", string(boolToCond(snap.ServeServiceHasBackend)))
	telemetry.SetDesiredReplicas(ctx, snap.DesiredWorkerReplicas)
	telemetry.SetReadyReplicas(ctx, snap.AvailableWorkerReplicas)

	return nil
}

// Build constructs a RayService resource based on the AI CR.
func (b *Builder) Build(ctx context.Context) (*rayv1.RayService, error) {
	rayclusterSpec, err := b.buildClusterConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to build cluster config: %w", err)
	}
	rs := &rayv1.RayService{
		ObjectMeta: metav1.ObjectMeta{
			Name:        b.ai.Name,
			Namespace:   b.ai.Namespace,
			Annotations: b.ai.Annotations,
			Labels:      b.ai.Labels,
		},
		Spec: rayv1.RayServiceSpec{
			RayClusterSpec: *rayclusterSpec,
		},
	}
	return rs, nil
}

func (b *Builder) buildClusterConfig(ctx context.Context) (*rayv1.RayClusterSpec, error) {
	acceleratorType := b.effectiveAcceleratorType()
	annotations, labels := buildHeadAnnotationsAndLabels(b.ai)
	head := rayv1.HeadGroupSpec{
		RayStartParams: map[string]string{
			"dashboard-host": "0.0.0.0",
			"num-cpus":       "0",
		},
		HeadService: &corev1.Service{
			ObjectMeta: metav1.ObjectMeta{
				Name:        b.ai.Name + "-head-svc",
				Namespace:   b.ai.Namespace,
				Annotations: annotations,
				Labels:      labels,
			},
		},
		Template: b.makeHeadTemplate(),
	}

	head.Template.ObjectMeta.Annotations = annotations
	head.Template.ObjectMeta.Labels = labels

	instanceFile := os.Getenv("INSTANCE_FILE")
	if instanceFile == "" {
		instanceFile = "instance.yaml" // default when INSTANCE_FILE is unset (local/test runs)
	}
	instanceYamlFile, err := os.ReadFile(instanceFile)
	if err != nil {
		return nil, fmt.Errorf("error reading YAML file: %v", err)
	}

	var instanceMap WorkerConfigs
	// must use sigs.k8s.io/yaml , stdlib yaml doesn't understand corev1
	if err := k8syaml.UnmarshalStrict(instanceYamlFile, &instanceMap); err != nil {
		return nil, fmt.Errorf("error reading YAML file: %v", err)
	}

	// Build the GPU worker-pool sizing from the global worker-scale.yaml,
	// scaled by the same platform-wide scaleFactor used for Serve replicas so
	// the worker pool grows in lockstep with the replicas it must schedule on
	// the shared, fixed GPU pool.
	workerScale, err := loadScaleConfig("WORKER_SCALE_FILE", "worker-scale.yaml")
	if err != nil {
		return nil, err
	}
	scaleFactor := b.effectiveScaleFactor()

	// initialize instanceScale to avoid nil map assignment panic
	instanceScale := make(map[string]int32)
	for k, val := range workerScale.InstanceScale[acceleratorType] {
		instanceScale[k] = val * scaleFactor
	}

	var workers []rayv1.WorkerGroupSpec
	gpuConfigs := instanceMap[acceleratorType]
	if len(gpuConfigs) == 0 {
		return nil, fmt.Errorf("instance.yaml has no worker tiers for defaultAcceleratorType %q; keys must match exactly (e.g. L40S, H100_NVL)", acceleratorType)
	}
	for _, cfg := range gpuConfigs {
		annotations, labels := buildWorkerAnnotationsAndLabels(b.ai, cfg)

		cpuLimit := cfg.Resources.Limits[corev1.ResourceCPU]
		replicas := instanceScale[cfg.Tier]

		maxReplicas := replicas + 5
		if cfg.GPUsPerPod > 0 {
			maxReplicas = replicas
		}

		wg := rayv1.WorkerGroupSpec{
			GroupName:   cfg.Tier,
			Replicas:    int32Ptr(replicas),
			MinReplicas: int32Ptr(replicas),
			MaxReplicas: int32Ptr(maxReplicas),
			RayStartParams: map[string]string{
				"num-cpus":  cpuLimit.String(),
				"resources": fmt.Sprintf(`"{\"accelerator_type:%s\":1,\"gpu_count:%d\":1}"`, acceleratorType, cfg.GPUsPerPod),
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Annotations: annotations,
					Labels:      labels,
				},
				Spec: b.makeWorkerTemplate(cfg).Spec,
			},
		}
		workers = append(workers, wg)
	}

	idleTimeout := int32Ptr(600)
	return &rayv1.RayClusterSpec{
		RayVersion:              os.Getenv("RAY_VERSION"),
		EnableInTreeAutoscaling: boolPtr(true),
		AutoscalerOptions:       &rayv1.AutoscalerOptions{IdleTimeoutSeconds: idleTimeout},
		HeadGroupSpec:           head,
		WorkerGroupSpecs:        workers,
	}, nil
}

// objectStorageSecretEnv returns env vars for S3COMPAT_OBJECT_STORE_ACCESS_KEY and S3COMPAT_OBJECT_STORE_SECRET_KEY from
// the objectStorage secret (s3_access_key/s3_secret_key) for S3-compatible object storage.
func (b *Builder) objectStorageSecretEnv() []corev1.EnvVar {
	if b.ai.Spec.ObjectStorage.SecretRef == "" {
		return nil
	}
	secretName := b.ai.Spec.ObjectStorage.SecretRef
	return []corev1.EnvVar{
		{
			Name: "S3COMPAT_OBJECT_STORE_ACCESS_KEY",
			ValueFrom: &corev1.EnvVarSource{
				SecretKeyRef: &corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: secretName},
					Key:                  "s3_access_key",
				},
			},
		},
		{
			Name: "S3COMPAT_OBJECT_STORE_SECRET_KEY",
			ValueFrom: &corev1.EnvVarSource{
				SecretKeyRef: &corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: secretName},
					Key:                  "s3_secret_key",
				},
			},
		},
	}
}

// rayS3DownloadEnv sets AWS_* variables so application code and Ray's runtime_env S3 fetch use the
// configured S3-compatible endpoint (via AWS_ENDPOINT_URL) and credentials when present.
func (b *Builder) rayS3DownloadEnv() []corev1.EnvVar {
	u, err := url.Parse(b.ai.Spec.ObjectStorage.Path)
	if err != nil {
		return nil
	}
	endpoint := strings.TrimSpace(b.ai.Spec.ObjectStorage.Endpoint)
	s3CompatScheme := u.Scheme == "s3compat" || u.Scheme == "minio" || u.Scheme == "seaweedfs"
	s3WithCustomEndpoint := u.Scheme == "s3" && endpoint != ""
	if (!s3CompatScheme && !s3WithCustomEndpoint) || endpoint == "" {
		return nil
	}
	var out []corev1.EnvVar
	out = append(out, corev1.EnvVar{Name: "AWS_ENDPOINT_URL", Value: endpoint})
	if r := strings.TrimSpace(b.ai.Spec.ObjectStorage.Region); r != "" {
		out = append(out,
			corev1.EnvVar{Name: "AWS_DEFAULT_REGION", Value: r},
			corev1.EnvVar{Name: "AWS_REGION", Value: r},
		)
	}
	if b.ai.Spec.ObjectStorage.SecretRef == "" {
		return out
	}
	sn := b.ai.Spec.ObjectStorage.SecretRef
	out = append(out,
		corev1.EnvVar{
			Name: "AWS_ACCESS_KEY_ID",
			ValueFrom: &corev1.EnvVarSource{
				SecretKeyRef: &corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: sn},
					Key:                  "s3_access_key",
				},
			},
		},
		corev1.EnvVar{
			Name: "AWS_SECRET_ACCESS_KEY",
			ValueFrom: &corev1.EnvVarSource{
				SecretKeyRef: &corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: sn},
					Key:                  "s3_secret_key",
				},
			},
		},
	)
	return out
}

func (b *Builder) makeHeadTemplate() corev1.PodTemplateSpec {
	headEnv := []corev1.EnvVar{
		{Name: "DEFAULT_GPU_TYPE", Value: b.effectiveAcceleratorType()},
		{Name: "CLUSTER_NAME", Value: "ai-platform-models"}, // FIXME
	}
	headEnv = append(headEnv, b.rayS3DownloadEnv()...)
	headEnv = append(headEnv, b.objectStorageSecretEnv()...)
	spec := corev1.PodSpec{
		Containers: []corev1.Container{{
			Name:            "ray-head",
			Image:           SetImageRegistry("RELATED_IMAGE_RAY_HEAD", b.ai.Spec.Images.RayHeadGroupImage),
			ImagePullPolicy: corev1.PullIfNotPresent,
			Args: []string{
				"ulimit -n 65536; echo head; $KUBERAY_GEN_RAY_START_CMD",
			},
			Command: []string{
				"/bin/bash",
				"-lc",
				"--",
			},
			Env: headEnv,
			Lifecycle: &corev1.Lifecycle{
				PreStop: &corev1.LifecycleHandler{
					Exec: &corev1.ExecAction{
						Command: []string{
							"/bin/sh",
							"-c",
							"ray stop",
						},
					},
				},
			},
			Ports: []corev1.ContainerPort{
				{
					ContainerPort: 6379,
					Name:          "gcs-server",
					Protocol:      corev1.ProtocolTCP,
				},
				{
					ContainerPort: 8265,
					Name:          "dashboard",
					Protocol:      corev1.ProtocolTCP,
				},
				{
					ContainerPort: 10001,
					Name:          "client",
					Protocol:      corev1.ProtocolTCP,
				},
				{
					ContainerPort: 8000,
					Name:          "serve",
					Protocol:      corev1.ProtocolTCP,
				},
			},
			Resources: corev1.ResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceCPU:              resource.MustParse("1"),
					corev1.ResourceMemory:           resource.MustParse("4Gi"),
					corev1.ResourceEphemeralStorage: resource.MustParse("5Gi"),
					"nvidia.com/gpu":                resource.MustParse("0"),
				},
				Limits: corev1.ResourceList{
					corev1.ResourceCPU:              resource.MustParse("4"),
					corev1.ResourceMemory:           resource.MustParse("16Gi"),
					corev1.ResourceEphemeralStorage: resource.MustParse("10Gi"),
					"nvidia.com/gpu":                resource.MustParse("0"),
				},
			},
			VolumeMounts: []corev1.VolumeMount{
				{
					MountPath: "/tmp/ray",
					Name:      "ray-logs",
				},
			},
		}},
	}

	spec.NodeSelector = b.ai.Spec.CPUSchedulingSpec.NodeSelector
	spec.Tolerations = b.ai.Spec.CPUSchedulingSpec.Tolerations
	spec.Affinity = b.ai.Spec.CPUSchedulingSpec.Affinity
	spec.ServiceAccountName = b.ai.Spec.ServiceAccountName
	// Propagate imagePullSecrets from AIPlatform spec
	spec.ImagePullSecrets = b.ai.Spec.Images.ImagePullSecrets
	// FIXME need to find better way to add sidecars
	return corev1.PodTemplateSpec{Spec: spec}
}

func (b *Builder) makeWorkerTemplate(cfg InstanceDetail) corev1.PodTemplateSpec {
	defaultEnv := []corev1.EnvVar{
		{Name: "DEFAULT_GPU_TYPE", Value: b.effectiveAcceleratorType()},
		{Name: "RAY_HEAD_SERVICE_HOST", Value: fmt.Sprintf("%s.%s.svc.%s", b.ai.Name+"-head-svc", b.ai.Namespace, os.Getenv("CLUSTER_DOMAIN"))},
		{Name: "SERVICE_NAME", Value: b.ai.Name},
		{Name: "SERVICE_INTERNAL_NAME", Value: b.ai.Name},
		{Name: "USE_SYSTEM_PERMISSIONS", Value: "true"},
		{Name: "GPG_PUBLICKEY_PATH", Value: "kv-splunk/al-platform.ray-worker-sa/gpgkey"}, // FIXME
		{Name: "GPU_TYPE", Value: b.effectiveAcceleratorType()},                           // FIXME
	}

	// Combine defaultEnv with cfg.Env to create combinedEnv
	combinedEnv := make([]corev1.EnvVar, len(defaultEnv))
	copy(combinedEnv, defaultEnv)

	// Add cfg.Env entries, cfg.Env values override defaultEnv if same key exists
	for key, value := range cfg.Env {
		found := false
		for i, envVar := range combinedEnv {
			if envVar.Name == key {
				combinedEnv[i].Value = value
				found = true
				break
			}
		}
		if !found {
			combinedEnv = append(combinedEnv, corev1.EnvVar{Name: key, Value: value})
		}
	}
	// S3-compatible: boto3 for Ray runtime_env working_dir + app-level S3COMPAT_* keys
	combinedEnv = append(combinedEnv, b.rayS3DownloadEnv()...)
	combinedEnv = append(combinedEnv, b.objectStorageSecretEnv()...)
	rayCommand := fmt.Sprintf(`echo %s worker;
        ulimit -n 65536;
    	export PATH="/home/ray/anaconda3/bin:$PATH";
        KUBERAY_GEN_RAY_START_CMD=$(echo $KUBERAY_GEN_RAY_START_CMD | sed -e 's/"{/{/g' -e 's/}"/}/g' -e 's/\\\"/"/g');
        $KUBERAY_GEN_RAY_START_CMD`, cfg.Tier)
	spec := corev1.PodSpec{
		Affinity:           b.ai.Spec.GPUSchedulingSpec.Affinity,
		Tolerations:        b.ai.Spec.GPUSchedulingSpec.Tolerations,
		NodeSelector:       b.ai.Spec.GPUSchedulingSpec.NodeSelector,
		ServiceAccountName: b.ai.Spec.WorkerGroupConfig.ServiceAccountName,
		Containers: []corev1.Container{{
			Name:            "ray-worker",
			Image:           SetImageRegistry("RELATED_IMAGE_RAY_WORKER", b.ai.Spec.WorkerGroupConfig.ImageRegistry),
			ImagePullPolicy: corev1.PullIfNotPresent,
			Command: []string{
				"/bin/bash",
				"-lc",
				"--",
			},
			Args: []string{
				rayCommand,
			},
			Env: combinedEnv,
			Lifecycle: &corev1.Lifecycle{
				PreStop: &corev1.LifecycleHandler{
					Exec: &corev1.ExecAction{
						Command: []string{
							"/bin/sh",
							"-c",
							"ray stop",
						},
					},
				},
			},
			Resources: cfg.Resources,
			VolumeMounts: []corev1.VolumeMount{
				{
					MountPath: "/tmp/ray",
					Name:      "ray-logs",
				},
			},
			Ports: []corev1.ContainerPort{
				{
					ContainerPort: 8080,
					Name:          "metrics",
					Protocol:      corev1.ProtocolTCP,
				},
			},
		},
		},
	}

	// apply scheduling
	spec.NodeSelector = b.ai.Spec.GPUSchedulingSpec.NodeSelector
	spec.Tolerations = b.ai.Spec.GPUSchedulingSpec.Tolerations
	spec.Affinity = b.ai.Spec.GPUSchedulingSpec.Affinity

	// Propagate imagePullSecrets from AIPlatform spec
	spec.ImagePullSecrets = b.ai.Spec.Images.ImagePullSecrets

	found := false
	for _, vol := range spec.Volumes {
		if vol.Name == "ray-logs" {
			found = true
			break
		}
	}

	if !found {
		spec.Volumes = append(spec.Volumes, corev1.Volume{
			Name: "ray-logs",
			VolumeSource: corev1.VolumeSource{
				EmptyDir: &corev1.EmptyDirVolumeSource{},
			},
		})
	}

	return corev1.PodTemplateSpec{Spec: spec}
}

func SetImageRegistry(key, defaultValue string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultValue
}

func buildWorkerAnnotationsAndLabels(aiPlatform *enterpriseApi.AIPlatform, cfg InstanceDetail) (map[string]string, map[string]string) {
	annotations := make(map[string]string)
	labels := make(map[string]string)

	// Example: propagate tier and GPU type as labels/annotations
	annotations["gpu-tier"] = cfg.Tier
	labels["gpu-tier"] = cfg.Tier
	if aiPlatform.Annotations != nil {
		for k, v := range aiPlatform.Annotations {
			if strings.Contains(k, "last-applied-configuration") {
				continue
			}
			annotations[k] = v
		}
	}
	if aiPlatform.Labels != nil {
		for k, v := range aiPlatform.Labels {
			if strings.Contains(k, "last-applied-configuration") {
				continue
			}
			labels[k] = v
		}
	}
	annotations["prometheus.io/path"] = "/metrics"
	annotations["prometheus.io/port"] = "8080"
	annotations["prometheus.io/scheme"] = "http"
	annotations["ray.io/overwrite-container-cmd"] = "true"
	splunkEnabled := aiPlatform.Spec.SplunkConfiguration.Endpoint != "" ||
		aiPlatform.Spec.SplunkConfiguration.SplunkCustomResourceRef.Name != ""
	if aiPlatform.Spec.Sidecars.Otel && splunkEnabled {
		annotations["sidecar.opentelemetry.io/inject"] = fmt.Sprintf("%s-otel-coll", aiPlatform.Name)
		annotations["sidecar.opentelemetry.io/auto-instrument"] = "true"
	}

	return annotations, labels
}

func buildHeadAnnotationsAndLabels(aiPlatform *enterpriseApi.AIPlatform) (map[string]string, map[string]string) {
	annotations := make(map[string]string)
	labels := make(map[string]string)

	// Example: propagate tier and GPU type as labels/annotations
	if aiPlatform.Annotations != nil {
		for k, v := range aiPlatform.Annotations {
			if strings.Contains(k, "last-applied-configuration") {
				continue
			}
			annotations[k] = v
		}
	}
	if aiPlatform.Labels != nil {
		for k, v := range aiPlatform.Labels {
			if strings.Contains(k, "last-applied-configuration") {
				continue
			}
			labels[k] = v
		}
	}
	annotations["prometheus.io/path"] = "/metrics"
	annotations["prometheus.io/port"] = "8080"
	annotations["prometheus.io/scheme"] = "http"
	annotations["ray.io/overwrite-container-cmd"] = "true"

	splunkEnabledHead := aiPlatform.Spec.SplunkConfiguration.Endpoint != "" ||
		aiPlatform.Spec.SplunkConfiguration.SplunkCustomResourceRef.Name != ""
	if aiPlatform.Spec.Sidecars.Otel && splunkEnabledHead {
		annotations["sidecar.opentelemetry.io/inject"] = fmt.Sprintf("%s-otel-coll", aiPlatform.Name)
		annotations["sidecar.opentelemetry.io/auto-instrument"] = "true"
	}

	return annotations, labels
}

// boolPtr returns a pointer to the given boolean value.
func boolPtr(b bool) *bool {
	return &b
}

func int32Ptr(i int32) *int32 {
	return &i
}

func keysOf(m map[string]string) []string {
	if len(m) == 0 {
		return nil
	}
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func boolToCond(b bool) metav1.ConditionStatus {
	if b {
		return metav1.ConditionTrue
	}
	return metav1.ConditionFalse
}

// cleanRayServiceSpec removes server-generated metadata fields from RayService spec
// to prevent "unknown field" warnings when updating RayService resources.
func cleanRayServiceSpec(spec *rayv1.RayServiceSpec) {
	if spec == nil {
		return
	}

	// Clean headGroupSpec
	if spec.RayClusterSpec.HeadGroupSpec.Template.ObjectMeta.CreationTimestamp != (metav1.Time{}) {
		spec.RayClusterSpec.HeadGroupSpec.Template.ObjectMeta.CreationTimestamp = metav1.Time{}
	}
	if spec.RayClusterSpec.HeadGroupSpec.HeadService != nil {
		cleanServiceMetadata(&spec.RayClusterSpec.HeadGroupSpec.HeadService.ObjectMeta)
	}

	// Clean workerGroupSpecs
	for i := range spec.RayClusterSpec.WorkerGroupSpecs {
		if spec.RayClusterSpec.WorkerGroupSpecs[i].Template.ObjectMeta.CreationTimestamp != (metav1.Time{}) {
			spec.RayClusterSpec.WorkerGroupSpecs[i].Template.ObjectMeta.CreationTimestamp = metav1.Time{}
		}
	}
}

// cleanServiceMetadata removes server-generated fields from ObjectMeta
func cleanServiceMetadata(meta *metav1.ObjectMeta) {
	if meta == nil {
		return
	}
	meta.CreationTimestamp = metav1.Time{}
	meta.DeletionTimestamp = nil
	meta.DeletionGracePeriodSeconds = nil
	meta.UID = ""
	meta.ResourceVersion = ""
	meta.Generation = 0
	meta.SelfLink = ""
	meta.ManagedFields = nil
}
