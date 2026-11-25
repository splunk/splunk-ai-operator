package agentruntime

// MPR-202: which objects an AgentRuntime AIService owns, so that deleting it removes
// exactly those (through Kubernetes garbage collection) and never a customer's.
//
// Envtest runs a real API server but no garbage collector, so these tests check the
// set the collector would remove: every object whose owner references name the
// AIService's UID. The cascade itself is shown on a cluster (see
// docs/agent-runtime/mpr-202-validation.md).

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	cmmeta "github.com/cert-manager/cert-manager/pkg/apis/meta/v1"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
)

type ownershipEnv struct {
	t   *testing.T
	ctx context.Context
	c   client.WithWatch
	r   *AgentRuntimeReconciler
}

func startOwnershipEnv(t *testing.T) *ownershipEnv {
	t.Helper()
	root := filepath.Join("..", "..", "..", "..")
	out, err := exec.Command("go", "list", "-m", "-f", "{{.Dir}}", "github.com/cert-manager/cert-manager").Output()
	require.NoError(t, err)
	preserve := true
	testEnv := &envtest.Environment{
		CRDDirectoryPaths: []string{
			filepath.Join(root, "config", "crd", "bases"),
			filepath.Join(strings.TrimSpace(string(out)), "deploy", "crds", "cert-manager.io_certificates.yaml"),
		},
		// The Prometheus operator CRD is not vendored; a permissive stand-in serves the API.
		CRDs: []*apiextensionsv1.CustomResourceDefinition{{
			ObjectMeta: metav1.ObjectMeta{Name: "servicemonitors.monitoring.coreos.com"},
			Spec: apiextensionsv1.CustomResourceDefinitionSpec{
				Group: "monitoring.coreos.com", Scope: apiextensionsv1.NamespaceScoped,
				Names: apiextensionsv1.CustomResourceDefinitionNames{Plural: "servicemonitors", Singular: "servicemonitor", Kind: "ServiceMonitor", ListKind: "ServiceMonitorList"},
				Versions: []apiextensionsv1.CustomResourceDefinitionVersion{{Name: "v1", Served: true, Storage: true,
					Schema: &apiextensionsv1.CustomResourceValidation{OpenAPIV3Schema: &apiextensionsv1.JSONSchemaProps{Type: "object", XPreserveUnknownFields: &preserve}}}},
			},
		}},
		ErrorIfCRDPathMissing: true,
	}
	if os.Getenv("KUBEBUILDER_ASSETS") == "" {
		matches, err := filepath.Glob(filepath.Join(root, "bin", "k8s", "*", "kube-apiserver"))
		require.NoError(t, err)
		if len(matches) == 0 {
			t.Skip("envtest binaries are required")
		}
		testEnv.BinaryAssetsDirectory = filepath.Dir(matches[0])
	}
	cfg, err := testEnv.Start()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, testEnv.Stop()) })

	t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_BASE", "docker.io/splunk/agent-runtime:test")
	t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_MLTK", "docker.io/splunk/agent-runtime-provider-mltk:test")
	t.Setenv("RELATED_AGENT_RUNTIME_MODULE_PROVIDER_MLTK", "agentcore_operations.loader:MLTKAgentLoader")
	t.Setenv(schemaSetupImageEnv, testSchemaImage)
	scheme := buildAgentRuntimeTestScheme(t)
	c, err := client.NewWithWatch(cfg, client.Options{Scheme: scheme})
	require.NoError(t, err)
	e := &ownershipEnv{t: t, ctx: context.Background(), c: c}
	e.r = e.reconciler(c)
	// The checkpoint Secret is customer-managed: referenced, never owned.
	require.NoError(t, c.Create(e.ctx, &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "checkpoint", Namespace: "default"},
		StringData: map[string]string{
			"DATABASE_URL": "postgresql://user:fixture@db/checkpoint?sslmode=disable",
			"PG_HOST":      "db", "PG_PORT": "5432", "PG_USER": "user", "PG_PASSWORD": "fixture", "PG_DBNAME": "checkpoint",
		},
	}))
	for _, profile := range []aiv1.AIPlatformProfile{aiv1.AIPlatformProfileCPUOnly, aiv1.AIPlatformProfileFullFeature} {
		p := &aiv1.AIPlatform{
			ObjectMeta: metav1.ObjectMeta{Name: "platform-" + strings.ToLower(string(profile)), Namespace: "default"},
			Spec:       aiv1.AIPlatformSpec{Profile: profile, ObjectStorage: aiv1.ObjectStorageSpec{Path: "s3://bucket", Region: "us-west-2"}},
		}
		require.NoError(t, c.Create(e.ctx, p))
		if profile == aiv1.AIPlatformProfileFullFeature {
			// fullfeature waits for the hosted-model platform; Ray itself is not an
			// AgentRuntime object, so only its readiness is simulated here.
			p.Status.RayServiceName = "ray"
			meta.SetStatusCondition(&p.Status.Conditions, metav1.Condition{Type: "RayServiceStatusReady", Status: metav1.ConditionTrue, Reason: "Ready", Message: "fixture"})
			require.NoError(t, c.Status().Update(e.ctx, p))
		}
	}
	return e
}

func (e *ownershipEnv) reconciler(c client.Client) *AgentRuntimeReconciler {
	return &AgentRuntimeReconciler{Client: client.WithFieldOwner(c, "runtime-test"), Scheme: e.c.Scheme(), Recorder: record.NewFakeRecorder(100)}
}

// newService creates an AgentRuntime AIService with every optional owned object on:
// metrics (ServiceMonitor) and operator-terminated mTLS (Certificate).
func (e *ownershipEnv) newService(name string, profile aiv1.AIPlatformProfile, edit func(*aiv1.AIService)) *aiv1.AIService {
	e.t.Helper()
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec: aiv1.AIServiceSpec{
			Feature:               aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk"},
			AIPlatformRef:         corev1.ObjectReference{Name: "platform-" + strings.ToLower(string(profile)), Namespace: "default"},
			CheckpointDbSecretRef: "checkpoint",
			TaskVolume:            aiv1.ObjectStorageSpec{Path: "s3://fixture", Region: "us-west-2"},
			Metrics:               aiv1.MetricsConfig{Enabled: true, Path: "/metrics"},
			MTLS: aiv1.MTLSConfig{Enabled: true, Termination: mtlsTerminationOperator,
				IssuerRef: cmmeta.ObjectReference{Name: "fixture-issuer", Kind: "ClusterIssuer", Group: "cert-manager.io"}},
		},
	}
	if edit != nil {
		edit(ai)
	}
	require.NoError(e.t, e.c.Create(e.ctx, ai))
	return ai
}

func (e *ownershipEnv) reconcileWith(r *AgentRuntimeReconciler, ai *aiv1.AIService) error {
	e.t.Helper()
	require.NoError(e.t, e.c.Get(e.ctx, client.ObjectKeyFromObject(ai), ai))
	return r.Reconcile(e.ctx, ai)
}

func (e *ownershipEnv) reconcile(ai *aiv1.AIService) error { return e.reconcileWith(e.r, ai) }

// install takes an AIService through every stage: the schema Job is created, then
// completed as the Job controller would, then the workload objects follow.
func (e *ownershipEnv) install(ai *aiv1.AIService) {
	e.t.Helper()
	require.Error(e.t, e.reconcile(ai), "the first pass waits for the schema Job")
	e.finishSchema(ai)
	require.NoError(e.t, e.reconcile(ai))
}

func (e *ownershipEnv) finishSchema(ai *aiv1.AIService) {
	e.t.Helper()
	require.NoError(e.t, e.c.Get(e.ctx, client.ObjectKeyFromObject(ai), ai))
	job := &batchv1.Job{}
	require.NoError(e.t, e.c.Get(e.ctx, client.ObjectKey{Namespace: ai.Namespace, Name: agentRuntimeSchemaStatus(e.t, ai).JobName}, job))
	now := metav1.Now()
	job.Status.StartTime, job.Status.CompletionTime = &now, &now
	job.Status.Conditions = []batchv1.JobCondition{
		{Type: batchv1.JobSuccessCriteriaMet, Status: corev1.ConditionTrue, LastTransitionTime: now},
		{Type: batchv1.JobComplete, Status: corev1.ConditionTrue, LastTransitionTime: now},
	}
	require.NoError(e.t, e.c.Status().Update(e.ctx, job))
}

// collectable lists, as "Kind/name", every object in the namespace whose owner
// references name uid: what garbage collection removes when that owner is deleted.
func (e *ownershipEnv) collectable(uid types.UID) []string {
	e.t.Helper()
	var out []string
	for _, l := range []client.ObjectList{&corev1.ServiceAccountList{}, &corev1.ConfigMapList{}, &corev1.SecretList{},
		&batchv1.JobList{}, &appsv1.DeploymentList{}, &corev1.ServiceList{}, &autoscalingv2.HorizontalPodAutoscalerList{},
		&monitoringv1.ServiceMonitorList{}, &certmanagerv1.CertificateList{}} {
		require.NoError(e.t, e.c.List(e.ctx, l, client.InNamespace("default")))
		items, err := meta.ExtractList(l)
		require.NoError(e.t, err)
		for _, item := range items {
			o := item.(client.Object)
			for _, ref := range o.GetOwnerReferences() {
				if ref.UID == uid {
					out = append(out, fmt.Sprintf("%T/%s", o, o.GetName()))
				}
			}
		}
	}
	sort.Strings(out)
	return out
}

func inventory(ai *aiv1.AIService, schemaJob string, extra ...string) []string {
	out := []string{
		"*v1.ServiceAccount/" + ai.Name + "-sa",
		"*v1.ConfigMap/" + ai.Name + "-agentruntime-config",
		"*v1.Certificate/" + ai.Name + "-agentruntime-cert",
		"*v1.Job/" + schemaJob,
		"*v1.Deployment/" + ai.Name + "-agentruntime-deployment",
		"*v1.Service/" + agentRuntimeServiceName(ai.Name),
		"*v2.HorizontalPodAutoscaler/" + ai.Name + "-agentruntime-hpa",
		"*v1.ServiceMonitor/" + ai.Name + "-agentruntime-metrics",
	}
	out = append(out, extra...)
	sort.Strings(out)
	return out
}

// issue writes the Secret cert-manager writes for a Certificate.
func (e *ownershipEnv) issue(secretName, certificate string) *corev1.Secret {
	e.t.Helper()
	s := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: secretName, Namespace: "default",
			Annotations: map[string]string{certManagerCertificateNameAnnotation: certificate}},
		Type: corev1.SecretTypeTLS,
		Data: map[string][]byte{corev1.TLSCertKey: []byte("cert"), corev1.TLSPrivateKeyKey: []byte("key")},
	}
	require.NoError(e.t, e.c.Create(e.ctx, s))
	return s
}

func (e *ownershipEnv) unchanged(obj client.Object, resourceVersion string) {
	e.t.Helper()
	require.NoError(e.t, e.c.Get(e.ctx, client.ObjectKeyFromObject(obj), obj))
	assert.Equal(e.t, resourceVersion, obj.GetResourceVersion(), "%T %s must not be written", obj, obj.GetName())
	assert.Empty(e.t, obj.GetOwnerReferences(), "%T %s must not be adopted", obj, obj.GetName())
}

func TestOwnership(t *testing.T) {
	e := startOwnershipEnv(t)
	ctx := e.ctx

	for _, profile := range []aiv1.AIPlatformProfile{aiv1.AIPlatformProfileCPUOnly, aiv1.AIPlatformProfileFullFeature} {
		t.Run("every object the feature creates is owned, and nothing else ("+string(profile)+")", func(t *testing.T) {
			name := "own-" + strings.ToLower(string(profile))
			// A customer object whose name extends the feature's names must never be swept up.
			similar := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: name + "-agentruntime-config-customer", Namespace: "default"}, Data: map[string]string{"k": "v"}}
			require.NoError(t, e.c.Create(ctx, similar))
			ai := e.newService(name, profile, nil)
			e.install(ai)
			// cert-manager issues the operator-generated Secret; the next pass owns it.
			tls := e.issue(name+"-tls", name+"-agentruntime-cert")
			require.NoError(t, e.reconcile(ai))

			job := agentRuntimeSchemaStatus(t, ai).JobName
			assert.Equal(t, inventory(ai, job, "*v1.Secret/"+name+"-tls"), e.collectable(ai.UID))
			require.NoError(t, e.c.Get(ctx, client.ObjectKeyFromObject(tls), tls))
			for _, ref := range tls.OwnerReferences {
				if ref.UID == ai.UID {
					assert.False(t, ref.Controller != nil && *ref.Controller, "the TLS Secret's controller is cert-manager's to set, not ours")
				}
			}
			checkpoint := &corev1.Secret{}
			require.NoError(t, e.c.Get(ctx, client.ObjectKey{Namespace: "default", Name: "checkpoint"}, checkpoint))
			assert.Empty(t, checkpoint.OwnerReferences, "the checkpoint Secret is customer-managed")
			e.unchanged(similar, similar.ResourceVersion)

			// Repeated reconciliation changes nothing.
			before := map[string]string{}
			for _, o := range e.ownedObjects(ai) {
				before[o.GetName()+fmt.Sprintf("%T", o)] = o.GetResourceVersion()
			}
			for range 2 {
				require.NoError(t, e.reconcile(ai))
			}
			for _, o := range e.ownedObjects(ai) {
				assert.Equal(t, before[o.GetName()+fmt.Sprintf("%T", o)], o.GetResourceVersion(), "%T %s rewritten by an idempotent pass", o, o.GetName())
			}

			// A missing owned object is recreated, owned; nothing else changes.
			require.NoError(t, e.c.Delete(ctx, &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: name + "-agentruntime-config", Namespace: "default"}}))
			require.NoError(t, e.reconcile(ai))
			assert.Equal(t, inventory(ai, job, "*v1.Secret/"+name+"-tls"), e.collectable(ai.UID))

			// Deleting the AIService is not blocked: nothing holds a finalizer on it.
			require.NoError(t, e.c.Delete(ctx, ai))
			err := e.c.Get(ctx, client.ObjectKeyFromObject(ai), &aiv1.AIService{})
			assert.True(t, apierrors.IsNotFound(err), "the AIService is gone at once, got %v", err)
			e.unchanged(similar, similar.ResourceVersion)
			e.unchanged(checkpoint, checkpoint.ResourceVersion)
		})
	}

	t.Run("a same-named object it does not own is refused and left unchanged", func(t *testing.T) {
		labels := map[string]string{"app": "customer"}
		podTemplate := corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: labels},
			Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "c", Image: "customer/app:1"}}}}
		cases := []struct {
			kind, stage string
			object      func(name string) client.Object
		}{
			{"ServiceAccount", "ServiceAccount", func(n string) client.Object {
				return &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: n + "-sa", Namespace: "default", Labels: labels}}
			}},
			{"ConfigMap", "AgentRuntimeConfigMap", func(n string) client.Object {
				return &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: n + "-agentruntime-config", Namespace: "default"}, Data: map[string]string{"customer": "data"}}
			}},
			{"Certificate", "Certificate", func(n string) client.Object {
				return &certmanagerv1.Certificate{ObjectMeta: metav1.ObjectMeta{Name: n + "-agentruntime-cert", Namespace: "default"},
					Spec: certmanagerv1.CertificateSpec{SecretName: "customer-tls", IssuerRef: cmmeta.ObjectReference{Name: "customer-issuer"}}}
			}},
			{"Deployment", "AgentRuntimeDeployment", func(n string) client.Object {
				return &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: n + "-agentruntime-deployment", Namespace: "default"},
					Spec: appsv1.DeploymentSpec{Selector: &metav1.LabelSelector{MatchLabels: labels}, Template: podTemplate}}
			}},
			{"Service", "AgentRuntimeService", func(n string) client.Object {
				return &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: agentRuntimeServiceName(n), Namespace: "default"},
					Spec: corev1.ServiceSpec{Selector: labels, Ports: []corev1.ServicePort{{Name: "web", Port: 9999, TargetPort: intstr.FromInt(9999)}}}}
			}},
			{"HorizontalPodAutoscaler", "AgentRuntimeHPA", func(n string) client.Object {
				return &autoscalingv2.HorizontalPodAutoscaler{ObjectMeta: metav1.ObjectMeta{Name: n + "-agentruntime-hpa", Namespace: "default"},
					Spec: autoscalingv2.HorizontalPodAutoscalerSpec{MaxReplicas: 9,
						ScaleTargetRef: autoscalingv2.CrossVersionObjectReference{APIVersion: "apps/v1", Kind: "Deployment", Name: "customer"}}}
			}},
			{"ServiceMonitor", "ServiceMonitor", func(n string) client.Object {
				return &monitoringv1.ServiceMonitor{ObjectMeta: metav1.ObjectMeta{Name: n + "-agentruntime-metrics", Namespace: "default", Labels: labels}}
			}},
		}
		for _, tc := range cases {
			t.Run(tc.kind, func(t *testing.T) {
				name := "conflict-" + strings.ToLower(tc.kind)
				customer := tc.object(name)
				require.NoError(t, e.c.Create(ctx, customer))
				rv := customer.GetResourceVersion()
				ai := e.newService(name, aiv1.AIPlatformProfileCPUOnly, nil)
				err := e.reconcile(ai)
				if err != nil && meta.FindStatusCondition(ai.Status.Conditions, "PostgresSchemaSetupReady").Reason == "Pending" {
					e.finishSchema(ai)
					err = e.reconcile(ai)
				}
				require.Error(t, err)
				var conflict *common.OwnershipConflictError
				assert.True(t, errors.As(err, &conflict), "a named ownership conflict, got %v", err)
				cond := meta.FindStatusCondition(ai.Status.Conditions, tc.stage+"Ready")
				require.NotNil(t, cond, "the %s stage reports the conflict", tc.stage)
				assert.Equal(t, metav1.ConditionFalse, cond.Status)
				assert.Equal(t, "OwnershipConflict", cond.Reason)
				assert.Contains(t, cond.Message, tc.kind+" default/"+customer.GetName())
				assert.Equal(t, "OwnershipConflict", meta.FindStatusCondition(ai.Status.Conditions, "Ready").Reason)
				e.unchanged(customer, rv)
				// A retry still refuses and still changes nothing.
				require.Error(t, e.reconcile(ai))
				e.unchanged(customer, rv)
				require.NoError(t, e.c.Delete(ctx, ai))
			})
		}
	})

	t.Run("a schema Job under the operator's name that it does not own is refused and left unchanged", func(t *testing.T) {
		ai := e.newService("conflict-job", aiv1.AIPlatformProfileCPUOnly, nil)
		require.Error(t, e.reconcile(ai))
		job := &batchv1.Job{}
		require.NoError(t, e.c.Get(ctx, client.ObjectKey{Namespace: "default", Name: agentRuntimeSchemaStatus(t, ai).JobName}, job))
		job.OwnerReferences = nil // now it is not this AIService's
		require.NoError(t, e.c.Update(ctx, job))
		rv := job.ResourceVersion
		err := e.reconcile(ai)
		var conflict *common.OwnershipConflictError
		require.ErrorAs(t, err, &conflict)
		cond := meta.FindStatusCondition(ai.Status.Conditions, "PostgresSchemaSetupReady")
		require.NotNil(t, cond)
		assert.Equal(t, "OwnershipConflict", cond.Reason)
		assert.Contains(t, cond.Message, "Job default/"+job.Name)
		e.unchanged(job, rv)
	})

	t.Run("a customer-named ServiceAccount is used and never owned", func(t *testing.T) {
		sa := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: "customer-sa", Namespace: "default", Labels: map[string]string{"app": "customer"}}}
		require.NoError(t, e.c.Create(ctx, sa))
		ai := e.newService("named-sa", aiv1.AIPlatformProfileCPUOnly, func(a *aiv1.AIService) { a.Spec.ServiceAccountName = "customer-sa" })
		e.install(ai)
		e.unchanged(sa, sa.ResourceVersion)
		dep := &appsv1.Deployment{}
		require.NoError(t, e.c.Get(ctx, client.ObjectKey{Namespace: "default", Name: "named-sa-agentruntime-deployment"}, dep))
		assert.Equal(t, "customer-sa", dep.Spec.Template.Spec.ServiceAccountName)
		assert.NotContains(t, e.collectable(ai.UID), "*v1.ServiceAccount/customer-sa")

		// A named ServiceAccount that does not exist is created, and still never owned:
		// another AIService or the customer's own tooling may rely on it.
		other := e.newService("named-sa-new", aiv1.AIPlatformProfileCPUOnly, func(a *aiv1.AIService) { a.Spec.ServiceAccountName = "made-for-runtime" })
		require.Error(t, e.reconcile(other))
		made := &corev1.ServiceAccount{}
		require.NoError(t, e.c.Get(ctx, client.ObjectKey{Namespace: "default", Name: "made-for-runtime"}, made))
		assert.Empty(t, made.OwnerReferences)
		assert.NotContains(t, e.collectable(other.UID), "*v1.ServiceAccount/made-for-runtime")

		// One an earlier build created or adopted is released.
		earlier := e.newService("named-sa-earlier", aiv1.AIPlatformProfileCPUOnly, func(a *aiv1.AIService) { a.Spec.ServiceAccountName = "adopted-by-earlier-build" })
		adopted := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: "adopted-by-earlier-build", Namespace: "default"}}
		require.NoError(t, controllerutil.SetControllerReference(earlier, adopted, e.c.Scheme()))
		require.NoError(t, e.c.Create(ctx, adopted))
		require.Error(t, e.reconcile(earlier))
		require.NoError(t, e.c.Get(ctx, client.ObjectKeyFromObject(adopted), adopted))
		assert.Empty(t, adopted.OwnerReferences, "the operator's reference is removed, so the ServiceAccount survives the AIService")
	})

	t.Run("the TLS Secret is owned only when the operator named it and cert-manager wrote it for this Certificate", func(t *testing.T) {
		named := e.newService("tls-named", aiv1.AIPlatformProfileCPUOnly, func(a *aiv1.AIService) { a.Spec.MTLS.SecretName = "customer-tls-secret" })
		e.install(named)
		customerTLS := e.issue("customer-tls-secret", "tls-named-agentruntime-cert")
		require.NoError(t, e.reconcile(named))
		e.unchanged(customerTLS, customerTLS.ResourceVersion)

		dflt := e.newService("tls-foreign", aiv1.AIPlatformProfileCPUOnly, nil)
		e.install(dflt)
		foreign := e.issue("tls-foreign-tls", "some-other-certificate")
		require.NoError(t, e.reconcile(dflt))
		e.unchanged(foreign, foreign.ResourceVersion)
	})

	t.Run("an operator-named TLS Secret the user later names in mtls.secretName is released", func(t *testing.T) {
		ai := e.newService("tls-later", aiv1.AIPlatformProfileCPUOnly, nil)
		e.install(ai)
		tls := e.issue("tls-later-tls", "tls-later-agentruntime-cert")
		// Another owner reference that must survive the release.
		other := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "tls-later-other-owner", Namespace: "default"}}
		require.NoError(t, e.c.Create(ctx, other))
		require.NoError(t, e.c.Get(ctx, client.ObjectKeyFromObject(tls), tls))
		require.NoError(t, controllerutil.SetOwnerReference(other, tls, e.c.Scheme()))
		require.NoError(t, e.c.Update(ctx, tls))
		require.NoError(t, e.reconcile(ai))
		assert.Contains(t, e.collectable(ai.UID), "*v1.Secret/tls-later-tls", "claimed while the name is the operator's")

		// The user names that same Secret to keep it.
		require.NoError(t, e.c.Get(ctx, client.ObjectKeyFromObject(ai), ai))
		ai.Spec.MTLS.SecretName = "tls-later-tls"
		require.NoError(t, e.c.Update(ctx, ai))
		require.NoError(t, e.reconcile(ai))
		assert.NotContains(t, e.collectable(ai.UID), "*v1.Secret/tls-later-tls", "released: it survives the AIService")
		require.NoError(t, e.c.Get(ctx, client.ObjectKeyFromObject(tls), tls))
		require.Len(t, tls.OwnerReferences, 1, "the other owner reference is kept")
		assert.Equal(t, other.UID, tls.OwnerReferences[0].UID)
		rv := tls.ResourceVersion
		require.NoError(t, e.reconcile(ai))
		require.NoError(t, e.c.Get(ctx, client.ObjectKeyFromObject(tls), tls))
		assert.Equal(t, rv, tls.ResourceVersion, "idempotent")
	})

	t.Run("a partial install and an API failure leave only owned objects, and delete nothing", func(t *testing.T) {
		ai := e.newService("partial", aiv1.AIPlatformProfileCPUOnly, nil)
		require.Error(t, e.reconcile(ai), "interrupted: the schema Job has not completed")
		job := agentRuntimeSchemaStatus(t, ai).JobName
		assert.Equal(t, []string{"*v1.Certificate/partial-agentruntime-cert", "*v1.ConfigMap/partial-agentruntime-config",
			"*v1.Job/" + job, "*v1.ServiceAccount/partial-sa"}, e.collectable(ai.UID))
		e.finishSchema(ai)

		var deletes []string
		failCreate := true
		flaky := interceptor.NewClient(e.c, interceptor.Funcs{
			Create: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.CreateOption) error {
				if _, ok := obj.(*appsv1.Deployment); ok && failCreate {
					failCreate = false
					return apierrors.NewServiceUnavailable("injected API failure")
				}
				return c.Create(ctx, obj, opts...)
			},
			Delete: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.DeleteOption) error {
				deletes = append(deletes, fmt.Sprintf("%T/%s", obj, obj.GetName()))
				return c.Delete(ctx, obj, opts...)
			},
		})
		r := e.reconciler(flaky)
		err := e.reconcileWith(r, ai)
		require.Error(t, err)
		assert.True(t, apierrors.IsServiceUnavailable(err), "the API failure is surfaced for a retry, got %v", err)
		assert.Equal(t, metav1.ConditionFalse, meta.FindStatusCondition(ai.Status.Conditions, "AgentRuntimeDeploymentReady").Status)
		require.NoError(t, e.reconcileWith(r, ai), "the retry completes")
		assert.Empty(t, deletes, "a failure or retry deletes nothing")
		assert.Equal(t, inventory(ai, job), e.collectable(ai.UID))
	})
}

// ownedObjects returns the live objects garbage collection would remove for ai.
func (e *ownershipEnv) ownedObjects(ai *aiv1.AIService) []client.Object {
	e.t.Helper()
	var out []client.Object
	for _, l := range []client.ObjectList{&corev1.ServiceAccountList{}, &corev1.ConfigMapList{}, &corev1.SecretList{},
		&batchv1.JobList{}, &appsv1.DeploymentList{}, &corev1.ServiceList{}, &autoscalingv2.HorizontalPodAutoscalerList{},
		&monitoringv1.ServiceMonitorList{}, &certmanagerv1.CertificateList{}} {
		require.NoError(e.t, e.c.List(e.ctx, l, client.InNamespace("default")))
		items, err := meta.ExtractList(l)
		require.NoError(e.t, err)
		for _, item := range items {
			o := item.(client.Object)
			for _, ref := range o.GetOwnerReferences() {
				if ref.UID == ai.UID {
					out = append(out, o)
				}
			}
		}
	}
	return out
}
