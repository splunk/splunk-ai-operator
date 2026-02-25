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
	"strings"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
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
var aiservicelog = logf.Log.WithName("aiservice-resource")

// SetupAIServiceWebhookWithManager registers the webhook for AIService in the manager.
func SetupAIServiceWebhookWithManager(mgr ctrl.Manager) error {
	return ctrl.NewWebhookManagedBy(mgr).For(&aiv1.AIService{}).
		WithValidator(&AIServiceCustomValidator{}).
		WithDefaulter(&AIServiceCustomDefaulter{}).
		Complete()
}

// TODO(user): EDIT THIS FILE!  THIS IS SCAFFOLDING FOR YOU TO OWN!

// +kubebuilder:webhook:path=/mutate-ai-splunk-com-v1-aiservice,mutating=true,failurePolicy=fail,sideEffects=None,groups=ai.splunk.com,resources=aiservices,verbs=create;update,versions=v1,name=maiservice-v1.kb.io,admissionReviewVersions=v1

// AIServiceCustomDefaulter struct is responsible for setting default values on the custom resource of the
// Kind AIService when those are created or updated.
//
// NOTE: The +kubebuilder:object:generate=false marker prevents controller-gen from generating DeepCopy methods,
// as it is used only for temporary operations and does not need to be deeply copied.
type AIServiceCustomDefaulter struct {
	Client client.Client
}

var _ webhook.CustomDefaulter = &AIServiceCustomDefaulter{}

// Default implements webhook.CustomDefaulter so a webhook will be registered for the Kind AIService.
func (d *AIServiceCustomDefaulter) Default(_ context.Context, obj runtime.Object) error {
	aiservice, ok := obj.(*aiv1.AIService)

	if !ok {
		return fmt.Errorf("expected an AIService object but got %T", obj)
	}
	aiservicelog.Info("Defaulting for AIService", "name", aiservice.GetName())

	// Clean ServiceTemplate metadata FIRST to prevent "unknown field" warnings
	cleanServiceTemplateMetadata(&aiservice.Spec.ServiceTemplate)

	// Default ClusterDomain
	if aiservice.Spec.ClusterDomain == "" {
		aiservice.Spec.ClusterDomain = "cluster.local"
	}

	// Default Port
	if aiservice.Spec.Port == 0 {
		aiservice.Spec.Port = 80
	}

	// Default Replicas
	if aiservice.Spec.Replicas == 0 {
		aiservice.Spec.Replicas = 1
	}

	// Default Metrics path
	if aiservice.Spec.Metrics.Enabled && aiservice.Spec.Metrics.Path == "" {
		aiservice.Spec.Metrics.Path = "/metrics"
	}

	// Default Metrics port
	if aiservice.Spec.Metrics.Enabled && aiservice.Spec.Metrics.Port == 0 {
		aiservice.Spec.Metrics.Port = 9090
	}

	// Default MTLS termination
	if aiservice.Spec.MTLS.Enabled && aiservice.Spec.MTLS.Termination == "" {
		aiservice.Spec.MTLS.Termination = "operator"
	}

	aiservicelog.Info("Defaulting complete for AIService", "name", aiservice.GetName())
	return nil
}

// TODO(user): change verbs to "verbs=create;update;delete" if you want to enable deletion validation.
// NOTE: The 'path' attribute must follow a specific pattern and should not be modified directly here.
// Modifying the path for an invalid path can cause API server errors; failing to locate the webhook.
// +kubebuilder:webhook:path=/validate-ai-splunk-com-v1-aiservice,mutating=false,failurePolicy=fail,sideEffects=None,groups=ai.splunk.com,resources=aiservices,verbs=create;update,versions=v1,name=vaiservice-v1.kb.io,admissionReviewVersions=v1

// AIServiceCustomValidator struct is responsible for validating the AIService resource
// when it is created, updated, or deleted.
//
// NOTE: The +kubebuilder:object:generate=false marker prevents controller-gen from generating DeepCopy methods,
// as this struct is used only for temporary operations and does not need to be deeply copied.
type AIServiceCustomValidator struct {
	Client client.Client
}

var _ webhook.CustomValidator = &AIServiceCustomValidator{}

// ValidateCreate implements webhook.CustomValidator so a webhook will be registered for the type AIService.
func (v *AIServiceCustomValidator) ValidateCreate(ctx context.Context, obj runtime.Object) (admission.Warnings, error) {
	aiservice, ok := obj.(*aiv1.AIService)
	if !ok {
		return nil, fmt.Errorf("expected a AIService object but got %T", obj)
	}
	aiservicelog.Info("Validation for AIService upon creation", "name", aiservice.GetName())

	var allErrs field.ErrorList
	var warnings admission.Warnings

	// Validate AIPlatformRef is required
	if aiservice.Spec.AIPlatformRef.Name == "" {
		allErrs = append(allErrs, field.Required(
			field.NewPath("spec").Child("aiPlatformRef").Child("name"),
			"aiPlatformRef.name must be specified",
		))
	}

	// Validate VectorDbUrl is required
	if aiservice.Spec.VectorDbUrl == "" {
		allErrs = append(allErrs, field.Required(
			field.NewPath("spec").Child("vectorDbUrl"),
			"vectorDbUrl must be specified",
		))
	} else {
		// TODO: Temporarily disabled - allow service names without http:// prefix
		// This validation was preventing valid Kubernetes service names from being used
		// We may want to add smarter validation later that distinguishes between URLs and service names
		/*
			if !strings.HasPrefix(aiservice.Spec.VectorDbUrl, "http://") && !strings.HasPrefix(aiservice.Spec.VectorDbUrl, "https://") {
				allErrs = append(allErrs, field.Invalid(
					field.NewPath("spec").Child("vectorDbUrl"),
					aiservice.Spec.VectorDbUrl,
					"vectorDbUrl must start with http:// or https://",
				))
			}
		*/
	}

	// Validate TaskVolume
	if errs := v.validateTaskVolume(&aiservice.Spec.TaskVolume, field.NewPath("spec").Child("taskVolume")); len(errs) > 0 {
		allErrs = append(allErrs, errs...)
	}

	// Validate SplunkConfiguration
	if errs := v.validateSplunkConfigurationForService(&aiservice.Spec.SplunkConfiguration, field.NewPath("spec").Child("splunkConfiguration")); len(errs) > 0 {
		allErrs = append(allErrs, errs...)
	}

	// Validate Replicas
	if aiservice.Spec.Replicas < 0 {
		allErrs = append(allErrs, field.Invalid(
			field.NewPath("spec").Child("replicas"),
			aiservice.Spec.Replicas,
			"replicas must be non-negative",
		))
	}

	// Validate Port
	if aiservice.Spec.Port < 1 || aiservice.Spec.Port > 65535 {
		allErrs = append(allErrs, field.Invalid(
			field.NewPath("spec").Child("port"),
			aiservice.Spec.Port,
			"port must be between 1 and 65535",
		))
	}

	// Validate MTLS
	if errs := v.validateMTLSForService(&aiservice.Spec.MTLS, field.NewPath("spec").Child("mtls")); len(errs) > 0 {
		allErrs = append(allErrs, errs...)
	}

	// Validate Metrics
	if errs := v.validateMetrics(&aiservice.Spec.Metrics, field.NewPath("spec").Child("metrics")); len(errs) > 0 {
		allErrs = append(allErrs, errs...)
	}

	if len(allErrs) > 0 {
		return warnings, allErrs.ToAggregate()
	}

	return warnings, nil
}

// ValidateUpdate implements webhook.CustomValidator so a webhook will be registered for the type AIService.
func (v *AIServiceCustomValidator) ValidateUpdate(ctx context.Context, oldObj, newObj runtime.Object) (admission.Warnings, error) {
	aiservice, ok := newObj.(*aiv1.AIService)
	if !ok {
		return nil, fmt.Errorf("expected a AIService object for the newObj but got %T", newObj)
	}
	aiservicelog.Info("Validation for AIService upon update", "name", aiservice.GetName())

	oldService, ok := oldObj.(*aiv1.AIService)
	if !ok {
		return nil, fmt.Errorf("expected a AIService object for the oldObj but got %T", oldObj)
	}

	var allErrs field.ErrorList
	var warnings admission.Warnings

	// Run the same validations as create
	if createWarnings, err := v.ValidateCreate(ctx, newObj); err != nil {
		return createWarnings, err
	} else {
		warnings = append(warnings, createWarnings...)
	}

	// Validate immutable fields
	if oldService.Spec.AIPlatformRef.Name != aiservice.Spec.AIPlatformRef.Name {
		allErrs = append(allErrs, field.Forbidden(
			field.NewPath("spec").Child("aiPlatformRef").Child("name"),
			"aiPlatformRef.name is immutable",
		))
	}

	if oldService.Spec.TaskVolume.Path != aiservice.Spec.TaskVolume.Path {
		allErrs = append(allErrs, field.Forbidden(
			field.NewPath("spec").Child("taskVolume").Child("path"),
			"taskVolume.path is immutable",
		))
	}

	if len(allErrs) > 0 {
		return warnings, allErrs.ToAggregate()
	}

	return warnings, nil
}

// ValidateDelete implements webhook.CustomValidator so a webhook will be registered for the type AIService.
func (v *AIServiceCustomValidator) ValidateDelete(ctx context.Context, obj runtime.Object) (admission.Warnings, error) {
	aiservice, ok := obj.(*aiv1.AIService)
	if !ok {
		return nil, fmt.Errorf("expected a AIService object but got %T", obj)
	}
	aiservicelog.Info("Validation for AIService upon deletion", "name", aiservice.GetName())

	// No validation needed on deletion
	return nil, nil
}

// validateTaskVolume validates the TaskVolume configuration
func (v *AIServiceCustomValidator) validateTaskVolume(taskVolume *aiv1.ObjectStorageSpec, fldPath *field.Path) field.ErrorList {
	var allErrs field.ErrorList

	// Path is required
	if taskVolume.Path == "" {
		allErrs = append(allErrs, field.Required(fldPath.Child("path"), "taskVolume.path must be specified"))
	} else {
		// Validate path format
		/*
			validPrefixes := []string{"s3://", "gs://", "azure://", "s3compat://", "minio://", "seaweedfs://"}
			hasValidPrefix := false
			for _, prefix := range validPrefixes {
				if strings.HasPrefix(taskVolume.Path, prefix) {
					hasValidPrefix = true
					break
				}
			}
			if !hasValidPrefix {
				allErrs = append(allErrs, field.Invalid(
					fldPath.Child("path"),
					taskVolume.Path,
					"path must start with s3://, gs://, azure://, s3compat://, minio://, or seaweedfs://",
				))
			}
		*/
	}

	// Region is required for AWS S3
	//if strings.HasPrefix(taskVolume.Path, "s3://") && taskVolume.Region == "" {
	//	allErrs = append(allErrs, field.Required(fldPath.Child("region"), "region is required for S3 storage"))
	//}

	return allErrs
}

// validateSplunkConfigurationForService validates the Splunk configuration for AIService
func (v *AIServiceCustomValidator) validateSplunkConfigurationForService(splunkConfig *aiv1.SplunkConfigurationSpec, fldPath *field.Path) field.ErrorList {
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

	// If using secret, validate SecretRef is set
	if hasEndpoint && splunkConfig.SecretRef.Name == "" {
		allErrs = append(allErrs, field.Required(
			fldPath.Child("secretRef").Child("name"),
			"secretRef.name is required when using endpoint",
		))
	}

	return allErrs
}

// validateMTLSForService validates the MTLS configuration for AIService
func (v *AIServiceCustomValidator) validateMTLSForService(mtls *aiv1.MTLSConfig, fldPath *field.Path) field.ErrorList {
	var allErrs field.ErrorList

	if mtls.Enabled {
		// Validate termination type
		if mtls.Termination != "" && mtls.Termination != "operator" && mtls.Termination != "mesh" {
			allErrs = append(allErrs, field.NotSupported(
				fldPath.Child("termination"),
				mtls.Termination,
				[]string{"operator", "mesh"},
			))
		}

		// If using operator termination, need IssuerRef
		if mtls.Termination == "operator" || mtls.Termination == "" {
			if mtls.IssuerRef.Name == "" {
				allErrs = append(allErrs, field.Required(
					fldPath.Child("issuerRef").Child("name"),
					"issuerRef.name must be specified when MTLS is enabled with operator termination",
				))
			}
		}

		// Validate DNSNames if specified
		if len(mtls.DNSNames) == 0 {
			allErrs = append(allErrs, field.Required(
				fldPath.Child("dnsNames"),
				"at least one DNS name must be specified when MTLS is enabled",
			))
		}
	}

	return allErrs
}

// validateMetrics validates the Metrics configuration
func (v *AIServiceCustomValidator) validateMetrics(metrics *aiv1.MetricsConfig, fldPath *field.Path) field.ErrorList {
	var allErrs field.ErrorList

	if metrics.Enabled {
		// Validate port range
		if metrics.Port < 1 || metrics.Port > 65535 {
			allErrs = append(allErrs, field.Invalid(
				fldPath.Child("port"),
				metrics.Port,
				"metrics port must be between 1 and 65535",
			))
		}

		// Validate path starts with /
		if metrics.Path != "" && !strings.HasPrefix(metrics.Path, "/") {
			allErrs = append(allErrs, field.Invalid(
				fldPath.Child("path"),
				metrics.Path,
				"metrics path must start with /",
			))
		}
	}

	return allErrs
}

// cleanServiceTemplateMetadata removes server-generated metadata fields from ServiceTemplate
// to prevent "unknown field" warnings during validation
func cleanServiceTemplateMetadata(template *corev1.Service) {
	if template == nil {
		return
	}

	// Clear server-generated metadata fields
	template.ObjectMeta.CreationTimestamp = metav1.Time{}
	template.ObjectMeta.DeletionTimestamp = nil
	template.ObjectMeta.DeletionGracePeriodSeconds = nil
	template.ObjectMeta.UID = ""
	template.ObjectMeta.ResourceVersion = ""
	template.ObjectMeta.Generation = 0
	template.ObjectMeta.SelfLink = ""
	template.ObjectMeta.ManagedFields = nil

	// Clear status - it's not used in templates
	template.Status = corev1.ServiceStatus{}
}
