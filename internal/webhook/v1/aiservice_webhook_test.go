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

			It("should reject secretSource=vault with no vaultFilePath", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:     "http://splunk:8088",
					SecretSource: aiv1.SecretSourceVault,
					VaultFilePath: "",
				}
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
				Expect(errs).NotTo(BeEmpty())
				Expect(errs[0].Field).To(ContainSubstring("vaultFilePath"))
				Expect(errs[0].Detail).To(ContainSubstring("required"))
			})

			It("should reject vaultFilePath pointing at the SA token (VULN-87311 PoC path)", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "http://splunk:8088",
					SecretSource:  aiv1.SecretSourceVault,
					VaultFilePath: "/var/run/secrets/kubernetes.io/serviceaccount/token",
				}
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
				Expect(errs).NotTo(BeEmpty())
				Expect(errs[0].Field).To(ContainSubstring("vaultFilePath"))
				Expect(errs[0].Detail).To(ContainSubstring("/vault/secrets/"))
			})

			It("should reject vaultFilePath with traversal sequence", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "http://splunk:8088",
					SecretSource:  aiv1.SecretSourceVault,
					VaultFilePath: "/vault/secrets/../../../etc/passwd",
				}
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
				Expect(errs).NotTo(BeEmpty())
				Expect(errs[0].Detail).To(ContainSubstring("/vault/secrets/"))
			})

			It("should reject path that starts with /vault/secrets but is not under it", func() {
				splunkConfig := &aiv1.SplunkConfigurationSpec{
					Endpoint:      "http://splunk:8088",
					SecretSource:  aiv1.SecretSourceVault,
					VaultFilePath: "/vault/secrets-evil/token",
				}
				errs := validator.validateSplunkConfigurationForService(splunkConfig, fldPath)
				Expect(errs).NotTo(BeEmpty())
				Expect(errs[0].Detail).To(ContainSubstring("/vault/secrets/"))
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
		})
	})
})
