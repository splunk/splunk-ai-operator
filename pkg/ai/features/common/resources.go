package common

import (
	"context"
	"fmt"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

// ServiceAccountOptions describes the feature-owned ServiceAccount to reconcile.
// Labels and annotations are limited to values managed by the caller; unrelated
// metadata already present on an existing ServiceAccount is preserved.
type ServiceAccountOptions struct {
	Name        string
	Labels      map[string]string
	Annotations map[string]string
}

// ReconcileServiceAccount creates or updates a feature-owned ServiceAccount.
// Ownership is applied in the mutation callback so an existing object with a
// different controller is rejected instead of being silently adopted.
func ReconcileServiceAccount(
	ctx context.Context,
	c client.Client,
	scheme *runtime.Scheme,
	owner client.Object,
	opts ServiceAccountOptions,
) (controllerutil.OperationResult, error) {
	if opts.Name == "" {
		return "", fmt.Errorf("ServiceAccount name must be set")
	}

	sa := &corev1.ServiceAccount{}
	sa.Name = opts.Name
	sa.Namespace = owner.GetNamespace()

	result, err := controllerutil.CreateOrUpdate(ctx, c, sa, func() error {
		if err := controllerutil.SetControllerReference(owner, sa, scheme); err != nil {
			return err
		}
		mergeMetadata(sa, opts.Labels, opts.Annotations)
		return nil
	})
	if err != nil {
		return result, fmt.Errorf("reconcile ServiceAccount %q: %w", opts.Name, err)
	}
	return result, nil
}

// CertificateOptions describes a feature-owned cert-manager Certificate.
// Spec is copied in full so callers can preserve all cert-manager fields they
// support instead of reducing the shared helper to a feature-specific subset.
type CertificateOptions struct {
	Name string
	Spec certmanagerv1.CertificateSpec
}

// ReconcileCertificate creates or updates a feature-owned Certificate.
// The returned object contains the current status, allowing callers to apply
// feature-specific readiness policy after the shared reconciliation completes.
func ReconcileCertificate(
	ctx context.Context,
	c client.Client,
	scheme *runtime.Scheme,
	owner client.Object,
	opts CertificateOptions,
) (*certmanagerv1.Certificate, controllerutil.OperationResult, error) {
	if opts.Name == "" {
		return nil, "", fmt.Errorf("Certificate name must be set")
	}

	cert := &certmanagerv1.Certificate{}
	cert.Name = opts.Name
	cert.Namespace = owner.GetNamespace()

	result, err := controllerutil.CreateOrUpdate(ctx, c, cert, func() error {
		if err := controllerutil.SetControllerReference(owner, cert, scheme); err != nil {
			return err
		}
		cert.Spec = *opts.Spec.DeepCopy()
		return nil
	})
	if err != nil {
		return cert, result, fmt.Errorf("reconcile Certificate %q: %w", opts.Name, err)
	}
	return cert, result, nil
}

func mergeMetadata(obj client.Object, labels, annotations map[string]string) {
	if len(labels) > 0 {
		if obj.GetLabels() == nil {
			obj.SetLabels(map[string]string{})
		}
		merged := obj.GetLabels()
		for key, value := range labels {
			merged[key] = value
		}
	}
	if len(annotations) > 0 {
		if obj.GetAnnotations() == nil {
			obj.SetAnnotations(map[string]string{})
		}
		merged := obj.GetAnnotations()
		for key, value := range annotations {
			merged[key] = value
		}
	}
}
