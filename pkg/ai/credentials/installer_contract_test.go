package credentials

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
)

// Compare the actual shell renderer with the Go contract. Independent parser
// tests alone can miss a Secret that installation writes but reconciliation rejects.
func TestInstallerRendererMatchesPostgresContract(t *testing.T) {
	source, err := os.ReadFile(filepath.Join("..", "..", "..", "tools", "ai-tier-cluster-setup", "k0s_cluster_with_stack.sh"))
	require.NoError(t, err)
	body := regexp.MustCompile(`(?ms)^render_agentruntime_checkpoint_secret_manifest\(\) \{.*?^\}$`).Find(source)
	require.NotEmpty(t, body)
	for _, tc := range []struct {
		name, uri string
		valid     bool
	}{
		{"ordinary", "postgresql://user:parity-canary@postgres:5432/checkpoints", true},
		{"escaped password", "postgresql://user:parity%20canary@postgres/checkpoints", true},
		{"IPv6 zone", "postgresql://user:parity-canary@[fe80::1%25eth0]/checkpoints", true},
		{"escaped option", "postgresql://user:parity-canary@postgres/checkpoints?application_name=x%3By", true},
		{"raw password space", "postgresql://user:parity canary@postgres/checkpoints", false},
		{"escaped DNS host", "postgresql://user:parity-canary@d%62/checkpoints", false},
		{"backslash host", "postgresql://user:parity-canary@bad\\host/checkpoints", false},
		{"query separator", "postgresql://user:parity-canary@postgres/checkpoints?application_name=x;y", false},
		{"database conninfo", "postgresql://user:parity-canary@postgres/host%3Dother%20dbname%3Dcheckpoints", false},
		{"database URI", "postgresql://user:parity-canary@postgres/postgresql%3A%2F%2Fother%2Fdb", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cmd := exec.Command("bash", "-c", string(body)+"\nrender_agentruntime_checkpoint_secret_manifest checkpoint default\n")
			cmd.Stdin = strings.NewReader(tc.uri)
			output, err := cmd.CombinedOutput()
			if !tc.valid {
				require.Error(t, err)
				require.NotContains(t, string(output), "parity")
				return
			}
			require.NoError(t, err)
			var secret corev1.Secret
			require.NoError(t, json.Unmarshal(output, &secret))
			require.NoError(t, ValidatePostgresSecret(&secret))
		})
	}
}
