package common

import (
	"context"
	"fmt"
	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"os"
	"path/filepath"
	"strings"
)

// vaultSecretsRoot is the only directory the operator is allowed to read via vaultFilePath.
const vaultSecretsRoot = "/vault/secrets"

// safeVaultPath validates p and returns the canonicalised, symlink-resolved path
// that should be opened. See pkg/splunkutils/vault_resolver.go for full rationale.
func safeVaultPath(p string) (string, error) {
	for _, component := range strings.Split(p, "/") {
		if component == ".." {
			return "", fmt.Errorf("vaultFilePath %q contains path traversal sequence", p)
		}
	}

	cleaned := filepath.Clean(p)
	prefix := vaultSecretsRoot + "/"
	if cleaned != vaultSecretsRoot && !strings.HasPrefix(cleaned, prefix) {
		return "", fmt.Errorf("vaultFilePath %q is outside the allowed prefix %q", p, vaultSecretsRoot)
	}

	resolved, err := filepath.EvalSymlinks(cleaned)
	if err != nil {
		return "", fmt.Errorf("failed to resolve vaultFilePath %q: %w", p, err)
	}
	if resolved != vaultSecretsRoot && !strings.HasPrefix(resolved, prefix) {
		return "", fmt.Errorf("vaultFilePath %q resolves to %q which is outside the allowed prefix %q", p, resolved, vaultSecretsRoot)
	}

	return resolved, nil
}

type VaultFileResolver struct{}

func (r *VaultFileResolver) GetHECToken(ctx context.Context, namespace string, cfg *aiApi.SplunkConfigurationSpec) (string, error) {
	if cfg.VaultFilePath == "" {
		return "", fmt.Errorf("VaultFilePath must be provided for SecretSource=vault")
	}

	safePath, err := safeVaultPath(cfg.VaultFilePath)
	if err != nil {
		return "", err
	}

	data, err := os.ReadFile(safePath)
	if err != nil {
		return "", fmt.Errorf("failed to read Vault-injected token file %q: %w", safePath, err)
	}

	token := strings.TrimSpace(string(data))
	if token == "" {
		return "", fmt.Errorf("vault-injected file %q is empty", safePath)
	}
	return token, nil
}
