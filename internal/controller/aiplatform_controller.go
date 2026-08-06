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

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/internal/controller/common"
	telemetry "github.com/splunk/splunk-ai-operator/internal/telemetry"
	aiplatform "github.com/splunk/splunk-ai-operator/pkg/ai"
	"github.com/splunk/splunk-ai-operator/pkg/config"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const ownerKey = ".metadata.controller"
const aiPlatformFinalizer = "ai.splunk.com/aiplatform-protect"

// +kubebuilder:rbac:groups=ai.splunk.com,resources=aiplatforms,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=ai.splunk.com,resources=aiplatforms/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=ai.splunk.com,resources=aiplatforms/finalizers,verbs=update
// +kubebuilder:rbac:groups=ai.splunk.com,resources=aiservices,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=cert-manager.io,resources=certificates,verbs=get;list;watch
// +kubebuilder:rbac:groups=opentelemetry.io,resources=opentelemetrycollectors,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=monitoring.coreos.com,resources=servicemonitors,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=monitoring.coreos.com,resources=prometheusrules,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=monitoring.coreos.com,resources=podmonitors,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=ray.io,resources=rayservices,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=ray.io,resources=rayclusters,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=ray.io,resources=rayjobs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=batch,resources=jobs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps,resources=statefulsets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=endpoints,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=serviceaccounts,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=secrets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=configmaps,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=rbac.authorization.k8s.io,resources=roles,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=rbac.authorization.k8s.io,resources=rolebindings,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=networking.k8s.io,resources=ingresses,verbs=get;list;watch;create;update;patch;delete

// AIPlatformReconciler reconciles a AIPlatform
type AIPlatformReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
	Config   *config.OperatorConfig // injected runtime config
}

func (r *AIPlatformReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	// telemetry setup omitted for brevity

	// fetch
	p := &aiv1.AIPlatform{}
	if err := r.Get(ctx, req.NamespacedName, p); err != nil {
		if client.IgnoreNotFound(err) != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	// deletion flow
	if p.DeletionTimestamp != nil {
		// only act if our finalizer is present
		if containsString(p.Finalizers, aiPlatformFinalizer) {
			// 1) run cleanup for platform‑level resources
			// delete or detach external resources here
			// example: ensure Ray and Weaviate are removed
			if done, err := r.finalizePlatform(ctx, p); err != nil {
				// transient error, requeue
				return ctrl.Result{}, err
			} else if !done {
				// still waiting on children to disappear, requeue soon
				return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
			}

			// 2) remove finalizer, allow deletion to complete
			p.Finalizers = removeString(p.Finalizers, aiPlatformFinalizer)
			if err := r.Update(ctx, p); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// normal reconcile
	svc := aiplatform.New(p, r.Client, r.Scheme, r.Recorder)
	res, err := svc.Reconcile(ctx, p)

	// optional: update platform status summary here
	// _ = r.reconcileStatus(ctx, p)

	return res, err
}

// --- 8️⃣ reconcileStatus: update CR status/conditions ---
func (r *AIPlatformReconciler) reconcileStatus(ctx context.Context, p *aiv1.AIPlatform) error {
	// reflect observedGeneration
	p.Status.ObservedGeneration = p.Generation

	cond := metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionTrue,
		Reason:             "Reconciled",
		Message:            "All resources are up-to-date",
		LastTransitionTime: metav1.Now(),
	}
	p.Status.Conditions = []metav1.Condition{cond}

	// ----- telemetry: gauges for generation & condition -----
	telemetry.SetObservedGeneration(ctx, p.Status.ObservedGeneration)
	telemetry.SetCondition(ctx, "Ready", string(cond.Status))

	// ----- telemetry: API latency/counter for status update (optional but useful) -----
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

// SetupWithManager sets up the controller with the Manager.
func (r *AIPlatformReconciler) SetupWithManager(mgr ctrl.Manager) error {
	// 1) Field index so we can quickly list AIService children by owning AIPlatform
	if err := mgr.GetFieldIndexer().IndexField(
		context.Background(),
		&aiv1.AIService{},
		ownerKey, // ".metadata.controller"
		func(rawObj client.Object) []string {
			svc := rawObj.(*aiv1.AIService)
			owner := metav1.GetControllerOf(svc)
			if owner == nil {
				return nil
			}
			if owner.APIVersion != aiv1.GroupVersion.String() || owner.Kind != "AIPlatform" {
				return nil
			}
			return []string{owner.Name}
		},
	); err != nil {
		return err
	}

	b := ctrl.NewControllerManagedBy(mgr).
		Named("aiplatform").
		// Predicates scoped to the primary resource via For()'s own
		// WithPredicates, NOT WithEventFilter — WithEventFilter populates
		// globalPredicates, which controller-runtime ANDs onto every Watches()/
		// Owns() too (see doWatch() in controller-runtime's builder package). That
		// would silently defeat the CACertRef Secret watch below: Secrets never
		// bump metadata.generation, and a pure .data rotation touches neither
		// annotations nor labels, so a global filter requiring one of those AND
		// SecretChangedPredicate never fires (AIP-4614 Part D — found in review).
		For(&aiv1.AIPlatform{}, builder.WithPredicates(predicate.Or(
			common.GenerationChangedPredicate(),
			common.AnnotationChangedPredicate(),
			common.LabelChangedPredicate(),
		))).
		// AIPlatform owns its AIService children - reconcile on generation changes
		Owns(&aiv1.AIService{}, builder.WithPredicates(predicate.Or(
			common.GenerationChangedPredicate(),
			common.AnnotationChangedPredicate(),
		))).
		// Infra owned by AIPlatform itself - with specific predicates
		// Ray resources - only reconcile on generation changes
		Owns(&rayv1.RayService{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		Owns(&rayv1.RayCluster{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		// Weaviate pieces - whatever we create at the platform level
		Owns(&appsv1.StatefulSet{}, builder.WithPredicates(common.StatefulSetChangedPredicate())). // if platform creates Weaviate as a StatefulSet
		Owns(&appsv1.Deployment{}, builder.WithPredicates(common.DeploymentChangedPredicate())).   // or a Deployment, if that's how we run it
		Owns(&corev1.Service{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		Owns(&corev1.ServiceAccount{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})). // for Weaviate service account
		Owns(&corev1.ConfigMap{}, builder.WithPredicates(common.ConfigMapChangedPredicate())).
		Owns(&corev1.Secret{}, builder.WithPredicates(common.SecretChangedPredicate())).
		// RBAC resources for Ray autoscaler
		Owns(&rbacv1.Role{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		Owns(&rbacv1.RoleBinding{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		// Watch CACertRef Secrets (not owned by AIPlatform - customer/installer
		// pre-creates them) so rotating the CA bundle's content in place triggers
		// a reconcile. Without this, splunkCACertChecksum's annotation update
		// only takes effect on the next reconcile triggered by something else
		// (AIP-4614 Tier 1 item 4).
		Watches(
			&corev1.Secret{},
			handler.EnqueueRequestsFromMapFunc(r.findAIPlatformsForCACertSecret),
			builder.WithPredicates(common.SecretChangedPredicate()),
		).
		WithOptions(controller.Options{
			MaxConcurrentReconciles: aiv1.TotalWorker,
		})

	return b.Complete(r)
}

// findAIPlatformsForCACertSecret maps a Secret to the AIPlatforms in the same
// namespace whose splunkConfiguration.caCertRef references it by name, so
// rotating the CA bundle's content (without renaming the Secret) triggers a
// reconcile instead of only being picked up on some unrelated trigger.
func (r *AIPlatformReconciler) findAIPlatformsForCACertSecret(ctx context.Context, secret client.Object) []reconcile.Request {
	log := logf.FromContext(ctx)

	var platforms aiv1.AIPlatformList
	if err := r.List(ctx, &platforms, client.InNamespace(secret.GetNamespace())); err != nil {
		log.Error(err, "failed to list AIPlatforms for CACertRef Secret", "secret", secret.GetName())
		return nil
	}

	var requests []reconcile.Request
	for i := range platforms.Items {
		p := &platforms.Items[i]
		ref := p.Spec.SplunkConfiguration.CACertRef
		if ref == nil || ref.Name != secret.GetName() {
			continue
		}
		requests = append(requests, reconcile.Request{
			NamespacedName: client.ObjectKeyFromObject(p),
		})
	}
	return requests
}

// finalizePlatform deletes platform‑owned children and waits until they are gone.
// Return (true, nil) when it is safe to remove the finalizer.
func (r *AIPlatformReconciler) finalizePlatform(ctx context.Context, p *aiv1.AIPlatform) (bool, error) {
	// delete AIService children, they may in turn delete lower layers they own
	{
		var services aiv1.AIServiceList
		if err := r.List(ctx, &services,
			client.InNamespace(p.Namespace),
			client.MatchingFields{ownerKey: p.Name},
		); err != nil {
			return false, err
		}
		for i := range services.Items {
			svc := &services.Items[i]
			// best effort delete
			_ = r.Delete(ctx, svc)
		}
		if len(services.Items) > 0 {
			return false, nil // wait for GC
		}
	}

	return true, nil
}
