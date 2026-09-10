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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
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
