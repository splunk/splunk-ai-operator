package v1

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"k8s.io/apiextensions-apiserver/pkg/apis/apiextensions"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	structuralschema "k8s.io/apiextensions-apiserver/pkg/apiserver/schema"
	structuraldefaulting "k8s.io/apiextensions-apiserver/pkg/apiserver/schema/defaulting"
	"sigs.k8s.io/yaml"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
)

func profilePlatform(profile aiv1.AIPlatformProfile) *aiv1.AIPlatform {
	return &aiv1.AIPlatform{Spec: aiv1.AIPlatformSpec{
		Profile:       profile,
		ObjectStorage: aiv1.ObjectStorageSpec{Path: "s3://bucket", Region: "us-west-2"},
	}}
}

func TestAIPlatformWebhook_ProfileAccepted(t *testing.T) {
	v := &AIPlatformCustomValidator{}
	for _, profile := range []aiv1.AIPlatformProfile{"", "full", "fullfeature", "cpuOnly"} {
		_, err := v.ValidateCreate(context.Background(), profilePlatform(profile))
		assert.NoError(t, err, "profile %q", profile)
	}
}

func TestAIPlatformWebhook_UnknownProfileRejected(t *testing.T) {
	v := &AIPlatformCustomValidator{}
	_, err := v.ValidateCreate(context.Background(), profilePlatform("cpuonly"))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "spec.profile")
	assert.Contains(t, err.Error(), "fullfeature")
}

func TestAIPlatformWebhook_CPUOnlyContradictionRejected(t *testing.T) {
	v := &AIPlatformCustomValidator{}
	p := profilePlatform(aiv1.AIPlatformProfileCPUOnly)
	p.Spec.DefaultAcceleratorType = "L40S"
	p.Spec.Features = []aiv1.FeatureSpec{{Name: "saia"}}
	_, err := v.ValidateCreate(context.Background(), p)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "spec.defaultAcceleratorType")
	assert.Contains(t, err.Error(), "spec.features[0].name")
}

func TestAIPlatformWebhook_DefaultingKeepsProfileAndSkipsVectorDBForCPUOnly(t *testing.T) {
	d := &AIPlatformCustomDefaulter{}

	cpu := profilePlatform(aiv1.AIPlatformProfileCPUOnly)
	require.NoError(t, d.Default(context.Background(), cpu))
	assert.Empty(t, cpu.Spec.Storage.VectorDB.Size)
	assert.Equal(t, aiv1.AIPlatformProfileCPUOnly, cpu.Spec.Profile)
	// The defaulted cpuOnly object must still pass validation.
	_, err := (&AIPlatformCustomValidator{}).ValidateCreate(context.Background(), cpu)
	assert.NoError(t, err)

	full := profilePlatform("")
	require.NoError(t, d.Default(context.Background(), full))
	assert.Equal(t, "50Gi", full.Spec.Storage.VectorDB.Size)
	assert.Empty(t, full.Spec.Profile, "an omitted profile must not be rewritten")
}

func TestAIPlatformWebhook_SwitchToCPUOnlyRejected(t *testing.T) {
	v := &AIPlatformCustomValidator{}
	for _, old := range []aiv1.AIPlatformProfile{"", "full", "fullfeature"} {
		_, err := v.ValidateUpdate(context.Background(), profilePlatform(old), profilePlatform(aiv1.AIPlatformProfileCPUOnly))
		require.Error(t, err, "old profile %q", old)
		assert.Contains(t, err.Error(), "spec.profile")
	}
}

func TestAIPlatformWebhook_EquivalentProfilesAreNotAChange(t *testing.T) {
	v := &AIPlatformCustomValidator{}
	_, err := v.ValidateUpdate(context.Background(), profilePlatform(""), profilePlatform("fullfeature"))
	assert.NoError(t, err)
	_, err = v.ValidateUpdate(context.Background(), profilePlatform("cpuOnly"), profilePlatform("cpuOnly"))
	assert.NoError(t, err)
}

// The AIPlatform CRs the installer renders for the checked-in profile examples
// (tools/ai-tier-cluster-setup/testdata/profile) must pass the operator's own
// admission rules, so installer output and operator validation cannot drift.
func TestAIPlatformWebhook_InstallerGoldenCRsAreAdmitted(t *testing.T) {
	cases := map[string]aiv1.AIPlatformProfile{
		"cpuonly":     aiv1.AIPlatformProfileCPUOnly,
		"fullfeature": aiv1.AIPlatformProfileFullFeature,
	}
	for name, want := range cases {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join("..", "..", "..", "tools", "ai-tier-cluster-setup", "testdata", "profile",
				"aiplatform-cr-"+name+".expected.yaml")
			raw, err := os.ReadFile(path)
			require.NoError(t, err)
			var p aiv1.AIPlatform
			require.NoError(t, yaml.UnmarshalStrict(raw, &p))
			assert.Equal(t, want, p.Spec.Profile)

			require.NoError(t, (&AIPlatformCustomDefaulter{}).Default(context.Background(), &p))
			_, err = (&AIPlatformCustomValidator{}).ValidateCreate(context.Background(), &p)
			assert.NoError(t, err)
		})
	}
}

// crdDefaulted applies the CRD's own structural defaulting (what the API server
// does before the mutating webhook runs) to a raw object.
func crdDefaulted(t *testing.T, raw []byte) aiv1.AIPlatform {
	t.Helper()
	crdBytes, err := os.ReadFile(filepath.Join("..", "..", "..", "config", "crd", "bases", "ai.splunk.com_aiplatforms.yaml"))
	require.NoError(t, err)
	var crd apiextensionsv1.CustomResourceDefinition
	require.NoError(t, yaml.UnmarshalStrict(crdBytes, &crd))
	var v1schema *apiextensionsv1.JSONSchemaProps
	for _, v := range crd.Spec.Versions {
		if v.Name == "v1" {
			v1schema = v.Schema.OpenAPIV3Schema
		}
	}
	require.NotNil(t, v1schema)
	var internal apiextensions.JSONSchemaProps
	require.NoError(t, apiextensionsv1.Convert_v1_JSONSchemaProps_To_apiextensions_JSONSchemaProps(v1schema, &internal, nil))
	structural, err := structuralschema.NewStructural(&internal)
	require.NoError(t, err)

	var obj map[string]interface{}
	require.NoError(t, yaml.Unmarshal(raw, &obj))
	structuraldefaulting.Default(obj, structural)
	defaultedJSON, err := json.Marshal(obj)
	require.NoError(t, err)
	var p aiv1.AIPlatform
	require.NoError(t, json.Unmarshal(defaultedJSON, &p))
	return p
}

// The golden CRs the installer applies must still be admitted AFTER the API
// server has applied the CRD defaults (sidecars.otel and prometheusOperator
// default to true, vectorDB.size to 50Gi). Without this, a CR that passes the
// webhook test on its own could be rejected by a real cluster.
func TestAIPlatformWebhook_InstallerGoldenCRsAreAdmittedAfterCRDDefaulting(t *testing.T) {
	for _, name := range []string{"cpuonly", "fullfeature"} {
		t.Run(name, func(t *testing.T) {
			raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tools", "ai-tier-cluster-setup", "testdata", "profile",
				"aiplatform-cr-"+name+".expected.yaml"))
			require.NoError(t, err)
			p := crdDefaulted(t, raw)
			require.NoError(t, (&AIPlatformCustomDefaulter{}).Default(context.Background(), &p))
			_, err = (&AIPlatformCustomValidator{}).ValidateCreate(context.Background(), &p)
			assert.NoError(t, err)
		})
	}
}

// Pins the behaviour users hit: once a sidecars object is present, the CRD
// defaults otel and prometheusOperator to true, which cpuOnly rejects. A cpuOnly
// CR must therefore either omit sidecars or set every flag false explicitly.
func TestAIPlatformWebhook_CPUOnlySidecarsDefaultingTrap(t *testing.T) {
	validate := func(spec string) error {
		p := crdDefaulted(t, []byte("apiVersion: ai.splunk.com/v1\nkind: AIPlatform\nmetadata: {name: x}\nspec:\n  profile: cpuOnly\n  objectStorage: {path: s3://b, region: us-west-2}\n"+spec))
		require.NoError(t, (&AIPlatformCustomDefaulter{}).Default(context.Background(), &p))
		_, err := (&AIPlatformCustomValidator{}).ValidateCreate(context.Background(), &p)
		return err
	}
	assert.NoError(t, validate(""), "omitting sidecars entirely is valid")
	assert.NoError(t, validate("  sidecars: {envoy: false, otel: false, prometheusOperator: false}\n"), "explicit false is valid")
	err := validate("  sidecars: {envoy: false}\n")
	require.Error(t, err, "a partial sidecars object picks up the CRD defaults (otel, prometheusOperator = true)")
	assert.Contains(t, err.Error(), "spec.sidecars")
	assert.NoError(t, validate("  storage: {}\n"), "an empty storage object has no vectorDB, so no default size appears")
	err = validate("  storage: {vectorDB: {}}\n")
	require.Error(t, err, "a present vectorDB object picks up the CRD default size")
	assert.Contains(t, err.Error(), "spec.storage.vectorDB")
}

// An invalid new object must not mask the update-only rules: the immutable
// region and the switch to cpuOnly are reported together with the profile
// contradictions.
func TestAIPlatformWebhook_UpdateReportsAllErrorsTogether(t *testing.T) {
	old := profilePlatform("fullfeature")
	updated := profilePlatform(aiv1.AIPlatformProfileCPUOnly)
	updated.Spec.GpuInstanceType = "g6.24xlarge"
	updated.Spec.ObjectStorage.Region = "eu-west-1" // immutable

	_, err := (&AIPlatformCustomValidator{}).ValidateUpdate(context.Background(), old, updated)
	require.Error(t, err)
	for _, want := range []string{"spec.gpuInstanceType", "spec.objectStorage.region", "spec.profile"} {
		assert.Contains(t, err.Error(), want)
	}
}

// Pins the directions an update may take. Switching an existing platform TO
// cpuOnly is rejected (covered above); moving away from cpuOnly is allowed by
// admission (what the reconciler does with it is MPR-229).
func TestAIPlatformWebhook_UpdateDirectionsFromCPUOnly(t *testing.T) {
	v := &AIPlatformCustomValidator{}
	for _, next := range []aiv1.AIPlatformProfile{"", "full", "fullfeature"} {
		_, err := v.ValidateUpdate(context.Background(), profilePlatform("cpuOnly"), profilePlatform(next))
		assert.NoError(t, err, "cpuOnly -> %q", next)
	}
}

func TestAIPlatformWebhook_ProfileMessagesAreGrammatical(t *testing.T) {
	p := profilePlatform(aiv1.AIPlatformProfileCPUOnly)
	p.Spec.DefaultAcceleratorType = "L40S"
	p.Spec.Sidecars.Otel = true
	_, err := (&AIPlatformCustomValidator{}).ValidateCreate(context.Background(), p)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "profile cpuOnly does not support GPU settings")
	assert.Contains(t, err.Error(), "profile cpuOnly does not support sidecars")
	assert.NotContains(t, err.Error(), "settings is not supported")
}
