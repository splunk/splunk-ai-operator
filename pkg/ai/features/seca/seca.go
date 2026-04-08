package seca

import (
	"context"

	"fmt"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	corev1 "k8s.io/api/core/v1"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
)

type SecaReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

func (h *SecaReconciler) BuildResources(namespace, name string) []client.Object {
	return []client.Object{
		ConfigMap(namespace, name),
		Secret(namespace, name),
		Deployment(namespace, name),
		Service(namespace, name),
	}
}

// Reconcile runs reconciliation stages for the CR.
func (r *SecaReconciler) Reconcile(ctx context.Context, aiservice *aiv1.AIService) error {
	log := log.FromContext(ctx)
	ai := &aiv1.AIService{}

	var conditions []metav1.Condition
	defer func() {
		ai.Status.Conditions = conditions
		ai.Status.ObservedGeneration = ai.Generation
		_ = r.Status().Update(ctx, ai)
	}()

	stages := []struct {
		name string
		fn   func(context.Context, *aiv1.AIService) error
	}{
		{"Validate", r.validateAIService},
	}

	for _, stage := range stages {
		err := stage.fn(ctx, ai)

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
func (r *SecaReconciler) validateAIService(ctx context.Context, ai *aiv1.AIService) error {
	if os.Getenv("RELATED_IMAGE_POST_INSTALL_HOOK") == "" {
		return fmt.Errorf("RELATED_IMAGE_POST_INSTALL_HOOK must be set")
	}
	// Populate URLs from AIPlatformRef if provided
	if ai.Spec.AIPlatformRef.Name != "" {
		plat := &aiv1.AIPlatform{}
		if err := r.Get(
			ctx,
			client.ObjectKey{Namespace: ai.Namespace, Name: ai.Spec.AIPlatformRef.Name},
			plat,
		); err != nil {
			return fmt.Errorf("fetching AIPlatform: %w", err)
		}
		ai.Spec.AIPlatformUrl = fmt.Sprintf("%s.%s.svc.%s:8000", plat.Status.RayServiceName, ai.Spec.AIPlatformRef.Namespace, "cluster.local")
		ai.Spec.VectorDbUrl = fmt.Sprintf("%s.%s.svc.%s", plat.Status.VectorDbServiceName, ai.Spec.AIPlatformRef.Namespace, "cluster.local")
	}
	if ai.Spec.AIPlatformRef.Name == "" && ai.Spec.AIPlatformUrl == "" {
		return fmt.Errorf(
			"either AIPlatformRef.Name or AIPlatformUrl must be set",
		)
	}
	if ai.Spec.AIPlatformUrl == "" && ai.Spec.VectorDbUrl == "" {
		return fmt.Errorf(
			"either AIPlatformUrl or VectorDbUrl must be set",
		)
	}
	// Default resources
	if ai.Spec.Resources.Requests == nil {
		ai.Spec.Resources.Requests = corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("500m"),
			corev1.ResourceMemory: resource.MustParse("1Gi"),
		}
	}
	if ai.Spec.Resources.Limits == nil {
		ai.Spec.Resources.Limits = corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("1"),
			corev1.ResourceMemory: resource.MustParse("2Gi"),
		}
	}
	if ai.Spec.TaskVolume == nil || ai.Spec.TaskVolume.Path == "" {
		return fmt.Errorf("task volume path must be set")
	}
	if ai.Spec.Replicas == 0 {
		ai.Spec.Replicas = 1
	}
	return nil
}
