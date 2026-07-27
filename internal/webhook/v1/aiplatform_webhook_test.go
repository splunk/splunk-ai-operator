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
				errs := validator.validateSplunkConfiguration(splunkConfig, false, fldPath)
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
				errs := validator.validateSplunkConfiguration(splunkConfig, false, fldPath)
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
				errs := validator.validateSplunkConfiguration(splunkConfig, false, fldPath)
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
				errs := validator.validateSplunkConfiguration(splunkConfig, false, fldPath)
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
				errs := validator.validateSplunkConfiguration(splunkConfig, false, fldPath)
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
				errs := validator.validateSplunkConfiguration(splunkConfig, false, fldPath)
				for _, e := range errs {
					Expect(e.Field).NotTo(ContainSubstring("vaultFilePath"))
				}
			})

			It("should accept an empty Splunk config (Splunk disabled)", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, fldPath)
				Expect(errs).To(BeEmpty(), "empty Splunk config must be admitted (Splunk optional)")
			})

			It("should still require secretRef when endpoint is set (partial config)", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:     "http://splunk:8088",
					SecretSource: aiv1.SecretSourceKubernetes,
				}
				errs := validator.validateSplunkConfiguration(splunkConfig, false, fldPath)
				e := findErr(errs, "secretRef")
				Expect(e).NotTo(BeNil(), "endpoint without secretRef must still error")
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
