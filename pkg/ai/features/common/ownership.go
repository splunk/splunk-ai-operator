package common

import (
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/apiutil"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

// Ownership rule for the objects a feature creates (MPR-202).
//
// A feature owns exactly the objects it created: each is created with the
// AIService as its controller, so deleting the AIService lets Kubernetes garbage
// collection remove them, and an interrupted reconciliation can only leave owned
// objects behind. An object that already exists under a name the feature uses,
// and is not controlled by this AIService (matched by UID), is never adopted,
// rewritten or deleted: the stage fails with an OwnershipConflictError naming it.
// Nothing is ever selected for deletion by label.

// OwnershipConflictError reports an existing object, under a name the feature
// uses, that this AIService does not control. The object is left unchanged.
type OwnershipConflictError struct {
	Kind      string
	Namespace string
	Name      string
}

func (e *OwnershipConflictError) Error() string {
	return fmt.Sprintf("%s %s/%s already exists and is not managed by this AIService; it was left unchanged: rename or remove it", e.Kind, e.Namespace, e.Name)
}

// ClaimOrRefuse is called first in a controllerutil.CreateOrUpdate or CreateOrPatch
// mutate function, where obj holds the live object (or the new one). A new object
// (no resourceVersion) gets owner as its controller. An existing object must
// already be controlled by owner; otherwise an OwnershipConflictError is returned
// and, because the mutate function fails, nothing is written.
func ClaimOrRefuse(owner, obj client.Object, scheme *runtime.Scheme) error {
	if obj.GetResourceVersion() == "" {
		return controllerutil.SetControllerReference(owner, obj, scheme)
	}
	if metav1.IsControlledBy(obj, owner) {
		return nil
	}
	return conflict(obj, scheme)
}

func conflict(obj client.Object, scheme *runtime.Scheme) error {
	kind := obj.GetObjectKind().GroupVersionKind().Kind
	if gvk, err := apiutil.GVKForObject(obj, scheme); err == nil {
		kind = gvk.Kind
	}
	return &OwnershipConflictError{Kind: kind, Namespace: obj.GetNamespace(), Name: obj.GetName()}
}
