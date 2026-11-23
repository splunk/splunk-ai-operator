package controller

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

const checkpointCanary = "checkpoint-credential-canary-2026"

type credentialFaultClient struct {
	client.Client
	fault string
}

func (c credentialFaultClient) Get(ctx context.Context, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
	if _, ok := obj.(*corev1.ConfigMap); ok && c.fault == "api" {
		return apierrors.NewBadRequest("rejected object contained " + checkpointCanary)
	}
	return c.Client.Get(ctx, key, obj, opts...)
}

func (c credentialFaultClient) Status() client.SubResourceWriter {
	return credentialStatusWriter{c.Client.Status(), c.fault}
}

type credentialStatusWriter struct {
	client.SubResourceWriter
	fault string
}

func (w credentialStatusWriter) Update(ctx context.Context, obj client.Object, opts ...client.SubResourceUpdateOption) error {
	if w.fault == "status" {
		return apierrors.NewConflict(schema.GroupResource{Group: aiv1.GroupVersion.Group, Resource: "aiservices"}, obj.GetName(), errors.New(checkpointCanary))
	}
	return w.SubResourceWriter.Update(ctx, obj, opts...)
}

// Exercise the outer controller, including its error log, rather than checking
// only the feature's already-sanitized condition message.
func TestAgentRuntimeCredentialDiagnosticsThroughController(t *testing.T) {
	for _, fault := range []string{"plaintext", "secret", "api", "status", "success"} {
		t.Run(fault, func(t *testing.T) {
			t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_BASE", "docker.io/splunk/runtime:test")
			t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_MLTK", "docker.io/splunk/provider:test")
			t.Setenv("RELATED_AGENT_RUNTIME_MODULE_PROVIDER_MLTK", "provider.loader:Loader")
			t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_SCHEMA_SETUP", "docker.io/splunk/schema@sha256:"+strings.Repeat("a", 64))
			s := runtime.NewScheme()
			require.NoError(t, scheme.AddToScheme(s))
			require.NoError(t, aiv1.AddToScheme(s))
			ai := &aiv1.AIService{ObjectMeta: metav1.ObjectMeta{Name: "credential-runtime", Namespace: "default", UID: "credential-runtime-uid"}, Spec: aiv1.AIServiceSpec{
				Feature:       aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk"},
				AIPlatformUrl: "http://ray:8000", CheckpointDbSecretRef: "checkpoint", Replicas: 1,
			}}
			secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "checkpoint", Namespace: "default"}, Type: corev1.SecretTypeOpaque, Data: map[string][]byte{
				"DATABASE_URL": []byte("postgresql://user:" + checkpointCanary + "@postgres:5432/checkpoints"),
				"PG_HOST":      []byte("postgres"), "PG_PORT": []byte("5432"), "PG_USER": []byte("user"),
				"PG_PASSWORD": []byte(checkpointCanary), "PG_DBNAME": []byte("checkpoints"),
			}}
			if fault == "plaintext" {
				ai.Spec.Feature.Env = map[string]string{"PG_PASSWORD": checkpointCanary}
			}
			if fault == "secret" {
				secret.Data["DATABASE_URL"] = []byte("postgresql://user:" + checkpointCanary + "%broken@postgres/checkpoints")
			}
			base := fake.NewClientBuilder().WithScheme(s).WithStatusSubresource(&aiv1.AIService{}).WithObjects(ai, secret).Build()
			c := credentialFaultClient{base, fault}
			recorder := record.NewFakeRecorder(50)
			var logs bytes.Buffer
			ctx := logf.IntoContext(context.Background(), zap.New(zap.WriteTo(&logs)))
			r := &AIServiceReconciler{Client: c, Scheme: s, Recorder: recorder}
			_, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(ai)})
			require.Error(t, err) // success reaches the real pending-schema gate
			assert.NotContains(t, err.Error(), checkpointCanary)
			assert.NotContains(t, logs.String(), checkpointCanary)
			if fault == "status" {
				assert.True(t, apierrors.IsConflict(err))
			}
			stored := &aiv1.AIService{}
			require.NoError(t, base.Get(ctx, client.ObjectKeyFromObject(ai), stored))
			raw, err := json.Marshal(stored.Status)
			require.NoError(t, err)
			assert.NotContains(t, string(raw), checkpointCanary)
			for _, list := range []client.ObjectList{&corev1.ConfigMapList{}, &appsv1.DeploymentList{}, &batchv1.JobList{}} {
				require.NoError(t, base.List(ctx, list))
				raw, err := json.Marshal(list)
				require.NoError(t, err)
				assert.NotContains(t, string(raw), checkpointCanary)
			}
			for len(recorder.Events) > 0 {
				assert.NotContains(t, <-recorder.Events, checkpointCanary)
			}
		})
	}
}
