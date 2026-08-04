package v1

import (
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

// TestVaultPathValidation_AIService tests validateSplunkConfigurationForService
// without requiring envtest binaries (pure unit tests).
func TestVaultPathValidation_AIService(t *testing.T) {
	v := AIServiceCustomValidator{}
	fldPath := field.NewPath("spec").Child("splunkConfiguration")

	tests := []struct {
		name         string
		cfg          aiv1.SplunkConfigurationSpec
		wantErrField string // empty string means no error expected on vaultFilePath
		wantErrMsg   string
	}{
		{
			name: "blocked: SA token path (VULN-87311 PoC)",
			cfg: aiv1.SplunkConfigurationSpec{
				Endpoint:      "http://splunk:8088",
				SecretSource:  aiv1.SecretSourceVault,
				VaultFilePath: "/var/run/secrets/kubernetes.io/serviceaccount/token",
			},
			wantErrField: "spec.splunkConfiguration.vaultFilePath",
			wantErrMsg:   "/vault/secrets/",
		},
		{
			name: "blocked: traversal sequence",
			cfg: aiv1.SplunkConfigurationSpec{
				Endpoint:      "http://splunk:8088",
				SecretSource:  aiv1.SecretSourceVault,
				VaultFilePath: "/vault/secrets/../../../etc/passwd",
			},
			wantErrField: "spec.splunkConfiguration.vaultFilePath",
			wantErrMsg:   "..",
		},
		{
			name: "blocked: prefix collision (/vault/secrets-evil/)",
			cfg: aiv1.SplunkConfigurationSpec{
				Endpoint:      "http://splunk:8088",
				SecretSource:  aiv1.SecretSourceVault,
				VaultFilePath: "/vault/secrets-evil/token",
			},
			wantErrField: "spec.splunkConfiguration.vaultFilePath",
			wantErrMsg:   "/vault/secrets/",
		},
		{
			name: "blocked: empty vaultFilePath with vault source",
			cfg: aiv1.SplunkConfigurationSpec{
				Endpoint:      "http://splunk:8088",
				SecretSource:  aiv1.SecretSourceVault,
				VaultFilePath: "",
			},
			wantErrField: "spec.splunkConfiguration.vaultFilePath",
			wantErrMsg:   "required",
		},
		{
			name: "allowed: valid path under /vault/secrets/",
			cfg: aiv1.SplunkConfigurationSpec{
				Endpoint:      "http://splunk:8088",
				SecretRef:     corev1.SecretReference{Name: "s"},
				SecretSource:  aiv1.SecretSourceVault,
				VaultFilePath: "/vault/secrets/splunk-hec",
			},
			wantErrField: "",
		},
		{
			name: "allowed: non-vault source ignores vaultFilePath entirely",
			cfg: aiv1.SplunkConfigurationSpec{
				Endpoint:      "http://splunk:8088",
				SecretRef:     corev1.SecretReference{Name: "s"},
				SecretSource:  aiv1.SecretSourceKubernetes,
				VaultFilePath: "/etc/passwd",
			},
			wantErrField: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			errs := v.validateSplunkConfigurationForService(&tc.cfg, fldPath)

			if tc.wantErrField == "" {
				for _, e := range errs {
					if e.Field == "spec.splunkConfiguration.vaultFilePath" {
						t.Errorf("unexpected vaultFilePath error: %v", e)
					}
				}
				return
			}

			var found *field.Error
			for _, e := range errs {
				if e.Field == tc.wantErrField {
					found = e
					break
				}
			}
			if found == nil {
				t.Fatalf("expected error on field %q, got errors: %v", tc.wantErrField, errs)
			}
			if tc.wantErrMsg != "" {
				if !contains(found.Detail, tc.wantErrMsg) && !contains(found.Error(), tc.wantErrMsg) {
					t.Errorf("expected error to contain %q, got: %v", tc.wantErrMsg, found)
				}
			}
		})
	}
}

// TestVaultPathValidation_AIPlatform mirrors the same cases for AIPlatform's webhook.
func TestVaultPathValidation_AIPlatform(t *testing.T) {
	v := AIPlatformCustomValidator{}
	fldPath := field.NewPath("spec").Child("splunkConfiguration")

	tests := []struct {
		name         string
		cfg          aiv1.SplunkConfigurationSpec
		wantErrField string
		wantErrMsg   string
	}{
		{
			name: "blocked: SA token path (VULN-87311 scope expansion)",
			cfg: aiv1.SplunkConfigurationSpec{
				Endpoint:      "http://splunk:8088",
				SecretSource:  aiv1.SecretSourceVault,
				VaultFilePath: "/var/run/secrets/kubernetes.io/serviceaccount/token",
			},
			wantErrField: "spec.splunkConfiguration.vaultFilePath",
			wantErrMsg:   "/vault/secrets/",
		},
		{
			name: "blocked: traversal sequence",
			cfg: aiv1.SplunkConfigurationSpec{
				Endpoint:      "http://splunk:8088",
				SecretSource:  aiv1.SecretSourceVault,
				VaultFilePath: "/vault/secrets/../../../etc/passwd",
			},
			wantErrField: "spec.splunkConfiguration.vaultFilePath",
			wantErrMsg:   "..",
		},
		{
			name: "blocked: empty vaultFilePath with vault source",
			cfg: aiv1.SplunkConfigurationSpec{
				Endpoint:      "http://splunk:8088",
				SecretSource:  aiv1.SecretSourceVault,
				VaultFilePath: "",
			},
			wantErrField: "spec.splunkConfiguration.vaultFilePath",
			wantErrMsg:   "required",
		},
		{
			name: "allowed: valid path under /vault/secrets/",
			cfg: aiv1.SplunkConfigurationSpec{
				Endpoint:      "http://splunk:8088",
				SecretRef:     corev1.SecretReference{Name: "s"},
				SecretSource:  aiv1.SecretSourceVault,
				VaultFilePath: "/vault/secrets/splunk-hec",
			},
			wantErrField: "",
		},
		{
			name: "allowed: non-vault source skips vaultFilePath check",
			cfg: aiv1.SplunkConfigurationSpec{
				Endpoint:      "http://splunk:8088",
				SecretRef:     corev1.SecretReference{Name: "s"},
				SecretSource:  aiv1.SecretSourceKubernetes,
				VaultFilePath: "/etc/passwd",
			},
			wantErrField: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			errs := v.validateSplunkConfiguration(&tc.cfg, false, fldPath)

			if tc.wantErrField == "" {
				for _, e := range errs {
					if e.Field == "spec.splunkConfiguration.vaultFilePath" {
						t.Errorf("unexpected vaultFilePath error: %v", e)
					}
				}
				return
			}

			var found *field.Error
			for _, e := range errs {
				if e.Field == tc.wantErrField {
					found = e
					break
				}
			}
			if found == nil {
				t.Fatalf("expected error on field %q, got errors: %v", tc.wantErrField, errs)
			}
			if tc.wantErrMsg != "" {
				if !contains(found.Detail, tc.wantErrMsg) && !contains(found.Error(), tc.wantErrMsg) {
					t.Errorf("expected error to contain %q, got: %v", tc.wantErrMsg, found)
				}
			}
		})
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(substr) == 0 ||
		func() bool {
			for i := 0; i <= len(s)-len(substr); i++ {
				if s[i:i+len(substr)] == substr {
					return true
				}
			}
			return false
		}())
}
