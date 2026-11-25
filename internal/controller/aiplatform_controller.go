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
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
)

const ownerKey = ".metadata.controller"

// aiPlatformFinalizer was added by early builds (2025-08) and is no longer added;
// the operator only removes it, so such platforms can still be deleted.
const aiPlatformFinalizer = "ai.splunk.com/aiplatform-protect"

// +kubebuilder:rbac:groups=ai.splunk.com,resources=aiplatforms,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=ai.splunk.com,resources=aiplatforms/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=ai.splunk.com,resources=aiplatforms/finalizers,verbs=update
// +kubebuilder:rbac:groups=ai.splunk.com,resources=aiservices,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=cert-manager.io,resources=certificates,verbs=get;list;watch;create;update;patch;delete
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

	// Deletion (MPR-202): the operator adds no finalizer. Everything it creates for
	// the platform is owned through controller references, so Kubernetes garbage
	// collection removes it, and nothing the operator does can block a deletion. A
	// platform still carrying the finalizer an early build added is released at once.
	if p.DeletionTimestamp != nil {
		if containsString(p.Finalizers, aiPlatformFinalizer) {
			p.Finalizers = removeString(p.Finalizers, aiPlatformFinalizer)
			if err := r.Update(ctx, p); err != nil {
				return ctrl.Result{}, client.IgnoreNotFound(err)
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
		For(&aiv1.AIPlatform{}).
		// The parent owns child specs, so arbitrary child writes could feed a spec
		// reconciliation loop. Observe runtime readiness and child deletion only.
		Owns(&aiv1.AIService{}, builder.WithPredicates(predicate.Or(agentRuntimeReadyChangedPredicate(), predicate.Funcs{
			CreateFunc: func(e event.CreateEvent) bool { return false },
			UpdateFunc: func(e event.UpdateEvent) bool { return false },
			DeleteFunc: func(e event.DeleteEvent) bool { return !e.DeleteStateUnknown },
		}))).
		// Infra owned by AIPlatform itself - with specific predicates
		// (the Ray resources are registered below, only when KubeRay is installed)
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
		// A child readiness event must pass both this global filter and its Owns
		// predicate; generation-only filtering here would discard health changes.
		WithEventFilter(predicate.Or(
			agentRuntimeReadyChangedPredicate(),
			common.GenerationChangedPredicate(),
			common.AnnotationChangedPredicate(),
			common.LabelChangedPredicate(),
		)).
		WithOptions(controller.Options{
			MaxConcurrentReconciles: aiv1.TotalWorker,
		})

	// A cpuOnly installation does not install KubeRay, so the ray.io APIs do not
	// exist. Watching a kind whose API is missing keeps the controller from ever
	// starting (no matches for kind "RayService"), so the Ray watches are
	// registered only when the API is present. Installations with KubeRay keep
	// exactly the watches they had before.
	for _, optional := range []struct {
		kind string
		obj  client.Object
	}{
		{"RayService", &rayv1.RayService{}},
		{"RayCluster", &rayv1.RayCluster{}},
	} {
		present, err := optionalResourcePresent(mgr, "ray.io", "v1", optional.kind)
		if err != nil {
			return err
		}
		if present {
			b = b.Owns(optional.obj, builder.WithPredicates(predicate.GenerationChangedPredicate{}))
		} else {
			ctrl.Log.WithName("setup").Info("API not installed; not watching it (expected for the cpuOnly profile)",
				"group", "ray.io", "kind", optional.kind)
		}
	}

	return b.Complete(r)
}

// optionalResourcePresent reports whether the API server serves group/version/kind.
// A missing API is not an error; any other discovery failure is.
func optionalResourcePresent(mgr ctrl.Manager, group, version, kind string) (bool, error) {
	_, err := mgr.GetRESTMapper().RESTMapping(schema.GroupKind{Group: group, Kind: kind}, version)
	if meta.IsNoMatchError(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}
