package controller

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrlconfig "sigs.k8s.io/controller-runtime/pkg/config"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

// serviceMonitorStandIn is a permissive CRD for monitoring.coreos.com ServiceMonitor.
// The real Prometheus-operator CRD YAML is not vendored, and these specs only need
// the API to exist; the cert-manager Certificate CRD below is the real one.
func serviceMonitorStandIn() *apiextensionsv1.CustomResourceDefinition {
	preserve := true
	return &apiextensionsv1.CustomResourceDefinition{
		ObjectMeta: metav1.ObjectMeta{Name: "servicemonitors.monitoring.coreos.com"},
		Spec: apiextensionsv1.CustomResourceDefinitionSpec{
			Group: "monitoring.coreos.com",
			Names: apiextensionsv1.CustomResourceDefinitionNames{Plural: "servicemonitors", Singular: "servicemonitor", Kind: "ServiceMonitor", ListKind: "ServiceMonitorList"},
			Scope: apiextensionsv1.NamespaceScoped,
			Versions: []apiextensionsv1.CustomResourceDefinitionVersion{{
				Name: "v1", Served: true, Storage: true,
				Schema: &apiextensionsv1.CustomResourceValidation{OpenAPIV3Schema: &apiextensionsv1.JSONSchemaProps{
					Type: "object", XPreserveUnknownFields: &preserve,
				}},
			}},
		},
	}
}

// End to end, with the two real controllers and the real handlers on a real
// API server that has no KubeRay CRDs: a cpuOnly platform with slim and
// agentruntime must come up, SLIM pointing at the AgentRuntime Service and
// neither getting a Ray platform URL.
var _ = Describe("cpuOnly AIPlatform end to end without KubeRay", func() {
	It("creates the SLIM and AgentRuntime workloads wired to each other, with no Ray", func() {
		waitForAPIAbsent("ray.io/v1") // KubeRay must really be absent, whatever spec ran before
		for k, v := range map[string]string{
			"RELATED_IMAGE_SLIM_API":                     "docker.io/splunk/slim:test",
			"RELATED_IMAGE_AGENT_RUNTIME_BASE":           "docker.io/splunk/agent-runtime:test",
			"RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_MLTK":  "docker.io/splunk/agent-runtime-provider-mltk:test",
			"RELATED_AGENT_RUNTIME_MODULE_PROVIDER_MLTK": "agentcore_operations.loader:MLTKAgentLoader",
			"RELATED_IMAGE_AGENT_RUNTIME_SCHEMA_SETUP":   "docker.io/splunk/agent-runtime-schema-setup@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		} {
			Expect(os.Setenv(k, v)).To(Succeed())
			DeferCleanup(func(key string) { _ = os.Unsetenv(key) }, k)
		}

		// APIs the handlers need that a cpuOnly cluster still has: cert-manager and
		// a ServiceMonitor API. KubeRay is deliberately NOT installed.
		certDir, err := goModDir("github.com/cert-manager/cert-manager")
		Expect(err).NotTo(HaveOccurred())
		certCRDs, err := envtest.InstallCRDs(cfg, envtest.CRDInstallOptions{
			Paths:              []string{filepath.Join(certDir, "deploy", "crds", "cert-manager.io_certificates.yaml")},
			ErrorIfPathMissing: true,
		})
		Expect(err).NotTo(HaveOccurred())
		smCRDs, err := envtest.InstallCRDs(cfg, envtest.CRDInstallOptions{CRDs: []*apiextensionsv1.CustomResourceDefinition{serviceMonitorStandIn()}})
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(func() {
			_ = envtest.UninstallCRDs(cfg, envtest.CRDInstallOptions{CRDs: append(certCRDs, smCRDs...)})
			waitForAPIAbsent("cert-manager.io/v1")
			waitForAPIAbsent("monitoring.coreos.com/v1")
		})

		sch := runtime.NewScheme()
		Expect(clientgoscheme.AddToScheme(sch)).To(Succeed())
		Expect(aiv1.AddToScheme(sch)).To(Succeed())
		Expect(rayv1.AddToScheme(sch)).To(Succeed()) // Go types linked; the API is absent
		Expect(certmanagerv1.AddToScheme(sch)).To(Succeed())
		Expect(monitoringv1.AddToScheme(sch)).To(Succeed())

		mgr, err := ctrl.NewManager(cfg, ctrl.Options{
			Scheme:     sch,
			Metrics:    metricsserver.Options{BindAddress: "0"},
			Controller: ctrlconfig.Controller{SkipNameValidation: boolPtr(true)},
		})
		Expect(err).NotTo(HaveOccurred())
		Expect((&AIPlatformReconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme(), Recorder: mgr.GetEventRecorderFor("e2e-platform")}).SetupWithManager(mgr)).To(Succeed())
		Expect((&AIServiceReconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme(), Recorder: mgr.GetEventRecorderFor("e2e-service")}).SetupWithManager(mgr)).To(Succeed())
		mctx, mcancel := context.WithCancel(ctx)
		DeferCleanup(mcancel)
		started := make(chan error, 1)
		go func() {
			defer GinkgoRecover()
			started <- mgr.Start(mctx)
		}()

		ns := "default"
		secret := &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{Name: "e2e-pg", Namespace: ns},
			Type:       corev1.SecretTypeOpaque,
			StringData: map[string]string{"DATABASE_URL": "postgresql://u:p@h:5432/d", "PG_HOST": "h", "PG_PORT": "5432", "PG_USER": "u", "PG_PASSWORD": "p", "PG_DBNAME": "d"},
		}
		Expect(k8sClient.Create(ctx, secret)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, secret) })

		name := fmt.Sprintf("e2e-%d", time.Now().UnixNano()%1000000)
		p := &aiv1.AIPlatform{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns},
			Spec: aiv1.AIPlatformSpec{
				Profile:       aiv1.AIPlatformProfileCPUOnly,
				ObjectStorage: aiv1.ObjectStorageSpec{Path: "s3://bucket", Region: "us-west-2"},
				Features: []aiv1.FeatureSpec{
					{Name: "slim", Version: "1.0.0"},
					{Name: "agentruntime", Provider: "mltk", CheckpointDbSecretRef: "e2e-pg"},
				},
			},
		}
		Expect(k8sClient.Create(ctx, p)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, p) })

		// SLIM reaches its Deployment with no Ray in the picture.
		var slimDep appsv1.Deployment
		Eventually(func() error {
			select {
			case err := <-started:
				return fmt.Errorf("manager stopped: %v", err)
			default:
			}
			return k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: name + "-slim-slim-deployment"}, &slimDep)
		}, 60*time.Second, time.Second).Should(Succeed())

		envOf := func(d *appsv1.Deployment) map[string]string {
			m := map[string]string{}
			for _, e := range d.Spec.Template.Spec.Containers[0].Env {
				m[e.Name] = e.Value
			}
			return m
		}
		slimEnv := envOf(&slimDep)
		// MPR-188: SLIM always receives both variables. With no Ray platform behind a
		// cpuOnly platform PLATFORM_URL carries the (empty) resolved input, which is an
		// observation of this fixture, not a constraint: a supplied value is kept.
		Expect(slimEnv).To(HaveKeyWithValue("PLATFORM_URL", ""), "cpuOnly SLIM has no Ray platform URL to derive")
		Expect(slimEnv).To(HaveKey("AI_TIER_AGENT_RUNTIME_URL"))
		Expect(slimEnv["AI_TIER_AGENT_RUNTIME_URL"]).To(MatchRegexp(`^http://%s-agentruntime-mltk-svc\.default\.svc\.cluster\.local:8080$`, name))

		// AgentRuntime passes validation (no Ray wait, no platform URL) and reaches the
		// schema Job, the first stage after validation, rather than failing on Ray.
		var ai aiv1.AIService
		Eventually(func() bool {
			if err := k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: name + "-agentruntime-mltk"}, &ai); err != nil {
				return false
			}
			for _, c := range ai.Status.Conditions {
				if c.Type == "ValidateReady" && c.Status == metav1.ConditionTrue {
					return true
				}
			}
			return false
		}, 60*time.Second, time.Second).Should(BeTrue(), "AgentRuntime validation must pass without Ray; conditions: %+v", ai.Status.Conditions)

		// The real API server emits a Job status-only update. Completion must
		// wake the AIService controller promptly, without waiting for error backoff.
		var schemaJob batchv1.Job
		Eventually(func() error {
			if err := k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: name + "-agentruntime-mltk"}, &ai); err != nil {
				return err
			}
			featureStatus := ai.Status.FeatureStatus
			if featureStatus == nil || featureStatus.AgentRuntime == nil || featureStatus.AgentRuntime.Schema == nil || featureStatus.AgentRuntime.Schema.JobName == "" {
				return fmt.Errorf("schema Job not recorded yet")
			}
			return k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: featureStatus.AgentRuntime.Schema.JobName}, &schemaJob)
		}, 30*time.Second, 100*time.Millisecond).Should(Succeed())
		finishedAt := metav1.Now()
		schemaJob.Status.StartTime = &finishedAt
		schemaJob.Status.CompletionTime = &finishedAt
		schemaJob.Status.Succeeded = 1
		schemaJob.Status.Conditions = []batchv1.JobCondition{
			{Type: batchv1.JobSuccessCriteriaMet, Status: corev1.ConditionTrue, LastTransitionTime: finishedAt},
			{Type: batchv1.JobComplete, Status: corev1.ConditionTrue, LastTransitionTime: finishedAt},
		}
		Expect(k8sClient.Status().Update(ctx, &schemaJob)).To(Succeed())
		Eventually(func() bool {
			if err := k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: ai.Name}, &ai); err != nil {
				return false
			}
			for _, c := range ai.Status.Conditions {
				if c.Type == "PostgresSchemaSetupReady" && c.Status == metav1.ConditionTrue {
					return true
				}
			}
			return false
		}, 3*time.Second, 100*time.Millisecond).Should(BeTrue(), "completed schema Job must wake AIService promptly")
		Expect(ai.Status.FeatureStatus).NotTo(BeNil(), "AgentRuntime status must survive the API server status update")
		Expect(ai.Status.FeatureStatus.AgentRuntime).NotTo(BeNil())
		Expect(ai.Status.FeatureStatus.AgentRuntime.Schema).NotTo(BeNil())
		Expect(ai.Status.FeatureStatus.AgentRuntime.Schema.AppliedHash).NotTo(BeEmpty())
		Expect(ai.Status.SchemaJobId).To(BeEmpty(), "AgentRuntime must not use the legacy SAIA schema Job field")
		var slimAI aiv1.AIService
		Expect(k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: name + "-slim"}, &slimAI)).To(Succeed())
		Expect(slimAI.Status.FeatureStatus).To(BeNil(), "SLIM must not acquire AgentRuntime status")
		verifyRuntimeReadinessWithControllers(&ai, p, sch)

		// Nothing Ray or Weaviate was ever created.
		var deps appsv1.DeploymentList
		Expect(k8sClient.List(ctx, &deps, client.InNamespace(ns))).To(Succeed())
		for _, d := range deps.Items {
			if strings.HasPrefix(d.Name, name) {
				Expect(d.Name).NotTo(ContainSubstring("weaviate"))
				Expect(d.Name).NotTo(ContainSubstring("ray"))
			}
		}
		var sts appsv1.StatefulSetList
		Expect(k8sClient.List(ctx, &sts, client.InNamespace(ns))).To(Succeed())
		for _, s := range sts.Items {
			Expect(s.Name).NotTo(HavePrefix(name), "no Weaviate StatefulSet for cpuOnly")
		}

		// The platform published its profile and the manager never stopped.
		var got aiv1.AIPlatform
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(p), &got)).To(Succeed())
		Expect(got.Status.Profile).To(Equal(aiv1.AIPlatformProfileCPUOnly))
		Consistently(started, time.Second).ShouldNot(Receive())
	})
})
