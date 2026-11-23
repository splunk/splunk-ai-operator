package controller

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/splunk/splunk-ai-operator/pkg/ai/credentials"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var _ = Describe("Checkpoint Secret deployment against the local API server", func() {
	It("runs the production installer creation path and preserves an identical Secret", func() {
		// This kubeconfig points only at envtest. It lets the actual installer
		// helper use kubectl instead of substituting a successful API write.
		dir, err := os.MkdirTemp("", "checkpoint-api-test-")
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(func() { _ = os.RemoveAll(dir) })
		kubeconfig := clientcmdapi.Config{
			Clusters:  map[string]*clientcmdapi.Cluster{"local": {Server: cfg.Host, CertificateAuthorityData: cfg.CAData}},
			AuthInfos: map[string]*clientcmdapi.AuthInfo{"local": {ClientCertificateData: cfg.CertData, ClientKeyData: cfg.KeyData}},
			Contexts:  map[string]*clientcmdapi.Context{"local": {Cluster: "local", AuthInfo: "local"}}, CurrentContext: "local",
		}
		kubeconfigPath := filepath.Join(dir, "kubeconfig")
		Expect(clientcmd.WriteToFile(kubeconfig, kubeconfigPath)).To(Succeed())
		configPath := filepath.Join(dir, "deployment.yaml")
		Expect(os.WriteFile(configPath, []byte(`aiPlatform:
  features:
    - name: agentruntime
      checkpointDbSecretRef: installer-api-checkpoint
  agentRuntime:
    checkpointSecrets:
      - name: installer-api-checkpoint
        create: true
        databaseUrlEnv: CHECKPOINT_TEST_URL
`), 0600)).To(Succeed())
		source, err := os.ReadFile(filepath.Join("..", "..", "tools", "ai-tier-cluster-setup", "k0s_cluster_with_stack.sh"))
		Expect(err).NotTo(HaveOccurred())
		script := "set -euo pipefail\nlog() { :; }\nwarn() { :; }\nerr() { echo \"$*\" >&2; exit 1; }\nneed() { :; }\nk0s_agentruntime_feature_enabled() { return 0; }\n"
		for _, name := range []string{"validate_agentruntime_checkpoint_config", "render_agentruntime_checkpoint_secret_manifest", "create_agentruntime_checkpoint_secrets"} {
			body := regexp.MustCompile(`(?ms)^` + name + `\(\) \{.*?^\}$`).Find(source)
			Expect(body).NotTo(BeEmpty(), name)
			script += string(body) + "\n"
		}
		script += "create_agentruntime_checkpoint_secrets\n"
		run := func() {
			cmd := exec.Command("bash", "-c", script)
			cmd.Env = append(os.Environ(), "KUBECONFIG="+kubeconfigPath, "CONFIG_FILE="+configPath, "AI_NS=default",
				"CHECKPOINT_TEST_URL=postgresql://user:installer-api-canary-2026@postgres:5432/checkpoints",
				"PATH="+os.Getenv("KUBEBUILDER_ASSETS")+string(os.PathListSeparator)+os.Getenv("PATH"))
			output, err := cmd.CombinedOutput()
			Expect(strings.Contains(string(output), "installer-api-canary-2026")).To(BeFalse())
			Expect(err).NotTo(HaveOccurred(), string(output))
		}
		run()
		secret := &corev1.Secret{}
		key := client.ObjectKey{Namespace: "default", Name: "installer-api-checkpoint"}
		Expect(k8sClient.Get(ctx, key, secret)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, secret) })
		Expect(credentials.ValidatePostgresSecret(secret)).To(Succeed())
		Expect(secret.OwnerReferences).To(BeEmpty())
		version := secret.ResourceVersion
		run()
		Expect(k8sClient.Get(ctx, key, secret)).To(Succeed())
		Expect(secret.ResourceVersion).To(Equal(version))
	})
})
