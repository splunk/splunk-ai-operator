package raybuilder

// import (
// 	"fmt"

// 	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
// 	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
// 	corev1 "k8s.io/api/core/v1"
// 	"k8s.io/apimachinery/pkg/api/resource"
// )

var modelToGPUConfig = map[string]struct {
	GPUType  string
	TPSize   int
	Replicas int
}{
	"llama-3-70b": {GPUType: "A10G", TPSize: 4, Replicas: 2},
	"mistral-7b":  {GPUType: "L40S", TPSize: 1, Replicas: 1},
}

// func generateRayGroups(spec *aiApi.AIPlatformSpec) ([]rayv1.WorkerGroupSpec, rayv1.HeadGroupSpec, error) {
// 	var workerGroups []rayv1.WorkerGroupSpec

// 	// Assume all features are for Splunk AI Assistant
// 	// Create worker groups for each model configuration
// 	for modelName, modelConfig := range modelToGPUConfig {
// 		replicas := int32(modelConfig.Replicas)
// 		workerGroup := rayv1.WorkerGroupSpec{
// 			GroupName: fmt.Sprintf("gpu-%s-%s", modelName, modelConfig.GPUType),
// 			Replicas:  &replicas,
// 			RayStartParams: map[string]string{
// 				"num-gpus": fmt.Sprintf("%d", modelConfig.TPSize),
// 			},
// 			Template: corev1.PodTemplateSpec{
// 				Spec: corev1.PodSpec{
// 					Containers: []corev1.Container{
// 						{
// 							Name: "ray-worker",
// 							Resources: corev1.ResourceRequirements{
// 								Requests: corev1.ResourceList{
// 									corev1.ResourceCPU:    resource.MustParse("4"),
// 									"nvidia.com/gpu":      resource.MustParse(fmt.Sprintf("%d", modelConfig.TPSize)),
// 									corev1.ResourceMemory: resource.MustParse("16Gi"),
// 								},
// 								Limits: corev1.ResourceList{
// 									corev1.ResourceCPU:    resource.MustParse("4"),
// 									"nvidia.com/gpu":      resource.MustParse(fmt.Sprintf("%d", modelConfig.TPSize)),
// 									corev1.ResourceMemory: resource.MustParse("16Gi"),
// 								},
// 							},
// 						},
// 					},
// 				},
// 			},
// 		}
// 		workerGroups = append(workerGroups, workerGroup)
// 	}

// 	// Add a default CPU-based worker group for Weaviate and SAIA
// 	if spec.GPUSchedulingSpec != nil {
// 		cpuReplicas := int32(1)
// 		cpuGroup := rayv1.WorkerGroupSpec{
// 			GroupName: "cpu-default",
// 			Replicas:  &cpuReplicas,
// 			Template: corev1.PodTemplateSpec{
// 				Spec: corev1.PodSpec{
// 					Containers: []corev1.Container{
// 						{
// 							Name: "ray-worker",
// 							Resources: corev1.ResourceRequirements{
// 								Requests: corev1.ResourceList{
// 									corev1.ResourceCPU:    resource.MustParse("2"),
// 									corev1.ResourceMemory: resource.MustParse("4Gi"),
// 								},
// 								Limits: corev1.ResourceList{
// 									corev1.ResourceCPU:    resource.MustParse("2"),
// 									corev1.ResourceMemory: resource.MustParse("4Gi"),
// 								},
// 							},
// 						},
// 					},
// 					Affinity:     spec.GPUSchedulingSpec.Affinity,
// 					Tolerations:  spec.GPUSchedulingSpec.Tolerations,
// 					NodeSelector: spec.GPUSchedulingSpec.NodeSelector,
// 				},
// 			},
// 		}
// 		workerGroups = append(workerGroups, cpuGroup)
// 	}

// 	// Head node (typically CPU-only and stable config)
// 	headGroup := rayv1.HeadGroupSpec{
// 		RayStartParams: map[string]string{
// 			"dashboard-host": "0.0.0.0",
// 		},
// 		Template: corev1.PodTemplateSpec{
// 			Spec: corev1.PodSpec{
// 				Containers: []corev1.Container{
// 					{
// 						Name: "ray-head",
// 						Resources: corev1.ResourceRequirements{
// 							Requests: corev1.ResourceList{
// 								corev1.ResourceCPU:    resource.MustParse("2"),
// 								corev1.ResourceMemory: resource.MustParse("4Gi"),
// 							},
// 							Limits: corev1.ResourceList{
// 								corev1.ResourceCPU:    resource.MustParse("2"),
// 								corev1.ResourceMemory: resource.MustParse("4Gi"),
// 							},
// 						},
// 					},
// 				},
// 				Affinity:     spec.GPUSchedulingSpec.Affinity,
// 				Tolerations:  spec.GPUSchedulingSpec.Tolerations,
// 				NodeSelector: spec.GPUSchedulingSpec.NodeSelector,
// 			},
// 		},
// 	}

// 	return workerGroups, headGroup, nil
// }
