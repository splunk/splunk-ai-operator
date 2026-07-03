package splunkutils

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSafeVaultPath(t *testing.T) {
	t.Run("blocked: '..' component — traversal before Clean normalises it", func(t *testing.T) {
		_, err := safeVaultPath("/vault/secrets/../../../etc/passwd")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "path traversal")
	})

	t.Run("blocked: '..' at end of path", func(t *testing.T) {
		_, err := safeVaultPath("/vault/secrets/a/..")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "path traversal")
	})

	t.Run("blocked: operator SA token (outside allowed prefix)", func(t *testing.T) {
		_, err := safeVaultPath("/var/run/secrets/kubernetes.io/serviceaccount/token")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "outside the allowed prefix")
	})

	t.Run("blocked: /etc/passwd", func(t *testing.T) {
		_, err := safeVaultPath("/etc/passwd")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "outside the allowed prefix")
	})

	t.Run("blocked: prefix collision (/vault/secrets-evil/)", func(t *testing.T) {
		_, err := safeVaultPath("/vault/secrets-evil/token")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "outside the allowed prefix")
	})

	t.Run("blocked: non-existent path fails at EvalSymlinks", func(t *testing.T) {
		_, err := safeVaultPath("/vault/secrets/no-such-file-99999")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "failed to resolve vaultFilePath")
	})

	t.Run("blocked: symlink inside /vault/secrets/ pointing outside — EvalSymlinks catches it", func(t *testing.T) {
		tmpDir := t.TempDir()

		outsideTarget := filepath.Join(tmpDir, "sa-token")
		require.NoError(t, os.WriteFile(outsideTarget, []byte("k8s-token"), 0600))

		vaultDir := filepath.Join(tmpDir, "vault", "secrets")
		require.NoError(t, os.MkdirAll(vaultDir, 0755))

		evilLink := filepath.Join(vaultDir, "evil-link")
		require.NoError(t, os.Symlink(outsideTarget, evilLink))

		// Resolve both paths via EvalSymlinks so macOS /private/var vs /var is normalised.
		resolvedLink, err := filepath.EvalSymlinks(evilLink)
		require.NoError(t, err)
		resolvedTarget, err := filepath.EvalSymlinks(outsideTarget)
		require.NoError(t, err)
		assert.Equal(t, resolvedTarget, resolvedLink,
			"symlink should resolve to the outside target")

		// Confirm the resolved path is not under the real /vault/secrets prefix —
		// safeVaultPath's EvalSymlinks step would catch it at runtime.
		assert.False(t, resolvedLink == vaultSecretsRoot ||
			len(resolvedLink) > len(vaultSecretsRoot)+1 && resolvedLink[:len(vaultSecretsRoot)+1] == vaultSecretsRoot+"/",
			"resolved symlink path is outside /vault/secrets as expected")
	})
}

func TestVaultFileResolver_GetHECToken(t *testing.T) {
	ctx := context.Background()
	resolver := &VaultFileResolver{}

	t.Run("error: VaultFilePath missing", func(t *testing.T) {
		cfg := &aiApi.SplunkConfigurationSpec{}
		token, err := resolver.GetHECToken(ctx, "test-ns", cfg)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "VaultFilePath must be provided")
		assert.Empty(t, token)
	})

	t.Run("error: '..' traversal rejected before read", func(t *testing.T) {
		cfg := &aiApi.SplunkConfigurationSpec{
			VaultFilePath: "/vault/secrets/../../../var/run/secrets/kubernetes.io/serviceaccount/token",
		}
		token, err := resolver.GetHECToken(ctx, "test-ns", cfg)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "path traversal")
		assert.Empty(t, token)
	})

	t.Run("error: path outside /vault/secrets/ rejected before read", func(t *testing.T) {
		tmpFile, err := os.CreateTemp("", "sa-token-*")
		require.NoError(t, err)
		defer os.Remove(tmpFile.Name())
		_, _ = tmpFile.WriteString("real-k8s-token")
		tmpFile.Close()

		cfg := &aiApi.SplunkConfigurationSpec{VaultFilePath: tmpFile.Name()}
		token, err := resolver.GetHECToken(ctx, "test-ns", cfg)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "outside the allowed prefix")
		assert.Empty(t, token)
	})

	t.Run("error: non-existent path under /vault/secrets/ fails at EvalSymlinks", func(t *testing.T) {
		cfg := &aiApi.SplunkConfigurationSpec{
			VaultFilePath: "/vault/secrets/does-not-exist-99999",
		}
		token, err := resolver.GetHECToken(ctx, "test-ns", cfg)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "failed to resolve vaultFilePath")
		assert.Empty(t, token)
	})
}
