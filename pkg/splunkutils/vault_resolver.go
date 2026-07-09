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

// safeVaultPath validates p and returns the canonicalised, symlink-resolved path
// that should be opened. It rejects:
//   - any path component equal to ".." (before filepath.Clean can erase them)
//   - any cleaned path not under /vault/secrets/
//   - any symlink-resolved path not under /vault/secrets/
//
// The returned path is the one actually opened, so validate-then-open cannot
// diverge from what the kernel sees.
func safeVaultPath(p string) (string, error) {
	// Reject ".." components before filepath.Clean normalises them away.
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

	// Resolve symlinks and re-validate the real path so a symlink inside
	// /vault/secrets/ pointing outside it is also caught.
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

	// Read the resolved path — not the original — so the path we validated is
	// identical to the path the kernel opens.
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
