package ai_platform

import (
	"context"
	"fmt"
	"hash/fnv"
	"os"
	"strings"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/raybuilder"
	"github.com/splunk/splunk-ai-operator/pkg/ai/sidecars"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const (
	agentRuntimeFeatureName = "agentruntime"
	maxDNSLabelLength       = 63
	ownerKey                = ".metadata.controller"
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

func (r *AIPlatformReconciler) Reconcile(ctx context.Context, p *aiApi.AIPlatform) (reconcile.Result, error) {

	var conditions []metav1.Condition
	defer func() {
		// Fetch the latest version of the CR before updating the status
		latest := &aiApi.AIPlatform{}
		namespacedName := client.ObjectKey{Namespace: p.Namespace, Name: p.Name}
		if err := r.Get(ctx, namespacedName, latest); err != nil {
			log.FromContext(ctx).Error(err, "failed to fetch latest CR")
			return
		}
		latest.Status = p.Status
		latest.Status.Conditions = conditions
		latest.Status.ObservedGeneration = p.Generation
		latest.Status.RayServiceName = p.Status.RayServiceName
		latest.Status.VectorDbServiceName = p.Status.VectorDbServiceName
		_ = r.Status().Update(ctx, latest)
	}()
	raybuilder := raybuilder.New(r.p, r.Client, r.Scheme, r.Recorder)
	sidecarBuilder := sidecars.New(r.Client, r.Scheme, r.Recorder, r.p)
	var scaleResult reconcile.Result

	stages := []struct {
		name string
		fn   func(context.Context, *aiApi.AIPlatform) error
	}{
		{"Validate", r.validate},
		//{"ApplicationsConfigMap", raybuilder.ReconcileApplicationsConfigMap},
		//{"InstancesConfigMap", raybuilder.ReconcileInstancesConfigMap},
		//{"ServeConfigMap", raybuilder.ReconcileServeConfigMap},
		{"Sidecars", sidecarBuilder.Reconcile},
		{"rayAutoscalerRBAC", raybuilder.ReconcileRayAutoscalerRBAC},
		{"RayService", raybuilder.ReconcileRayService},
		{"ActiveClusterScale", func(ctx context.Context, p *aiApi.AIPlatform) error {
			var err error
			scaleResult, err = raybuilder.ReconcileActiveClusterScale(ctx, p)
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
	}

	for _, stage := range stages {
		err := stage.fn(ctx, p)
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
			//r.Recorder.Event(p, corev1.EventTypeWarning, stage.name+"Failed", err.Error())
		} else {
			//r.Recorder.Event(p, corev1.EventTypeNormal, stage.name+"Succeeded", "stage succeeded")
		}
		conditions = append(conditions, cond)
		if err != nil {
			return reconcile.Result{}, err
		}
	}

	// all done
	conditions = append(conditions, metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionTrue,
		Reason:             "AllReconciled",
		Message:            "all stages completed successfully",
		LastTransitionTime: metav1.Now(),
	})

	return scaleResult, nil
}

// ReconcileFeatures ensures each feature's AIService exists and is up to date.
func (r *AIPlatformReconciler) ReconcileFeatures(ctx context.Context, platform *aiApi.AIPlatform) error {
	log := log.FromContext(ctx)

	// Build the desired set of child service names
	desired := make(map[string]struct{}, len(platform.Spec.Features))

	for _, feature := range platform.Spec.Features {
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
	replicas := int32(1)
	if feature.Name == agentRuntimeFeatureName && feature.MinReplicas != nil {
		replicas = *feature.MinReplicas
	}
	serviceAccountName := feature.ServiceAccountName
	if feature.Name == agentRuntimeFeatureName && serviceAccountName == "" {
		serviceAccountName = name + "-sa"
	}
	resources := corev1.ResourceRequirements{}
	if feature.Name == agentRuntimeFeatureName {
		resources = defaultAgentRuntimeResources()
		if platform.Status.RayServiceName != "" {
			aiPlatformURL = fmt.Sprintf("%s://%s.%s.svc.%s:8000",
				aiPlatformScheme, platform.Status.RayServiceName, platform.Namespace, clusterDomain)
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
			ServiceAccountName:    serviceAccountName,
			TaskVolume:            taskObjectStorage,
			SplunkConfiguration:   platform.Spec.SplunkConfiguration,
			VectorDbUrl:           vectorDbUrl,
			AIPlatformUrl:         aiPlatformURL,
			AIPlatformScheme:      aiPlatformScheme,
			Replicas:              replicas,
			Port:                  80,
			Resources:             resources,
			MinReplicas:           cloneInt32Ptr(feature.MinReplicas),
			MaxReplicas:           cloneInt32Ptr(feature.MaxReplicas),
			TargetCPUUtilization:  cloneInt32Ptr(feature.TargetCPUUtilization),
			CheckpointDbSecretRef: feature.CheckpointDbSecretRef,
			RuntimeVersion:        feature.RuntimeVersion,
			Metrics: aiApi.MetricsConfig{
				Enabled: true,
				Port:    8080,
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

	if feature.Name == agentRuntimeFeatureName && platform.Spec.CPUSchedulingSpec != nil {
		svc.Spec.NodeSelector = cloneStringMap(platform.Spec.CPUSchedulingSpec.NodeSelector)
		svc.Spec.Tolerations = append([]corev1.Toleration(nil), platform.Spec.CPUSchedulingSpec.Tolerations...)
		if platform.Spec.CPUSchedulingSpec.Affinity != nil {
			svc.Spec.Affinity = *platform.Spec.CPUSchedulingSpec.Affinity.DeepCopy()
		}
	}

	return svc
}

func defaultAgentRuntimeResources() corev1.ResourceRequirements {
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

// CheckAIServiceStatus verifies that all AIService children have successful conditions.
// Returns an error if any AIService has failed conditions, preventing AIPlatform from marking itself as Ready.
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

	// Check each child's status conditions
	for i := range children.Items {
		child := &children.Items[i]

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
