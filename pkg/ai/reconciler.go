package ai_platform

import (
	"context"
	"fmt"
	"os"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/raybuilder"
	"github.com/splunk/splunk-ai-operator/pkg/ai/sidecars"
	corev1 "k8s.io/api/core/v1"
	//"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	//"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const ownerKey = ".metadata.controller"

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

	return reconcile.Result{}, nil
}

// ReconcileFeatures ensures each feature's AIService exists and is up to date.
func (r *AIPlatformReconciler) ReconcileFeatures(ctx context.Context, platform *aiApi.AIPlatform) error {
	log := log.FromContext(ctx)

	// Build the desired set of child service names
	desired := make(map[string]struct{}, len(platform.Spec.Features))

	for _, feature := range platform.Spec.Features {
		serviceName := fmt.Sprintf("%s-%s", platform.Name, feature.Name)
		desired[serviceName] = struct{}{}

		// Prepare object with identity for CreateOrUpdate
		var svc aiApi.AIService
		svc.Name = serviceName
		svc.Namespace = platform.Namespace

		_, err := controllerutil.CreateOrUpdate(ctx, r.Client, &svc, func() error {
			// After client Get, svc holds the live AIService (empty on first create).
			preservedResources := svc.Spec.Resources

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

func (r *AIPlatformReconciler) buildAIService(ctx context.Context, platform *aiApi.AIPlatform, feature aiApi.FeatureSpec, name string) *aiApi.AIService {
	vectorDbUrl := platform.Status.VectorDbServiceName

	// Pass the bucket path as-is to the AIService
	// The feature implementation is responsible for creating its own subdirectories
	// (e.g., /tasks, /models, /artifacts) as needed
	taskObjectStorage := platform.Spec.ObjectStorage
	// Don't append feature name - just pass the bucket path directly
	// taskObjectStorage.Path is already set from platform.Spec.ObjectStorage
	svc := &aiApi.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: platform.Namespace,
			Labels: map[string]string{
				"aiplatform": platform.Name,
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
			ServiceAccountName:  feature.ServiceAccountName,
			TaskVolume:          taskObjectStorage,
			SplunkConfiguration: platform.Spec.SplunkConfiguration,
			VectorDbUrl:         vectorDbUrl,
			Replicas:            1,
			Metrics: aiApi.MetricsConfig{
				Enabled: true,
				Port:    8080,
				Path:    "/metrics",
			},
			MTLS:             platform.Spec.MTLS,
			ImagePullSecrets: platform.Spec.Images.ImagePullSecrets,
		},
	}

	// SAIA v2: populate from operator env var if set
	if v2Image := os.Getenv("RELATED_IMAGE_SAIA_API_V2"); v2Image != "" {
		svc.Spec.V2 = aiApi.SAIAv2Config{Image: v2Image, Replicas: 1}
		svc.Spec.V2Worker = aiApi.SAIAWorkerConfig{Replicas: 1}
	}

	return svc
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
