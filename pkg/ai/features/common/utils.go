package common

import (
	"context"
	"fmt"
	"net"
	"path"

	//"io"
	"net/http"
	"net/url"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

var nonPropagatedAnnotations = map[string]struct{}{
	"kubectl.kubernetes.io/last-applied-configuration": {},
	"kubectl.kubernetes.io/restartedAt":                {},
	"script-reconcile-ts":                              {},
}

// FilterPropagatedAnnotations copies annotations that are safe to propagate
// from an AIService to its child resources. Installer/controller bookkeeping
// annotations must stay on the AIService: copying them into pod templates
// turns every installer run into an otherwise unnecessary workload rollout.
func FilterPropagatedAnnotations(src map[string]string) map[string]string {
	filtered := make(map[string]string, len(src))
	for key, value := range src {
		if _, skip := nonPropagatedAnnotations[key]; skip {
			continue
		}
		filtered[key] = value
	}
	return filtered
}

var IsConditionTrue = func(conditions []metav1.Condition, condType string) bool {
	for _, cond := range conditions {
		if cond.Type == condType && cond.Status == metav1.ConditionTrue {
			return true
		}
	}
	return false
}

var CheckRayHeadService = func(ctx context.Context, endpoint string) error {
	u, err := url.Parse(endpoint)
	if err != nil {
		return fmt.Errorf("invalid endpoint: %w", err)
	}
	if u.Scheme == "" {
		u.Scheme = "http"
	}

	// If no port is present, default to 8265. If a port exists, keep it.
	host := u.Host
	if host == "" {
		host = u.Path // allow bare "localhost:8265"
		u.Path = ""
	}
	if _, _, err := net.SplitHostPort(host); err != nil {
		// no port in host, add default
		host = net.JoinHostPort(host, "8265")
	}
	u.Host = host

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to reach Ray head endpoint: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("ray head returned %s", resp.Status)
	}
	return nil
}

var CheckWeaviateService = func(ctx context.Context, weaviateURL string) error {
	u, err := url.Parse(weaviateURL)
	if err != nil {
		return fmt.Errorf("invalid weaviate URL: %w", err)
	}
	// accept bare "host[:port]" without scheme
	if u.Scheme == "" {
		u.Scheme = "http"
	}
	if u.Host == "" {
		// when given "localhost:8080" without scheme, Parse puts it in Path
		u.Host = u.Path
		u.Path = ""
	}
	// if no port provided, you can set a default here if you have one, otherwise leave as is
	// _, _, err = net.SplitHostPort(u.Host)
	// if err != nil { u.Host = net.JoinHostPort(u.Host, "8080") }

	// append readiness path
	u.Path = path.Join("/", u.Path, "/v1/.well-known/ready")

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}

	client := http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to reach Weaviate endpoint: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("weaviate not ready, returned status=%d", resp.StatusCode)
	}
	return nil
}
