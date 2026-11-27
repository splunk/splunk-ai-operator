package controller

import (
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/discovery"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrlconfig "sigs.k8s.io/controller-runtime/pkg/config"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

// A cpuOnly installation has no KubeRay, so the ray.io CRDs do not exist in the
// cluster (the installer even requires components.kuberay: false for cpuOnly).
// The operator must still start and reconcile. This runs the real controller
// against a real API server whose only CRDs are this operator's own
// (config/crd/bases), i.e. with no RayService or RayCluster API at all.
var _ = Describe("AIPlatform controller in a cluster without KubeRay", func() {
	It("starts and reconciles a cpuOnly AIPlatform", func() {
		waitForAPIAbsent("ray.io/v1") // another spec may have just uninstalled it
		sch := runtime.NewScheme()
		Expect(clientgoscheme.AddToScheme(sch)).To(Succeed())
		Expect(aiv1.AddToScheme(sch)).To(Succeed())
		// The Go types are registered (the operator binary always links them);
		// what is missing is the API in the cluster.
		Expect(rayv1.AddToScheme(sch)).To(Succeed())

		mgr, err := ctrl.NewManager(cfg, ctrl.Options{
			Scheme:         sch,
			Metrics:        metricsserver.Options{BindAddress: "0"},
			LeaderElection: false,
			Controller:     ctrlconfig.Controller{SkipNameValidation: boolPtr(true)},
		})
		Expect(err).NotTo(HaveOccurred())

		Expect((&AIPlatformReconciler{
			Client:   mgr.GetClient(),
			Scheme:   mgr.GetScheme(),
			Recorder: mgr.GetEventRecorderFor("aiplatform-nokuberay-test"),
		}).SetupWithManager(mgr)).To(Succeed())

		mctx, mcancel := context.WithCancel(ctx)
		DeferCleanup(mcancel)
		started := make(chan error, 1)
		go func() {
			defer GinkgoRecover()
			started <- mgr.Start(mctx)
		}()

		runtimePolicy := agentRuntimePolicyForControllerTest()
		p := &aiv1.AIPlatform{
			ObjectMeta: metav1.ObjectMeta{Name: fmt.Sprintf("nokuberay-%d", time.Now().UnixNano()%1000000), Namespace: "default"},
			Spec: aiv1.AIPlatformSpec{
				Profile:       aiv1.AIPlatformProfileCPUOnly,
				ObjectStorage: aiv1.ObjectStorageSpec{Path: "s3://bucket", Region: "us-west-2"},
				Features: []aiv1.FeatureSpec{
					{Name: "slim", Version: "1.0.0"},
					{Name: "agentruntime", Provider: "launchpad", CheckpointDbSecretRef: "pg", NetworkPolicy: runtimePolicy},
				},
			},
		}
		Expect(k8sClient.Create(ctx, p)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, p) })

		// The reconciler runs and publishes the resolved profile.
		Eventually(func() (aiv1.AIPlatformProfile, error) {
			select {
			case err := <-started:
				return "", fmt.Errorf("the manager stopped before reconciling: %v", err)
			default:
			}
			var got aiv1.AIPlatform
			if err := k8sClient.Get(ctx, client.ObjectKeyFromObject(p), &got); err != nil {
				return "", err
			}
			return got.Status.Profile, nil
		}, 30*time.Second, 500*time.Millisecond).Should(Equal(aiv1.AIPlatformProfileCPUOnly))

		// The manager is still running, and the platform created its AIService
		// child with no Ray or Weaviate involved.
		Consistently(started, 2*time.Second).ShouldNot(Receive())
		var children aiv1.AIServiceList
		Eventually(func() int {
			Expect(k8sClient.List(ctx, &children, client.InNamespace("default"))).To(Succeed())
			n := 0
			for _, c := range children.Items {
				if metav1.IsControlledBy(&c, p) {
					n++
				}
			}
			return n
		}, 20*time.Second, 500*time.Millisecond).Should(Equal(2), "slim and agentruntime")

		// SLIM is pointed at the AgentRuntime Service (cpuOnly has no Ray URL).
		for _, c := range children.Items {
			if !metav1.IsControlledBy(&c, p) {
				continue
			}
			switch c.Spec.Feature.Name {
			case "agentruntime":
				Expect(c.Spec.Feature.NetworkPolicy).To(Equal(runtimePolicy))
			case "slim":
				Expect(c.Spec.AIPlatformUrl).To(BeEmpty())
				Expect(c.Spec.AgentRuntimeUrl).To(MatchRegexp(`^http://.+-svc\.default\.svc\.cluster\.local:8080$`))
				Expect(c.Spec.AgentRuntimeUrl).To(ContainSubstring(p.Name + "-agentruntime-launchpad"))
			}
		}
	})
})

func boolPtr(b bool) *bool { return &b }

// The other direction: when KubeRay IS installed the Ray watches are registered
// exactly as before, so fullfeature installations lose nothing.
var _ = Describe("AIPlatform controller in a cluster with KubeRay", func() {
	It("detects the Ray APIs only once their CRDs are installed, and still starts", func() {
		sch := runtime.NewScheme()
		Expect(clientgoscheme.AddToScheme(sch)).To(Succeed())
		Expect(aiv1.AddToScheme(sch)).To(Succeed())
		Expect(rayv1.AddToScheme(sch)).To(Succeed())

		newManager := func() ctrl.Manager {
			mgr, err := ctrl.NewManager(cfg, ctrl.Options{
				Scheme:         sch,
				Metrics:        metricsserver.Options{BindAddress: "0"},
				LeaderElection: false,
				Controller:     ctrlconfig.Controller{SkipNameValidation: boolPtr(true)},
			})
			Expect(err).NotTo(HaveOccurred())
			return mgr
		}

		before, err := optionalResourcePresent(newManager(), "ray.io", "v1", "RayService")
		Expect(err).NotTo(HaveOccurred())
		Expect(before).To(BeFalse(), "no KubeRay CRDs are installed yet")

		out, err := exec.Command("go", "list", "-m", "-f", "{{.Dir}}", "github.com/ray-project/kuberay/ray-operator").Output()
		Expect(err).NotTo(HaveOccurred())
		crdDir := filepath.Join(strings.TrimSpace(string(out)), "config", "crd", "bases")
		crds, err := envtest.InstallCRDs(cfg, envtest.CRDInstallOptions{
			Paths: []string{
				filepath.Join(crdDir, "ray.io_rayservices.yaml"),
				filepath.Join(crdDir, "ray.io_rayclusters.yaml"),
			},
			ErrorIfPathMissing: true,
		})
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(func() {
			_ = envtest.UninstallCRDs(cfg, envtest.CRDInstallOptions{CRDs: crds})
			waitForAPIAbsent("ray.io/v1")
		})

		mgr := newManager()
		for _, kind := range []string{"RayService", "RayCluster"} {
			present, err := optionalResourcePresent(mgr, "ray.io", "v1", kind)
			Expect(err).NotTo(HaveOccurred())
			Expect(present).To(BeTrue(), "%s is served once KubeRay is installed", kind)
		}

		Expect((&AIPlatformReconciler{
			Client:   mgr.GetClient(),
			Scheme:   mgr.GetScheme(),
			Recorder: mgr.GetEventRecorderFor("aiplatform-kuberay-test"),
		}).SetupWithManager(mgr)).To(Succeed())
		mctx, mcancel := context.WithCancel(ctx)
		DeferCleanup(mcancel)
		started := make(chan error, 1)
		go func() {
			defer GinkgoRecover()
			started <- mgr.Start(mctx)
		}()
		Consistently(started, 3*time.Second).ShouldNot(Receive(), "the manager runs with the Ray watches registered")
	})
})

// goModDir returns the directory of a dependency in the module cache.
func goModDir(module string) (string, error) {
	out, err := exec.Command("go", "list", "-m", "-f", "{{.Dir}}", module).Output()
	return strings.TrimSpace(string(out)), err
}

// waitForAPIAbsent blocks until the API server no longer serves groupVersion.
// Uninstalling a CRD is asynchronous: the API stays discoverable for a moment, and
// a manager built in that window registers watches on an API that then vanishes.
// Specs that install CRDs wait here when they clean up, and specs that depend on
// an API being absent assert it first, so spec order cannot make them flaky.
func waitForAPIAbsent(groupVersion string) {
	disco, err := discovery.NewDiscoveryClientForConfig(cfg)
	Expect(err).NotTo(HaveOccurred())
	Eventually(func() bool {
		_, err := disco.ServerResourcesForGroupVersion(groupVersion)
		return apierrors.IsNotFound(err)
	}, 60*time.Second, 250*time.Millisecond).Should(BeTrue(), "%s is still served", groupVersion)
}
