package v1

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

func i32(v int32) *int32 { return &v }

func TestAIPlatformProfileResolve(t *testing.T) {
	cases := []struct {
		in    AIPlatformProfile
		want  AIPlatformProfile
		valid bool
	}{
		{"", AIPlatformProfileFullFeature, true},
		{AIPlatformProfileLegacyFull, AIPlatformProfileFullFeature, true},
		{AIPlatformProfileFullFeature, AIPlatformProfileFullFeature, true},
		{AIPlatformProfileCPUOnly, AIPlatformProfileCPUOnly, true},
		// An unknown value is never converted into a supported profile.
		{"cpuonly", "cpuonly", false},
		{"gpu", "gpu", false},
	}
	for _, tc := range cases {
		t.Run(string(tc.in), func(t *testing.T) {
			assert.Equal(t, tc.want, tc.in.Resolve())
			assert.Equal(t, tc.valid, tc.in.IsValid())
		})
	}
}

func TestValidateProfileAcceptsSupportedProfiles(t *testing.T) {
	for _, p := range []AIPlatformProfile{"", "full", "fullfeature", "cpuOnly"} {
		s := AIPlatformSpec{Profile: p}
		assert.Empty(t, s.ValidateProfile(field.NewPath("spec")), "profile %q", p)
	}
}

func TestValidateProfileFullfeatureKeepsModelServingSettings(t *testing.T) {
	s := AIPlatformSpec{
		Profile:                AIPlatformProfileFullFeature,
		GpuInstanceType:        "g6.24xlarge",
		DefaultAcceleratorType: "L40S",
		ScaleFactor:            i32(3),
		GPUSchedulingSpec:      &SchedulingSpec{},
		Features:               []FeatureSpec{{Name: "saia"}, {Name: "slim"}},
		Sidecars:               SidecarSpec{Envoy: true},
	}
	assert.Empty(t, s.ValidateProfile(field.NewPath("spec")))
}

func TestValidateProfileRejectsUnknownProfileWithSupportedValues(t *testing.T) {
	s := AIPlatformSpec{Profile: "cpuonly"}
	errs := s.ValidateProfile(field.NewPath("spec"))
	require.Len(t, errs, 1)
	assert.Equal(t, "spec.profile", errs[0].Field)
	assert.Equal(t, field.ErrorTypeNotSupported, errs[0].Type)
	for _, want := range []string{"cpuOnly", "fullfeature"} {
		assert.Contains(t, errs[0].Error(), want)
	}
}

func TestValidateProfileCPUOnlyRejectsContradictions(t *testing.T) {
	enabled := &IngressSpec{Enabled: true}
	cases := map[string]struct {
		mutate func(*AIPlatformSpec)
		field  string
	}{
		"saia feature":  {func(s *AIPlatformSpec) { s.Features = []FeatureSpec{{Name: "saia"}} }, "spec.features[0].name"},
		"seca feature":  {func(s *AIPlatformSpec) { s.Features = []FeatureSpec{{Name: "slim"}, {Name: "seca"}} }, "spec.features[1].name"},
		"gpu instance":  {func(s *AIPlatformSpec) { s.GpuInstanceType = "g6" }, "spec.gpuInstanceType"},
		"accelerator":   {func(s *AIPlatformSpec) { s.DefaultAcceleratorType = "L40S" }, "spec.defaultAcceleratorType"},
		"gpu scheduler": {func(s *AIPlatformSpec) { s.GPUSchedulingSpec = &SchedulingSpec{} }, "spec.gpuScheduler"},
		"worker group":  {func(s *AIPlatformSpec) { s.WorkerGroupConfig = &WorkerGroupConfig{} }, "spec.workerGroupConfig"},
		"scale factor":  {func(s *AIPlatformSpec) { s.ScaleFactor = i32(2) }, "spec.scaleFactor"},
		"ray head":      {func(s *AIPlatformSpec) { s.Images.RayHeadGroupImage = "x" }, "spec.images.rayHeadGroupImage"},
		"ray worker":    {func(s *AIPlatformSpec) { s.Images.RayWorkerGroupImage = "x" }, "spec.images.rayWorkerGroupImage"},
		"weaviate":      {func(s *AIPlatformSpec) { s.Images.WeaviateImage = "x" }, "spec.images.weaviateImage"},
		"saia image":    {func(s *AIPlatformSpec) { s.Images.SAIAImage = "x" }, "spec.images.saiaImage"},
		"vectordb size": {func(s *AIPlatformSpec) { s.Storage.VectorDB.Size = "50Gi" }, "spec.storage.vectorDB"},
		"vectordb pvc":  {func(s *AIPlatformSpec) { s.Storage.VectorDB.PVCName = "pvc" }, "spec.storage.vectorDB"},
		"ingress":       {func(s *AIPlatformSpec) { s.Ingress = enabled }, "spec.ingress"},
		"envoy":         {func(s *AIPlatformSpec) { s.Sidecars.Envoy = true }, "spec.sidecars"},
		"otel":          {func(s *AIPlatformSpec) { s.Sidecars.Otel = true }, "spec.sidecars"},
		"prometheus":    {func(s *AIPlatformSpec) { s.Sidecars.PrometheusOperator = true }, "spec.sidecars"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			s := AIPlatformSpec{Profile: AIPlatformProfileCPUOnly}
			tc.mutate(&s)
			errs := s.ValidateProfile(field.NewPath("spec"))
			require.Len(t, errs, 1)
			assert.Equal(t, tc.field, errs[0].Field)
			assert.Equal(t, field.ErrorTypeForbidden, errs[0].Type)
			assert.Contains(t, errs[0].Detail, "cpuOnly")
		})
	}
}

func TestValidateProfileCPUOnlyAcceptsMinimalSpec(t *testing.T) {
	s := AIPlatformSpec{
		Profile:     AIPlatformProfileCPUOnly,
		ScaleFactor: i32(1), // the CRD default
		Features:    []FeatureSpec{{Name: "slim"}, {Name: "agentruntime", Provider: "launchpad"}},
		Ingress:     &IngressSpec{Enabled: false},
	}
	assert.Empty(t, s.ValidateProfile(field.NewPath("spec")))
}

func TestValidateProfileReportsEveryConflictDeterministically(t *testing.T) {
	build := func() AIPlatformSpec {
		return AIPlatformSpec{
			Profile:         AIPlatformProfileCPUOnly,
			GpuInstanceType: "g6",
			Images:          Images{WeaviateImage: "w", RayHeadGroupImage: "r", SAIAImage: "s"},
			Sidecars:        SidecarSpec{Otel: true},
		}
	}
	a, b := build(), build()
	first := a.ValidateProfile(field.NewPath("spec")).ToAggregate().Error()
	second := b.ValidateProfile(field.NewPath("spec")).ToAggregate().Error()
	assert.Equal(t, first, second)
	// gpuInstanceType, three images and sidecars: every conflict is reported.
	assert.Len(t, a.ValidateProfile(field.NewPath("spec")), 5)
}

func marshalKeys(t *testing.T, spec AIPlatformSpec) map[string]json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(spec)
	require.NoError(t, err)
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(raw, &m))
	return m
}

// The mutating webhook returns the re-marshalled spec as a JSON patch. For
// cpuOnly the empty storage and sidecars objects must not be materialized,
// otherwise the API server's CRD defaults turn them into forbidden settings.
func TestAIPlatformSpecMarshalJSON_CPUOnlyOmitsEmptyStorageAndSidecars(t *testing.T) {
	m := marshalKeys(t, AIPlatformSpec{Profile: AIPlatformProfileCPUOnly})
	assert.NotContains(t, m, "storage")
	assert.NotContains(t, m, "sidecars")
	assert.Contains(t, m, "profile")
}

func TestAIPlatformSpecMarshalJSON_CPUOnlyKeepsNonEmptyValues(t *testing.T) {
	m := marshalKeys(t, AIPlatformSpec{
		Profile:  AIPlatformProfileCPUOnly,
		Sidecars: SidecarSpec{Otel: true},
		Storage:  StorageSpec{VectorDB: VectorDBStorageSpec{Size: "1Gi"}},
	})
	assert.Contains(t, m, "sidecars", "a real setting must still be sent so validation can reject it")
	assert.Contains(t, m, "storage")
}

// Every profile other than cpuOnly marshals exactly as before: empty storage
// and sidecars objects are still written, and keep picking up the CRD defaults.
func TestAIPlatformSpecMarshalJSON_OtherProfilesAreUnchanged(t *testing.T) {
	for _, p := range []AIPlatformProfile{"", AIPlatformProfileLegacyFull, AIPlatformProfileFullFeature} {
		m := marshalKeys(t, AIPlatformSpec{Profile: p})
		assert.Contains(t, m, "storage", "profile %q", p)
		assert.Contains(t, m, "sidecars", "profile %q", p)
		assert.JSONEq(t, `{}`, string(m["sidecars"]), "profile %q", p)
	}
}

func TestAIPlatformSpecMarshalJSON_RoundTrips(t *testing.T) {
	in := AIPlatformSpec{
		Profile:     AIPlatformProfileCPUOnly,
		ScaleFactor: i32(1),
		Features:    []FeatureSpec{{Name: "slim"}},
	}
	raw, err := json.Marshal(in)
	require.NoError(t, err)
	var out AIPlatformSpec
	require.NoError(t, json.Unmarshal(raw, &out))
	assert.Equal(t, in.Profile, out.Profile)
	assert.Equal(t, in.Features, out.Features)
	assert.Equal(t, *in.ScaleFactor, *out.ScaleFactor)
}
