package slim

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

func TestManagedAgentRouteBothProfiles(t *testing.T) {
	t.Setenv("RELATED_IMAGE_SLIM_API", "slim-api:route-fixture")
	ctx := context.Background()
	bundle := issuerCertificate(t, time.Now().Add(time.Hour), true)
	for _, profile := range []aiv1.AIPlatformProfile{aiv1.AIPlatformProfileCPUOnly, aiv1.AIPlatformProfileFullFeature} {
		t.Run(string(profile), func(t *testing.T) {
			scheme := buildTestScheme(t)
			require.NoError(t, monitoringv1.AddToScheme(scheme))
			platform := slimPlatform(profile, profile == aiv1.AIPlatformProfileFullFeature)
			platform.UID = "platform"
			platform.Namespace = "route-tests"
			platform.Spec.ClusterDomain = "internal.test"
			platform.Spec.Features = []aiv1.FeatureSpec{{Name: "slim"}, {Name: "agentruntime", Provider: "mltk"}}
			slim := slimService("")
			slim.Generation = 4
			slim.Namespace = platform.Namespace
			slim.Spec.AIPlatformRef.Namespace = platform.Namespace
			slim.Spec.ClusterDomain = platform.Spec.ClusterDomain
			slim.Spec.AIPlatformUrl = "https://models.example.test/ai-platform-models/v1/"
			slim.Spec.SplunkConfiguration = aiv1.SplunkConfigurationSpec{
				Endpoint: "https://issuer.example.test:8089", CACertRef: &corev1.LocalObjectReference{Name: "issuer-ca"},
			}
			require.NoError(t, controllerutil.SetControllerReference(platform, slim, scheme))
			runtimeName := agentruntime.FeatureAIServiceName(platform.Name, "mltk")
			runtime := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{Name: runtimeName, Namespace: platform.Namespace, UID: "runtime", Generation: 3},
				Spec:       aiv1.AIServiceSpec{Feature: aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk"}},
			}
			require.NoError(t, controllerutil.SetControllerReference(platform, runtime, scheme))
			runtimeSvc := &corev1.Service{
				ObjectMeta: metav1.ObjectMeta{Name: agentruntime.ServiceName(runtimeName), Namespace: platform.Namespace, UID: "runtime-svc"},
				Spec: corev1.ServiceSpec{
					Type: corev1.ServiceTypeClusterIP, ClusterIP: "10.96.0.11",
					Selector: map[string]string{"app": runtimeName, "component": runtimeName},
					Ports: []corev1.ServicePort{
						{Name: "http", Port: 8080, TargetPort: intstr.FromInt32(8080)},
						{Name: "metrics", Port: 9090, TargetPort: intstr.FromInt32(9090)},
					},
				},
			}
			require.NoError(t, controllerutil.SetControllerReference(runtime, runtimeSvc, scheme))
			// The fake API does not allocate service addresses, so seed the
			// address the API server would assign when SLIM creates its Service.
			slimSvc := &corev1.Service{
				ObjectMeta: metav1.ObjectMeta{Name: slimServiceName(slim.Name), Namespace: platform.Namespace, UID: "slim-svc"},
				Spec:       corev1.ServiceSpec{ClusterIP: "10.96.0.12"},
			}
			require.NoError(t, controllerutil.SetControllerReference(slim, slimSvc, scheme))
			cert := &corev1.Secret{
				ObjectMeta: metav1.ObjectMeta{Name: "issuer-ca", Namespace: platform.Namespace},
				Data:       map[string][]byte{"ca.crt": bundle},
			}
			c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(slim, runtime).
				WithObjects(platform, slim, runtime, runtimeSvc, slimSvc, cert).Build()
			r := &SlimReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(100)}
			reconcile := func(wantStatus metav1.ConditionStatus, reason, endpoint string) {
				t.Helper()
				require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(slim), slim))
				require.NoError(t, r.Reconcile(ctx, slim))
				condition := meta.FindStatusCondition(slim.Status.Conditions, agentRouteAvailable)
				require.NotNil(t, condition)
				require.Equal(t, wantStatus, condition.Status)
				require.Equal(t, reason, condition.Reason)
				require.Equal(t, slim.Generation, condition.ObservedGeneration)
				if endpoint == "" {
					require.Nil(t, slim.Status.FeatureStatus)
				} else {
					require.Equal(t, endpoint, slim.Status.FeatureStatus.Slim.AITKEndpoint)
				}
			}
			reconcile(metav1.ConditionFalse, "RuntimeUnavailable", "")

			dep := &appsv1.Deployment{}
			require.NoError(t, c.Get(ctx, client.ObjectKey{Namespace: slim.Namespace, Name: slim.Name + "-slim-deployment"}, dep))
			env := map[string]string{}
			for _, v := range dep.Spec.Template.Spec.Containers[0].Env {
				env[v.Name] = v.Value
			}
			require.Equal(t, "http://lp-agentruntime-mltk-svc.route-tests.svc.internal.test:8080", env["AI_TIER_AGENT_RUNTIME_URL"])
			require.Equal(t, "https://models.example.test", env["PLATFORM_URL"])
			require.Equal(t, "AITIER", env["DEPLOYMENT_TYPE"])
			require.Equal(t, "v1alpha1", env["API_VERSION"])
			require.Equal(t, "https://issuer.example.test:8089", env["SPLUNK_ISSUERS"])
			require.Equal(t, "/etc/splunk-issuer-ca/ca.crt", env["SSL_CERT_FILE"])
			require.Equal(t, env["SSL_CERT_FILE"], env["REQUESTS_CA_BUNDLE"])

			runtime.Status.ObservedGeneration = runtime.Generation
			runtime.Status.Conditions = []metav1.Condition{{Type: "Ready", Status: metav1.ConditionTrue, ObservedGeneration: runtime.Generation - 1}}
			require.NoError(t, c.Status().Update(ctx, runtime))
			reconcile(metav1.ConditionFalse, "RuntimeUnavailable", "")
			runtime.Status.Conditions[0].ObservedGeneration = runtime.Generation
			require.NoError(t, c.Status().Update(ctx, runtime))
			const internalEndpoint = "http://lp-slim-slim-service.route-tests.svc.internal.test:8080/tenant/slim-api/v1alpha1"
			reconcile(metav1.ConditionTrue, "EndpointAvailable", internalEndpoint)

			// A published endpoint is retained through each downstream failure,
			// but its current condition changes before it can be used for onboarding.
			runtimeSvc.Spec.Selector["app"] = "other"
			require.NoError(t, c.Update(ctx, runtimeSvc))
			reconcile(metav1.ConditionFalse, "SelectorMismatch", internalEndpoint)
			runtimeSvc.Spec.Selector["app"] = runtimeName
			require.NoError(t, c.Update(ctx, runtimeSvc))
			runtime.Status.Conditions[0].Status = metav1.ConditionFalse
			require.NoError(t, c.Status().Update(ctx, runtime))
			reconcile(metav1.ConditionFalse, "RuntimeUnavailable", internalEndpoint)
			runtime.Status.Conditions[0].Status = metav1.ConditionTrue
			require.NoError(t, c.Status().Update(ctx, runtime))
			reconcile(metav1.ConditionTrue, "EndpointAvailable", internalEndpoint)

			require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(slim), slim))
			slim.Spec.SplunkConfiguration.AITKSlimOrigin = "https://gateway.example.test:8443/"
			require.NoError(t, c.Update(ctx, slim))
			const gatewayEndpoint = "https://gateway.example.test:8443/tenant/slim-api/v1alpha1"
			reconcile(metav1.ConditionTrue, "EndpointAvailable", gatewayEndpoint)
			reconcile(metav1.ConditionTrue, "EndpointAvailable", gatewayEndpoint)
			require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(dep), dep))
			require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(slimSvc), slimSvc))
			// Keep the focused render evidence free of certificates and credential data.
			evidence, err := json.Marshal(map[string]any{
				"deployment": dep.Spec, "slimService": slimSvc.Spec, "runtimeService": runtimeSvc.Spec, "slimStatus": slim.Status,
			})
			require.NoError(t, err)
			t.Logf("route configuration: %s", evidence)

			// A manually supplied origin cannot redirect SLIM to an unrelated
			// Service or expose credentials in its route diagnostics.
			slim.Spec.AgentRuntimeUrl = "https://private@other.example.test"
			require.NoError(t, c.Update(ctx, slim))
			err = r.Reconcile(ctx, slim)
			require.ErrorContains(t, err, "must match the selected internal AgentRuntime")
			require.NotContains(t, err.Error(), "private")
			require.Equal(t, metav1.ConditionFalse, meta.FindStatusCondition(slim.Status.Conditions, agentRouteAvailable).Status)
			require.Equal(t, gatewayEndpoint, slim.Status.FeatureStatus.Slim.AITKEndpoint)

			require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(slim), slim))
			slim.Spec.AgentRuntimeUrl = ""
			require.NoError(t, c.Update(ctx, slim))
			require.NoError(t, c.Delete(ctx, runtime))
			reconcile(metav1.ConditionFalse, "RuntimeUnavailable", gatewayEndpoint)
			current := &appsv1.Deployment{}
			require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(dep), current))
			require.Equal(t, dep.Spec.Template, current.Spec.Template)
		})
	}
}

func TestAITKOriginRejectsTransportAndPathMismatch(t *testing.T) {
	for _, origin := range []string{
		"/", "http://gateway.example.test", "https://gateway.example.test/rewrite",
		"https://gateway.example.test/?q=private", "https://private@gateway.example.test",
		"https://gateway.example.test#private", "https://gateway.example.test:65536",
	} {
		t.Run(origin, func(t *testing.T) {
			ai := slimService("")
			ai.Spec.SplunkConfiguration.AITKSlimOrigin = origin
			err := validateAITKOrigin(ai)
			require.ErrorContains(t, err, "must be an HTTPS origin")
			require.NotContains(t, err.Error(), "private")
		})
	}
}
