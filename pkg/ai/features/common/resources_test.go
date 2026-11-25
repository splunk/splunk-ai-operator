package common

import (
	"context"
	"testing"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	cmmeta "github.com/cert-manager/cert-manager/pkg/apis/meta/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

func buildResourceTestScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := runtime.NewScheme()
	require.NoError(t, aiv1.AddToScheme(scheme))
	require.NoError(t, corev1.AddToScheme(scheme))
	require.NoError(t, certmanagerv1.AddToScheme(scheme))
	return scheme
}

func newResourceTestOwner(name, uid string) *aiv1.AIService {
	return &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: "default",
			UID:       types.UID(uid),
		},
	}
}

func TestReconcileServiceAccount_CreateAndNoOp(t *testing.T) {
	ctx := context.Background()
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(owner).Build()

	result, err := ReconcileServiceAccount(ctx, fakeClient, scheme, owner, ServiceAccountOptions{
		Name:        "service-sa",
		Labels:      map[string]string{"app": "service"},
		Annotations: map[string]string{"example.com/managed": "true"},
	})
	require.NoError(t, err)
	assert.Equal(t, controllerutil.OperationResultCreated, result)

	sa := &corev1.ServiceAccount{}
	require.NoError(t, fakeClient.Get(ctx, client.ObjectKey{Name: "service-sa", Namespace: "default"}, sa))
	require.Len(t, sa.OwnerReferences, 1)
	assert.Equal(t, types.UID("service-uid"), sa.OwnerReferences[0].UID)
	assert.Equal(t, "service", sa.Labels["app"])
	assert.Equal(t, "true", sa.Annotations["example.com/managed"])

	result, err = ReconcileServiceAccount(ctx, fakeClient, scheme, owner, ServiceAccountOptions{
		Name:        "service-sa",
		Labels:      map[string]string{"app": "service"},
		Annotations: map[string]string{"example.com/managed": "true"},
	})
	require.NoError(t, err)
	assert.Equal(t, controllerutil.OperationResultNone, result)
}

func TestReconcileServiceAccount_UpdatesManagedMetadata(t *testing.T) {
	ctx := context.Background()
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(owner).Build()

	_, err := ReconcileServiceAccount(ctx, fakeClient, scheme, owner, ServiceAccountOptions{Name: "service-sa"})
	require.NoError(t, err)
	_, err = ReconcileServiceAccount(ctx, fakeClient, scheme, owner, ServiceAccountOptions{
		Name:   "service-sa",
		Labels: map[string]string{"app": "updated"},
	})
	require.NoError(t, err)

	sa := &corev1.ServiceAccount{}
	require.NoError(t, fakeClient.Get(ctx, client.ObjectKey{Name: "service-sa", Namespace: "default"}, sa))
	assert.Equal(t, "updated", sa.Labels["app"])
}

func TestReconcileServiceAccount_RejectsConflictingOwner(t *testing.T) {
	ctx := context.Background()
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	otherOwner := newResourceTestOwner("other", "other-uid")
	sa := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: "service-sa", Namespace: "default"}}
	require.NoError(t, controllerutil.SetControllerReference(otherOwner, sa, scheme))
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(owner, otherOwner, sa).Build()

	_, err := ReconcileServiceAccount(ctx, fakeClient, scheme, owner, ServiceAccountOptions{Name: "service-sa"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "already owned")

	stored := &corev1.ServiceAccount{}
	require.NoError(t, fakeClient.Get(ctx, client.ObjectKey{Name: "service-sa", Namespace: "default"}, stored))
	assert.Equal(t, types.UID("other-uid"), stored.OwnerReferences[0].UID)
}

func TestReconcileCertificate_CreateNoOpAndUpdate(t *testing.T) {
	ctx := context.Background()
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(owner).Build()

	opts := CertificateOptions{
		Name: "service-tls",
		Spec: certmanagerv1.CertificateSpec{
			SecretName: "service-tls-secret",
			IssuerRef:  cmmeta.ObjectReference{Name: "issuer", Kind: "ClusterIssuer"},
			DNSNames:   []string{"service.default.svc.cluster.local"},
			Usages:     []certmanagerv1.KeyUsage{certmanagerv1.UsageServerAuth},
		},
	}

	cert, result, err := ReconcileCertificate(ctx, fakeClient, scheme, owner, opts)
	require.NoError(t, err)
	assert.Equal(t, controllerutil.OperationResultCreated, result)
	assert.Equal(t, "service-tls-secret", cert.Spec.SecretName)
	assert.Equal(t, types.UID("service-uid"), cert.OwnerReferences[0].UID)

	_, result, err = ReconcileCertificate(ctx, fakeClient, scheme, owner, opts)
	require.NoError(t, err)
	assert.Equal(t, controllerutil.OperationResultNone, result)

	opts.Spec.IssuerRef.Name = "new-issuer"
	cert, result, err = ReconcileCertificate(ctx, fakeClient, scheme, owner, opts)
	require.NoError(t, err)
	assert.Equal(t, controllerutil.OperationResultUpdated, result)
	assert.Equal(t, "new-issuer", cert.Spec.IssuerRef.Name)
}

func TestReconcileCertificate_RejectsConflictingOwner(t *testing.T) {
	ctx := context.Background()
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	otherOwner := newResourceTestOwner("other", "other-uid")
	cert := &certmanagerv1.Certificate{ObjectMeta: metav1.ObjectMeta{Name: "service-tls", Namespace: "default"}}
	require.NoError(t, controllerutil.SetControllerReference(otherOwner, cert, scheme))
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(owner, otherOwner, cert).Build()

	_, _, err := ReconcileCertificate(ctx, fakeClient, scheme, owner, CertificateOptions{
		Name: "service-tls",
		Spec: certmanagerv1.CertificateSpec{SecretName: "service-tls-secret"},
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "already owned")

	stored := &certmanagerv1.Certificate{}
	require.NoError(t, fakeClient.Get(ctx, client.ObjectKey{Name: "service-tls", Namespace: "default"}, stored))
	assert.Equal(t, types.UID("other-uid"), stored.OwnerReferences[0].UID)
}

func TestReconcileCertificate_KeepsPersistedIssuerDefaults(t *testing.T) {
	ctx := context.Background()
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	opts := CertificateOptions{
		Name: "service-tls",
		Spec: certmanagerv1.CertificateSpec{
			SecretName: "service-tls-secret",
			IssuerRef:  cmmeta.ObjectReference{Name: "issuer"},
		},
	}
	stored := &certmanagerv1.Certificate{
		ObjectMeta: metav1.ObjectMeta{Name: opts.Name, Namespace: owner.Namespace},
		Spec:       *opts.Spec.DeepCopy(),
	}
	stored.Spec.IssuerRef.Kind = "Issuer"
	stored.Spec.IssuerRef.Group = certmanagerv1.SchemeGroupVersion.Group
	require.NoError(t, controllerutil.SetControllerReference(owner, stored, scheme))
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(stored).Build()

	cert, result, err := ReconcileCertificate(ctx, fakeClient, scheme, owner, opts)
	require.NoError(t, err)
	require.Equal(t, controllerutil.OperationResultNone, result)
	assert.Equal(t, stored.Spec.IssuerRef, cert.Spec.IssuerRef)

	unqualifiedIssuer := opts.Spec.IssuerRef
	opts.Spec.IssuerRef = cmmeta.ObjectReference{Name: "external", Kind: "ExternalIssuer", Group: "issuer.example"}
	cert, result, err = ReconcileCertificate(ctx, fakeClient, scheme, owner, opts)
	require.NoError(t, err)
	require.Equal(t, controllerutil.OperationResultUpdated, result)
	assert.Equal(t, opts.Spec.IssuerRef, cert.Spec.IssuerRef)

	opts.Spec.IssuerRef = unqualifiedIssuer
	cert, result, err = ReconcileCertificate(ctx, fakeClient, scheme, owner, opts)
	require.NoError(t, err)
	require.Equal(t, controllerutil.OperationResultUpdated, result)
	assert.Equal(t, unqualifiedIssuer, cert.Spec.IssuerRef)
}

// MPR-202 (RefuseUnowned): an existing object the owner does not control (here, one
// nobody owns, as a customer's would be) is never adopted or changed.
func TestReconcileServiceAccount_NeverAdoptsAnUnownedServiceAccount(t *testing.T) {
	ctx := context.Background()
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	customer := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: "service-sa", Namespace: "default", Labels: map[string]string{"app": "customer"}}}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(owner, customer).Build()

	_, err := ReconcileServiceAccount(ctx, fakeClient, scheme, owner, ServiceAccountOptions{Name: "service-sa", Labels: map[string]string{"app": "operator"}, RefuseUnowned: true})
	var conflict *OwnershipConflictError
	require.ErrorAs(t, err, &conflict)
	assert.Equal(t, OwnershipConflictError{Kind: "ServiceAccount", Namespace: "default", Name: "service-sa"}, *conflict)

	result, err := ReconcileServiceAccount(ctx, fakeClient, scheme, owner, ServiceAccountOptions{Name: "service-sa", Labels: map[string]string{"app": "operator"}, CustomerManaged: true})
	require.NoError(t, err, "a ServiceAccount the user named is used as it is")
	assert.Equal(t, controllerutil.OperationResultNone, result)

	stored := &corev1.ServiceAccount{}
	require.NoError(t, fakeClient.Get(ctx, client.ObjectKey{Name: "service-sa", Namespace: "default"}, stored))
	assert.Empty(t, stored.OwnerReferences, "never adopted")
	assert.Equal(t, "customer", stored.Labels["app"], "never changed")

	// A named ServiceAccount that does not exist is created, and still never owned.
	result, err = ReconcileServiceAccount(ctx, fakeClient, scheme, owner, ServiceAccountOptions{Name: "made-sa", CustomerManaged: true})
	require.NoError(t, err)
	assert.Equal(t, controllerutil.OperationResultCreated, result)
	require.NoError(t, fakeClient.Get(ctx, client.ObjectKey{Name: "made-sa", Namespace: "default"}, stored))
	assert.Empty(t, stored.OwnerReferences)
}

// A user-named ServiceAccount that an earlier build created or adopted carries the
// owner's reference; it is removed, so the ServiceAccount survives the owner. Any other
// owner reference is kept.
func TestReconcileServiceAccount_ReleasesACustomerServiceAccountAnEarlierBuildOwned(t *testing.T) {
	ctx := context.Background()
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	other := newResourceTestOwner("other", "other-uid")
	sa := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: "customer-sa", Namespace: "default"}}
	require.NoError(t, controllerutil.SetControllerReference(owner, sa, scheme))
	require.NoError(t, controllerutil.SetOwnerReference(other, sa, scheme))
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(owner, other, sa).Build()

	result, err := ReconcileServiceAccount(ctx, fakeClient, scheme, owner, ServiceAccountOptions{Name: "customer-sa", CustomerManaged: true})
	require.NoError(t, err)
	assert.Equal(t, controllerutil.OperationResultUpdated, result)
	stored := &corev1.ServiceAccount{}
	require.NoError(t, fakeClient.Get(ctx, client.ObjectKey{Name: "customer-sa", Namespace: "default"}, stored))
	require.Len(t, stored.OwnerReferences, 1)
	assert.Equal(t, types.UID("other-uid"), stored.OwnerReferences[0].UID)

	result, err = ReconcileServiceAccount(ctx, fakeClient, scheme, owner, ServiceAccountOptions{Name: "customer-sa", CustomerManaged: true})
	require.NoError(t, err)
	assert.Equal(t, controllerutil.OperationResultNone, result, "idempotent")
}

func TestReconcileCertificate_NeverAdoptsAnUnownedCertificate(t *testing.T) {
	ctx := context.Background()
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	customer := &certmanagerv1.Certificate{ObjectMeta: metav1.ObjectMeta{Name: "service-tls", Namespace: "default"},
		Spec: certmanagerv1.CertificateSpec{SecretName: "customer-secret"}}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(owner, customer).Build()

	_, _, err := ReconcileCertificate(ctx, fakeClient, scheme, owner, CertificateOptions{Name: "service-tls", Spec: certmanagerv1.CertificateSpec{SecretName: "operator-secret"}, RefuseUnowned: true})
	var conflict *OwnershipConflictError
	require.ErrorAs(t, err, &conflict)
	stored := &certmanagerv1.Certificate{}
	require.NoError(t, fakeClient.Get(ctx, client.ObjectKey{Name: "service-tls", Namespace: "default"}, stored))
	assert.Empty(t, stored.OwnerReferences)
	assert.Equal(t, "customer-secret", stored.Spec.SecretName)
}

func TestClaimOrRefuse(t *testing.T) {
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	fresh := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "c", Namespace: "default"}}
	require.NoError(t, ClaimOrRefuse(owner, fresh, scheme))
	assert.True(t, metav1.IsControlledBy(fresh, owner), "a new object is created owned")

	owned := fresh.DeepCopy()
	owned.ResourceVersion = "7"
	require.NoError(t, ClaimOrRefuse(owner, owned, scheme), "an object it controls is updated")

	// Same name and kind of owner, but a different UID: an earlier AIService's object,
	// which garbage collection removes; it is not taken over meanwhile.
	stale := owned.DeepCopy()
	stale.OwnerReferences[0].UID = "earlier-uid"
	var conflict *OwnershipConflictError
	assert.ErrorAs(t, ClaimOrRefuse(owner, stale, scheme), &conflict)

	unowned := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "c", Namespace: "default", ResourceVersion: "3"}}
	require.ErrorAs(t, ClaimOrRefuse(owner, unowned, scheme), &conflict)
	assert.Contains(t, conflict.Error(), "ConfigMap default/c already exists and is not managed by this AIService")
	assert.Empty(t, unowned.OwnerReferences, "refusing leaves the object as it was")
}

// CustomerManaged never hides an API failure.
func TestReconcileServiceAccount_CustomerManagedStillSurfacesAPIFailures(t *testing.T) {
	ctx := context.Background()
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	failing := interceptor.NewClient(fake.NewClientBuilder().WithScheme(scheme).WithObjects(owner).Build(), interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
			return apierrors.NewServiceUnavailable("injected")
		},
	})
	_, err := ReconcileServiceAccount(ctx, failing, scheme, owner, ServiceAccountOptions{Name: "customer-sa", CustomerManaged: true})
	require.Error(t, err)
	assert.True(t, apierrors.IsServiceUnavailable(err), "the failure is surfaced for a retry, got %v", err)
}

// Without RefuseUnowned the helpers keep their earlier behaviour (SAIA relies on it):
// an unowned object is adopted, and one another controller owns is still refused.
func TestReconcileHelpers_KeepTheEarlierBehaviourWithoutRefuseUnowned(t *testing.T) {
	ctx := context.Background()
	scheme := buildResourceTestScheme(t)
	owner := newResourceTestOwner("service", "service-uid")
	sa := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: "service-sa", Namespace: "default"}}
	cert := &certmanagerv1.Certificate{ObjectMeta: metav1.ObjectMeta{Name: "service-tls", Namespace: "default"}}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(owner, sa, cert).Build()

	_, err := ReconcileServiceAccount(ctx, fakeClient, scheme, owner, ServiceAccountOptions{Name: "service-sa"})
	require.NoError(t, err)
	require.NoError(t, fakeClient.Get(ctx, client.ObjectKeyFromObject(sa), sa))
	assert.True(t, metav1.IsControlledBy(sa, owner), "adopted, as before")

	_, _, err = ReconcileCertificate(ctx, fakeClient, scheme, owner, CertificateOptions{Name: "service-tls", Spec: certmanagerv1.CertificateSpec{SecretName: "s"}})
	require.NoError(t, err)
	require.NoError(t, fakeClient.Get(ctx, client.ObjectKeyFromObject(cert), cert))
	assert.True(t, metav1.IsControlledBy(cert, owner), "adopted, as before")
}
