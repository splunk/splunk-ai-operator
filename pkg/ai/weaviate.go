package ai_platform

import (
	"context"
	"fmt"
	"os"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	meta "k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

func (r *AIPlatformReconciler) ReconcileWeaviateDatabaseStatus(ctx context.Context, p *aiApi.AIPlatform) error {
	// 1️⃣ Fetch the up-to-date StatefulSet for Weaviate
	sts := &appsv1.StatefulSet{}
	key := types.NamespacedName{Namespace: p.Namespace, Name: fmt.Sprintf("%s-weaviate", p.Name)}
	if err := r.Get(ctx, key, sts); err != nil {
		return err
	}

	// 2️⃣ Update the status based on StatefulSet readiness
	ready := metav1.ConditionFalse
	reason := "WeaviateNotReady"
	msg := "Weaviate database is not ready"
	if sts.Status.ReadyReplicas == *sts.Spec.Replicas {
		ready = metav1.ConditionTrue
		reason = "WeaviateReady"
		msg = "Weaviate database is ready"
	}

	cond := metav1.Condition{
		Type:               "WeaviateReady",
		Status:             ready,
		Reason:             reason,
		Message:            msg,
		LastTransitionTime: metav1.Now(),
	}
	meta.SetStatusCondition(&p.Status.Conditions, cond)

	// 3️⃣ Add Weaviate service name to status
	p.Status.VectorDbServiceName = fmt.Sprintf("%s-weaviate", p.Name)

	return nil
}

// ReconcileWeaviateDatabase manages ServiceAccount, StatefulSet, and Service for Weaviate
func (r *AIPlatformReconciler) ReconcileWeaviateDatabase(ctx context.Context, instance *aiApi.AIPlatform) error {
	// Resolve Weaviate image from env
	weaviateImage := os.Getenv("RELATED_IMAGE_WEAVIATE")
	if weaviateImage == "" {
		err := fmt.Errorf("RELATED_IMAGE_WEAVIATE environment variable is required")
		r.Recorder.Event(instance, corev1.EventTypeWarning, "WeaviateConfigError", err.Error())
		return err
	}

	// Derive default values
	name := fmt.Sprintf("%s-weaviate", instance.Name)
	defaultReplicas := int32(1)
	defaultSA := name

	replicas := &defaultReplicas
	resources := corev1.ResourceRequirements{
		Requests: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("2"),
			corev1.ResourceMemory: resource.MustParse("4Gi"),
		},
		Limits: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("2"),
			corev1.ResourceMemory: resource.MustParse("4Gi"),
		},
	}

	labels := map[string]string{"app": name}

	// 1) Ensure ServiceAccount
	sa := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{
			Name:      defaultSA,
			Namespace: instance.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(instance, sa, r.Scheme); err != nil {
		return err
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, sa, func() error { return nil }); err != nil {
		return err
	}

	// 2) Ensure StatefulSet
	sts := &appsv1.StatefulSet{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: instance.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(instance, sts, r.Scheme); err != nil {
		return err
	}

	// Check if StatefulSet exists to emit creation event
	stsExists := true
	existingSts := &appsv1.StatefulSet{}
	if err := r.Get(ctx, types.NamespacedName{Name: name, Namespace: instance.Namespace}, existingSts); err != nil {
		if apierrors.IsNotFound(err) {
			stsExists = false
			r.Recorder.Event(instance, corev1.EventTypeNormal, "WeaviateCreating", "Creating Weaviate StatefulSet")
		}
	}

	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, sts, func() error {
		// Set immutable fields only if StatefulSet is being created (UID will be empty for new objects)
		if sts.UID == "" {
			sts.Spec.Selector = &metav1.LabelSelector{MatchLabels: labels}
			sts.Spec.ServiceName = name
		}

		// Mutable fields - can always be updated
		sts.Spec.Replicas = replicas
		sts.Spec.Template.ObjectMeta.Labels = labels
		sts.Spec.Template.Spec.ServiceAccountName = defaultSA
		sts.Spec.Template.Spec.Affinity = instance.Spec.CPUSchedulingSpec.Affinity
		sts.Spec.Template.Spec.Tolerations = instance.Spec.CPUSchedulingSpec.Tolerations
		sts.Spec.Template.Spec.NodeSelector = instance.Spec.CPUSchedulingSpec.NodeSelector
		// Propagate imagePullSecrets from AIPlatform spec
		sts.Spec.Template.Spec.ImagePullSecrets = instance.Spec.Images.ImagePullSecrets

		// Determine PVC configuration
		volumeMounts := []corev1.VolumeMount{}
		var volumeClaimTemplates []corev1.PersistentVolumeClaim

		// Check if user provided an existing PVC name
		if instance.Spec.Storage.VectorDB.PVCName != "" {
			// Use existing PVC
			sts.Spec.Template.Spec.Volumes = []corev1.Volume{{
				Name: "weaviate-data",
				VolumeSource: corev1.VolumeSource{
					PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
						ClaimName: instance.Spec.Storage.VectorDB.PVCName,
					},
				},
			}}
			volumeMounts = append(volumeMounts, corev1.VolumeMount{
				Name:      "weaviate-data",
				MountPath: "/var/lib/weaviate",
			})
		} else {
			// Create dynamic PVC via VolumeClaimTemplate
			volumeSize := instance.Spec.Storage.VectorDB.Size
			if volumeSize == "" {
				volumeSize = "50Gi" // default
			}

			pvcTemplate := corev1.PersistentVolumeClaim{
				ObjectMeta: metav1.ObjectMeta{
					Name: "weaviate-data",
				},
				Spec: corev1.PersistentVolumeClaimSpec{
					AccessModes: []corev1.PersistentVolumeAccessMode{
						corev1.ReadWriteOnce,
					},
					Resources: corev1.VolumeResourceRequirements{
						Requests: corev1.ResourceList{
							corev1.ResourceStorage: resource.MustParse(volumeSize),
						},
					},
				},
			}

			// Add StorageClassName if specified
			if instance.Spec.Storage.VectorDB.StorageClassName != "" {
				pvcTemplate.Spec.StorageClassName = &instance.Spec.Storage.VectorDB.StorageClassName
			}

			volumeClaimTemplates = append(volumeClaimTemplates, pvcTemplate)
			volumeMounts = append(volumeMounts, corev1.VolumeMount{
				Name:      "weaviate-data",
				MountPath: "/var/lib/weaviate",
			})
		}

		// Set VolumeClaimTemplates only on creation (immutable field)
		if sts.UID == "" {
			sts.Spec.VolumeClaimTemplates = volumeClaimTemplates
		}

		// Container definition
		sts.Spec.Template.Spec.Containers = []corev1.Container{{
			Name:            "weaviate",
			Image:           weaviateImage,
			ImagePullPolicy: corev1.PullIfNotPresent,
			Resources:       resources,
			VolumeMounts: volumeMounts,
			Ports: []corev1.ContainerPort{{
				Name:          "http",
				ContainerPort: 8080,
			}},
			Env: []corev1.EnvVar{
				{
					Name:  "PERSISTENCE_DATA_PATH",
					Value: "/var/lib/weaviate",
				},
			},
		}}
		return nil
	}); err != nil {
		r.Recorder.Eventf(instance, corev1.EventTypeWarning, "WeaviateCreationFailed", "Failed to create/update Weaviate: %v", err)
		return err
	}

	if !stsExists {
		r.Recorder.Event(instance, corev1.EventTypeNormal, "WeaviateCreated", "Weaviate StatefulSet created successfully")
	}

	// 3) Ensure Service
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: instance.Namespace,
		},
	}
	if err := controllerutil.SetControllerReference(instance, svc, r.Scheme); err != nil {
		return err
	}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Spec.Selector = labels
		svc.Spec.Ports = []corev1.ServicePort{{
			Name:       "http",
			Port:       80,
			TargetPort: intstr.FromInt(8080),
		}}
		return nil
	}); err != nil {
		return err
	}

	return nil
}
