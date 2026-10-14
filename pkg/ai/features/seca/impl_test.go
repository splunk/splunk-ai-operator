package seca

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestConfigMap(t *testing.T) {
	cm := ConfigMap("test-namespace", "test-service")

	assert.NotNil(t, cm)
	assert.Equal(t, "test-service-seca-config", cm.Name)
	assert.Equal(t, "test-namespace", cm.Namespace)
	assert.Equal(t, "true", cm.Data["TOAD_FEATURE_ENABLED"])
}

func TestDeployment(t *testing.T) {
	deployment := Deployment("test-namespace", "test-service")

	assert.NotNil(t, deployment)
	assert.Equal(t, "test-service-seca", deployment.Name)
	assert.Equal(t, "test-namespace", deployment.Namespace)
	assert.Equal(t, map[string]string{"app": "seca"}, deployment.Labels)

	// Verify replicas
	assert.NotNil(t, deployment.Spec.Replicas)
	assert.Equal(t, int32(1), *deployment.Spec.Replicas)

	// Verify selector
	assert.Equal(t, map[string]string{"app": "seca"}, deployment.Spec.Selector.MatchLabels)

	// Verify container
	assert.Len(t, deployment.Spec.Template.Spec.Containers, 1)
	container := deployment.Spec.Template.Spec.Containers[0]
	assert.Equal(t, "seca", container.Name)
	assert.Equal(t, "docker.io/splunk/SECA:latest", container.Image)

	// Verify environment variable
	assert.Len(t, container.Env, 1)
	assert.Equal(t, "TOAD_CONFIG", container.Env[0].Name)
	assert.NotNil(t, container.Env[0].ValueFrom)
	assert.NotNil(t, container.Env[0].ValueFrom.ConfigMapKeyRef)
	assert.Equal(t, "TOAD_FEATURE_ENABLED", container.Env[0].ValueFrom.ConfigMapKeyRef.Key)
	assert.Equal(t, "test-service-seca-config", container.Env[0].ValueFrom.ConfigMapKeyRef.Name)
}

func TestService(t *testing.T) {
	service := Service("test-namespace", "test-service")

	assert.NotNil(t, service)
	assert.Equal(t, "test-service-seca-svc", service.Name)
	assert.Equal(t, "test-namespace", service.Namespace)
	assert.Equal(t, map[string]string{"app": "seca"}, service.Spec.Selector)

	// Verify ports
	assert.Len(t, service.Spec.Ports, 1)
	assert.Equal(t, "http", service.Spec.Ports[0].Name)
	assert.Equal(t, int32(8080), service.Spec.Ports[0].Port)
}

func TestPointer(t *testing.T) {
	val := pointer(int32(42))
	assert.NotNil(t, val)
	assert.Equal(t, int32(42), *val)
}
