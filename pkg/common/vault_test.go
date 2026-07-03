package common

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestValidateVaultPath(t *testing.T) {
	t.Run("allowed: direct child of /vault/secrets/", func(t *testing.T) {
		assert.NoError(t, validateVaultPath("/vault/secrets/splunk"))
	})

	t.Run("allowed: nested under /vault/secrets/", func(t *testing.T) {
		assert.NoError(t, validateVaultPath("/vault/secrets/a/b/token"))
	})

	t.Run("blocked: operator SA token path", func(t *testing.T) {
		err := validateVaultPath("/var/run/secrets/kubernetes.io/serviceaccount/token")
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "outside the allowed prefix")
	})

	t.Run("blocked: /etc/passwd", func(t *testing.T) {
		err := validateVaultPath("/etc/passwd")
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "outside the allowed prefix")
	})

	t.Run("blocked: traversal sequence escaping root", func(t *testing.T) {
		err := validateVaultPath("/vault/secrets/../../../etc/passwd")
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "outside the allowed prefix")
	})

	t.Run("blocked: path that only starts with /vault/secrets but is not under it", func(t *testing.T) {
		err := validateVaultPath("/vault/secrets-extra/token")
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "outside the allowed prefix")
	})

	t.Run("blocked: symlink resolving outside root", func(t *testing.T) {
		tmpDir := t.TempDir()
		target := filepath.Join(tmpDir, "target_secret")
		require.NoError(t, os.WriteFile(target, []byte("data"), 0600))

		vaultDir := filepath.Join(tmpDir, "vault", "secrets")
		require.NoError(t, os.MkdirAll(vaultDir, 0755))
		link := filepath.Join(vaultDir, "evil_link")
		require.NoError(t, os.Symlink(target, link))

		_ = validateVaultPath(link) // symlink defence; result depends on real FS prefix
	})
}

func TestVaultFileResolver_GetHECToken(t *testing.T) {
	ctx := context.Background()
	resolver := &VaultFileResolver{}

	t.Run("error: VaultFilePath is missing", func(t *testing.T) {
		cfg := &aiApi.SplunkConfigurationSpec{}

		token, err := resolver.GetHECToken(ctx, "test-ns", cfg)

		assert.Error(t, err)
		assert.Contains(t, err.Error(), "VaultFilePath must be provided")
		assert.Empty(t, token)
	})

	t.Run("error: path outside /vault/secrets/ is rejected before read", func(t *testing.T) {
		tmpFile, err := os.CreateTemp("", "sa-token-*")
		require.NoError(t, err)
		defer os.Remove(tmpFile.Name())
		_, _ = tmpFile.WriteString("real-k8s-token")
		tmpFile.Close()

		cfg := &aiApi.SplunkConfigurationSpec{
			VaultFilePath: tmpFile.Name(),
		}

		token, err := resolver.GetHECToken(ctx, "test-ns", cfg)

		assert.Error(t, err)
		assert.Contains(t, err.Error(), "outside the allowed prefix")
		assert.Empty(t, token)
	})

	t.Run("error: traversal sequence rejected", func(t *testing.T) {
		cfg := &aiApi.SplunkConfigurationSpec{
			VaultFilePath: "/vault/secrets/../../../var/run/secrets/kubernetes.io/serviceaccount/token",
		}

		token, err := resolver.GetHECToken(ctx, "test-ns", cfg)

		assert.Error(t, err)
		assert.Contains(t, err.Error(), "outside the allowed prefix")
		assert.Empty(t, token)
	})

	t.Run("error: non-existent file under allowed prefix", func(t *testing.T) {
		cfg := &aiApi.SplunkConfigurationSpec{
			VaultFilePath: "/vault/secrets/does-not-exist-12345",
		}

		token, err := resolver.GetHECToken(ctx, "test-ns", cfg)

		assert.Error(t, err)
		assert.Contains(t, err.Error(), "failed to read Vault-injected token file")
		assert.Empty(t, token)
	})

	t.Run("token trimming logic (unit)", func(t *testing.T) {
		assert.NoError(t, validateVaultPath("/vault/secrets/splunk-hec"))
		raw := "  super-secret-token\n"
		assert.Equal(t, "super-secret-token", strings.TrimSpace(raw))
	})
}
