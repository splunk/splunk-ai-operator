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
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

var _ = Describe("AIService Webhook", func() {
	var (
		obj       *aiv1.AIService
		oldObj    *aiv1.AIService
		validator AIServiceCustomValidator
		defaulter AIServiceCustomDefaulter
	)

	BeforeEach(func() {
		obj = &aiv1.AIService{}
		oldObj = &aiv1.AIService{}
		validator = AIServiceCustomValidator{}
		Expect(validator).NotTo(BeNil(), "Expected validator to be initialized")
		defaulter = AIServiceCustomDefaulter{}
		Expect(defaulter).NotTo(BeNil(), "Expected defaulter to be initialized")
		Expect(oldObj).NotTo(BeNil(), "Expected oldObj to be initialized")
		Expect(obj).NotTo(BeNil(), "Expected obj to be initialized")
	})

	AfterEach(func() {})

	Context("When creating AIService under Defaulting Webhook", func() {})

	Context("When creating or updating AIService under Validating Webhook", func() {
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
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
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
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
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
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
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
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
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
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
				// The only errors (if any) should NOT be about vaultFilePath
				for _, e := range errs {
					Expect(e.Field).NotTo(ContainSubstring("vaultFilePath"))
				}
			})

			It("should not validate vaultFilePath when secretSource is not vault", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "http://splunk:8088",
					SecretRef:     corev1.SecretReference{Name: "my-secret"},
					SecretSource:  aiv1.SecretSourceKubernetes,
					VaultFilePath: "/etc/passwd", // would be invalid if vault source
				}
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
				for _, e := range errs {
					Expect(e.Field).NotTo(ContainSubstring("vaultFilePath"))
				}
			})

			It("should accept an empty Splunk config (Splunk disabled)", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{}
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
				Expect(errs).To(BeEmpty(), "empty Splunk config must be admitted (Splunk optional)")
			})

			It("should accept an issuer endpoint without a HEC secret", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:     "https://splunk:8089",
					SecretSource: aiv1.SecretSourceKubernetes,
				}
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
				Expect(errs).To(BeEmpty())
			})
		})

		Describe("hecEndpoint validation", func() {
			fldPath := field.NewPath("spec").Child("splunkConfiguration")

			for _, withSecret := range []bool{false, true} {
				withSecret := withSecret
				description := " without secretRef"
				if withSecret {
					description = " with secretRef"
				}
				It("should reject hecEndpoint without a management/JWKS source"+description, func() {
					splunkConfig := &aiv1.SplunkConfigurationSpec{
						HECEndpoint: "http://splunk:8088",
					}
					if withSecret {
						splunkConfig.SecretRef.Name = "splunk-hec"
					}

					errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)

					Expect(errs).To(HaveLen(1))
					Expect(errs[0].Field).To(Equal("spec.splunkConfiguration.hecEndpoint"))
					Expect(errs[0].Detail).To(ContainSubstring("endpoint or splunkCustomResourceRef.name"))
				})
			}

			It("should accept hecEndpoint with endpoint and secretRef", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:    "https://splunk:8089",
					HECEndpoint: "https://splunk:8088",
				}
				splunkConfig.SecretRef.Name = "splunk-hec"

				Expect(validator.validateSplunkConfigurationForService(splunkConfig, fldPath)).To(BeEmpty())
			})

			It("should accept hecEndpoint with a Splunk CR reference", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					HECEndpoint: "https://splunk:8088",
				}
				splunkConfig.SplunkCustomResourceRef.Name = "splunk-standalone"

				Expect(validator.validateSplunkConfigurationForService(splunkConfig, fldPath)).To(BeEmpty())
			})
		})
	})
})
