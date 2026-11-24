package imagesnapshot

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLoadInput_WithoutACandidateReadsTheComponentSwitchesButNoInventory(t *testing.T) {
	cfg := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(cfg, []byte("components:\n  monitoring: false\n"), 0o644))
	in, err := LoadInput(InputFiles{Config: cfg})
	require.NoError(t, err)
	assert.Nil(t, in.Candidate)
	assert.False(t, in.ComponentOn(ProfileCPUOnly, "monitoring"))
	assert.True(t, in.ComponentOn(ProfileCPUOnly, "otel"), "an omitted switch is on")
	_, err = BuildInventory(in)
	assert.ErrorContains(t, err, "a candidate manifest is required", "an inventory still needs the candidate")
}

func TestLoadInput_RejectsAValuesFileForTheOtherProfile(t *testing.T) {
	v := filepath.Join(t.TempDir(), "values.yaml")
	require.NoError(t, os.WriteFile(v, []byte("profile: {effective: fullfeature}\n"), 0o644))
	_, err := LoadInput(InputFiles{Candidate: candidatePath, CPUOnlyValues: v})
	assert.ErrorContains(t, err, `is the rendered profile "fullfeature", not "cpuOnly"`)
}
