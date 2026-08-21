package splunkutils

import (
	"context"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestKubernetesSecretResolver_GetHECToken(t *testing.T) {
	ns := "test-ns"
	ctx := context.Background()

	// Register scheme
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)

	tests := []struct {
		name        string
		namespace   string
		cfg         *aiApi.SplunkConfigurationSpec
		objects     []client.Object
		expectedVal string
		expectedErr string
	}{
		{
			name:      "uses the configured SecretRef name",
			namespace: ns,
			cfg: &aiApi.SplunkConfigurationSpec{SecretRef: corev1.SecretReference{
				Name: "customer-hec-secret",
			}},
			objects: []client.Object{
				&corev1.Secret{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "customer-hec-secret",
						Namespace: ns,
					},
					Data: map[string][]byte{
						"hec_token": []byte("custom-secret-token"),
					},
				},
			},
			expectedVal: "custom-secret-token",
			expectedErr: "",
		},
		{
			name:      "accepts an explicit matching namespace",
			namespace: ns,
			cfg: &aiApi.SplunkConfigurationSpec{SecretRef: corev1.SecretReference{
				Name:      "customer-hec-secret",
				Namespace: ns,
			}},
			objects: []client.Object{
				&corev1.Secret{
					ObjectMeta: metav1.ObjectMeta{Name: "customer-hec-secret", Namespace: ns},
					Data:       map[string][]byte{"hec_token": []byte("matching-namespace-token")},
				},
			},
			expectedVal: "matching-namespace-token",
		},
		{
			name:      "falls back to the legacy namespace-scoped Secret when name is omitted",
			namespace: ns,
			cfg:       &aiApi.SplunkConfigurationSpec{},
			objects: []client.Object{
				&corev1.Secret{
					ObjectMeta: metav1.ObjectMeta{Name: GetNamespaceScopedSecretName(ns), Namespace: ns},
					Data:       map[string][]byte{"hec_token": []byte("legacy-token")},
				},
			},
			expectedVal: "legacy-token",
		},
		{
			name:      "does not fall back when an explicit SecretRef is missing",
			namespace: ns,
			cfg: &aiApi.SplunkConfigurationSpec{SecretRef: corev1.SecretReference{
				Name: "missing-custom-secret",
			}},
			objects: []client.Object{
				&corev1.Secret{
					ObjectMeta: metav1.ObjectMeta{Name: GetNamespaceScopedSecretName(ns), Namespace: ns},
					Data:       map[string][]byte{"hec_token": []byte("must-not-be-used")},
				},
			},
			expectedErr: `failed to get Splunk secret "missing-custom-secret" in namespace "test-ns"`,
		},
		{
			name:        "returns an error when the configured Secret is not found",
			namespace:   ns,
			cfg:         &aiApi.SplunkConfigurationSpec{SecretRef: corev1.SecretReference{Name: "not-found"}},
			objects:     []client.Object{}, // no secret in fake client
			expectedVal: "",
			expectedErr: `failed to get Splunk secret "not-found" in namespace "test-ns"`,
		},
		{
			name:      "returns an error when hec_token is missing",
			namespace: ns,
			cfg:       &aiApi.SplunkConfigurationSpec{SecretRef: corev1.SecretReference{Name: "incomplete-secret"}},
			objects: []client.Object{
				&corev1.Secret{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "incomplete-secret",
						Namespace: ns,
					},
					Data: map[string][]byte{
						"wrong_key": []byte("value"),
					},
				},
			},
			expectedVal: "",
			expectedErr: `secret "incomplete-secret" missing required key "hec_token"`,
		},
		{
			name:      "rejects a cross-namespace SecretRef",
			namespace: ns,
			cfg: &aiApi.SplunkConfigurationSpec{SecretRef: corev1.SecretReference{
				Name:      "other-secret",
				Namespace: "other-ns",
			}},
			objects: []client.Object{
				&corev1.Secret{
					ObjectMeta: metav1.ObjectMeta{Name: "other-secret", Namespace: "other-ns"},
					Data:       map[string][]byte{"hec_token": []byte("must-not-cross-namespaces")},
				},
			},
			expectedErr: "cross-namespace Secret references are not supported",
		},
		{
			name:        "returns an error for a nil configuration",
			namespace:   ns,
			cfg:         nil,
			expectedErr: "Splunk configuration is required",
		},
		{
			name:        "returns an error for an empty AI resource namespace",
			namespace:   "",
			cfg:         &aiApi.SplunkConfigurationSpec{SecretRef: corev1.SecretReference{Name: "some-secret"}},
			expectedErr: "AI resource namespace is required",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Build fake client with test-specific objects
			fakeClient := fake.NewClientBuilder().
				WithScheme(scheme).
				WithObjects(tt.objects...).
				Build()

			resolver := &KubernetesSecretResolver{Client: fakeClient}

			got, err := resolver.GetHECToken(ctx, tt.namespace, tt.cfg)

			if tt.expectedErr == "" {
				assert.NoError(t, err)
				assert.Equal(t, tt.expectedVal, got)
			} else {
				assert.Error(t, err)
				assert.Contains(t, err.Error(), tt.expectedErr)
			}
		})
	}
}
