package raystatus

import (
	"context"
	"fmt"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/selection"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	kuberayutils "github.com/ray-project/kuberay/ray-operator/controllers/ray/utils"
)

// RaySnapshot is a normalized view we can write into CR status or use to derive conditions.
type RaySnapshot struct {
	// From RayService
	ServiceReady         bool
	UpgradeInProgress    bool
	ServiceStatusRunning bool // legacy/fallback
	ActiveClusterName    string
	ObservedGeneration   int64

	// From cluster discovery
	HeadPodReady            bool
	DesiredWorkerReplicas   int32
	AvailableWorkerReplicas int32

	// Serve routing
	ServeServiceName       string
	ServeServiceHasBackend bool

	// Useful details
	HeadServiceName string
	HeadPodName     string
	HeadServiceIP   string

	// Endpoints from RayClusterStatus.Endpoints (map[string]string)
	EndpointMap   map[string]string
	DashboardURL  string
	ServeURL      string
	DashboardPort int32 // parsed from DashboardURL if present
	ServePort     int32 // parsed from ServeURL if present
}

// CollectRaySnapshot gathers status from RayService, RayCluster, and K8s Services/Endpoints.
func CollectRaySnapshot(ctx context.Context, c client.Client, ns, name string) (*RaySnapshot, error) {
	// Derive the stable service names the same way KubeRay does (CheckName front-truncates
	// names over ~41 chars), so status never publishes a Service that doesn't exist.
	headServiceName, err := kuberayutils.GenerateHeadServiceName(kuberayutils.RayServiceCRD, rayv1.RayClusterSpec{}, name)
	if err != nil {
		return nil, fmt.Errorf("generate RayService head service name: %w", err)
	}
	snap := &RaySnapshot{
		HeadServiceName:  headServiceName,
		ServeServiceName: kuberayutils.GenerateServeServiceName(name),
	}

	// 1) RayService
	rs := &rayv1.RayService{}
	if err := c.Get(ctx, types.NamespacedName{Namespace: ns, Name: name}, rs); err != nil {
		return nil, err
	}
	snap.ObservedGeneration = rs.Status.ObservedGeneration

	// conditions (Ready, UpgradeInProgress) as before...
	for _, cond := range rs.Status.Conditions {
		switch cond.Type {
		case "Ready":
			snap.ServiceReady = cond.Status == metav1.ConditionTrue
		case "UpgradeInProgress":
			snap.UpgradeInProgress = cond.Status == metav1.ConditionTrue
		}
	}
	snap.ServiceStatusRunning = rs.Status.ServiceStatus == rayv1.Running

	// Active cluster & endpoints map
	if rs.Status.ActiveServiceStatus.RayClusterName != "" {
		snap.ActiveClusterName = rs.Status.ActiveServiceStatus.RayClusterName
	}
	// ⚠️ endpoints is map[string]string
	snap.EndpointMap = rs.Status.ActiveServiceStatus.RayClusterStatus.Endpoints

	// surface common URLs if present (case-insensitive keys)
	snap.ServeURL = getEndpointURL(snap.EndpointMap, "Serve", "serve", "SERVE", "RayServe", "rayserve")
	snap.DashboardURL = getEndpointURL(snap.EndpointMap, "Dashboard", "dashboard")

	// best-effort ports
	snap.ServePort = parsePort(snap.ServeURL)
	snap.DashboardPort = parsePort(snap.DashboardURL)

	// Collect active RayCluster head details for diagnostics, but keep
	// HeadServiceName on the stable RayService endpoint initialized above.
	h := rs.Status.ActiveServiceStatus.RayClusterStatus.Head
	snap.HeadServiceIP = h.ServiceIP
	snap.HeadPodName = h.PodName

	// fallback cluster naming if not present
	if snap.ActiveClusterName == "" {
		snap.ActiveClusterName = fmt.Sprintf("%s-raycluster", name)
	}

	// 2) RayCluster readiness (as before: conditions/state/pods)
	// ... (unchanged code that sets HeadPodReady, DesiredWorkerReplicas, AvailableWorkerReplicas) ...

	// 3) Serve service endpoints (is traffic routable?)
	ep := &corev1.Endpoints{}
	if err := c.Get(ctx, types.NamespacedName{Namespace: ns, Name: snap.ServeServiceName}, ep); err == nil {
		for _, subset := range ep.Subsets {
			if len(subset.Addresses) > 0 {
				snap.ServeServiceHasBackend = true
				break
			}
		}
	}

	return snap, nil
}

func checkHeadPodReady(ctx context.Context, c client.Client, ns, clusterName string) (bool, error) {
	req1, _ := labels.NewRequirement("ray.io/cluster", selection.Equals, []string{clusterName})
	req2, _ := labels.NewRequirement("ray.io/node-type", selection.Equals, []string{"head"})
	selector := labels.NewSelector().Add(*req1, *req2)

	var pods corev1.PodList
	if err := c.List(ctx, &pods, &client.ListOptions{Namespace: ns, LabelSelector: selector}); err != nil {
		return false, err
	}
	for _, p := range pods.Items {
		if isPodReady(&p) {
			return true, nil
		}
	}
	return false, nil
}

func isPodReady(p *corev1.Pod) bool {
	for _, cond := range p.Status.Conditions {
		if cond.Type == corev1.PodReady && cond.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

func sumWorkerReplicas(ctx context.Context, c client.Client, ns, clusterName string) (desired, available int32, _ error) {
	req1, _ := labels.NewRequirement("ray.io/cluster", selection.Equals, []string{clusterName})
	req2, _ := labels.NewRequirement("ray.io/node-type", selection.Equals, []string{"worker"})
	selector := labels.NewSelector().Add(*req1, *req2)

	var sts appsv1.StatefulSetList
	if err := c.List(ctx, &sts, &client.ListOptions{Namespace: ns, LabelSelector: selector}); err != nil {
		return 0, 0, err
	}
	for _, s := range sts.Items {
		if s.Spec.Replicas != nil {
			desired += *s.Spec.Replicas
		}
		available += s.Status.ReadyReplicas
	}
	return desired, available, nil
}

// ApplyNormalizedConditions writes consolidated conditions onto your CR (AIPlatform or AIService).
// It prefers RayService Ready + Serve endpoints + HeadReady + worker readiness.
// Tweak the policy as you like (e.g., require 100% workers or a threshold).
func ApplyNormalizedConditions(conds *[]metav1.Condition, snap *RaySnapshot) {
	now := metav1.NewTime(time.Now())

	set := func(t, reason, msg string, status metav1.ConditionStatus) {
		meta.SetStatusCondition(conds, metav1.Condition{
			Type:               t,
			Status:             status,
			Reason:             reason,
			Message:            msg,
			LastTransitionTime: now,
		})
	}

	// RayServiceReady (prefer Conditions; fallback to ServiceStatus)
	rsReady := snap.ServiceReady || snap.ServiceStatusRunning
	set("RayServiceReady",
		map[bool]string{true: "Ready", false: "NotReady"}[rsReady],
		fmt.Sprintf("Ready=%t UpgradeInProgress=%t", rsReady, snap.UpgradeInProgress),
		map[bool]metav1.ConditionStatus{true: metav1.ConditionTrue, false: metav1.ConditionFalse}[rsReady],
	)

	// RayServiceUpgradeInProgress
	set("RayServiceUpgradeInProgress",
		map[bool]string{true: "Upgrading", false: "Idle"}[snap.UpgradeInProgress],
		"Zero-downtime upgrade status as reported by KubeRay",
		map[bool]metav1.ConditionStatus{true: metav1.ConditionTrue, false: metav1.ConditionFalse}[snap.UpgradeInProgress],
	)

	// RayClusterReady (combine head + workers). Adjust the policy to your SLOs.
	clusterReady := snap.HeadPodReady && snap.DesiredWorkerReplicas == snap.AvailableWorkerReplicas
	set("RayClusterReady",
		map[bool]string{true: "AllPodsReady", false: "PodsNotReady"}[clusterReady],
		fmt.Sprintf("workers %d/%d headReady=%t", snap.AvailableWorkerReplicas, snap.DesiredWorkerReplicas, snap.HeadPodReady),
		map[bool]metav1.ConditionStatus{true: metav1.ConditionTrue, false: metav1.ConditionFalse}[clusterReady],
	)

	// RayServeRouteReady (is serve service backed by endpoints?)
	set("RayServeRouteReady",
		map[bool]string{true: "EndpointsAvailable", false: "NoEndpoints"}[snap.ServeServiceHasBackend],
		fmt.Sprintf("service=%s endpointsBacked=%t", snap.ServeServiceName, snap.ServeServiceHasBackend),
		map[bool]metav1.ConditionStatus{true: metav1.ConditionTrue, false: metav1.ConditionFalse}[snap.ServeServiceHasBackend],
	)

	// Optional: PlatformReady – a top-level rollup you can show to users
	platformReady := rsReady && clusterReady && snap.ServeServiceHasBackend
	set("Ready",
		map[bool]string{true: "AllHealthy", false: "Degraded"}[platformReady],
		"Composite of RayServiceReady ∧ RayClusterReady ∧ RayServeRouteReady",
		map[bool]metav1.ConditionStatus{true: metav1.ConditionTrue, false: metav1.ConditionFalse}[platformReady],
	)
}
