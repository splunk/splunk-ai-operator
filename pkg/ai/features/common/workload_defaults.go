package common

import (
	"maps"
	"slices"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
)

const deploymentRevisionAnnotation = "deployment.kubernetes.io/revision"

// PreserveDeploymentRevision keeps the revision set by the Deployment
// controller on the Deployment itself, independently of the Pod annotations.
func PreserveDeploymentRevision(deployment *appsv1.Deployment, desired map[string]string) map[string]string {
	annotations := maps.Clone(desired)
	if revision, ok := deployment.Annotations[deploymentRevisionAnnotation]; ok {
		if annotations == nil {
			annotations = make(map[string]string, 1)
		}
		annotations[deploymentRevisionAnnotation] = revision
	}
	return annotations
}

// PreserveAllocatedNodePorts keeps the live allocation for retained ports when
// the desired Service still uses node ports and leaves the value unspecified.
func PreserveAllocatedNodePorts(serviceType corev1.ServiceType, desired, current []corev1.ServicePort) {
	if serviceType != corev1.ServiceTypeNodePort && serviceType != corev1.ServiceTypeLoadBalancer {
		return
	}
	for i := range desired {
		port := &desired[i]
		if port.NodePort != 0 {
			continue
		}
		for _, previous := range current {
			if previous.Name == port.Name && previous.Protocol == port.Protocol {
				port.NodePort = previous.NodePort
				break
			}
		}
	}
}

// PreservePodTemplateDefaults retains Kubernetes defaults already present on
// the stored template. Dropping them makes the client send an update that the
// API server defaults back to the same object. Explicit values still win.
func PreservePodTemplateDefaults(desired, current *corev1.PodTemplateSpec) {
	next, old := &desired.Spec, &current.Spec
	preserveDefault(&next.RestartPolicy, old.RestartPolicy, corev1.RestartPolicyAlways)
	preserveDefault(&next.DNSPolicy, old.DNSPolicy, corev1.DNSClusterFirst)
	preserveDefault(&next.SchedulerName, old.SchedulerName, corev1.DefaultSchedulerName)
	if next.ServiceAccountName == old.ServiceAccountName {
		// The API also exposes serviceAccountName through its deprecated alias.
		preserveDefault(&next.DeprecatedServiceAccount, old.DeprecatedServiceAccount, next.ServiceAccountName)
	}
	preserveDefaultPointer(&next.TerminationGracePeriodSeconds, old.TerminationGracePeriodSeconds, int64(corev1.DefaultTerminationGracePeriodSeconds))
	preserveDefaultPointer(&next.EnableServiceLinks, old.EnableServiceLinks, corev1.DefaultEnableServiceLinks)
	if next.SecurityContext == nil && equality.Semantic.DeepEqual(old.SecurityContext, &corev1.PodSecurityContext{}) {
		next.SecurityContext = &corev1.PodSecurityContext{}
	}
	preserveContainerDefaults(next.Containers, old.Containers)
	preserveContainerDefaults(next.InitContainers, old.InitContainers)
	for i := range next.Volumes {
		volume := &next.Volumes[i]
		index := slices.IndexFunc(old.Volumes, func(v corev1.Volume) bool { return v.Name == volume.Name })
		if index < 0 {
			continue
		}
		previous := &old.Volumes[index]
		if volume.ConfigMap != nil && previous.ConfigMap != nil {
			preserveDefaultPointer(&volume.ConfigMap.DefaultMode, previous.ConfigMap.DefaultMode, corev1.ConfigMapVolumeSourceDefaultMode)
		}
		if volume.Secret != nil && previous.Secret != nil {
			preserveDefaultPointer(&volume.Secret.DefaultMode, previous.Secret.DefaultMode, corev1.SecretVolumeSourceDefaultMode)
		}
	}
}

func preserveContainerDefaults(desired, current []corev1.Container) {
	for i := range desired {
		container := &desired[i]
		index := slices.IndexFunc(current, func(c corev1.Container) bool { return c.Name == container.Name })
		if index < 0 {
			continue
		}
		previous := &current[index]
		preserveDefault(&container.TerminationMessagePath, previous.TerminationMessagePath, corev1.TerminationMessagePathDefault)
		preserveDefault(&container.TerminationMessagePolicy, previous.TerminationMessagePolicy, corev1.TerminationMessageReadFile)
		for i := range container.Ports {
			port := &container.Ports[i]
			index := slices.IndexFunc(previous.Ports, func(p corev1.ContainerPort) bool {
				return p.Name == port.Name && p.ContainerPort == port.ContainerPort
			})
			if index >= 0 {
				preserveDefault(&port.Protocol, previous.Ports[index].Protocol, corev1.ProtocolTCP)
			}
		}
		preserveProbeDefaults(container.LivenessProbe, previous.LivenessProbe)
		preserveProbeDefaults(container.ReadinessProbe, previous.ReadinessProbe)
		preserveProbeDefaults(container.StartupProbe, previous.StartupProbe)
	}
}

func preserveProbeDefaults(desired, current *corev1.Probe) {
	if desired == nil || current == nil {
		return
	}
	preserveDefault(&desired.TimeoutSeconds, current.TimeoutSeconds, 1)
	preserveDefault(&desired.PeriodSeconds, current.PeriodSeconds, 10)
	preserveDefault(&desired.SuccessThreshold, current.SuccessThreshold, 1)
	preserveDefault(&desired.FailureThreshold, current.FailureThreshold, 3)
	if desired.HTTPGet != nil && current.HTTPGet != nil {
		preserveDefault(&desired.HTTPGet.Path, current.HTTPGet.Path, "/")
		preserveDefault(&desired.HTTPGet.Scheme, current.HTTPGet.Scheme, corev1.URISchemeHTTP)
	}
}

func preserveDefault[T comparable](desired *T, current, defaultValue T) {
	var zero T
	if *desired == zero && current == defaultValue {
		*desired = current
	}
}

func preserveDefaultPointer[T comparable](desired **T, current *T, defaultValue T) {
	if *desired == nil && current != nil && *current == defaultValue {
		*desired = &defaultValue
	}
}
