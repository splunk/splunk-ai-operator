// Temporary live validation controller. It runs the production AIService
// reconciler with a cache restricted to one labelled disposable AIService.
package main

import (
	"os"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/internal/controller"
	"github.com/splunk/splunk-ai-operator/pkg/config"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

func main() {
	labelValue := os.Getenv("MPR189_TEST_LABEL_VALUE")
	if labelValue == "" {
		panic("MPR189_TEST_LABEL_VALUE is required")
	}
	scheme := runtime.NewScheme()
	for _, add := range []func(*runtime.Scheme) error{
		clientgoscheme.AddToScheme,
		aiv1.AddToScheme,
		certmanagerv1.AddToScheme,
		monitoringv1.AddToScheme,
		rayv1.AddToScheme,
	} {
		if err := add(scheme); err != nil {
			panic(err)
		}
	}
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme: scheme,
		Cache: cache.Options{ByObject: map[client.Object]cache.ByObject{
			&aiv1.AIService{}: {Label: labels.SelectorFromSet(labels.Set{"mpr189-validation": labelValue})},
		}},
		Metrics:                metricsserver.Options{BindAddress: "0"},
		HealthProbeBindAddress: "0",
		LeaderElection:         false,
	})
	if err != nil {
		panic(err)
	}
	if err := (&controller.AIServiceReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorderFor("mpr189-live"),
		Config:   &config.OperatorConfig{Mode: config.ModeNormal},
	}).SetupWithManager(mgr); err != nil {
		panic(err)
	}
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		panic(err)
	}
}
