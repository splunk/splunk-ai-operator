package e2e

import (
	"os/exec"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestSpecs(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "e2e specs")
}

// BeforeSuite runs once before any e2e spec. Skip the entire suite if the cluster is unreachable
// (e.g. no kubeconfig, missing AWS/cloud credentials, or cluster down) so "go test ./..." can pass
// without a live cluster.
var _ = BeforeSuite(func() {
	cmd := exec.Command("kubectl", "cluster-info")
	if err := cmd.Run(); err != nil {
		Skip("e2e specs require a reachable Kubernetes cluster (kubectl cluster-info failed). Configure kubeconfig and cloud credentials, or run unit tests only: go test $(go list ./... | grep -v /e2e)")
	}
})
