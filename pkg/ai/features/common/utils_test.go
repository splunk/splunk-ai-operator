package common

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestIsConditionTrue(t *testing.T) {
	conds := []metav1.Condition{
		{Type: "Ready", Status: metav1.ConditionTrue},
		{Type: "Healthy", Status: metav1.ConditionFalse},
	}
	if !IsConditionTrue(conds, "Ready") {
		t.Error("Expected Ready condition to be true")
	}
	if IsConditionTrue(conds, "Healthy") {
		t.Error("Expected Healthy condition to be false")
	}
	if IsConditionTrue(conds, "Missing") {
		t.Error("Expected Missing condition to be false")
	}
}

func TestFilterPropagatedAnnotations(t *testing.T) {
	src := map[string]string{
		"custom": "kept",
		"kubectl.kubernetes.io/last-applied-configuration": "drop",
		"example.com/last-applied-configuration":           "kept",
		"kubectl.kubernetes.io/restartedAt":                "drop",
		"script-reconcile-ts":                              "drop",
		"splunk-ai-operator/splunk-ca-hash":                "drop",
		"splunk-ai-operator/splunk-issuers-hash":           "drop",
	}

	filtered := FilterPropagatedAnnotations(src)
	if len(filtered) != 2 || filtered["custom"] != "kept" || filtered["example.com/last-applied-configuration"] != "kept" {
		t.Fatalf("unexpected filtered annotations: %#v", filtered)
	}
	if src["script-reconcile-ts"] != "drop" {
		t.Fatal("source annotations were mutated")
	}
}

func TestCheckRayHeadService_Success(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	// Override the default endpoint by patching the function (simulate)
	//oldURL := "http://localhost:8265"
	defer func() {
		// restore if needed
	}()
	err := CheckRayHeadService(context.Background(), server.URL)
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestCheckRayHeadService_EmptyURL(t *testing.T) {
	err := CheckRayHeadService(context.Background(), "")
	if err == nil {
		t.Error("Expected error for empty URL")
	}
}

func TestCheckRayHeadService_BadStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()
	err := CheckRayHeadService(context.Background(), server.URL)
	if err == nil {
		t.Error("Expected error for non-200 status")
	}
}

func TestCheckWeaviateService_Success(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	err := CheckWeaviateService(context.Background(), server.URL)
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestCheckWeaviateService_BadStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	err := CheckWeaviateService(context.Background(), server.URL)
	if err == nil {
		t.Error("Expected error for non-200 status")
	}
}
