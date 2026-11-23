package ai_platform

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"os"
	"strings"
	"time"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/credentials"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	featurecommon "github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	"github.com/splunk/splunk-ai-operator/pkg/ai/raybuilder"
	"github.com/splunk/splunk-ai-operator/pkg/ai/sidecars"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/validation/field"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const (
	agentRuntimeFeatureName       = "agentruntime"
	slimFeatureName               = "slim"
	agentRuntimeMetricsPort int32 = 9090
	maxDNSLabelLength             = 63
	ownerKey                      = ".metadata.controller"
)

type AIPlatformReconciler struct {
	p *aiApi.AIPlatform
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

func New(p *aiApi.AIPlatform, client client.Client, scheme *runtime.Scheme, recorder record.EventRecorder) *AIPlatformReconciler {
	return &AIPlatformReconciler{
		p:        p,
		Client:   client,
		Scheme:   scheme,
		Recorder: recorder,
	}
}

func (r *AIPlatformReconciler) Reconcile(ctx context.Context, p *aiApi.AIPlatform) (result reconcile.Result, retErr error) {
	before := p.DeepCopy().Status
	setCondition := func(kind string, status metav1.ConditionStatus, reason, message string) {
		// Preserve transition times and unrelated conditions so repeated child
		// observations can settle without producing further status events.
		meta.SetStatusCondition(&p.Status.Conditions, metav1.Condition{Type: kind, Status: status, Reason: reason, Message: message, ObservedGeneration: p.Generation})
	}
	defer func() {
		p.Status.ObservedGeneration = p.Generation
		p.Status.Profile = p.Spec.ResolvedProfile()
		if !equality.Semantic.DeepEqual(before, p.Status) {
			// Keep the resourceVersion from this observation. A conflict must cause
			// a fresh evaluation rather than copying old results onto a newer spec.
			retErr = errors.Join(retErr, r.Status().Update(ctx, p))
		}
	}()
	var scaleResult reconcile.Result
	stages := r.stagesFor(p, &scaleResult)

	for _, stage := range stages {
		err := stage.fn(ctx, p)
		if err != nil {
			var pending *agentRuntimeNotReadyError
			if errors.As(err, &pending) {
				// An unhealthy child is an observed waiting state, not a failed API
				// operation. Publish it and retry without error-driven backoff.
				setCondition(stage.name+"Ready", metav1.ConditionFalse, "AgentRuntimeNotReady", pending.Error())
				setCondition("Ready", metav1.ConditionFalse, "AgentRuntimeNotReady", pending.Error())
				return reconcile.Result{RequeueAfter: 5 * time.Second}, nil
			}
			setCondition(stage.name+"Ready", metav1.ConditionFalse, "Error", err.Error())
			setCondition("Ready", metav1.ConditionFalse, "ReconcileFailed", stage.name+" reconciliation has not completed")
			return reconcile.Result{}, err
		}
		setCondition(stage.name+"Ready", metav1.ConditionTrue, "Reconciled", "stage succeeded")
	}
	setCondition("Ready", metav1.ConditionTrue, "AllReconciled", "all stages completed successfully")
	return scaleResult, nil
}

// reconcileStage is one named step of the platform reconcile.
type reconcileStage struct {
	name string
	fn   func(context.Context, *aiApi.AIPlatform) error
}

// stagesFor returns the ordered reconcile stages for the platform's resolved
// profile.
//
// cpuOnly has no Ray, no vector database and no Ray-backed ingress, and its
// cluster has no KubeRay (or necessarily Prometheus operator) APIs, so it runs
// only the stages that create its feature services. The Sidecars stage is left
// out too: its monitoring resources are Ray-specific even when every sidecar
// flag is false, and cpuOnly rejects sidecars anyway.
//
// fullfeature (including an omitted or legacy "full" profile) keeps exactly the
// stage list it had before profiles existed.
func (r *AIPlatformReconciler) stagesFor(p *aiApi.AIPlatform, scaleResult *reconcile.Result) []reconcileStage {
	stages := []reconcileStage{{"Validate", r.validate}}
	if p.Spec.ResolvedProfile() == aiApi.AIPlatformProfileCPUOnly {
		return append(stages,
			reconcileStage{"AIService", r.ReconcileFeatures},
			reconcileStage{"AIServiceStatus", r.CheckAIServiceStatus},
		)
	}
	raybuilder := raybuilder.New(r.p, r.Client, r.Scheme, r.Recorder)
	sidecarBuilder := sidecars.New(r.Client, r.Scheme, r.Recorder, r.p)
	return append(stages, []reconcileStage{
		//{"ApplicationsConfigMap", raybuilder.ReconcileApplicationsConfigMap},
		//{"InstancesConfigMap", raybuilder.ReconcileInstancesConfigMap},
		//{"ServeConfigMap", raybuilder.ReconcileServeConfigMap},
		{"Sidecars", sidecarBuilder.Reconcile},
		{"rayAutoscalerRBAC", raybuilder.ReconcileRayAutoscalerRBAC},
		{"RayService", raybuilder.ReconcileRayService},
		{"ActiveClusterScale", func(ctx context.Context, p *aiApi.AIPlatform) error {
			var err error
			*scaleResult, err = raybuilder.ReconcileActiveClusterScale(ctx, p)
			return err
		}},
		{"WeaviateDatabase", r.ReconcileWeaviateDatabase},
		{"Ingress", r.ReconcileIngress},
		// collect status of each stage
		{"RayServiceStatus", raybuilder.ApplyNormalizedConditions},
		{"WeaviateDatabaseStatus", r.ReconcileWeaviateDatabaseStatus},
		{"IngressStatus", r.UpdateIngressStatus},
		{"AIService", r.ReconcileFeatures},
		{"AIServiceStatus", r.CheckAIServiceStatus},
	}...)
}

// ReconcileFeatures ensures each feature's AIService exists and is up to date.
func (r *AIPlatformReconciler) ReconcileFeatures(ctx context.Context, platform *aiApi.AIPlatform) error {
	log := log.FromContext(ctx)

	// Build the desired set of child service names
	desired := make(map[string]struct{}, len(platform.Spec.Features))

	for i, feature := range platform.Spec.Features {
		// Older objects may predate admission rules. Reject credential literals
		// before persisting a second copy in an operator-generated child.
		if feature.Name == agentRuntimeFeatureName {
			if errs := credentials.ValidatePostgresEnvironment(feature.Env, field.NewPath("spec", "features").Index(i).Child("env")); len(errs) > 0 {
				return errs.ToAggregate()
			}
		}
		serviceName := featureServiceName(platform.Name, feature)
		desired[serviceName] = struct{}{}

		// Prepare object with identity for CreateOrUpdate
		var svc aiApi.AIService
		svc.Name = serviceName
		svc.Namespace = platform.Namespace

		op, err := controllerutil.CreateOrUpdate(ctx, r.Client, &svc, func() error {
			// After client Get, svc holds the live AIService (empty on first create).
			preservedResources := svc.Spec.Resources
			// Preserve any direct `kubectl patch aiservice` edit of ServiceTemplate.
			// Without this, an admin who patches the public SAIA Service type
			// (e.g. to NodePort for browser-direct v2 traffic) would see their
			// change revert on the next AIPlatform reconcile, same footgun as
			// Resources above.
			preservedServiceTemplate := svc.Spec.ServiceTemplate

			// Ensure ownership
			if err := controllerutil.SetControllerReference(platform, &svc, r.Scheme); err != nil {
				return err
			}

			// Desired state from your builder
			built := r.buildAIService(ctx, platform, feature, serviceName)

			// Copy desired spec
			svc.Spec = built.Spec

			// buildAIService does not set Resources; without this, every AIPlatform reconcile
			// wipes kubectl patches / user-set limits (e.g. SAIA memory) back to empty → 2Gi defaults.
			if resourceRequirementsNonEmpty(preservedResources) {
				svc.Spec.Resources = preservedResources
			}
			// If the admin already patched serviceTemplate (non-empty
			// spec.type), keep that override. Otherwise fall through to the
			// value buildAIService() just set from AIPlatform.spec.
			if preservedServiceTemplate.Spec.Type != "" {
				svc.Spec.ServiceTemplate = preservedServiceTemplate
			}

			// Merge labels
			if svc.Labels == nil {
				svc.Labels = map[string]string{}
			}
			for k, v := range built.Labels {
				svc.Labels[k] = v
			}

			// Merge annotations
			if svc.Annotations == nil {
				svc.Annotations = map[string]string{}
			}
			for k, v := range built.Annotations {
				svc.Annotations[k] = v
			}

			return nil
		})
		if err != nil {
			return err
		}
		if op == controllerutil.OperationResultUpdated {
			log.Info("updated AIService child spec", "name", svc.Name, "feature", feature.Name, "provider", feature.Provider)
		}
	}

	// Prune services for features that no longer exist
	var children aiApi.AIServiceList
	if err := r.List(
		ctx,
		&children,
		client.InNamespace(platform.Namespace),
		client.MatchingFields{ownerKey: platform.Name}, // requires index on .metadata.controller
	); err != nil {
		return err
	}

	for i := range children.Items {
		child := &children.Items[i]
		if _, keep := desired[child.Name]; !keep {
			if err := r.Delete(ctx, child); client.IgnoreNotFound(err) != nil {
				return err
			}
			log.Info("deleted AIService for removed feature", "name", child.Name)
		}
	}

	return nil
}

func resourceRequirementsNonEmpty(r corev1.ResourceRequirements) bool {
	return len(r.Requests) > 0 || len(r.Limits) > 0
}

func clusterDomainOrDefault(domain string) string {
	if domain == "" {
		return "cluster.local"
	}
	return domain
}

func featureServiceName(platformName string, feature aiApi.FeatureSpec) string {
	name := fmt.Sprintf("%s-%s", platformName, feature.Name)
	if feature.Name == agentRuntimeFeatureName && feature.Provider != "" {
		name = fmt.Sprintf("%s-%s", name, feature.Provider)
		return boundedDNSLabel(name)
	}
	return name
}

func boundedDNSLabel(name string) string {
	if len(name) <= maxDNSLabelLength {
		return name
	}
	hash := shortHash(name)
	maxPrefixLength := maxDNSLabelLength - len(hash) - 1
	prefix := strings.TrimRight(name[:maxPrefixLength], "-")
	if prefix == "" {
		prefix = name[:maxPrefixLength]
	}
	return prefix + "-" + hash
}

func shortHash(value string) string {
	h := fnv.New32a()
	_, _ = h.Write([]byte(value))
	return fmt.Sprintf("%08x", h.Sum32())
}

func cloneStringMap(value map[string]string) map[string]string {
	if value == nil {
		return nil
	}
	cloned := make(map[string]string, len(value))
	for k, v := range value {
		cloned[k] = v
	}
	return cloned
}

func (r *AIPlatformReconciler) buildAIService(ctx context.Context, platform *aiApi.AIPlatform, feature aiApi.FeatureSpec, name string) *aiApi.AIService {
	vectorDbUrl := platform.Status.VectorDbServiceName
	clusterDomain := platform.Spec.ClusterDomain
	if clusterDomain == "" {
		clusterDomain = "cluster.local"
	}
	aiPlatformScheme := "http"
	aiPlatformURL := ""
	serviceAccountName := feature.ServiceAccountName
	if feature.Name == agentRuntimeFeatureName && serviceAccountName == "" {
		serviceAccountName = name + "-sa"
	}
	resources := corev1.ResourceRequirements{}
	metricsPort := int32(8080)
	if feature.Name == agentRuntimeFeatureName {
		metricsPort = agentRuntimeMetricsPort
		resources = agentruntime.DefaultResources()
		if platform.Status.RayServiceName != "" {
			aiPlatformURL = fmt.Sprintf("%s://%s.%s.svc.%s:8000",
				aiPlatformScheme, platform.Status.RayServiceName, platform.Namespace, clusterDomain)
		}
	}
	// Under cpuOnly there is no Ray platform URL; SLIM routes to the AgentRuntime
	// Service. Both profiles hand SLIM that URL (the SLIM handler resolves it for
	// the others); this only sets it explicitly for cpuOnly, using the same single
	// definition of the Service URL. With more than one agentruntime feature there
	// is no unambiguous Service, so it is left empty and the SLIM handler reports
	// that, exactly as it does for the other profiles.
	agentRuntimeURL := ""
	if feature.Name == slimFeatureName && platform.Spec.ResolvedProfile() == aiApi.AIPlatformProfileCPUOnly {
		var runtimeFeatures []aiApi.FeatureSpec
		for _, f := range platform.Spec.Features {
			if f.Name == agentRuntimeFeatureName {
				runtimeFeatures = append(runtimeFeatures, f)
			}
		}
		if len(runtimeFeatures) == 1 {
			agentRuntimeURL = agentruntime.FeatureServiceURL(platform.Name, runtimeFeatures[0].Provider, platform.Namespace, clusterDomain)
		}
	}
	serviceTemplate := *platform.Spec.ServiceTemplate.DeepCopy()
	cleanServiceTemplate(&serviceTemplate)

	// Pass the bucket path as-is to the AIService
	// The feature implementation is responsible for creating its own subdirectories
	// (e.g., /tasks, /models, /artifacts) as needed
	taskObjectStorage := platform.Spec.ObjectStorage
	// Don't append feature name - just pass the bucket path directly
	// taskObjectStorage.Path is already set from platform.Spec.ObjectStorage
	v2 := aiApi.SAIAv2Config{Replicas: 1}
	if v2Image := os.Getenv("RELATED_IMAGE_SAIA_API_V2"); v2Image != "" {
		v2.Image = v2Image
	}

	svc := &aiApi.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: platform.Namespace,
			Labels: map[string]string{
				"aiplatform": boundedDNSLabel(platform.Name),
				"feature":    feature.Name,
			},
		},
		Spec: aiApi.AIServiceSpec{
			Feature: feature,
			Version: feature.Version,
			AIPlatformRef: corev1.ObjectReference{
				APIVersion: "ai.splunk.com/v1",
				Kind:       "AIPlatform",
				Name:       platform.Name,
				Namespace:  platform.Namespace,
			},
			ServiceAccountName:  serviceAccountName,
			TaskVolume:          taskObjectStorage,
			SplunkConfiguration: platform.Spec.SplunkConfiguration,
			VectorDbUrl:         vectorDbUrl,
			AIPlatformUrl:       aiPlatformURL,
			AgentRuntimeUrl:     agentRuntimeURL,
			AIPlatformScheme:    aiPlatformScheme,
			// AgentRuntime takes its floor from MinReplicas.
			Replicas:              1,
			Port:                  80,
			Resources:             resources,
			MinReplicas:           cloneInt32Ptr(feature.MinReplicas),
			MaxReplicas:           cloneInt32Ptr(feature.MaxReplicas),
			TargetCPUUtilization:  cloneInt32Ptr(feature.TargetCPUUtilization),
			CheckpointDbSecretRef: feature.CheckpointDbSecretRef,
			RuntimeVersion:        feature.RuntimeVersion,
			Metrics: aiApi.MetricsConfig{
				Enabled: true,
				Port:    metricsPort,
				Path:    "/metrics",
			},
			MTLS: platform.Spec.MTLS,
			// Propagate public-exposure preference from AIPlatform. Customers deploy
			// the higher-level AIPlatform CR, so any NodePort / LoadBalancer setting
			// they configure at that level must flow down to the AIService. Without
			// this copy, the spec lands on AIPlatform and is silently ignored.
			// Deep-copy because corev1.Service is a value type with nested
			// slices/maps; a shallow copy would share state across children.
			ServiceTemplate:  serviceTemplate,
			ClusterDomain:    clusterDomain,
			ImagePullSecrets: platform.Spec.Images.ImagePullSecrets,
			V2:               v2,
			V2Worker:         aiApi.SAIAWorkerConfig{Replicas: 1},
		},
	}

	if feature.Provider != "" {
		svc.Labels["provider"] = feature.Provider
	}

	// The agent runtime always runs on CPU nodes. Under cpuOnly every workload is
	// CPU-only, so SLIM follows the CPU scheduler too: on a cluster that also has
	// GPU nodes it must not depend on a taint to stay off them. fullfeature leaves
	// SLIM unplaced exactly as before, so an operator upgrade does not roll it.
	if platform.Spec.CPUSchedulingSpec != nil &&
		(feature.Name == agentRuntimeFeatureName ||
			(feature.Name == slimFeatureName && platform.Spec.ResolvedProfile() == aiApi.AIPlatformProfileCPUOnly)) {
		svc.Spec.NodeSelector = cloneStringMap(platform.Spec.CPUSchedulingSpec.NodeSelector)
		svc.Spec.Tolerations = append([]corev1.Toleration(nil), platform.Spec.CPUSchedulingSpec.Tolerations...)
		if platform.Spec.CPUSchedulingSpec.Affinity != nil {
			svc.Spec.Affinity = *platform.Spec.CPUSchedulingSpec.Affinity.DeepCopy()
		}
	}

	return svc
}

func cloneInt32Ptr(value *int32) *int32 {
	if value == nil {
		return nil
	}
	cloned := *value
	return &cloned
}

func cleanServiceTemplate(svc *corev1.Service) {
	if svc == nil {
		return
	}
	svc.TypeMeta = metav1.TypeMeta{}
	svc.ObjectMeta = metav1.ObjectMeta{}
	svc.Status = corev1.ServiceStatus{}
}

// Keep ordinary child health waiting distinct from failures to read or reconcile
// resources so the caller can use a bounded readiness retry.
type agentRuntimeNotReadyError struct{ name string }

func (e *agentRuntimeNotReadyError) Error() string {
	return fmt.Sprintf("AgentRuntime AIService %s must report Ready=True for its current generation; inspect its readiness conditions", e.name)
}

// CheckAIServiceStatus requires current runtime readiness and retains the
// existing error-condition checks for other feature types.
func (r *AIPlatformReconciler) CheckAIServiceStatus(ctx context.Context, platform *aiApi.AIPlatform) error {
	log := log.FromContext(ctx)

	// List all AIService children owned by this AIPlatform
	var children aiApi.AIServiceList
	if err := r.List(
		ctx,
		&children,
		client.InNamespace(platform.Namespace),
		client.MatchingFields{ownerKey: platform.Name},
	); err != nil {
		return fmt.Errorf("failed to list AIService children: %w", err)
	}
	byName := make(map[string]*aiApi.AIService, len(children.Items))
	for i := range children.Items {
		byName[children.Items[i].Name] = &children.Items[i]
	}
	// Check configured runtimes even when they are absent from the child list;
	// deletion must not make the remaining children appear collectively healthy.
	for _, feature := range platform.Spec.Features {
		if feature.Name != agentRuntimeFeatureName {
			continue
		}
		name := featureServiceName(platform.Name, feature)
		child := byName[name]
		if child == nil || child.Spec.Feature.Name != agentRuntimeFeatureName || !metav1.IsControlledBy(child, platform) || !featurecommon.IsCurrentServiceReady(child) {
			return &agentRuntimeNotReadyError{name: name}
		}
	}

	// Check each child's status conditions
	for i := range children.Items {
		child := &children.Items[i]
		if child.Spec.Feature.Name == agentRuntimeFeatureName {
			// Runtime health was checked above using current Ready, regardless of
			// reason text. Retain the legacy error-reason rule for other features.
			continue
		}

		// Check if AIService has any failed conditions
		for _, cond := range child.Status.Conditions {
			if cond.Status == metav1.ConditionFalse && cond.Reason == "Error" {
				log.Info("AIService has failed condition",
					"service", child.Name,
					"conditionType", cond.Type,
					"reason", cond.Reason,
					"message", cond.Message)
				return fmt.Errorf("AIService %s has failed condition %s: %s",
					child.Name, cond.Type, cond.Message)
			}
		}
	}

	// Use V(1) for verbose logging - only errors are important at info level
	log.V(1).Info("All AIService children have successful conditions", "count", len(children.Items))
	return nil
}
