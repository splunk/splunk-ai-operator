package splunkutils

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
)

// vaultSecretsRoot is the only directory the operator is allowed to read via vaultFilePath.
const vaultSecretsRoot = "/vault/secrets"

// validateVaultPath rejects any path outside vaultSecretsRoot, including traversal
// sequences and symlinks that resolve outside the root.
func validateVaultPath(p string) error {
	cleaned := filepath.Clean(p)
	prefix := vaultSecretsRoot + "/"
	if cleaned != vaultSecretsRoot && !strings.HasPrefix(cleaned, prefix) {
		return fmt.Errorf("vaultFilePath %q is outside the allowed prefix %q", p, vaultSecretsRoot)
	}
	// If the target already exists, verify the fully-resolved path is also in bounds.
	if resolved, err := filepath.EvalSymlinks(cleaned); err == nil {
		if resolved != vaultSecretsRoot && !strings.HasPrefix(resolved, prefix) {
			return fmt.Errorf("vaultFilePath %q resolves to %q which is outside the allowed prefix %q", p, resolved, vaultSecretsRoot)
		}
	}
	return nil
}

type VaultFileResolver struct{}

func (r *VaultFileResolver) GetHECToken(ctx context.Context, namespace string, cfg *aiApi.SplunkConfigurationSpec) (string, error) {
	if cfg.VaultFilePath == "" {
		return "", fmt.Errorf("VaultFilePath must be provided for SecretSource=vault")
	}

	if err := validateVaultPath(cfg.VaultFilePath); err != nil {
		return "", err
	}

	data, err := os.ReadFile(cfg.VaultFilePath)
	if err != nil {
		return "", fmt.Errorf("failed to read Vault-injected token file %q: %w", cfg.VaultFilePath, err)
	}

	token := strings.TrimSpace(string(data))
	if token == "" {
		return "", fmt.Errorf("vault-injected file %q is empty", cfg.VaultFilePath)
	}
	return token, nil
}
