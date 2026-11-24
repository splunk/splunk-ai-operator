package slim

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/util/validation"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	issuerCAKey               = "ca.crt"
	issuerCAVolume            = "splunk-issuer-ca"
	issuerCAPath              = "/etc/splunk-issuer-ca"
	issuerHostOverrideEnv     = "SPLUNK_ISSUER_HOST_OVERRIDE"
	issuerTrustHashAnnotation = "splunk-ai-operator/issuer-trust-hash"
)

type issuerTrust struct {
	hostOverride string
	hash         string
	needsDrain   bool
}

func (trust issuerTrust) revisionLabel() string {
	if trust.hash == "" {
		return ""
	}
	// Kubernetes limits label values to 63 characters. A 128-bit prefix still
	// distinguishes trust revisions while the full digest remains on the template.
	return trust.hash[:32]
}

// validateIssuerTrust pins the verified host override in the Pod environment
// and identifies the trust revision that must finish rolling out before serving.
func (r *SlimReconciler) validateIssuerTrust(ctx context.Context, ai *aiv1.AIService, required bool) (issuerTrust, error) {
	config := &ai.Spec.SplunkConfiguration
	if config.CACertRef == nil {
		if required {
			return issuerTrust{}, errors.New("spec.splunkConfiguration.caCertRef.name is required for SLIM to verify the Splunk issuer")
		}
		return issuerTrust{}, nil
	}
	name := config.CACertRef.Name
	if len(validation.IsDNS1123Subdomain(name)) != 0 {
		return issuerTrust{}, errors.New("spec.splunkConfiguration.caCertRef.name must be a Kubernetes Secret name")
	}
	issuers := buildSplunkIssuersVal(ai)
	if issuers == "" {
		return issuerTrust{}, errors.New("spec.splunkConfiguration must identify at least one Splunk token issuer")
	}
	if config.SplunkCustomResourceRef.Name != "" {
		// Validate the derived primary issuer before combining it with the
		// allowlist. A malformed reference must not introduce extra CSV entries.
		primary := *ai
		primary.Spec.SplunkConfiguration.TrustedIssuers = nil
		address := strings.TrimPrefix(buildSplunkIssuersVal(&primary), "https://")
		if !validIssuerAddress(address, false) {
			return issuerTrust{}, errors.New("spec.splunkConfiguration.splunkCustomResourceRef must identify a valid Splunk Service address")
		}
	} else if config.Endpoint != "" && !validIssuerAddress(config.Endpoint, true) {
		return issuerTrust{}, errors.New("spec.splunkConfiguration.endpoint must identify an HTTPS issuer")
	}
	for i, issuer := range config.TrustedIssuers {
		if !validIssuerAddress(issuer, true) {
			return issuerTrust{}, fmt.Errorf("spec.splunkConfiguration.trustedIssuers[%d] must identify an HTTPS issuer", i)
		}
	}

	secret := &corev1.Secret{}
	if err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: name}, secret); err != nil {
		if apierrors.IsNotFound(err) {
			return issuerTrust{}, errors.New("spec.splunkConfiguration.caCertRef names a Secret missing from the SLIM namespace")
		}
		return issuerTrust{}, errors.New("cannot read spec.splunkConfiguration.caCertRef Secret")
	}
	bundle := secret.Data[issuerCAKey]
	if !validIssuerCABundle(bundle, time.Now()) {
		return issuerTrust{}, errors.New("spec.splunkConfiguration.caCertRef Secret must have a ca.crt key with currently valid PEM CA certificates")
	}

	cm := &corev1.ConfigMap{}
	if err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-slim-config"}, cm); err != nil && !apierrors.IsNotFound(err) {
		return issuerTrust{}, errors.New("cannot read SLIM issuer configuration")
	}
	override := cm.Data[issuerHostOverrideEnv]
	if override != "" && !validIssuerAddress(override, false) {
		return issuerTrust{}, errors.New("SLIM SPLUNK_ISSUER_HOST_OVERRIDE must be a hostname or host:port for HTTPS")
	}
	hash := sha256.Sum256([]byte(strings.Join([]string{name, issuers, override, string(bundle)}, "\x00")))
	return issuerTrust{hostOverride: override, hash: fmt.Sprintf("%x", hash)}, nil
}

func validIssuerAddress(value string, allowIssuerURL bool) bool {
	// SLIM treats its issuer whitelist as CSV and normalizes a bare
	// Splunk serverName claim to HTTPS before it contacts that server.
	if strings.ContainsAny(value, ",\\") || strings.IndexFunc(value, unicode.IsSpace) >= 0 {
		return false
	}
	rawURL := value
	if !strings.Contains(value, "://") {
		rawURL = "https://" + value
	} else if !allowIssuerURL {
		return false
	}
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Scheme != "https" || parsed.User != nil ||
		parsed.Fragment != "" || strings.Contains(rawURL, "#") || parsed.RawQuery != "" || parsed.ForceQuery ||
		(!allowIssuerURL && parsed.Path != "") || strings.HasSuffix(parsed.Host, ":") {
		return false
	}

	host := parsed.Hostname()
	if net.ParseIP(host) == nil && len(validation.IsDNS1123Subdomain(strings.ToLower(strings.TrimSuffix(host, ".")))) != 0 {
		return false
	}
	if port := parsed.Port(); port != "" {
		n, err := strconv.Atoi(port)
		return err == nil && n > 0 && n <= 65535
	}
	return true
}

func validIssuerCABundle(bundle []byte, now time.Time) bool {
	bundle = bytes.TrimSpace(bundle)
	if len(bundle) == 0 {
		return false
	}
	for len(bundle) > 0 {
		const endMarker = "-----END CERTIFICATE-----"
		end := bytes.Index(bundle, []byte(endMarker))
		if end < 0 || !bytes.HasPrefix(bundle, []byte("-----BEGIN CERTIFICATE-----")) {
			return false
		}
		end += len(endMarker)
		block, _ := pem.Decode(bundle[:end])
		if block == nil || block.Type != "CERTIFICATE" || len(block.Headers) != 0 {
			return false
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil || !cert.IsCA || now.Before(cert.NotBefore) || now.After(cert.NotAfter) ||
			(cert.KeyUsage != 0 && cert.KeyUsage&x509.KeyUsageCertSign == 0) {
			return false
		}
		bundle = bytes.TrimSpace(bundle[end:])
	}
	return true
}

func appendIssuerTrust(
	ref *corev1.LocalObjectReference,
	override string,
	volumes []corev1.Volume,
	mounts []corev1.VolumeMount,
	env []corev1.EnvVar,
) ([]corev1.Volume, []corev1.VolumeMount, []corev1.EnvVar) {
	if ref == nil {
		return volumes, mounts, env
	}
	volumes = append(volumes, corev1.Volume{
		Name: issuerCAVolume,
		VolumeSource: corev1.VolumeSource{
			Secret: &corev1.SecretVolumeSource{
				SecretName: ref.Name,
				Items:      []corev1.KeyToPath{{Key: issuerCAKey, Path: issuerCAKey}},
			},
		},
	})
	mounts = append(mounts, corev1.VolumeMount{Name: issuerCAVolume, MountPath: issuerCAPath, ReadOnly: true})
	bundlePath := issuerCAPath + "/" + issuerCAKey
	// Without either CA variable the supplied SLIM candidate disables
	// certificate verification for its outbound issuer/JWKS calls.
	env = append(env,
		corev1.EnvVar{Name: "SSL_CERT_FILE", Value: bundlePath},
		corev1.EnvVar{Name: "REQUESTS_CA_BUNDLE", Value: bundlePath},
		corev1.EnvVar{Name: issuerHostOverrideEnv, Value: override},
	)
	return volumes, mounts, env
}
