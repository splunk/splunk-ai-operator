/*
Copyright 2024.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1

import (
	"encoding/json"
	"reflect"

	"k8s.io/apimachinery/pkg/util/validation/field"
)

// AIPlatformProfile is the AI Tier deployment profile selected through
// spec.profile (installer key: aiPlatform.profile).
type AIPlatformProfile string

const (
	// AIPlatformProfileCPUOnly runs the AI Tier without any local GPU-hosted
	// model workload. Models and tools are reached over a customer-provided
	// BYO LLM endpoint and Splunk MCP.
	AIPlatformProfileCPUOnly AIPlatformProfile = "cpuOnly"

	// AIPlatformProfileFullFeature is the canonical name of the profile that
	// also runs supplied hosted-model workloads on GPU capacity.
	AIPlatformProfileFullFeature AIPlatformProfile = "fullfeature"

	// AIPlatformProfileLegacyFull is the pre-existing spelling of
	// fullfeature. It is accepted for compatibility and always resolves to
	// AIPlatformProfileFullFeature. New documentation must not use it.
	AIPlatformProfileLegacyFull AIPlatformProfile = "full"
)

// SupportedAIPlatformProfiles lists the accepted values of spec.profile in
// the order they are presented in error messages. The empty string (omitted)
// is also accepted and resolves to fullfeature.
var SupportedAIPlatformProfiles = []string{
	string(AIPlatformProfileCPUOnly),
	string(AIPlatformProfileFullFeature),
	string(AIPlatformProfileLegacyFull),
}

// Resolve returns the canonical profile for p. An omitted value and the
// legacy value "full" resolve to fullfeature. Any other value is returned
// unchanged so the caller can reject it; it is never converted to another
// profile.
func (p AIPlatformProfile) Resolve() AIPlatformProfile {
	switch p {
	case "", AIPlatformProfileLegacyFull:
		return AIPlatformProfileFullFeature
	default:
		return p
	}
}

// IsValid reports whether p is an accepted spec.profile value.
func (p AIPlatformProfile) IsValid() bool {
	switch p {
	case "", AIPlatformProfileCPUOnly, AIPlatformProfileFullFeature, AIPlatformProfileLegacyFull:
		return true
	}
	return false
}

// ResolvedProfile returns the canonical profile for the platform: cpuOnly or
// fullfeature for valid specs.
func (s *AIPlatformSpec) ResolvedProfile() AIPlatformProfile {
	return s.Profile.Resolve()
}

// ValidateProfile checks spec.profile and rejects settings that contradict the
// selected profile. It returns field-specific, non-secret errors and never
// rewrites the spec: a partial profile is not silently converted into the
// other profile. The admission webhook and the operator's reconcile both call
// it so a CR applied without the webhook gets the same answer.
func (s *AIPlatformSpec) ValidateProfile(specPath *field.Path) field.ErrorList {
	profilePath := specPath.Child("profile")
	if !s.Profile.IsValid() {
		return field.ErrorList{field.NotSupported(profilePath, string(s.Profile), SupportedAIPlatformProfiles)}
	}
	if s.ResolvedProfile() != AIPlatformProfileCPUOnly {
		return nil
	}

	var errs field.ErrorList
	unsupported := func(what string) string { return "profile cpuOnly does not support " + what }
	for i, feature := range s.Features {
		if feature.Name == "saia" || feature.Name == "seca" {
			errs = append(errs, field.Forbidden(specPath.Child("features").Index(i).Child("name"),
				unsupported("feature "+feature.Name)+"; remove it or set profile: fullfeature"))
		}
	}
	if s.GpuInstanceType != "" {
		errs = append(errs, field.Forbidden(specPath.Child("gpuInstanceType"), unsupported("GPU settings")))
	}
	if s.DefaultAcceleratorType != "" {
		errs = append(errs, field.Forbidden(specPath.Child("defaultAcceleratorType"), unsupported("GPU settings")))
	}
	if s.GPUSchedulingSpec != nil {
		errs = append(errs, field.Forbidden(specPath.Child("gpuScheduler"), unsupported("GPU scheduling")))
	}
	if s.WorkerGroupConfig != nil {
		errs = append(errs, field.Forbidden(specPath.Child("workerGroupConfig"), unsupported("Ray worker groups")))
	}
	if s.ScaleFactor != nil && *s.ScaleFactor > 1 {
		errs = append(errs, field.Forbidden(specPath.Child("scaleFactor"),
			"scaleFactor above 1 multiplies GPU capacity, which profile cpuOnly does not use"))
	}
	for _, img := range []struct{ name, value string }{
		{"rayHeadGroupImage", s.Images.RayHeadGroupImage},
		{"rayWorkerGroupImage", s.Images.RayWorkerGroupImage},
		{"weaviateImage", s.Images.WeaviateImage},
		{"saiaImage", s.Images.SAIAImage},
	} {
		if img.value != "" {
			errs = append(errs, field.Forbidden(specPath.Child("images").Child(img.name), unsupported("Ray, Weaviate and SAIA image overrides")))
		}
	}
	v := s.Storage.VectorDB
	if v.Size != "" || v.PVCName != "" || v.StorageClassName != "" {
		errs = append(errs, field.Forbidden(specPath.Child("storage").Child("vectorDB"),
			unsupported("vectorDB storage")+"; omit the vectorDB object (the CRD defaults vectorDB.size to 50Gi whenever the object is present)"))
	}
	if s.Ingress != nil && s.Ingress.Enabled {
		errs = append(errs, field.Forbidden(specPath.Child("ingress"), unsupported("Ray-backed ingress")))
	}
	if s.Sidecars.Envoy || s.Sidecars.Otel || s.Sidecars.PrometheusOperator {
		errs = append(errs, field.Forbidden(specPath.Child("sidecars"),
			unsupported("sidecars")+"; omit sidecars or set envoy, otel and prometheusOperator to false (the CRD defaults otel and prometheusOperator to true whenever the object is present)"))
	}
	return errs
}

// MarshalJSON leaves empty storage and sidecars objects out of a cpuOnly spec.
//
// Storage and Sidecars are value-typed, so encoding/json always writes them,
// even when empty. The mutating webhook returns the re-marshalled object as a
// JSON patch, which materializes "storage: {vectorDB: {}}" and "sidecars: {}".
// The API server then applies the CRD defaults to those new objects
// (vectorDB.size 50Gi, sidecars.otel and prometheusOperator true) and
// ValidateProfile rejects the result, so no cpuOnly CR could ever be admitted
// (reproduced against a real API server). An absent parent object receives no
// nested defaults, so omitting the empty ones keeps a cpuOnly spec valid.
//
// Every other profile marshals exactly as before: the legacy behaviour of
// materializing those objects, and the defaults they pick up, is unchanged.
func (s AIPlatformSpec) MarshalJSON() ([]byte, error) {
	type plain AIPlatformSpec // no methods, so no recursion
	out := struct {
		plain
		Storage  *StorageSpec `json:"storage,omitempty"`
		Sidecars *SidecarSpec `json:"sidecars,omitempty"`
	}{plain: plain(s)}

	omitEmpty := s.ResolvedProfile() == AIPlatformProfileCPUOnly
	if !omitEmpty || !reflect.ValueOf(s.Storage).IsZero() {
		out.Storage = &s.Storage
	}
	if !omitEmpty || !reflect.ValueOf(s.Sidecars).IsZero() {
		out.Sidecars = &s.Sidecars
	}
	return json.Marshal(out)
}
