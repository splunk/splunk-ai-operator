/*
Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"context"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/internal/controller/common"
	telemetry "github.com/splunk/splunk-ai-operator/internal/telemetry"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features"
	"github.com/splunk/splunk-ai-operator/pkg/config"
)

const aiServiceFinalizer = "ai.splunk.com/aiservice-protect"

// AIServiceReconciler reconciles a AIService object
type AIServiceReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
	Config   *config.OperatorConfig // injected runtime config
}

// +kubebuilder:rbac:groups=ai.splunk.com,resources=aiservices,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=ai.splunk.com,resources=aiservices/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=ai.splunk.com,resources=aiservices/finalizers,verbs=update
// +kubebuilder:rbac:groups=cert-manager.io,resources=certificates,verbs=get;list;watch;
// +kubebuilder:rbac:groups=opentelemetry.io,resources=opentelemetrycollectors,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=monitoring.coreos.com,resources=servicemonitors,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=monitoring.coreos.com,resources=prometheusrules,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=monitoring.coreos.com,resources=podmonitors,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=batch,resources=jobs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps,resources=statefulsets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=pods,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=endpoints,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=serviceaccounts,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=secrets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="core",resources=configmaps,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="monitoring",resources=servicemonitors,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=rbac.authorization.k8s.io,resources=roles,verbs=create;get;list;watch;update;patch;delete
// +kubebuilder:rbac:groups=rbac.authorization.k8s.io,resources=rolebindings,verbs=create;get;list;watch;update;patch;delete

// Reconcile is part of the main kubernetes reconciliation loop which aims to
// move the current state of the cluster closer to the desired state.
// TODO(user): Modify the Reconcile function to compare the state specified by
// the AIService object against the actual cluster state, and then
// perform operations to make the cluster state reflect the state specified by
// the user.
//
// For more details, check Reconcile and its Result here:
// - https://pkg.go.dev/sigs.k8s.io/controller-runtime@v0.20.4/pkg/reconcile
func (r *AIServiceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)
	// Use V(1) for verbose logging - reduces noise in production
	log.V(1).Info("Reconciling AIService", "name", req.Name, "namespace", req.Namespace)

	// telemetry scope
	scope := telemetry.Scope{
		Namespace: req.Namespace,
		Name:      req.Name,
		Kind:      "AIService",
		Feature:   "unknown",
	}
	ctx = telemetry.WithScope(ctx, scope)
	totalStart := time.Now()
	defer func() { telemetry.ObserveReconcileStage(ctx, "total", totalStart) }()

	// fetch
	fetchStart := time.Now()
	ai := &aiv1.AIService{}
	if err := r.Get(ctx, req.NamespacedName, ai); err != nil {
		telemetry.ObserveReconcileStage(ctx, "fetch", fetchStart)
		if client.IgnoreNotFound(err) != nil {
			telemetry.ObserveReconcileError(ctx, "get")
			telemetry.ObserveReconcileResult(ctx, "error")
			return ctrl.Result{}, err
		}
		// deleted already
		telemetry.ObserveReconcileResult(ctx, "success")
		return ctrl.Result{}, nil
	}
	telemetry.ObserveReconcileStage(ctx, "fetch", fetchStart)

	// update scope with feature name
	featureName := ai.Spec.Feature.Name
	if featureName == "" {
		featureName = "unknown"
	}
	ctx = telemetry.WithScope(ctx, telemetry.Scope{
		Namespace: req.Namespace,
		Name:      req.Name,
		Kind:      "AIService",
		Feature:   featureName,
	})

	// deletion handling with finalizer
	if ai.DeletionTimestamp != nil {
		// run feature specific finalization if needed
		if containsString(ai.Finalizers, aiServiceFinalizer) {
			if factory, ok := features.FeatureFactories[featureName]; ok {
				if handler, err := factory.New(ctx, r.Client, r.Scheme, ai, r.Recorder); err == nil {
					// TODO - define Finalize handlers
					if f, ok := handler.(interface {
						Finalize(context.Context, *aiv1.AIService) error
					}); ok {
						if err := f.Finalize(ctx, ai); err != nil {
							telemetry.ObserveReconcileError(ctx, "finalize")
							return ctrl.Result{}, err
						}
					}
				}
			}
			// remove finalizer
			ai.Finalizers = removeString(ai.Finalizers, aiServiceFinalizer)
			if err := r.Update(ctx, ai); err != nil {
				return ctrl.Result{}, err
			}
		}
		telemetry.ObserveReconcileResult(ctx, "success")
		return ctrl.Result{}, nil
	}

	// feature handler init
	factoryInit := time.Now()
	factory, ok := features.FeatureFactories[featureName]
	telemetry.ObserveReconcileStage(ctx, "factory_lookup", factoryInit)
	if !ok {
		log.Error(nil, "No factory registered for feature", "feature", featureName)
		telemetry.ObserveReconcileError(ctx, "factory_lookup")
		telemetry.ObserveReconcileResult(ctx, "error")
		// requeue to avoid hot looping if spec is wrong - small delay
		return ctrl.Result{RequeueAfter: 10 * time.Second}, nil
	}

	handlerInit := time.Now()
	handler, err := factory.New(ctx, r.Client, r.Scheme, ai, r.Recorder)
	telemetry.ObserveReconcileStage(ctx, "handler_init", handlerInit)
	if err != nil {
		log.Error(err, "failed to initialize feature handler", "feature", featureName)
		telemetry.ObserveReconcileError(ctx, "handler_init")
		telemetry.ObserveReconcileResult(ctx, "error")
		return ctrl.Result{}, err
	}

	// feature reconcile
	featStart := time.Now()
	if err := handler.Reconcile(ctx, ai); err != nil {
		telemetry.ObserveReconcileStage(ctx, "feature_reconcile", featStart)
		log.Error(err, "feature reconciliation failed", "feature", featureName)
		telemetry.ObserveReconcileError(ctx, "reconcile")
		telemetry.ObserveReconcileResult(ctx, "error")
		return ctrl.Result{}, err
	}
	telemetry.ObserveReconcileStage(ctx, "feature_reconcile", featStart)

	// status update
	if err := r.reconcileStatus(ctx, ai); err != nil {
		telemetry.ObserveReconcileError(ctx, "status_update")
		return ctrl.Result{}, err
	}

	telemetry.ObserveReconcileResult(ctx, "success")
	return ctrl.Result{}, nil
}

// aiServiceEventFilter is the controller-wide event filter. Owned-resource
// predicates are combined with this filter, so ConfigMap data changes must be
// admitted here as well as by the ConfigMap-specific Owns predicate. This is
// required for values snapshotted into pod templates, such as EMBEDDING_MODEL.
func aiServiceEventFilter() predicate.Predicate {
	return predicate.Or(
		common.GenerationChangedPredicate(),
		common.AnnotationChangedPredicate(),
		common.LabelChangedPredicate(),
		common.ConfigMapChangedPredicate(),
	)
}

// SetupWithManager sets up the controller with the Manager.
func (r *AIServiceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&aiv1.AIService{}).
		Named("aiservice").
		// Owned resources with specific predicates to avoid reconciliation loops
		Owns(&corev1.ServiceAccount{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		Owns(&corev1.ConfigMap{}, builder.WithPredicates(common.ConfigMapChangedPredicate())).
		Owns(&corev1.Secret{}, builder.WithPredicates(common.SecretChangedPredicate())).
		Owns(&certmanagerv1.Certificate{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		Owns(&batchv1.Job{}, builder.WithPredicates(common.JobChangedPredicate())).
		Owns(&appsv1.Deployment{}, builder.WithPredicates(common.DeploymentChangedPredicate())).
		Owns(&corev1.Service{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		Owns(&monitoringv1.ServiceMonitor{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		// Watch referenced AIPlatform (not owned by AIService)
		Watches(
			&aiv1.AIPlatform{},
			handler.EnqueueRequestsFromMapFunc(r.findAIServicesForPlatform),
			builder.WithPredicates(predicate.Or(
				common.GenerationChangedPredicate(),
				common.AnnotationChangedPredicate(),
			)),
		).
		// Add predicates to filter events and avoid unnecessary reconciliations
		WithEventFilter(aiServiceEventFilter()).
		// Configure concurrency control
		WithOptions(controller.Options{
			MaxConcurrentReconciles: aiv1.TotalWorker,
		}).
		Complete(r)
}

// --- 8️⃣ reconcileStatus: update CR status/conditions ---
func (r *AIServiceReconciler) reconcileStatus(ctx context.Context, p *aiv1.AIService) error {
	// reflect observedGeneration
	p.Status.ObservedGeneration = p.Generation

	// Note: Feature reconciler already sets detailed stage conditions in Status.Conditions
	// We only update the overall Ready condition here if not already set by feature reconciler
	hasReadyCondition := false
	for _, c := range p.Status.Conditions {
		if c.Type == "Ready" {
			hasReadyCondition = true
			break
		}
	}

	// Only add Ready condition if feature reconciler didn't already add it
	if !hasReadyCondition {
		cond := metav1.Condition{
			Type:               "Ready",
			Status:             metav1.ConditionTrue,
			Reason:             "Reconciled",
			Message:            "All resources are up-to-date",
			LastTransitionTime: metav1.Now(),
		}
		p.Status.Conditions = append(p.Status.Conditions, cond)
	}

	// telemetry: gauges for generation & condition
	telemetry.SetObservedGeneration(ctx, p.Status.ObservedGeneration)

	// Get the Ready condition status for telemetry
	for _, c := range p.Status.Conditions {
		if c.Type == "Ready" {
			telemetry.SetCondition(ctx, "Ready", string(c.Status))
			break
		}
	}

	// FIXME: add AIService scale fields, set them here:
	// telemetry.SetDesiredReplicas(ctx, p.Spec.Replicas)
	// telemetry.SetReadyReplicas(ctx, p.Status.ReadyReplicas)

	// telemetry: API latency/counter for status update
	apiStart := time.Now()
	err := r.Status().Update(ctx, p)
	telemetry.ObserveAPILatency(ctx, "status", "k8s_status_update", apiStart)
	if err != nil {
		telemetry.IncAPIRequest(ctx, "status", "k8s_status_update", "error")
		telemetry.ObserveReconcileError(ctx, "status_update")
		return err
	}
	telemetry.IncAPIRequest(ctx, "status", "k8s_status_update", "ok")
	return nil
}

// findAIServicesForPlatform maps an AIPlatform resource to AIServices that reference it
func (r *AIServiceReconciler) findAIServicesForPlatform(ctx context.Context, platform client.Object) []reconcile.Request {
	log := logf.FromContext(ctx)

	var services aiv1.AIServiceList
	if err := r.List(ctx, &services, client.InNamespace(platform.GetNamespace())); err != nil {
		log.Error(err, "failed to list AIServices for AIPlatform", "platform", platform.GetName())
		return nil
	}

	var requests []reconcile.Request
	for _, svc := range services.Items {
		// Check if this service references the platform
		if svc.Spec.AIPlatformRef.Name == platform.GetName() &&
			(svc.Spec.AIPlatformRef.Namespace == platform.GetNamespace() || svc.Spec.AIPlatformRef.Namespace == "") {
			requests = append(requests, reconcile.Request{
				NamespacedName: types.NamespacedName{
					Name:      svc.Name,
					Namespace: svc.Namespace,
				},
			})
			log.V(1).Info("queueing AIService for reconciliation due to AIPlatform change",
				"service", svc.Name,
				"platform", platform.GetName())
		}
	}

	return requests
}

func containsString(slice []string, s string) bool {
	for _, x := range slice {
		if x == s {
			return true
		}
	}
	return false
}

func removeString(slice []string, s string) []string {
	out := make([]string, 0, len(slice))
	for _, x := range slice {
		if x != s {
			out = append(out, x)
		}
	}
	return out
}
