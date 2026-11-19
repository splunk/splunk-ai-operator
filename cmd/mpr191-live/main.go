// Scoped live readiness validation. This command runs both production
// reconcilers in one disposable namespace, impersonating its test ServiceAccount.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/internal/controller"
	"github.com/splunk/splunk-ai-operator/pkg/config"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

// Faults change only the disposable workload's desired configuration. All
// readiness observations still come from the real API server and kubelet.
// Holding the fault prevents normal reconciliation repairing it before the
// unhealthy observation can be tested. Missing fault files mean normal operation.
type faultClient struct {
	client.Client
	namespace string
	path      string
}

func (c *faultClient) Update(ctx context.Context, obj client.Object, opts ...client.UpdateOption) error {
	if obj.GetNamespace() == c.namespace && c.path != "" {
		raw, err := os.ReadFile(c.path)
		if err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("read validation fault mode: %w", err)
		}
		switch mode := strings.TrimSpace(string(raw)); mode {
		case "", "none":
		case "probe":
			if dep, ok := obj.(*appsv1.Deployment); ok && dep.Labels["feature"] == "agentruntime" {
				for i := range dep.Spec.Template.Spec.Containers {
					probe := dep.Spec.Template.Spec.Containers[i].ReadinessProbe
					if probe != nil && probe.HTTPGet != nil {
						probe.HTTPGet.Path = "/mpr191-unhealthy"
						probe.InitialDelaySeconds = 1
						probe.PeriodSeconds = 2
						probe.FailureThreshold = 1
					}
				}
			}
		case "service":
			if svc, ok := obj.(*corev1.Service); ok && svc.Labels["feature"] == "agentruntime" {
				svc.Spec.Selector = map[string]string{"app": "mpr191-missing-backend"}
			}
		default:
			return fmt.Errorf("unsupported validation fault mode")
		}
	}
	return c.Client.Update(ctx, obj, opts...)
}

func main() {
	namespace := flag.String("namespace", "", "existing disposable mpr191-* namespace")
	faultPath := flag.String("fault-file", "", "optional local validation fault-mode file")
	flag.Parse()
	if !strings.HasPrefix(*namespace, "mpr191-") || len(*namespace) < len("mpr191-")+1 {
		panic("an explicit disposable mpr191-* namespace is required")
	}
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	scheme := runtime.NewScheme()
	for _, add := range []func(*runtime.Scheme) error{
		clientgoscheme.AddToScheme, aiv1.AddToScheme, certmanagerv1.AddToScheme,
		monitoringv1.AddToScheme, rayv1.AddToScheme,
	} {
		if err := add(scheme); err != nil {
			panic(err)
		}
	}
	cfg := ctrl.GetConfigOrDie()
	cfg.Impersonate.UserName = "system:serviceaccount:" + *namespace + ":mpr191-controller"
	cfg.Impersonate.Groups = []string{"system:serviceaccounts", "system:serviceaccounts:" + *namespace, "system:authenticated"}
	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme: scheme,
		Cache:  cache.Options{DefaultNamespaces: map[string]cache.Config{*namespace: {}}},
		NewClient: func(cfg *rest.Config, options client.Options) (client.Client, error) {
			base, err := client.New(cfg, options)
			if err != nil {
				return nil, err
			}
			return &faultClient{Client: base, namespace: *namespace, path: *faultPath}, nil
		},
		Metrics: metricsserver.Options{BindAddress: "0"}, HealthProbeBindAddress: "0", LeaderElection: false,
	})
	if err != nil {
		panic(err)
	}
	if err := (&controller.AIPlatformReconciler{Client: mgr.GetClient(), Scheme: scheme, Recorder: mgr.GetEventRecorderFor("mpr191-platform"), Config: &config.OperatorConfig{Mode: config.ModeNormal}}).SetupWithManager(mgr); err != nil {
		panic(err)
	}
	if err := (&controller.AIServiceReconciler{Client: mgr.GetClient(), Scheme: scheme, Recorder: mgr.GetEventRecorderFor("mpr191-service"), Config: &config.OperatorConfig{Mode: config.ModeNormal}}).SetupWithManager(mgr); err != nil {
		panic(err)
	}
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		panic(err)
	}
}
