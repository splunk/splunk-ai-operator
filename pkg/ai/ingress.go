package ai_platform

import (
	"context"
	"fmt"
	"strings"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	kuberayutils "github.com/ray-project/kuberay/ray-operator/controllers/ray/utils"
	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

// resolveRayServiceName falls back to the KubeRay-normalized name when
// p.Status.RayServiceName isn't populated yet (e.g. before the first reconcile).
func resolveRayServiceName(p *aiApi.AIPlatform) (string, error) {
	if p.Status.RayServiceName != "" {
		return p.Status.RayServiceName, nil
	}
	return kuberayutils.GenerateHeadServiceName(kuberayutils.RayServiceCRD, rayv1.RayClusterSpec{}, p.Name)
}

// ReconcileIngress creates or updates Ingress resources for the AIPlatform
func (r *AIPlatformReconciler) ReconcileIngress(ctx context.Context, p *aiApi.AIPlatform) error {
	// Skip if Ingress is not enabled
	if p.Spec.Ingress == nil || !p.Spec.Ingress.Enabled {
		// Clean up any existing Ingress if it was disabled
		ingress := &networkingv1.Ingress{
			ObjectMeta: metav1.ObjectMeta{
				Name:      p.Name,
				Namespace: p.Namespace,
			},
		}
		err := r.Client.Delete(ctx, ingress)
		if err != nil && !apierrors.IsNotFound(err) {
			return fmt.Errorf("failed to delete Ingress: %w", err)
		}
		return nil
	}

	// Check if Ingress already exists to emit creation event
	ingressExists := true
	existingIngress := &networkingv1.Ingress{}
	key := types.NamespacedName{Name: p.Name, Namespace: p.Namespace}
	if err := r.Get(ctx, key, existingIngress); err != nil {
		if apierrors.IsNotFound(err) {
			ingressExists = false
			r.Recorder.Event(p, corev1.EventTypeNormal, "IngressCreating", "Creating Ingress resource")
		}
	}

	// Build Ingress resource
	ingress := &networkingv1.Ingress{
		ObjectMeta: metav1.ObjectMeta{
			Name:        p.Name,
			Namespace:   p.Namespace,
			Annotations: p.Spec.Ingress.Annotations,
		},
	}

	if err := controllerutil.SetControllerReference(p, ingress, r.Scheme); err != nil {
		return err
	}

	rayServiceName, err := resolveRayServiceName(p)
	if err != nil {
		return fmt.Errorf("determine RayService name: %w", err)
	}

	// Build Ingress rules from spec
	rules := []networkingv1.IngressRule{}
	for _, hostSpec := range p.Spec.Ingress.Hosts {
		paths := []networkingv1.HTTPIngressPath{}
		for _, pathSpec := range hostSpec.Paths {
			pathType := parsePathType(pathSpec.PathType)

			// Determine which service to route to based on path
			serviceName := rayServiceName
			servicePort := int32(8000) // Ray Serve default port

			// Support routing to different services
			if pathSpec.Path == "/dashboard" || pathSpec.Path == "/dashboard/*" {
				servicePort = 8265 // Ray Dashboard port
			} else if pathSpec.Path == "/weaviate" || pathSpec.Path == "/weaviate/*" {
				serviceName = p.Status.VectorDbServiceName
				servicePort = 80 // Weaviate port
			}

			paths = append(paths, networkingv1.HTTPIngressPath{
				Path:     pathSpec.Path,
				PathType: &pathType,
				Backend: networkingv1.IngressBackend{
					Service: &networkingv1.IngressServiceBackend{
						Name: serviceName,
						Port: networkingv1.ServiceBackendPort{
							Number: servicePort,
						},
					},
				},
			})
		}

		rules = append(rules, networkingv1.IngressRule{
			Host: hostSpec.Host,
			IngressRuleValue: networkingv1.IngressRuleValue{
				HTTP: &networkingv1.HTTPIngressRuleValue{
					Paths: paths,
				},
			},
		})
	}

	// Build TLS configuration
	tls := []networkingv1.IngressTLS{}
	for _, tlsSpec := range p.Spec.Ingress.TLS {
		tls = append(tls, networkingv1.IngressTLS{
			Hosts:      tlsSpec.Hosts,
			SecretName: tlsSpec.SecretName,
		})
	}

	// Set IngressClassName if specified
	var ingressClassName *string
	if p.Spec.Ingress.ClassName != "" {
		ingressClassName = &p.Spec.Ingress.ClassName
	}

	// Create or update the Ingress
	_, err = controllerutil.CreateOrUpdate(ctx, r.Client, ingress, func() error {
		ingress.Spec = networkingv1.IngressSpec{
			IngressClassName: ingressClassName,
			Rules:            rules,
			TLS:              tls,
		}
		return nil
	})

	if err != nil {
		r.Recorder.Eventf(p, corev1.EventTypeWarning, "IngressCreationFailed", "Failed to create/update Ingress: %v", err)
		return fmt.Errorf("failed to create/update Ingress: %w", err)
	}

	if !ingressExists {
		r.Recorder.Event(p, corev1.EventTypeNormal, "IngressCreated", "Ingress resource created successfully")
	}

	// Update status with Ingress information after successful creation
	return r.UpdateIngressStatus(ctx, p)
}

// UpdateIngressStatus updates the AIPlatform status with Ingress readiness information
func (r *AIPlatformReconciler) UpdateIngressStatus(ctx context.Context, p *aiApi.AIPlatform) error {
	// If Ingress is disabled, remove status condition
	if p.Spec.Ingress == nil || !p.Spec.Ingress.Enabled {
		// Remove IngressReady condition if it exists
		meta.RemoveStatusCondition(&p.Status.Conditions, "IngressReady")
		return nil
	}

	// Fetch the Ingress to check its status
	ingress := &networkingv1.Ingress{}
	key := types.NamespacedName{Name: p.Name, Namespace: p.Namespace}
	if err := r.Get(ctx, key, ingress); err != nil {
		if apierrors.IsNotFound(err) {
			// Ingress not found, set condition to False
			cond := metav1.Condition{
				Type:               "IngressReady",
				Status:             metav1.ConditionFalse,
				Reason:             "IngressNotFound",
				Message:            "Ingress resource not found",
				LastTransitionTime: metav1.Now(),
			}
			meta.SetStatusCondition(&p.Status.Conditions, cond)
			return nil
		}
		return err
	}

	// Check previous status for state transition detection
	prevStatus := metav1.ConditionUnknown
	for _, cond := range p.Status.Conditions {
		if cond.Type == "IngressReady" {
			prevStatus = cond.Status
			break
		}
	}

	// Determine if Ingress has been assigned an address (LoadBalancer IP or hostname)
	ingressReady := len(ingress.Status.LoadBalancer.Ingress) > 0

	// Build status message with Ingress addresses
	var message string
	var addresses []string
	if ingressReady {
		for _, ing := range ingress.Status.LoadBalancer.Ingress {
			if ing.IP != "" {
				addresses = append(addresses, ing.IP)
			} else if ing.Hostname != "" {
				addresses = append(addresses, ing.Hostname)
			}
		}
		if len(addresses) > 0 {
			message = fmt.Sprintf("Ingress ready with address(es): %s", strings.Join(addresses, ", "))
		} else {
			message = "Ingress has LoadBalancer entry but no address yet"
			ingressReady = false
		}
	} else {
		message = "Waiting for Ingress controller to assign address"
	}

	// Emit event only on state transition
	newStatus := metav1.ConditionTrue
	if !ingressReady {
		newStatus = metav1.ConditionFalse
	}

	if newStatus == metav1.ConditionTrue && prevStatus != metav1.ConditionTrue {
		r.Recorder.Event(p, corev1.EventTypeNormal, "IngressReady", message)
	} else if newStatus == metav1.ConditionFalse && prevStatus == metav1.ConditionTrue {
		r.Recorder.Event(p, corev1.EventTypeWarning, "IngressNotReady", message)
	}

	// Set status condition
	cond := metav1.Condition{
		Type:               "IngressReady",
		Status:             newStatus,
		Reason:             map[bool]string{true: "AddressAssigned", false: "AddressPending"}[ingressReady],
		Message:            message,
		LastTransitionTime: metav1.Now(),
	}
	meta.SetStatusCondition(&p.Status.Conditions, cond)

	return nil
}

// parsePathType converts string to PathType
func parsePathType(pathType string) networkingv1.PathType {
	switch pathType {
	case "Exact":
		return networkingv1.PathTypeExact
	case "Prefix":
		return networkingv1.PathTypePrefix
	case "ImplementationSpecific":
		return networkingv1.PathTypeImplementationSpecific
	default:
		// Default to Prefix if not specified
		return networkingv1.PathTypePrefix
	}
}
