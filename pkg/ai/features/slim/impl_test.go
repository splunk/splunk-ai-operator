package slim

import (
	"context"
	"strings"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// buildTestScheme creates a scheme with the types reconcileSlimService needs.
func buildTestScheme(t *testing.T) *runtime.Scheme {
	s := runtime.NewScheme()
	require.NoError(t, aiv1.AddToScheme(s))
	require.NoError(t, corev1.AddToScheme(s))
	require.NoError(t, appsv1.AddToScheme(s))
	return s
}

func Test_reconcileSlimService_ServiceTypeVariations(t *testing.T) {
	// Slim mirrors SAIA's contract: the customer's k0s-cluster-config.yaml can
	// omit / empty / explicitly-set serviceTemplate and get the expected
	// Service.Type. Slim has no v1/v2/nginx split, so its public Service is the
	// only Service the reconciler renders. The k0s installer gives slim a
	// DISTINCT NodePort (30081) from SAIA's (30080), so the "explicit NodePort"
	// case pins 30081 to lock in that no-collision contract.
	scheme := buildTestScheme(t)

	cases := []struct {
		name         string
		template     corev1.Service
		wantType     corev1.ServiceType
		wantNodePort int32 // 0 = don't check
	}{
		{
			name:     "omitted/empty template → ClusterIP",
			template: corev1.Service{}, // zero value, what yq-absent produces
			wantType: corev1.ServiceTypeClusterIP,
		},
		{
			name: "explicit ClusterIP → ClusterIP",
			template: corev1.Service{
				Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeClusterIP},
			},
			wantType: corev1.ServiceTypeClusterIP,
		},
		{
			name: "NodePort without explicit port → NodePort auto-allocated",
			template: corev1.Service{
				Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeNodePort},
			},
			wantType: corev1.ServiceTypeNodePort,
			// wantNodePort == 0 means we don't assert a specific value
		},
		{
			name: "NodePort with explicit 30081 → NodePort 30081",
			template: corev1.Service{
				Spec: corev1.ServiceSpec{
					Type: corev1.ServiceTypeNodePort,
					Ports: []corev1.ServicePort{
						{Name: "http", NodePort: 30081},
					},
				},
			},
			wantType:     corev1.ServiceTypeNodePort,
			wantNodePort: 30081,
		},
		{
			name: "LoadBalancer → LoadBalancer",
			template: corev1.Service{
				Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeLoadBalancer},
			},
			wantType: corev1.ServiceTypeLoadBalancer,
		},
		{
			name: "Unknown garbage type → ClusterIP (safe default)",
			template: corev1.Service{
				Spec: corev1.ServiceSpec{Type: corev1.ServiceType("Bogus")},
			},
			wantType: corev1.ServiceTypeClusterIP,
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			ai := &aiv1.AIService{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "svctype-" + sanitize(tc.name),
					Namespace: "default",
					UID:       "uid-123",
				},
				Spec: aiv1.AIServiceSpec{
					ServiceTemplate: tc.template,
				},
			}

			fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
			r := &SlimReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

			require.NoError(t, r.reconcileSlimService(context.Background(), ai))

			svc := &corev1.Service{}
			require.NoError(t, fakeClient.Get(context.Background(),
				types.NamespacedName{Name: ai.Name + "-slim-service", Namespace: "default"}, svc))

			assert.Equal(t, tc.wantType, svc.Spec.Type)
			if tc.wantNodePort != 0 {
				require.NotEmpty(t, svc.Spec.Ports)
				// http is the first port slim renders; the installer patches its
				// NodePort. Find it by name to stay robust to port ordering.
				var httpPort *corev1.ServicePort
				for i := range svc.Spec.Ports {
					if svc.Spec.Ports[i].Name == "http" {
						httpPort = &svc.Spec.Ports[i]
						break
					}
				}
				require.NotNil(t, httpPort, "expected an http port on the slim service")
				assert.Equal(t, tc.wantNodePort, httpPort.NodePort)
			}
		})
	}
}

// findVolume returns the named volume, or nil if absent.
func findSlimVolume(volumes []corev1.Volume, name string) *corev1.Volume {
	for i := range volumes {
		if volumes[i].Name == name {
			return &volumes[i]
		}
	}
	return nil
}

// slimEnvToMap converts a slice of EnvVar to a map for easy assertion.
func slimEnvToMap(envs []corev1.EnvVar) map[string]string {
	m := make(map[string]string)
	for _, e := range envs {
		if e.ValueFrom == nil {
			m[e.Name] = e.Value
		}
	}
	return m
}

func newTestSlimAIService(name string) *aiv1.AIService {
	return &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: "default",
			UID:       "uid-123",
		},
		Spec: aiv1.AIServiceSpec{
			AIPlatformUrl:      "http://platform:8000",
			Replicas:           1,
			ServiceAccountName: "test-sa",
		},
	}
}

func Test_reconcileSlimDeployment_CABundle_NotSetByDefault(t *testing.T) {
	scheme := buildTestScheme(t)
	ai := newTestSlimAIService("slim-cabundle-default")

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SlimReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSlimDeployment(context.Background(), ai))

	dep := &appsv1.Deployment{}
	require.NoError(t, fakeClient.Get(context.Background(), types.NamespacedName{Name: ai.Name + "-slim-deployment", Namespace: "default"}, dep))

	container := dep.Spec.Template.Spec.Containers[0]
	envMap := slimEnvToMap(container.Env)
	assert.NotContains(t, envMap, "REQUESTS_CA_BUNDLE")
	assert.NotContains(t, envMap, "SSL_CERT_FILE")
	assert.Nil(t, findSlimVolume(dep.Spec.Template.Spec.Volumes, "splunk-ca"))
	assert.NotContains(t, dep.Spec.Template.Annotations, "splunk-ai-operator/splunk-ca-hash")
}

func Test_reconcileSlimDeployment_CABundle_WiresEnvVolumeAndHash(t *testing.T) {
	scheme := buildTestScheme(t)
	ai := newTestSlimAIService("slim-cabundle-wired")
	ai.Spec.SplunkConfiguration.CACertRef = &aiv1.CABundleRef{Name: "ai-splunk-server-tls"}

	caSecret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "ai-splunk-server-tls", Namespace: "default"},
		Data:       map[string][]byte{"ca.crt": []byte("fake-ca-pem-1")},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, caSecret).Build()
	r := &SlimReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSlimDeployment(context.Background(), ai))

	dep := &appsv1.Deployment{}
	require.NoError(t, fakeClient.Get(context.Background(), types.NamespacedName{Name: ai.Name + "-slim-deployment", Namespace: "default"}, dep))

	container := dep.Spec.Template.Spec.Containers[0]
	envMap := slimEnvToMap(container.Env)
	assert.Equal(t, "/etc/splunk-ca/ca.crt", envMap["REQUESTS_CA_BUNDLE"])
	assert.Equal(t, "/etc/splunk-ca/ca.crt", envMap["SSL_CERT_FILE"])

	vol := findSlimVolume(dep.Spec.Template.Spec.Volumes, "splunk-ca")
	require.NotNil(t, vol)
	require.NotNil(t, vol.Secret)
	assert.Equal(t, "ai-splunk-server-tls", vol.Secret.SecretName)

	hash1 := dep.Spec.Template.Annotations["splunk-ai-operator/splunk-ca-hash"]
	assert.NotEmpty(t, hash1)

	// Rotating the Secret's content in place (same name) must change the hash,
	// so the pod rolls even though CACertRef itself didn't change (AIP-4614 Part G.2).
	caSecret.Data["ca.crt"] = []byte("fake-ca-pem-2-rotated")
	require.NoError(t, fakeClient.Update(context.Background(), caSecret))

	require.NoError(t, r.reconcileSlimDeployment(context.Background(), ai))

	dep2 := &appsv1.Deployment{}
	require.NoError(t, fakeClient.Get(context.Background(), types.NamespacedName{Name: ai.Name + "-slim-deployment", Namespace: "default"}, dep2))
	hash2 := dep2.Spec.Template.Annotations["splunk-ai-operator/splunk-ca-hash"]
	assert.NotEmpty(t, hash2)
	assert.NotEqual(t, hash1, hash2)
}

func Test_reconcileSlimDeployment_CABundle_MissingSecretOmitsHash(t *testing.T) {
	scheme := buildTestScheme(t)
	ai := newTestSlimAIService("slim-cabundle-missing")
	ai.Spec.SplunkConfiguration.CACertRef = &aiv1.CABundleRef{Name: "does-not-exist"}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SlimReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSlimDeployment(context.Background(), ai))

	dep := &appsv1.Deployment{}
	require.NoError(t, fakeClient.Get(context.Background(), types.NamespacedName{Name: ai.Name + "-slim-deployment", Namespace: "default"}, dep))

	container := dep.Spec.Template.Spec.Containers[0]
	envMap := slimEnvToMap(container.Env)
	assert.Equal(t, "/etc/splunk-ca/ca.crt", envMap["REQUESTS_CA_BUNDLE"])
	assert.NotContains(t, dep.Spec.Template.Annotations, "splunk-ai-operator/splunk-ca-hash")
}

// sanitize turns a free-form subtest name into a valid k8s resource name.
func sanitize(s string) string {
	s = strings.ToLower(s)
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			out = append(out, c)
		default:
			if len(out) > 0 && out[len(out)-1] != '-' {
				out = append(out, '-')
			}
		}
	}
	// Trim trailing hyphen so the name is a valid RFC-1123 label.
	for len(out) > 0 && out[len(out)-1] == '-' {
		out = out[:len(out)-1]
	}
	return string(out)
}
