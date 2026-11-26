package agentruntime

import (
	"context"
	"errors"

	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// safeRuntimeError is the boundary before errors leave the feature and reach
// controller-runtime's logger. API Status details may contain the rejected
// object, so retain only retry-relevant classification and a controlled message.
func safeRuntimeError(err error, message string) error {
	if err == nil {
		return nil
	}
	for _, terminal := range []error{context.Canceled, context.DeadlineExceeded} {
		if errors.Is(err, terminal) {
			return terminal
		}
	}
	var state *schemaStageError
	if errors.As(err, &state) {
		return state
	}
	// An ownership conflict carries only an object's kind, namespace and name.
	var conflict *common.OwnershipConflictError
	if errors.As(err, &conflict) {
		return conflict
	}
	var status apierrors.APIStatus
	if errors.As(err, &status) {
		s := status.Status()
		var details *metav1.StatusDetails
		if s.Details != nil && s.Details.RetryAfterSeconds > 0 {
			// Retry delays are numeric control data. Object names and Causes can
			// contain rejected credential values and are intentionally omitted.
			details = &metav1.StatusDetails{RetryAfterSeconds: s.Details.RetryAfterSeconds}
		}
		return &apierrors.StatusError{ErrStatus: metav1.Status{
			Status: s.Status, Reason: s.Reason, Code: s.Code, Message: message, Details: details,
		}}
	}
	return errors.New(message)
}
