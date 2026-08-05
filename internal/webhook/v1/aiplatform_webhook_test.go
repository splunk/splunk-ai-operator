/*
Copyright 2025.

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
	"context"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

var _ = Describe("AIPlatform Webhook", func() {
	var (
		obj       *aiv1.AIPlatform
		oldObj    *aiv1.AIPlatform
		validator AIPlatformCustomValidator
		defaulter AIPlatformCustomDefaulter
	)

	BeforeEach(func() {
		obj = &aiv1.AIPlatform{}
		oldObj = &aiv1.AIPlatform{}
		validator = AIPlatformCustomValidator{}
		Expect(validator).NotTo(BeNil(), "Expected validator to be initialized")
		defaulter = AIPlatformCustomDefaulter{}
		Expect(defaulter).NotTo(BeNil(), "Expected defaulter to be initialized")
		Expect(oldObj).NotTo(BeNil(), "Expected oldObj to be initialized")
		Expect(obj).NotTo(BeNil(), "Expected obj to be initialized")
	})

	AfterEach(func() {})

	Context("When creating AIPlatform under Defaulting Webhook", func() {})

	Context("When creating or updating AIPlatform under Validating Webhook", func() {
		Describe("legacy endpoint-only OTel updates", func() {
			legacyPlatform := func() *aiv1.AIPlatform {
				return &aiv1.AIPlatform{
					Spec: aiv1.AIPlatformSpec{
						ObjectStorage: aiv1.ObjectStorageSpec{Path: "minio://ai-platform-bucket"},
						Sidecars:      aiv1.SidecarSpec{Otel: true},
						SplunkConfiguration: aiv1.SplunkConfigurationSpec{
							Endpoint:  "https://splunk.example.test:8089",
							SecretRef: corev1.SecretReference{Name: "splunk-secret"},
						},
					},
				}
			}

			It("rejects the endpoint-only shape on create", func() {
				_, err := validator.ValidateCreate(context.Background(), legacyPlatform())
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("hecEndpoint"))
			})

			It("allows an unrelated update to an already-admitted legacy object", func() {
				oldPlatform := legacyPlatform()
				newPlatform := oldPlatform.DeepCopy()
				one := int32(1)
				newPlatform.Spec.ScaleFactor = &one

				warnings, err := validator.ValidateUpdate(context.Background(), oldPlatform, newPlatform)
				Expect(err).NotTo(HaveOccurred())
				Expect(warnings).To(ContainElement(ContainSubstring("legacy OTel configuration")))
			})

			It("requires hecEndpoint when OTel is newly enabled", func() {
				oldPlatform := legacyPlatform()
				oldPlatform.Spec.Sidecars.Otel = false
				newPlatform := oldPlatform.DeepCopy()
				newPlatform.Spec.Sidecars.Otel = true

				_, err := validator.ValidateUpdate(context.Background(), oldPlatform, newPlatform)
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("hecEndpoint"))
			})

			It("requires hecEndpoint when the legacy Splunk configuration changes", func() {
				oldPlatform := legacyPlatform()
				newPlatform := oldPlatform.DeepCopy()
				newPlatform.Spec.SplunkConfiguration.Endpoint = "https://new-splunk.example.test:8089"

				_, err := validator.ValidateUpdate(context.Background(), oldPlatform, newPlatform)
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("hecEndpoint"))
			})
		})

		// --- vaultFilePath security tests (VULN-87311) ---

		Describe("vaultFilePath validation", func() {
			fldPath := field.NewPath("spec").Child("splunkConfiguration")

			// findErr returns the first field.Error whose Field contains substr.
			findErr := func(errs field.ErrorList, fieldSubstr string) *field.Error {
				for _, e := range errs {
					if strings.Contains(e.Field, fieldSubstr) {
						return e
					}
				}
				return nil
			}

			It("should reject secretSource=vault with no vaultFilePath", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "http://splunk:8088",
					SecretSource:  aiv1.SecretSourceVault,
					VaultFilePath: "",
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "vaultFilePath")
				Expect(e).NotTo(BeNil(), "expected a vaultFilePath error")
				Expect(e.Detail).To(ContainSubstring("required"))
			})

			It("should reject vaultFilePath pointing at the SA token (VULN-87311 PoC path)", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "http://splunk:8088",
					SecretSource:  aiv1.SecretSourceVault,
					VaultFilePath: "/var/run/secrets/kubernetes.io/serviceaccount/token",
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "vaultFilePath")
				Expect(e).NotTo(BeNil(), "expected a vaultFilePath error")
				Expect(e.Detail).To(ContainSubstring("/vault/secrets/"))
			})

			It("should reject vaultFilePath with traversal sequence", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "http://splunk:8088",
					SecretSource:  aiv1.SecretSourceVault,
					VaultFilePath: "/vault/secrets/../../../etc/passwd",
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "vaultFilePath")
				Expect(e).NotTo(BeNil(), "expected a vaultFilePath error")
				Expect(e.Detail).To(ContainSubstring(".."))
			})

			It("should reject path that starts with /vault/secrets but is not under it", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "http://splunk:8088",
					SecretSource:  aiv1.SecretSourceVault,
					VaultFilePath: "/vault/secrets-evil/token",
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "vaultFilePath")
				Expect(e).NotTo(BeNil(), "expected a vaultFilePath error")
				Expect(e.Detail).To(ContainSubstring("/vault/secrets/"))
			})

			It("should accept a valid vaultFilePath under /vault/secrets/", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "http://splunk:8088",
					SecretRef:     corev1.SecretReference{Name: "my-secret"},
					SecretSource:  aiv1.SecretSourceVault,
					VaultFilePath: "/vault/secrets/splunk-hec-token",
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				for _, e := range errs {
					Expect(e.Field).NotTo(ContainSubstring("vaultFilePath"))
				}
			})

			It("should not validate vaultFilePath when secretSource is not vault", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "http://splunk:8088",
					SecretRef:     corev1.SecretReference{Name: "my-secret"},
					SecretSource:  aiv1.SecretSourceKubernetes,
					VaultFilePath: "/etc/passwd",
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				for _, e := range errs {
					Expect(e.Field).NotTo(ContainSubstring("vaultFilePath"))
				}
			})

			It("should accept an empty Splunk config (Splunk disabled)", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				Expect(errs).To(BeEmpty(), "empty Splunk config must be admitted (Splunk optional)")
			})

			It("should accept an empty Splunk config when the global OTel toggle is enabled", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{}
				errs := validator.validateSplunkConfiguration(splunkConfig, true, "default", fldPath)
				Expect(errs).To(BeEmpty(), "OTel must gracefully skip a platform with no Splunk telemetry config")
			})

			It("should require an explicit hecEndpoint when OTel and Splunk telemetry are enabled", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:  "https://splunk.example.test:8089",
					SecretRef: corev1.SecretReference{Name: "splunk-secret"},
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, true, "default", fldPath)
				e := findErr(errs, "hecEndpoint")
				Expect(e).NotTo(BeNil(), "the management endpoint must not be reused as the HEC endpoint")
				Expect(e.Detail).To(ContainSubstring("not used as a fallback"))
			})

			It("should accept an explicit hecEndpoint when OTel and Splunk telemetry are enabled", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:    "https://splunk.example.test:8089",
					HECEndpoint: "https://splunk.example.test:8088",
					SecretRef:   corev1.SecretReference{Name: "splunk-secret"},
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, true, "default", fldPath)
				e := findErr(errs, "hecEndpoint")
				Expect(e).To(BeNil(), "an explicit HEC endpoint must be admitted")
			})

			It("should require a Kubernetes secretRef for an HEC-only OTel configuration", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					HECEndpoint: "https://splunk.example.test:8088",
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, true, "default", fldPath)
				e := findErr(errs, "secretRef")
				Expect(e).NotTo(BeNil(), "the OTel collector always loads its HEC token from a Kubernetes Secret")
				Expect(e.Detail).To(ContainSubstring("sidecars.otel"))
			})

			It("should require a Kubernetes secretRef when OTel uses a Splunk custom resource", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					HECEndpoint: "https://splunk.example.test:8088",
					SplunkCustomResourceRef: corev1.ObjectReference{
						Name: "splunk-standalone",
					},
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, true, "default", fldPath)
				e := findErr(errs, "secretRef")
				Expect(e).NotTo(BeNil(), "a custom-resource reference does not remove OTel's Secret dependency")
			})

			It("should allow vault-only credentials when OTel is disabled", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "https://splunk.example.test:8089",
					SecretSource:  aiv1.SecretSourceVault,
					VaultFilePath: "/vault/secrets/splunk-hec-token",
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "secretRef")
				Expect(e).To(BeNil(), "vault-only credentials remain supported when OTel is disabled")
			})

			It("should reject vault-only credentials when OTel is enabled", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "https://splunk.example.test:8089",
					HECEndpoint:   "https://splunk.example.test:8088",
					SecretSource:  aiv1.SecretSourceVault,
					VaultFilePath: "/vault/secrets/splunk-hec-token",
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, true, "default", fldPath)
				e := findErr(errs, "secretRef")
				Expect(e).NotTo(BeNil(), "the OTel collector cannot consume vault-only credentials")
				Expect(e.Detail).To(ContainSubstring("vault-only"))
			})

			It("should still require secretRef when endpoint is set (partial config)", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:     "http://splunk:8088",
					SecretSource: aiv1.SecretSourceKubernetes,
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "secretRef")
				Expect(e).NotTo(BeNil(), "endpoint without secretRef must still error")
			})
		})

		Describe("caCertRef.namespace validation (AIP-4614 Tier 1)", func() {
			fldPath := field.NewPath("spec").Child("splunkConfiguration")

			findErr := func(errs field.ErrorList, fieldSubstr string) *field.Error {
				for _, e := range errs {
					if strings.Contains(e.Field, fieldSubstr) {
						return e
					}
				}
				return nil
			}

			It("should reject a caCertRef.namespace that differs from the AIPlatform's own namespace", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:  "http://splunk:8088",
					SecretRef: corev1.SecretReference{Name: "my-secret"},
					CACertRef: &aiv1.CABundleRef{Name: "splunk-ca", Namespace: "other-namespace"},
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "caCertRef")
				Expect(e).NotTo(BeNil(), "cross-namespace caCertRef must be rejected")
				Expect(e.Detail).To(ContainSubstring("cross-namespace"))
			})

			It("should reject a cross-namespace caCertRef when it is the only Splunk setting", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					CACertRef: &aiv1.CABundleRef{Name: "splunk-ca", Namespace: "other-namespace"},
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "caCertRef")
				Expect(e).NotTo(BeNil(), "the empty-config fast path must not bypass caCertRef validation")
				Expect(e.Detail).To(ContainSubstring("cross-namespace"))
			})

			It("should reject a cross-namespace caCertRef with trustedIssuers only", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					TrustedIssuers: []string{"https://splunk.example.test:8089"},
					CACertRef:      &aiv1.CABundleRef{Name: "splunk-ca", Namespace: "other-namespace"},
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "caCertRef")
				Expect(e).NotTo(BeNil(), "trustedIssuers must not make the empty-config fast path bypass caCertRef validation")
				Expect(e.Detail).To(ContainSubstring("cross-namespace"))
			})

			It("should accept a caCertRef.namespace that matches the AIPlatform's own namespace", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:  "http://splunk:8088",
					SecretRef: corev1.SecretReference{Name: "my-secret"},
					CACertRef: &aiv1.CABundleRef{Name: "splunk-ca", Namespace: "default"},
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "caCertRef")
				Expect(e).To(BeNil(), "same-namespace caCertRef must be admitted")
			})

			It("should accept an empty caCertRef.namespace (defaults to same namespace)", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:  "http://splunk:8088",
					SecretRef: corev1.SecretReference{Name: "my-secret"},
					CACertRef: &aiv1.CABundleRef{Name: "splunk-ca"},
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "caCertRef")
				Expect(e).To(BeNil(), "unset caCertRef.namespace must be admitted")
			})

			It("should reject a cross-namespace Splunk secretRef", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint: "https://splunk.example.test:8089",
					SecretRef: corev1.SecretReference{
						Name:      "splunk-secret",
						Namespace: "other-namespace",
					},
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, "default", fldPath)
				e := findErr(errs, "secretRef.namespace")
				Expect(e).NotTo(BeNil(), "pod and OTel Secret references cannot cross namespaces")
				Expect(e.Detail).To(ContainSubstring("cannot cross namespaces"))
			})
		})

		Describe("scaleFactor validation", func() {
			sfPath := field.NewPath("spec").Child("scaleFactor")

			It("should reject scaleFactor of 0", func() {
				zero := int32(0)
				errs := validator.validateScaleFactor(&zero, sfPath)
				Expect(errs).NotTo(BeEmpty(), "expected a scaleFactor error")
				Expect(errs[0].Detail).To(ContainSubstring("at least 1"))
			})

			It("should reject a negative scaleFactor", func() {
				neg := int32(-1)
				errs := validator.validateScaleFactor(&neg, sfPath)
				Expect(errs).NotTo(BeEmpty(), "expected a scaleFactor error")
				Expect(errs[0].Detail).To(ContainSubstring("at least 1"))
			})

			It("should accept a scaleFactor of 1", func() {
				one := int32(1)
				errs := validator.validateScaleFactor(&one, sfPath)
				Expect(errs).To(BeEmpty())
			})

			It("should accept an unset scaleFactor (defaults to 1)", func() {
				errs := validator.validateScaleFactor(nil, sfPath)
				Expect(errs).To(BeEmpty())
			})
		})
	})
})
