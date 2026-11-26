package podsecurity

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
)

func TestRuntimeDefaultSeccomp(t *testing.T) {
	sc := RuntimeDefaultSeccomp()
	require.NotNil(t, sc.SeccompProfile)
	assert.Equal(t, corev1.SeccompProfileTypeRuntimeDefault, sc.SeccompProfile.Type)
	assert.Nil(t, sc.SeccompProfile.LocalhostProfile)

	// Each call returns a new value, so one pod spec cannot change another.
	assert.NotSame(t, sc, RuntimeDefaultSeccomp())
}
