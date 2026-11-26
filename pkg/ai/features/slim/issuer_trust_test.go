package slim

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"testing"
	"time"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func issuerCertificate(t *testing.T, notAfter time.Time, ca bool) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	cert := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Fixture issuer"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              notAfter,
		BasicConstraintsValid: true,
		IsCA:                  ca,
	}
	if ca {
		cert.KeyUsage = x509.KeyUsageCertSign
	}
	encoded, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	require.NoError(t, err)
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: encoded})
}

func TestSLIMIssuerTrustValidationAndRendering(t *testing.T) {
	ca := issuerCertificate(t, time.Now().Add(time.Hour), true)
	ctx := context.Background()
	scheme := runtime.NewScheme()
	require.NoError(t, corev1.AddToScheme(scheme))
	const canary = "private-fixture-value"
	for _, tt := range []struct {
		name          string
		required      bool
		caRef         *corev1.LocalObjectReference
		secretData    map[string][]byte
		trustedIssuer string
		splunkRef     corev1.ObjectReference
		override      string
		wantError     string
	}{
		{name: "legacy without trust configuration"},
		{name: "managed without a CA reference", required: true, wantError: "caCertRef.name is required"},
		{name: "missing Secret", required: true, caRef: &corev1.LocalObjectReference{Name: "issuer-ca"}, trustedIssuer: "issuer.example", wantError: "missing from the SLIM namespace"},
		{name: "malformed Secret data stays private", required: true, caRef: &corev1.LocalObjectReference{Name: "issuer-ca"}, secretData: map[string][]byte{"ca.crt": []byte(canary)}, trustedIssuer: "issuer.example", wantError: "valid PEM CA certificates"},
		{name: "requires an issuer", required: true, caRef: &corev1.LocalObjectReference{Name: "issuer-ca"}, secretData: map[string][]byte{"ca.crt": ca}, wantError: "identify at least one Splunk token issuer"},
		{name: "wrong scheme", required: true, caRef: &corev1.LocalObjectReference{Name: "issuer-ca"}, secretData: map[string][]byte{"ca.crt": ca}, trustedIssuer: "http://issuer.example", wantError: "must identify an HTTPS issuer"},
		{name: "reject malformed derived primary issuer", required: true, caRef: &corev1.LocalObjectReference{Name: "issuer-ca"}, secretData: map[string][]byte{"ca.crt": ca}, splunkRef: corev1.ObjectReference{Name: "splunk," + canary}, wantError: "must identify a valid Splunk Service address"},
		{name: "reject issuer entry delimiters", required: true, caRef: &corev1.LocalObjectReference{Name: "issuer-ca"}, secretData: map[string][]byte{"ca.crt": ca}, trustedIssuer: "issuer.example," + canary, wantError: "must identify an HTTPS issuer"},
		{name: "reject invalid host override and suppress its content", required: true, caRef: &corev1.LocalObjectReference{Name: "issuer-ca"}, secretData: map[string][]byte{"ca.crt": ca}, trustedIssuer: "issuer.example", override: "https://" + canary + "@issuer.example:8089", wantError: "must be a hostname or host:port"},
		{name: "valid direct issuer", required: true, caRef: &corev1.LocalObjectReference{Name: "issuer-ca"}, secretData: map[string][]byte{"ca.crt": ca, "sensitive": []byte(canary)}, trustedIssuer: "https://issuer.example:8089"},
		{name: "valid exact serverName and host override", required: true, caRef: &corev1.LocalObjectReference{Name: "issuer-ca"}, secretData: map[string][]byte{"ca.crt": ca}, trustedIssuer: "SplunkServerName", override: "issuer.example:8089"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			ai := &aiv1.AIService{ObjectMeta: metav1.ObjectMeta{Name: "platform-slim", Namespace: "test"}}
			ai.Spec.SplunkConfiguration.CACertRef = tt.caRef
			ai.Spec.SplunkConfiguration.SplunkCustomResourceRef = tt.splunkRef
			if tt.trustedIssuer != "" {
				ai.Spec.SplunkConfiguration.TrustedIssuers = []string{tt.trustedIssuer}
			}
			objects := []client.Object{
				&corev1.ConfigMap{
					ObjectMeta: metav1.ObjectMeta{Name: "platform-slim-slim-config", Namespace: ai.Namespace},
					Data:       map[string]string{issuerHostOverrideEnv: tt.override},
				},
			}
			if tt.secretData != nil {
				objects = append(objects, &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "issuer-ca", Namespace: ai.Namespace}, Data: tt.secretData})
			}
			r := &SlimReconciler{Client: fake.NewClientBuilder().WithScheme(scheme).WithObjects(objects...).Build()}

			trust, err := r.validateIssuerTrust(ctx, ai, tt.required)
			if tt.wantError != "" {
				require.ErrorContains(t, err, tt.wantError)
				assert.NotContains(t, err.Error(), canary)
				return
			}
			require.NoError(t, err)
			volumes, mounts, env := appendIssuerTrust(tt.caRef, trust.hostOverride, nil, nil, nil)
			if tt.caRef == nil {
				assert.Empty(t, volumes)
				assert.Empty(t, mounts)
				assert.Empty(t, env)
				return
			}
			assert.NotEmpty(t, trust.hash)
			require.Len(t, volumes, 1)
			require.NotNil(t, volumes[0].Secret)
			assert.Equal(t, "issuer-ca", volumes[0].Secret.SecretName)
			assert.Equal(t, []corev1.KeyToPath{{Key: "ca.crt", Path: "ca.crt"}}, volumes[0].Secret.Items)
			require.Len(t, mounts, 1)
			assert.True(t, mounts[0].ReadOnly)
			assert.Empty(t, mounts[0].SubPath, "normal Secret projection allows kubelet to update mounted CA contents")
			for _, name := range []string{"SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"} {
				assert.Contains(t, env, corev1.EnvVar{Name: name, Value: mounts[0].MountPath + "/ca.crt"})
			}
			assert.Contains(t, env, corev1.EnvVar{Name: issuerHostOverrideEnv, Value: tt.override})
			assert.Equal(t, tt.trustedIssuer, buildSplunkIssuersVal(ai), "the token's issuer must match exactly")
		})
	}
}

func TestSLIMIssuerTrustRejectsInvalidCertificateBundles(t *testing.T) {
	now := time.Now()
	ca := issuerCertificate(t, now.Add(time.Hour), true)
	for _, tt := range []struct {
		name   string
		bundle []byte
		valid  bool
	}{
		{name: "valid CA", bundle: ca, valid: true},
		{name: "two valid CAs", bundle: append(append([]byte(nil), ca...), ca...), valid: true},
		{name: "expired CA", bundle: issuerCertificate(t, now.Add(-time.Minute), true)},
		{name: "leaf certificate", bundle: issuerCertificate(t, now.Add(time.Hour), false)},
		{name: "private key ahead of CA", bundle: append([]byte("-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----\n"), ca...)},
		{name: "malformed cert ahead of CA", bundle: append([]byte("-----BEGIN CERTIFICATE-----\nprivate\n-----END CERTIFICATE-----\n"), ca...)},
	} {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.valid, validIssuerCABundle(tt.bundle, now))
		})
	}
}
