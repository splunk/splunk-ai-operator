package common

import (
	"context"
	"fmt"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

// EnsureServiceControllerReference claims a new Service or preserves ownership
// of an existing one. Call it in the mutation callback after the Service is read.
func EnsureServiceControllerReference(scheme *runtime.Scheme, owner client.Object, service *corev1.Service) error {
	// A controller with the same name can have a different UID after recreation.
	// An existing Service also needs an explicit owner before we change where it routes.
	if service.ResourceVersion != "" && !metav1.IsControlledBy(service, owner) {
		return fmt.Errorf("Service %s/%s is not controlled by %s/%s",
			service.Namespace, service.Name, owner.GetNamespace(), owner.GetName())
	}
	return controllerutil.SetControllerReference(owner, service, scheme)
}

// ServiceAccountOptions describes the feature-owned ServiceAccount to reconcile.
// Labels and annotations are limited to values managed by the caller; unrelated
// metadata already present on an existing ServiceAccount is preserved.
type ServiceAccountOptions struct {
	Name        string
	Labels      map[string]string
	Annotations map[string]string
	// RefuseUnowned applies the MPR-202 ownership rule (see ClaimOrRefuse): an
	// existing ServiceAccount the owner does not control is never adopted; it is an
	// OwnershipConflictError. Without it, the earlier behaviour is kept: an unowned
	// ServiceAccount is adopted, and one another controller owns is refused.
	RefuseUnowned bool
	// CustomerManaged is for a ServiceAccount the user named. It is the customer's,
	// never owned: one that exists is used as it is, and one that does not exist is
	// created without an owner reference, so it is never deleted with the owner. If
	// the owner controls it (an earlier build created or adopted it), that owner
	// reference is removed. Labels and annotations are not applied.
	CustomerManaged bool
}

// ReconcileServiceAccount creates or updates a feature-owned ServiceAccount. For
// RefuseUnowned and CustomerManaged, see those options.
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
	if opts.CustomerManaged {
		result, err := ensureCustomerServiceAccount(ctx, c, owner, sa)
		if err != nil {
			return result, fmt.Errorf("reconcile ServiceAccount %q: %w", opts.Name, err)
		}
		return result, nil
	}

	result, err := controllerutil.CreateOrUpdate(ctx, c, sa, func() error {
		if err := claim(owner, sa, scheme, opts.RefuseUnowned); err != nil {
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

// ensureCustomerServiceAccount makes a user-named ServiceAccount exist without ever
// owning it (see ServiceAccountOptions.CustomerManaged).
func ensureCustomerServiceAccount(ctx context.Context, c client.Client, owner client.Object, sa *corev1.ServiceAccount) (controllerutil.OperationResult, error) {
	err := c.Get(ctx, client.ObjectKeyFromObject(sa), sa)
	if apierrors.IsNotFound(err) {
		if err := c.Create(ctx, sa); err != nil {
			if apierrors.IsAlreadyExists(err) {
				return controllerutil.OperationResultNone, nil // the customer created it meanwhile
			}
			return controllerutil.OperationResultNone, err
		}
		return controllerutil.OperationResultCreated, nil
	}
	if err != nil {
		return controllerutil.OperationResultNone, err
	}
	refs := sa.GetOwnerReferences()
	kept := refs[:0:0]
	for _, ref := range refs {
		if ref.UID != owner.GetUID() {
			kept = append(kept, ref)
		}
	}
	if len(kept) == len(refs) {
		return controllerutil.OperationResultNone, nil
	}
	patch := client.MergeFromWithOptions(sa.DeepCopy(), client.MergeFromWithOptimisticLock{})
	sa.SetOwnerReferences(kept)
	if err := c.Patch(ctx, sa, patch); err != nil {
		return controllerutil.OperationResultNone, err
	}
	return controllerutil.OperationResultUpdated, nil
}

// CertificateOptions describes a feature-owned cert-manager Certificate.
// Spec is copied in full so callers can preserve all cert-manager fields they
// support instead of reducing the shared helper to a feature-specific subset.
type CertificateOptions struct {
	Name string
	Spec certmanagerv1.CertificateSpec
	// RefuseUnowned applies the MPR-202 ownership rule, as for ServiceAccountOptions.
	RefuseUnowned bool
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
		if err := claim(owner, cert, scheme, opts.RefuseUnowned); err != nil {
			return err
		}
		desired := opts.Spec.DeepCopy()
		PreserveCertificateIssuerDefaults(desired, &cert.Spec)
		cert.Spec = *desired
		return nil
	})
	if err != nil {
		return cert, result, fmt.Errorf("reconcile Certificate %q: %w", opts.Name, err)
	}
	return cert, result, nil
}

// PreserveCertificateIssuerDefaults keeps issuer defaults persisted by newer
// cert-manager webhooks. Older versions can leave the same fields unset.
func PreserveCertificateIssuerDefaults(desired, current *certmanagerv1.CertificateSpec) {
	preserveDefault(&desired.IssuerRef.Kind, current.IssuerRef.Kind, "Issuer")
	preserveDefault(&desired.IssuerRef.Group, current.IssuerRef.Group, certmanagerv1.SchemeGroupVersion.Group)
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

// claim sets owner as obj's controller inside a mutate function. With refuseUnowned
// it is ClaimOrRefuse; without, it is the earlier behaviour, which adopts an unowned
// object and refuses one another controller owns.
func claim(owner, obj client.Object, scheme *runtime.Scheme, refuseUnowned bool) error {
	if refuseUnowned {
		return ClaimOrRefuse(owner, obj, scheme)
	}
	return controllerutil.SetControllerReference(owner, obj, scheme)
}
