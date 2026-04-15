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
	"path/filepath"
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
	S3CompatObjectStoreEndpointUrl string           `yaml:"S3COMPAT_OBJECT_STORE_ENDPOINT_URL"`
	S3CompatObjectStoreAccessKey   string           `yaml:"S3COMPAT_OBJECT_STORE_ACCESS_KEY"`
	S3CompatObjectStoreSecretKey   string           `yaml:"S3COMPAT_OBJECT_STORE_SECRET_KEY"`
	Replicas                       map[string]int32 `yaml:"REPLICAS"`
	WorkingDirBase                 string           `yaml:"WORKING_DIR_BASE"`
	ModelVersion                   string           `yaml:"MODEL_VERSION"`
	AcceleratorType                string           `yaml:"ACCELERATOR_TYPE"`
}

type WorkerConfigs map[string][]InstanceDetail

type InstanceDetail struct {
	Tier       string                      `yaml:"tier"`
	GPUsPerPod int32                       `yaml:"gpusPerPod"`
	Env        map[string]string           `yaml:"env,omitempty"`
	Resources  corev1.ResourceRequirements `yaml:"resources"`
}

type FeatureConfig struct {
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

// rayWorkingDirBase builds the base URI for runtime_env.working_dir application zips.
//
// Ray's Serve config rejects plain http:// for remote working_dir URIs; allowed schemes include
// s3 and https. We always use s3:// for S3 and S3-compatible backends (AWS, MinIO, SeaweedFS, etc.).
// Ray pods receive AWS_ENDPOINT_URL plus AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (when applicable)
// from rayS3DownloadEnv; modern boto3/botocore honor AWS_ENDPOINT_URL for the S3 client used to
// fetch runtime_env packages.
//
// For GCS we use gs:// (scheme may be gs or gcs in objectStorage.path).
func rayWorkingDirBase(scheme, bucket string) string {
	switch strings.ToLower(scheme) {
	case "s3", "s3compat", "minio", "seaweedfs":
		return fmt.Sprintf("s3://%s/ray-services/ai-platform/applications", bucket)
	case "gs", "gcs":
		return fmt.Sprintf("gs://%s/ray-services/ai-platform/applications", bucket)
	default:
		return fmt.Sprintf("%s://%s/ray-services/ai-platform/applications", scheme, bucket)
	}
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

	// Set CloudProvider and artifacts provider/bucket from URL scheme (for SDK model loaders).
	// ARTIFACTS_PROVIDER matches storage client GetProvider(): s3/minio/seaweedfs/s3compat -> "s3", gs/gcs -> "gcs", azure -> "azure".
	// S3 (AWS) uses cloudProvider "aws" when no custom endpoint; s3compat/minio/seaweedfs use "s3compat".
	var cloudProvider, artifactsProvider string
	switch u.Scheme {
	case "s3":
		if p.Spec.ObjectStorage.Endpoint != "" {
			cloudProvider = "s3compat"
		} else {
			cloudProvider = "aws"
		}
		artifactsProvider = "s3"
	case "s3compat", "minio", "seaweedfs":
		cloudProvider = "s3compat"
		artifactsProvider = "s3"
	case "gs", "gcs":
		cloudProvider = "gcp"
		artifactsProvider = "gcs"
	case "azure":
		cloudProvider = "azure"
		artifactsProvider = "azure"
	default:
		cloudProvider = "azure"
		artifactsProvider = "azure"
	}

	// Initialize the replicas map by iterating through features
	replicasMap := make(map[string]int32)

	for _, feature := range p.Spec.Features {
		// Read YAML file for this feature
		fileName := filepath.Join("features", feature.Name+".yaml")
		yamlData, err := os.ReadFile(fileName)
		if err != nil {
			logger.Error(err, "Failed to read feature YAML file", "feature", feature.Name, "file", fileName)
			continue
		}

		// Parse the YAML content into a map
		var featureConfig FeatureConfig
		err = yaml.UnmarshalStrict(yamlData, &featureConfig)
		if err != nil {
			logger.Error(err, "Failed to parse feature YAML", "feature", feature.Name, "file", fileName)
			continue
		}

		// Calculate replicas multiplier from feature.Replicas (nil means auto => 1)
		var multiplier int32 = 1
		if feature.ScaleFactor != nil {
			// Validation guarantees value >= 1
			multiplier = *feature.ScaleFactor
		}
		// Use V(1) for verbose debug logging - only shown with --zap-log-level=debug
		logger.V(1).Info("Loaded feature configuration", "feature", feature.Name, "scaleFactor", multiplier)

		// Generate map from product of values and feature's Replicas setting
		for appName, baseReplicas := range featureConfig.ApplicationScale {
			replicasMap[appName] = baseReplicas * multiplier
		}
	}

	// S3-compatible backends (s3compat, minio, seaweedfs) need custom endpoint and credentials. S3 (AWS) uses region/IRSA only.
	s3CompatScheme := (u.Scheme == "s3compat" || u.Scheme == "minio" || u.Scheme == "seaweedfs")
	s3CompatObjectStoreEndpoint := ""
	if s3CompatScheme && p.Spec.ObjectStorage.Endpoint != "" {
		s3CompatObjectStoreEndpoint = p.Spec.ObjectStorage.Endpoint
	}

	var s3CompatObjectStoreAccessKey, s3CompatObjectStoreSecretKey string
	if p.Spec.ObjectStorage.SecretRef != "" && s3CompatScheme {
		var secret corev1.Secret
		secretRef := types.NamespacedName{Namespace: p.Namespace, Name: p.Spec.ObjectStorage.SecretRef}
		if err := b.Get(ctx, secretRef, &secret); err != nil {
			logger.Error(err, "Failed to get object storage secret for S3-compatible credentials", "secret", p.Spec.ObjectStorage.SecretRef)
			return err
		}
		if raw, ok := secret.Data["s3_access_key"]; ok {
			s3CompatObjectStoreAccessKey = string(raw)
		}
		if raw, ok := secret.Data["s3_secret_key"]; ok {
			s3CompatObjectStoreSecretKey = string(raw)
		}
	}

	// Build working_dir base (s3:// or gs://; see rayWorkingDirBase).
	workingDirBase := rayWorkingDirBase(u.Scheme, u.Host)

	param := ApplicationParams{
		ArtifactBucketName:             u.Host,
		ArtifactsProvider:              artifactsProvider,
		CloudProvider:                  cloudProvider,
		S3CompatObjectStoreEndpointUrl: s3CompatObjectStoreEndpoint,
		S3CompatObjectStoreAccessKey:   s3CompatObjectStoreAccessKey,
		S3CompatObjectStoreSecretKey:   s3CompatObjectStoreSecretKey,
		Replicas:                       replicasMap,
		WorkingDirBase:                 workingDirBase,
		ModelVersion:                   os.Getenv("MODEL_VERSION"),
		AcceleratorType:                b.effectiveAcceleratorType(),
	}

	// Use embedded applications.yaml content
	applicationFile := os.Getenv("APPLICATION_FILE")
	if applicationFile == "" {
		applicationFile = "applications.yaml" // fallback for backward compatibility
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
		instanceFile = "instance.yaml" // fallback for backward compatibility
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

	// initialize instanceScale to avoid nil map assignment panic
	instanceScale := make(map[string]int32)
	for _, feature := range b.ai.Spec.Features {
		// Read YAML file for this feature
		fileName := filepath.Join("features", feature.Name+".yaml")
		yamlData, err := os.ReadFile(fileName)
		if err != nil {
			return nil, fmt.Errorf("failed to read feature YAML file %s: %v", feature.Name, err)

		}
		var featureConfig FeatureConfig
		err = yaml.UnmarshalStrict(yamlData, &featureConfig)
		if err != nil {
			return nil, fmt.Errorf("failed to parse feature YAML file %s: %v", fileName, err)
		}
		for k, val := range featureConfig.InstanceScale[acceleratorType] {
			old_val, ok := instanceScale[k]
			if ok {
				instanceScale[k] = old_val + val
			} else {
				instanceScale[k] = val
			}
		}
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
					corev1.ResourceMemory:           resource.MustParse("2Gi"),
					corev1.ResourceEphemeralStorage: resource.MustParse("5Gi"),
					"nvidia.com/gpu":                resource.MustParse("0"),
				},
				Limits: corev1.ResourceList{
					corev1.ResourceCPU:              resource.MustParse("4"),
					corev1.ResourceMemory:           resource.MustParse("8Gi"),
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
	if aiPlatform.Spec.Sidecars.Otel {
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

	if aiPlatform.Spec.Sidecars.Otel {
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
