package splunkutils

import (
	"context"
	"fmt"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type KubernetesSecretResolver struct {
	Client client.Client
}

func (r *KubernetesSecretResolver) GetHECToken(ctx context.Context, namespace string, cfg *aiApi.SplunkConfigurationSpec) (string, error) {
	if cfg == nil {
		return "", fmt.Errorf("Splunk configuration is required to resolve the HEC token")
	}
	if namespace == "" {
		return "", fmt.Errorf("AI resource namespace is required to resolve the HEC token")
	}

	// An explicit SecretRef is authoritative. Keep the namespace-scoped Secret
	// only as a compatibility fallback for SplunkCustomResourceRef users that
	// predate SecretRef; current endpoint/OTel configurations require
	// SecretRef.Name at admission.
	secretName := cfg.SecretRef.Name
	if secretName == "" {
		secretName = GetNamespaceScopedSecretName(namespace)
	}

	secretNamespace := cfg.SecretRef.Namespace
	if secretNamespace == "" {
		secretNamespace = namespace
	}
	if secretNamespace != namespace {
		return "", fmt.Errorf(
			"Splunk secret %q references namespace %q, but cross-namespace Secret references are not supported (AI resource namespace is %q)",
			secretName,
			secretNamespace,
			namespace,
		)
	}

	var secret corev1.Secret
	if err := r.Client.Get(ctx, client.ObjectKey{Name: secretName, Namespace: secretNamespace}, &secret); err != nil {
		return "", fmt.Errorf("failed to get Splunk secret %q in namespace %q: %w", secretName, secretNamespace, err)
	}
	hecToken, ok := secret.Data[splunkSecretKeyHecToken]
	if !ok {
		return "", fmt.Errorf("secret %q missing required key %q", secretName, splunkSecretKeyHecToken)
	}
	return string(hecToken), nil
}
