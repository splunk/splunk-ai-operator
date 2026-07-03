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
	"fmt"
	"path/filepath"
	"strings"

	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/validation/field"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/webhook"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
)

// nolint:unused
// log is for logging in this package.
var aiplatformlog = logf.Log.WithName("aiplatform-resource")

// SetupAIPlatformWebhookWithManager registers the webhook for AIPlatform in the manager.
func SetupAIPlatformWebhookWithManager(mgr ctrl.Manager) error {
	return ctrl.NewWebhookManagedBy(mgr).For(&aiv1.AIPlatform{}).
		WithValidator(&AIPlatformCustomValidator{}).
		WithDefaulter(&AIPlatformCustomDefaulter{}).
		Complete()
}

// TODO(user): EDIT THIS FILE!  THIS IS SCAFFOLDING FOR YOU TO OWN!

// +kubebuilder:webhook:path=/mutate-ai-splunk-com-v1-aiplatform,mutating=true,failurePolicy=fail,sideEffects=None,groups=ai.splunk.com,resources=aiplatforms,verbs=create;update,versions=v1,name=maiplatform-v1.kb.io,admissionReviewVersions=v1

// AIPlatformCustomDefaulter struct is responsible for setting default values on the custom resource of the
// Kind AIPlatform when those are created or updated.
//
// NOTE: The +kubebuilder:object:generate=false marker prevents controller-gen from generating DeepCopy methods,
// as it is used only for temporary operations and does not need to be deeply copied.
type AIPlatformCustomDefaulter struct {
	Client client.Client
}

var _ webhook.CustomDefaulter = &AIPlatformCustomDefaulter{}

// Default implements webhook.CustomDefaulter so a webhook will be registered for the Kind AIPlatform.
func (d *AIPlatformCustomDefaulter) Default(_ context.Context, obj runtime.Object) error {
	aiplatform, ok := obj.(*aiv1.AIPlatform)

	if !ok {
		return fmt.Errorf("expected an AIPlatform object but got %T", obj)
	}
	aiplatformlog.Info("Defaulting for AIPlatform", "name", aiplatform.GetName())

	// Note: RayService spec cleaning is done in raybuilder since it's constructed dynamically

	// Default ClusterDomain
	if aiplatform.Spec.ClusterDomain == "" {
		aiplatform.Spec.ClusterDomain = "cluster.local"
	}

	// Default Sidecars - removed automatic defaulting to true
	// Users must explicitly enable sidecars in their configuration
	// This allows users to disable sidecars by setting them to false

	// Default Storage size for VectorDB if not specified
	if aiplatform.Spec.Storage.VectorDB.Size == "" && aiplatform.Spec.Storage.VectorDB.PVCName == "" {
		aiplatform.Spec.Storage.VectorDB.Size = "50Gi"
	}

	// Default Ingress settings if enabled
	if aiplatform.Spec.Ingress != nil && aiplatform.Spec.Ingress.Enabled {
		if aiplatform.Spec.Ingress.ClassName == "" {
			aiplatform.Spec.Ingress.ClassName = "nginx"
		}
	}

	// Default MTLS termination if enabled
	if aiplatform.Spec.MTLS.Enabled && aiplatform.Spec.MTLS.Termination == "" {
		aiplatform.Spec.MTLS.Termination = "operator"
	}

	// Default OTelImage if not specified
	if aiplatform.Spec.Images.OTelImage == "" {
		aiplatform.Spec.Images.OTelImage = "otel/opentelemetry-collector-contrib:0.122.1"
	}

	aiplatformlog.Info("Defaulting complete for AIPlatform", "name", aiplatform.GetName())
	return nil
}

// TODO(user): change verbs to "verbs=create;update;delete" if you want to enable deletion validation.
// NOTE: The 'path' attribute must follow a specific pattern and should not be modified directly here.
// Modifying the path for an invalid path can cause API server errors; failing to locate the webhook.
// +kubebuilder:webhook:path=/validate-ai-splunk-com-v1-aiplatform,mutating=false,failurePolicy=fail,sideEffects=None,groups=ai.splunk.com,resources=aiplatforms,verbs=create;update,versions=v1,name=vaiplatform-v1.kb.io,admissionReviewVersions=v1

// AIPlatformCustomValidator struct is responsible for validating the AIPlatform resource
// when it is created, updated, or deleted.
//
// NOTE: The +kubebuilder:object:generate=false marker prevents controller-gen from generating DeepCopy methods,
// as this struct is used only for temporary operations and does not need to be deeply copied.
type AIPlatformCustomValidator struct {
	Client client.Client
}

var _ webhook.CustomValidator = &AIPlatformCustomValidator{}

// ValidateCreate implements webhook.CustomValidator so a webhook will be registered for the type AIPlatform.
func (v *AIPlatformCustomValidator) ValidateCreate(ctx context.Context, obj runtime.Object) (admission.Warnings, error) {
	aiplatform, ok := obj.(*aiv1.AIPlatform)
	if !ok {
		return nil, fmt.Errorf("expected a AIPlatform object but got %T", obj)
	}
	aiplatformlog.Info("Validation for AIPlatform upon creation", "name", aiplatform.GetName())

	var allErrs field.ErrorList
	var warnings admission.Warnings

	// Validate ObjectStorage
	if errs := v.validateObjectStorage(&aiplatform.Spec.ObjectStorage, field.NewPath("spec").Child("objectStorage")); len(errs) > 0 {
		allErrs = append(allErrs, errs...)
	}

	// Validate SplunkConfiguration
	if errs := v.validateSplunkConfiguration(&aiplatform.Spec.SplunkConfiguration, field.NewPath("spec").Child("splunkConfiguration")); len(errs) > 0 {
		allErrs = append(allErrs, errs...)
	}

	// Validate Storage
	if errs := v.validateStorage(&aiplatform.Spec.Storage, field.NewPath("spec").Child("storage")); len(errs) > 0 {
		allErrs = append(allErrs, errs...)
	}

	// Validate Ingress
	if aiplatform.Spec.Ingress != nil {
		if errs := v.validateIngress(aiplatform.Spec.Ingress, field.NewPath("spec").Child("ingress")); len(errs) > 0 {
			allErrs = append(allErrs, errs...)
		}
	}

	// Validate MTLS
	if errs := v.validateMTLS(&aiplatform.Spec.MTLS, aiplatform.Spec.CertificateRef, field.NewPath("spec")); len(errs) > 0 {
		allErrs = append(allErrs, errs...)
	}

	// Validate Features
	if errs := v.validateFeatures(aiplatform.Spec.Features, field.NewPath("spec").Child("features")); len(errs) > 0 {
		allErrs = append(allErrs, errs...)
	}

	if len(allErrs) > 0 {
		return warnings, allErrs.ToAggregate()
	}

	return warnings, nil
}

// ValidateUpdate implements webhook.CustomValidator so a webhook will be registered for the type AIPlatform.
func (v *AIPlatformCustomValidator) ValidateUpdate(ctx context.Context, oldObj, newObj runtime.Object) (admission.Warnings, error) {
	aiplatform, ok := newObj.(*aiv1.AIPlatform)
	if !ok {
		return nil, fmt.Errorf("expected a AIPlatform object for the newObj but got %T", newObj)
	}
	aiplatformlog.Info("Validation for AIPlatform upon update", "name", aiplatform.GetName())

	oldPlatform, ok := oldObj.(*aiv1.AIPlatform)
	if !ok {
		return nil, fmt.Errorf("expected a AIPlatform object for the oldObj but got %T", oldObj)
	}

	var allErrs field.ErrorList
	var warnings admission.Warnings

	// Run the same validations as create
	if createWarnings, err := v.ValidateCreate(ctx, newObj); err != nil {
		return createWarnings, err
	} else {
		warnings = append(warnings, createWarnings...)
	}

	// Validate immutable fields (path is mutable to allow switching storage backends, e.g. MinIO to SeaweedFS)
	if oldPlatform.Spec.ObjectStorage.Region != aiplatform.Spec.ObjectStorage.Region {
		allErrs = append(allErrs, field.Forbidden(
			field.NewPath("spec").Child("objectStorage").Child("region"),
			"objectStorage.region is immutable",
		))
	}

	if len(allErrs) > 0 {
		return warnings, allErrs.ToAggregate()
	}

	return warnings, nil
}

// ValidateDelete implements webhook.CustomValidator so a webhook will be registered for the type AIPlatform.
func (v *AIPlatformCustomValidator) ValidateDelete(ctx context.Context, obj runtime.Object) (admission.Warnings, error) {
	aiplatform, ok := obj.(*aiv1.AIPlatform)
	if !ok {
		return nil, fmt.Errorf("expected a AIPlatform object but got %T", obj)
	}
	aiplatformlog.Info("Validation for AIPlatform upon deletion", "name", aiplatform.GetName())

	// No validation needed on deletion
	return nil, nil
}

// validateObjectStorage validates the ObjectStorage configuration
func (v *AIPlatformCustomValidator) validateObjectStorage(objStorage *aiv1.ObjectStorageSpec, fldPath *field.Path) field.ErrorList {
	var allErrs field.ErrorList

	// Path is required
	if objStorage.Path == "" {
		allErrs = append(allErrs, field.Required(fldPath.Child("path"), "objectStorage.path must be specified"))
	} else {
		// Validate path format (s3://, gs://, azure://, s3compat://, minio://, seaweedfs://)
		validPrefixes := []string{"s3://", "gs://", "azure://", "s3compat://", "minio://", "seaweedfs://"}
		hasValidPrefix := false
		for _, prefix := range validPrefixes {
			if strings.HasPrefix(objStorage.Path, prefix) {
				hasValidPrefix = true
				break
			}
		}
		if !hasValidPrefix {
			allErrs = append(allErrs, field.Invalid(
				fldPath.Child("path"),
				objStorage.Path,
				"path must start with s3://, gs://, azure://, s3compat://, minio://, or seaweedfs://",
			))
		}
	}

	// Region is required for AWS S3
	if strings.HasPrefix(objStorage.Path, "s3://") && objStorage.Region == "" {
		allErrs = append(allErrs, field.Required(fldPath.Child("region"), "region is required for S3 storage"))
	}

	return allErrs
}

// validateSplunkConfiguration validates the Splunk configuration
func (v *AIPlatformCustomValidator) validateSplunkConfiguration(splunkConfig *aiv1.SplunkConfigurationSpec, fldPath *field.Path) field.ErrorList {
	var allErrs field.ErrorList

	// Must have either Endpoint or SplunkCustomResourceRef
	hasEndpoint := splunkConfig.Endpoint != ""
	hasCRRef := splunkConfig.SplunkCustomResourceRef.Name != ""

	if !hasEndpoint && !hasCRRef {
		allErrs = append(allErrs, field.Required(
			fldPath,
			"SplunkConfiguration must have either Endpoint or SplunkCustomResourceRef set",
		))
	}

	// TODO: Temporarily disabled - allow service names without http:// prefix
	// This validation was preventing valid Kubernetes service names from being used
	// We may want to add smarter validation later that distinguishes between URLs and service names
	/*
		if hasEndpoint && !strings.HasPrefix(splunkConfig.Endpoint, "http://") && !strings.HasPrefix(splunkConfig.Endpoint, "https://") {
			allErrs = append(allErrs, field.Invalid(
				fldPath.Child("endpoint"),
				splunkConfig.Endpoint,
				"endpoint must start with http:// or https://",
			))
		}
	*/

	// Vault source supplies its token via a file; it does not use a k8s SecretRef.
	// All other sources require SecretRef when an explicit endpoint is set.
	if splunkConfig.SecretSource != aiv1.SecretSourceVault {
		if hasEndpoint && splunkConfig.SecretRef.Name == "" {
			allErrs = append(allErrs, field.Required(
				fldPath.Child("secretRef").Child("name"),
				"secretRef.name is required when using endpoint",
			))
		}
	}

	// Guard against path traversal: vaultFilePath must be under /vault/secrets/.
	// The admission webhook cannot call EvalSymlinks (the file need not exist yet),
	// so we explicitly reject ".." components before filepath.Clean can erase them,
	// then verify the cleaned path stays within the allowed root.
	if splunkConfig.SecretSource == aiv1.SecretSourceVault {
		if splunkConfig.VaultFilePath == "" {
			allErrs = append(allErrs, field.Required(
				fldPath.Child("vaultFilePath"),
				"vaultFilePath is required when secretSource is vault",
			))
		} else {
			hasTraversal := false
			for _, component := range strings.Split(splunkConfig.VaultFilePath, "/") {
				if component == ".." {
					hasTraversal = true
					break
				}
			}
			if hasTraversal {
				allErrs = append(allErrs, field.Invalid(
					fldPath.Child("vaultFilePath"),
					splunkConfig.VaultFilePath,
					"vaultFilePath must be under /vault/secrets/ and must not contain '..'",
				))
			} else {
				cleaned := filepath.Clean(splunkConfig.VaultFilePath)
				if !strings.HasPrefix(cleaned, "/vault/secrets/") {
					allErrs = append(allErrs, field.Invalid(
						fldPath.Child("vaultFilePath"),
						splunkConfig.VaultFilePath,
						"vaultFilePath must be under /vault/secrets/",
					))
				}
			}
		}
	}

	return allErrs
}

// validateStorage validates the Storage configuration
func (v *AIPlatformCustomValidator) validateStorage(storage *aiv1.StorageSpec, fldPath *field.Path) field.ErrorList {
	var allErrs field.ErrorList

	// Validate VectorDB storage
	if storage.VectorDB.Size != "" {
		// Validate size is a valid quantity
		if _, err := resource.ParseQuantity(storage.VectorDB.Size); err != nil {
			allErrs = append(allErrs, field.Invalid(
				fldPath.Child("vectorDB").Child("size"),
				storage.VectorDB.Size,
				fmt.Sprintf("invalid size format: %v", err),
			))
		}
	}

	// Can't specify both PVCName and Size
	if storage.VectorDB.PVCName != "" && storage.VectorDB.Size != "" {
		allErrs = append(allErrs, field.Forbidden(
			fldPath.Child("vectorDB"),
			"cannot specify both pvcName and size, choose one",
		))
	}

	return allErrs
}

// validateIngress validates the Ingress configuration
func (v *AIPlatformCustomValidator) validateIngress(ingress *aiv1.IngressSpec, fldPath *field.Path) field.ErrorList {
	var allErrs field.ErrorList

	if ingress.Enabled {
		// Validate hosts are specified
		if len(ingress.Hosts) == 0 {
			allErrs = append(allErrs, field.Required(
				fldPath.Child("hosts"),
				"at least one host must be specified when ingress is enabled",
			))
		}

		// Validate each host
		for i, host := range ingress.Hosts {
			hostPath := fldPath.Child("hosts").Index(i)
			if host.Host == "" {
				allErrs = append(allErrs, field.Required(
					hostPath.Child("host"),
					"host must be specified",
				))
			}

			// Validate paths
			if len(host.Paths) == 0 {
				allErrs = append(allErrs, field.Required(
					hostPath.Child("paths"),
					"at least one path must be specified",
				))
			}

			for j, path := range host.Paths {
				pathPath := hostPath.Child("paths").Index(j)
				if path.Path == "" {
					allErrs = append(allErrs, field.Required(
						pathPath.Child("path"),
						"path must be specified",
					))
				}
				// Validate pathType
				validPathTypes := []string{"Prefix", "Exact", "ImplementationSpecific"}
				isValidPathType := false
				for _, validType := range validPathTypes {
					if path.PathType == validType {
						isValidPathType = true
						break
					}
				}
				if !isValidPathType {
					allErrs = append(allErrs, field.NotSupported(
						pathPath.Child("pathType"),
						path.PathType,
						validPathTypes,
					))
				}
			}
		}

		// Validate TLS configuration if specified
		for i, tls := range ingress.TLS {
			tlsPath := fldPath.Child("tls").Index(i)
			if len(tls.Hosts) == 0 {
				allErrs = append(allErrs, field.Required(
					tlsPath.Child("hosts"),
					"at least one host must be specified for TLS",
				))
			}
			if tls.SecretName == "" {
				allErrs = append(allErrs, field.Required(
					tlsPath.Child("secretName"),
					"secretName must be specified for TLS",
				))
			}
		}
	}

	return allErrs
}

// validateMTLS validates the MTLS configuration
func (v *AIPlatformCustomValidator) validateMTLS(mtls *aiv1.MTLSConfig, certificateRef string, fldPath *field.Path) field.ErrorList {
	var allErrs field.ErrorList

	if mtls.Enabled {
		// Validate termination type
		if mtls.Termination != "" && mtls.Termination != "operator" && mtls.Termination != "mesh" {
			allErrs = append(allErrs, field.NotSupported(
				fldPath.Child("mtls").Child("termination"),
				mtls.Termination,
				[]string{"operator", "mesh"},
			))
		}

		// If using operator termination, need either IssuerRef or certificateRef
		if mtls.Termination == "operator" || mtls.Termination == "" {
			hasIssuerRef := mtls.IssuerRef.Name != ""
			hasCertRef := certificateRef != ""

			if !hasIssuerRef && !hasCertRef {
				allErrs = append(allErrs, field.Required(
					fldPath.Child("mtls"),
					"either mtls.issuerRef or certificateRef must be specified when MTLS is enabled with operator termination",
				))
			}
		}
	}

	return allErrs
}

// validateFeatures validates the Features configuration
func (v *AIPlatformCustomValidator) validateFeatures(features []aiv1.FeatureSpec, fldPath *field.Path) field.ErrorList {
	var allErrs field.ErrorList

	featureNames := make(map[string]bool)

	for i, feature := range features {
		featurePath := fldPath.Index(i)

		// Validate feature name is specified
		if feature.Name == "" {
			allErrs = append(allErrs, field.Required(
				featurePath.Child("name"),
				"feature name must be specified",
			))
		}

		// Check for duplicate feature names
		if featureNames[feature.Name] {
			allErrs = append(allErrs, field.Duplicate(
				featurePath.Child("name"),
				feature.Name,
			))
		}
		featureNames[feature.Name] = true

		// Validate scaleFactor if specified
		if feature.ScaleFactor != nil && *feature.ScaleFactor < 1 {
			allErrs = append(allErrs, field.Invalid(
				featurePath.Child("scaleFactor"),
				*feature.ScaleFactor,
				"scaleFactor must be at least 1",
			))
		}
	}

	return allErrs
}
