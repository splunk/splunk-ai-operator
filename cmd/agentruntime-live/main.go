// Scoped live runtime validation. This command runs both production
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
	webhookv1 "github.com/splunk/splunk-ai-operator/internal/webhook/v1"
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
	"sigs.k8s.io/controller-runtime/pkg/webhook"
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
						probe.HTTPGet.Path = "/credential-validation-unhealthy"
						probe.InitialDelaySeconds = 1
						probe.PeriodSeconds = 2
						probe.FailureThreshold = 1
					}
				}
			}
		case "service":
			if svc, ok := obj.(*corev1.Service); ok && svc.Labels["feature"] == "agentruntime" {
				svc.Spec.Selector = map[string]string{"app": "credential-validation-missing-backend"}
			}
		default:
			return fmt.Errorf("unsupported validation fault mode")
		}
	}
	return c.Client.Update(ctx, obj, opts...)
}

func main() {
	namespace := flag.String("namespace", "", "existing disposable credential-validation-* namespace")
	faultPath := flag.String("fault-file", "", "optional local validation fault-mode file")
	certDir := flag.String("webhook-cert-dir", "", "temporary TLS certificate directory for isolated admission validation")
	flag.Parse()
	if *certDir == "" {
		panic("an explicit temporary webhook certificate directory is required")
	}
	// Require an explicit test namespace before constructing any clients.
	if !strings.HasPrefix(*namespace, "credential-validation-") || len(*namespace) < len("credential-validation-")+1 {
		panic("an explicit disposable credential-validation-* namespace is required")
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
	// Namespace-scoped caching limits observations; impersonation also makes API
	// requests exercise the test ServiceAccount's permissions instead of admin
	// permissions from the kubeconfig used to start this process.
	cfg.Impersonate.UserName = "system:serviceaccount:" + *namespace + ":credential-validation-controller"
	cfg.Impersonate.Groups = []string{"system:serviceaccounts", "system:serviceaccounts:" + *namespace, "system:authenticated"}
	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:        scheme,
		WebhookServer: webhook.NewServer(webhook.Options{Host: "0.0.0.0", Port: 19443, CertDir: *certDir}),
		Cache:         cache.Options{DefaultNamespaces: map[string]cache.Config{*namespace: {}}},
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
	// Register the production admission handlers on the isolated TLS endpoint.
	// The API server configuration selects only the disposable namespace.
	if err := webhookv1.SetupAIPlatformWebhookWithManager(mgr); err != nil {
		panic(err)
	}
	if err := webhookv1.SetupAIServiceWebhookWithManager(mgr); err != nil {
		panic(err)
	}
	// Register both controllers so the fixture exercises child health events and
	// their effect on parent readiness through the normal production watches.
	if err := (&controller.AIPlatformReconciler{Client: mgr.GetClient(), Scheme: scheme, Recorder: mgr.GetEventRecorderFor("credential-validation-platform"), Config: &config.OperatorConfig{Mode: config.ModeNormal}}).SetupWithManager(mgr); err != nil {
		panic(err)
	}
	if err := (&controller.AIServiceReconciler{Client: mgr.GetClient(), Scheme: scheme, Recorder: mgr.GetEventRecorderFor("credential-validation-service"), Config: &config.OperatorConfig{Mode: config.ModeNormal}}).SetupWithManager(mgr); err != nil {
		panic(err)
	}
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		panic(err)
	}
}
