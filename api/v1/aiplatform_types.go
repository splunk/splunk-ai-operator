/*
Copyright 2024.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1

import (
	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// AIPlatform is the Schema for the AIPlatform API
// +k8s:openapi-gen=true
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:path=aiplatforms,scope=Namespaced,shortName=spai;aiplatform
// +kubebuilder:printcolumn:name="Ready",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status",description="Platform ready status"
// +kubebuilder:printcolumn:name="RayService",type="string",JSONPath=".status.conditions[?(@.type=='RayServiceReady')].status",description="Ray service status"
// +kubebuilder:printcolumn:name="VectorDB",type="string",JSONPath=".status.conditions[?(@.type=='WeaviateDatabaseReady')].status",description="VectorDB status"
// +kubebuilder:printcolumn:name="Ingress",type="string",JSONPath=".status.conditions[?(@.type=='IngressReady')].status",priority=1,description="Ingress status"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp",description="Age of resource"
type AIPlatform struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   AIPlatformSpec   `json:"spec,omitempty"`
	Status AIPlatformStatus `json:"status,omitempty"`
}

// AIPlatformSpec defines the desired state
type AIPlatformSpec struct {
	// ObjectStorage defines the object storage configuration for AI artifacts, tasks, and models
	// Supported providers: S3, GCS, Azure Blob Storage, MinIO
	// +kubebuilder:validation:Required
	ObjectStorage ObjectStorageSpec `json:"objectStorage"`

	// ServiceAccountName is the name of the service account to use for the AIPlatform
	// Used for Ray, Weaviate, SAIA, etc and also IAM role for S3 access
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	ServiceAccountName string `json:"serviceAccountName,omitempty"`

	// GpuInstanceType is the type of GPU instance to use for Ray worker groups
	// Examples: "g6.24xlarge", "p4d.24xlarge", "nvidia-tesla-t4"
	// +kubebuilder:validation:Optional
	GpuInstanceType string `json:"gpuInstanceType,omitempty"`

	// Features defines the AI features to enable in the platform
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MaxItems=10
	Features []FeatureSpec `json:"features,omitempty"`

	// ScaleFactor is a platform-wide capacity multiplier. It uniformly scales
	// BOTH the model (Serve) replicas AND the GPU worker-pool pod counts, so a
	// single knob grows capacity without needing to know which models exist or
	// how many GPUs each uses. The cluster must have proportionally more GPUs
	// available before raising it. Defaults to 1 (single-capacity deployment).
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:default=1
	ScaleFactor *int32 `json:"scaleFactor,omitempty"`

	// WorkerGroupConfig defines the Ray worker group configuration
	// +kubebuilder:validation:Optional
	WorkerGroupConfig *WorkerGroupConfig `json:"workerGroupConfig,omitempty"`

	// Sidecars defines which sidecars to inject into pods
	// +kubebuilder:validation:Optional
	Sidecars SidecarSpec `json:"sidecars,omitempty"`

	// CertificateRef references a cert-manager Certificate or Issuer for mTLS
	// +kubebuilder:validation:Optional
	CertificateRef string `json:"certificateRef,omitempty"`

	// ClusterDomain is the cluster domain for service DNS
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="cluster.local"
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$`
	ClusterDomain string `json:"clusterDomain,omitempty"`

	// Images defines custom container images for platform components
	// +kubebuilder:validation:Optional
	Images Images `json:"images,omitempty"`

	// DefaultAcceleratorType is the default GPU type to use for Ray worker groups
	// Examples: "nvidia-tesla-t4", "nvidia-tesla-v100", "nvidia-a100"
	// +kubebuilder:validation:Optional
	DefaultAcceleratorType string `json:"defaultAcceleratorType,omitempty"`

	// SplunkConfiguration defines the Splunk integration configuration
	// +kubebuilder:validation:Optional
	SplunkConfiguration SplunkConfigurationSpec `json:"splunkConfiguration,omitempty"`

	// Storage defines persistent storage configuration for platform components
	// +kubebuilder:validation:Optional
	Storage StorageSpec `json:"storage,omitempty"`

	// GPUSchedulingSpec defines the scheduling configuration for GPU-based Ray worker groups
	// +kubebuilder:validation:Optional
	GPUSchedulingSpec *SchedulingSpec `json:"gpuScheduler,omitempty"`

	// CPUSchedulingSpec defines the scheduling configuration for CPU-based Ray worker groups
	// +kubebuilder:validation:Optional
	CPUSchedulingSpec *SchedulingSpec `json:"cpuScheduler,omitempty"`

	// Ingress defines the Ingress configuration for external access
	// +kubebuilder:validation:Optional
	Ingress *IngressSpec `json:"ingress,omitempty"`

	// MTLS defines the mTLS configuration for secure communication
	// +kubebuilder:validation:Optional
	MTLS MTLSConfig `json:"mtls,omitempty"`

	// ServiceTemplate is a template used to create Kubernetes services
	// +kubebuilder:validation:Optional
	ServiceTemplate corev1.Service `json:"serviceTemplate,omitempty"`
}

// Images defines custom container images for platform components
type Images struct {
	// SAIA service image
	// +kubebuilder:validation:Optional
	SAIAImage string `json:"saiaImage,omitempty"`
	// Weaviate vector database image, e.g. "docker.io/weaviate:latest"
	// +kubebuilder:validation:Optional
	WeaviateImage string `json:"weaviateImage,omitempty"`
	// Ray head group image, e.g. "rayproject/ray-head:latest"
	// +kubebuilder:validation:Optional
	RayHeadGroupImage string `json:"rayHeadGroupImage,omitempty"`
	// Ray worker group image, e.g. "rayproject/ray-worker:latest"
	// +kubebuilder:validation:Optional
	RayWorkerGroupImage string `json:"rayWorkerGroupImage,omitempty"`
	// OTelImage is the OpenTelemetry Collector sidecar image
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="otel/opentelemetry-collector-contrib:0.122.1"
	OTelImage string `json:"otelImage,omitempty"`
	// ImagePullSecrets is a list of secret names for pulling container images from private registries
	// If specified, these secrets will be added to ALL pods created by the operator
	// (Ray head, Ray workers, Weaviate, SAIA, jobs, etc.)
	// Use this when your container images are hosted in private registries like AWS ECR, Docker Hub, GCR, or ACR
	// Kubernetes will gracefully handle the case where imagePullSecrets are provided but images are public
	// +kubebuilder:validation:Optional
	ImagePullSecrets []corev1.LocalObjectReference `json:"imagePullSecrets,omitempty"`
}

// StorageSpec defines persistent storage configuration for platform components
type StorageSpec struct {
	// VectorDB storage configuration
	// +kubebuilder:validation:Optional
	VectorDB VectorDBStorageSpec `json:"vectorDB,omitempty"`
	// Add other storage categories here if needed, e.g., for model artifacts
}

// VectorDBStorageSpec defines storage configuration for the vector database
type VectorDBStorageSpec struct {
	// Optional name of an existing PVC to use (mutually exclusive with Size)
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	PVCName string `json:"pvcName,omitempty"`

	// Size of the volume to create if PVCName is not provided
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="50Gi"
	// +kubebuilder:validation:Pattern=`^([+-]?[0-9.]+)([eEinumkKMGTP]*[-+]?[0-9]*)$`
	Size string `json:"size,omitempty"`

	// Optional StorageClassName to use for dynamic PVC provisioning
	// +kubebuilder:validation:Optional
	StorageClassName string `json:"storageClassName,omitempty"`
}

// FeatureSpec defines the features to enable in the AIPlatform
type FeatureSpec struct {
	// Name of the feature, e.g. "saia", "seca", "slim", or "agentruntime"
	// +kubebuilder:validation:Enum=saia;seca;slim;agentruntime
	Name string `json:"name,omitempty"`
	// Provider identifies the product team for multi-provider features such as agentruntime.
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	Provider string `json:"provider,omitempty"`
	// ServiceAccountName is the name of the service account to use for the feature
	ServiceAccountName string `json:"serviceAccountName,omitempty"`
	// Version of the feature, e.g. "1.0.0"
	Version string `json:"version,omitempty"`
	// RuntimeVersion optionally pins the shared agent-runtime base image version.
	// +kubebuilder:validation:Optional
	RuntimeVersion string `json:"runtimeVersion,omitempty"`
	// MinReplicas is the HPA floor for this feature.
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Minimum=1
	MinReplicas *int32 `json:"minReplicas,omitempty"`
	// MaxReplicas is the HPA ceiling for this feature.
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Minimum=1
	MaxReplicas *int32 `json:"maxReplicas,omitempty"`
	// TargetCPUUtilization is the target average CPU utilization percentage for HPA.
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=100
	TargetCPUUtilization *int32 `json:"targetCPUUtilization,omitempty"`
	// CheckpointDbSecretRef references a Secret containing Postgres checkpoint connection settings.
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	CheckpointDbSecretRef string `json:"checkpointDbSecretRef,omitempty"`
}

// WeaviateSpec defines the configuration for the Weaviate vector database
type WeaviateSpec struct {
	// Replicas is the number of Weaviate replicas
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=1
	Replicas *int32 `json:"replicas"`

	// Resources defines the compute resources for Weaviate pods
	// +kubebuilder:validation:Optional
	Resources corev1.ResourceRequirements `json:"resources,omitempty"`

	// ServiceAccountName is the name of the service account to use for Weaviate
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	ServiceAccountName string `json:"serviceAccountName,omitempty"`

	// SchedulingSpec defines the scheduling configuration for Weaviate pods
	SchedulingSpec `json:",inline"` // inlines NodeSelector, Tolerations, Affinity
}

// HeadGroupSpec defines the configuration for the Ray head group
type HeadGroupSpec struct {
	// ServiceAccountName is the name of the service account to use for the Ray head group
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	ServiceAccountName string `json:"serviceAccountName,omitempty"`

	// SchedulingSpec defines the scheduling configuration for Ray head group pods
	SchedulingSpec `json:",inline"` // inlines NodeSelector, Tolerations, Affinity

	// ImageRegistry is the image registry to use for the Ray head group
	// +kubebuilder:validation:Optional
	ImageRegistry string `json:"imageRegistry,omitempty"`
}

// WorkerGroupConfig defines the configuration for Ray worker groups
type WorkerGroupConfig struct {
	// ServiceAccountName is the name of the service account to use for Ray worker groups
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	ServiceAccountName string `json:"serviceAccountName,omitempty"`

	// ImageRegistry is the image registry to use for Ray worker groups
	// +kubebuilder:validation:Optional
	ImageRegistry string `json:"imageRegistry,omitempty"`
}

// GPUConfig defines one worker-tier with scheduling and accelerator settings
type GPUConfig struct {
	// Tier is the name of this GPU worker tier
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	Tier string `json:"tier"`

	// MinReplicas is the minimum number of replicas for this tier
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=0
	MinReplicas int32 `json:"minReplicas"`

	// MaxReplicas is the maximum number of replicas for this tier
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=1
	MaxReplicas int32 `json:"maxReplicas"`

	// GPUsPerPod is the number of GPUs per pod
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=1
	GPUsPerPod int32 `json:"gpusPerPod"`

	// Resources defines the compute resources for this tier
	// +kubebuilder:validation:Optional
	Resources corev1.ResourceRequirements `json:"resources,omitempty"`
}

// SchedulingSpec exposes common pod-scheduling knobs
type SchedulingSpec struct {
	// NodeSelector is a map of key-value pairs for node selection
	// +kubebuilder:validation:Optional
	NodeSelector map[string]string `json:"nodeSelector,omitempty"`

	// Tolerations allows pods to schedule onto nodes with matching taints
	// +kubebuilder:validation:Optional
	Tolerations []corev1.Toleration `json:"tolerations,omitempty"`

	// Affinity defines pod affinity and anti-affinity rules
	// +kubebuilder:validation:Optional
	Affinity *corev1.Affinity `json:"affinity,omitempty"`
}

// SplunkConfigurationSpec defines the Splunk integration configuration
type SplunkConfigurationSpec struct {
	// SplunkCustomResourceRef references an existing SplunkConfiguration custom resource
	// +kubebuilder:validation:Optional
	SplunkCustomResourceRef corev1.ObjectReference `json:"splunkCustomResourceRef,omitempty"`

	// SecretRef references a Secret containing Splunk credentials
	// +kubebuilder:validation:Optional
	SecretRef corev1.SecretReference `json:"secretRef,omitempty"`

	// Endpoint is the Splunk HEC endpoint URL or service name (mutually exclusive with SplunkCustomResourceRef)
	// Either Endpoint or SplunkCustomResourceRef must be provided
	// +kubebuilder:validation:Optional
	Endpoint string `json:"endpoint,omitempty"`

	// Token is the Splunk HEC token (consider using SecretRef instead)
	// +kubebuilder:validation:Optional
	Token string `json:"token,omitempty"`

	// SecretSource indicates whether token comes from Kubernetes Secret or Vault Agent
	// +kubebuilder:validation:Optional
	SecretSource SecretSourceType `json:"secretSource,omitempty"`

	// VaultFilePath is the path where Vault Agent injects the Splunk HEC token
	// +kubebuilder:validation:Optional
	VaultFilePath string `json:"vaultFilePath,omitempty"`

	// TrustedIssuers is a list of Splunk JWT issuer URLs (management port,
	// e.g. https://<splunk-host>:8089) that SAIA will trust for token validation.
	// When the in-cluster Splunk Standalone is deployed (SplunkCustomResourceRef is set),
	// its issuer is included automatically and TrustedIssuers are appended.
	// In external or disabled modes, SPLUNK_ISSUERS is populated solely from this list.
	// +optional
	TrustedIssuers []string `json:"trustedIssuers,omitempty"`
}

// ReplicasSpec sets min/max worker replicas
type ReplicasSpec struct {
	// Min is the minimum number of replicas
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Minimum=0
	Min int32 `json:"min,omitempty"`

	// Max is the maximum number of replicas
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Minimum=1
	Max int32 `json:"max,omitempty"`
}

// MachineClass configures CPU, memory, GPU per-worker
type MachineClass struct {
	// ResourceRequirements defines the compute resources
	// +kubebuilder:validation:Optional
	ResourceRequirements corev1.ResourceRequirements `json:"resourceRequirements,omitempty"`

	// GPU is the number of GPUs
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Minimum=0
	GPU int32 `json:"gpu,omitempty"`

	// EphemeralStorage is the ephemeral storage size, e.g. "100Gi"
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Pattern=`^([+-]?[0-9.]+)([eEinumkKMGTP]*[-+]?[0-9]*)$`
	EphimeralStorage string `json:"ephemeral-storage,omitempty"`
}

// SidecarSpec toggles injection of sidecars
type SidecarSpec struct {
	// Envoy enables Envoy sidecar injection
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=false
	Envoy bool `json:"envoy,omitempty"`

	// Otel enables OpenTelemetry sidecar injection
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=true
	Otel bool `json:"otel,omitempty"`

	// PrometheusOperator enables Prometheus Operator sidecar
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=true
	PrometheusOperator bool `json:"prometheusOperator,omitempty"`
}

// ObjectStorageSpec defines object storage configuration for AI artifacts, tasks, and models
type ObjectStorageSpec struct {
	// Remote volume URI in the format s3://bucketname/<path prefix>, gs://bucketname/<path prefix>,
	// azure://containername/<path prefix>, s3compat://bucketname/<path prefix> (generic S3-compatible), minio://, or seaweedfs://
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Pattern=`^(s3|gs|azure|minio|seaweedfs|s3compat)://[a-zA-Z0-9.\-_]+(/.*)?$`
	Path string `json:"path"`

	// Optional override endpoint (only needed for S3-compatible services like MinIO, SeaweedFS)
	// Must be a valid HTTP/HTTPS URL. When set with s3:// path, backend is treated as S3-compatible (MinIO, SeaweedFS, etc.)
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Pattern=`^https?://.*$`
	Endpoint string `json:"endpoint,omitempty"`

	// Region of the remote storage volume. Required for S3, optional for other providers
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	Region string `json:"region"`

	// Secret name containing storage credentials (e.g. s3_access_key, s3_secret_key for S3-compatible backends)
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	SecretRef string `json:"secretRef,omitempty"`

	// Provider is an optional hint for documentation and tooling. Operator derives behavior from path scheme and endpoint.
	// Values: aws, minio, seaweedfs, s3compat, gcs, azure
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Enum=aws;minio;seaweedfs;s3compat;gcs;azure
	Provider string `json:"provider,omitempty"`
}

// IngressSpec defines Ingress configuration for external access to platform services
type IngressSpec struct {
	// Enabled determines whether to create an Ingress resource
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=false
	Enabled bool `json:"enabled,omitempty"`

	// ClassName specifies the Ingress class (e.g., "nginx", "traefik")
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinLength=1
	ClassName string `json:"className,omitempty"`

	// Annotations for the Ingress resource
	// +kubebuilder:validation:Optional
	Annotations map[string]string `json:"annotations,omitempty"`

	// Hosts defines the list of host rules for the Ingress
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinItems=1
	Hosts []IngressHost `json:"hosts,omitempty"`

	// TLS configuration for the Ingress
	// +kubebuilder:validation:Optional
	TLS []IngressTLS `json:"tls,omitempty"`
}

// IngressHost defines a host and its paths for Ingress routing
type IngressHost struct {
	// Host is the FQDN for the Ingress rule
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$`
	Host string `json:"host"`

	// Paths defines the list of paths for this host
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinItems=1
	Paths []IngressPath `json:"paths"`
}

// IngressPath defines a path for Ingress routing
type IngressPath struct {
	// Path is the URL path for the Ingress rule
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	Path string `json:"path"`

	// PathType determines how the path is matched (Prefix, Exact, or ImplementationSpecific)
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Enum=Prefix;Exact;ImplementationSpecific
	PathType string `json:"pathType"`
}

// IngressTLS defines TLS configuration for Ingress
type IngressTLS struct {
	// Hosts is the list of hosts covered by this TLS certificate
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinItems=1
	Hosts []string `json:"hosts"`

	// SecretName is the name of the Secret containing the TLS certificate
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	SecretName string `json:"secretName"`
}

// AIPlatformStatus defines observed state
type AIPlatformStatus struct {
	RayServiceName      string                     `json:"rayServiceName,omitempty"`
	VectorDbServiceName string                     `json:"vectorDbServiceName,omitempty"`
	RayServiceStatus    rayv1.ServiceStatus        `json:"rayServiceStatus,omitempty"`
	Conditions          []metav1.Condition         `json:"conditions,omitempty"`
	ObservedGeneration  int64                      `json:"observedGeneration,omitempty"`
	Ingress             corev1.LoadBalancerIngress `json:"ingress,omitempty"` // Ingress for the AIPlatform, e.g. for SAIA or Weaviate
}

// +kubebuilder:object:root=true
type AIPlatformList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []AIPlatform `json:"items"`
}

func init() {
	SchemeBuilder.Register(&AIPlatform{}, &AIPlatformList{})
}
