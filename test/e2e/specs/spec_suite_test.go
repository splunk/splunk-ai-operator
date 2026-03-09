package e2e

import (
	"context"
	"errors"
	"os/exec"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestSpecs(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "e2e specs")
}

// clusterReachableTimeout is the max time to wait for kubectl cluster-info before skipping e2e.
const clusterReachableTimeout = 10 * time.Second

// BeforeSuite runs once before any e2e spec. Skip the entire suite if the cluster is unreachable
// (e.g. no kubeconfig, missing AWS/cloud credentials, or cluster down) so "go test ./..." can pass
// without a live cluster. Uses a short timeout to avoid blocking indefinitely on hung network calls.
var _ = BeforeSuite(func() {
	ctx, cancel := context.WithTimeout(context.Background(), clusterReachableTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "kubectl", "cluster-info", "--request-timeout=5s")
	if err := cmd.Run(); err != nil {
		msg := "e2e specs require a reachable Kubernetes cluster (kubectl cluster-info failed). Configure kubeconfig and cloud credentials, or run unit tests only: go test $(go list ./... | grep -v /e2e)"
		if errors.Is(err, context.DeadlineExceeded) {
			msg = "e2e specs skipped: cluster unreachable within " + clusterReachableTimeout.String() + " (timeout). " + msg
		}
		Skip(msg)
	}
})
