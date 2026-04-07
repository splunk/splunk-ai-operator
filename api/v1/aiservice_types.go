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
	cmmeta "github.com/cert-manager/cert-manager/pkg/apis/meta/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const aiServiceFinalizer = "ai.splunk.com/aiservice-protect"

// EDIT THIS FILE!  THIS IS SCAFFOLDING FOR YOU TO OWN!
// NOTE: json tags are required.  Any new fields you add must have json tags for the fields to be serialized.

// AIServiceSpec defines the desired state of AIService
type AIServiceSpec struct {
	// Feature defines the features to be enabled for the AIService
	// +kubebuilder:validation:Optional
	Feature FeatureSpec `json:"features,omitempty"`

	// Version specifies the version of the AIService
	// +kubebuilder:validation:Optional
	Version string `json:"version,omitempty"`

	// TaskVolume specifies the object storage volume for tasks
	// +kubebuilder:validation:Optional
	TaskVolume *ObjectStorageSpec `json:"taskVolume,omitempty"`

	// SplunkConfiguration specifies the Splunk configuration for the AIService
	// +kubebuilder:validation:Optional
	SplunkConfiguration SplunkConfigurationSpec `json:"splunkConfiguration,omitempty"`

	// VectorDbUrl specifies the URL or service name for the vector database
	// +kubebuilder:validation:Required
	VectorDbUrl string `json:"vectorDbUrl"`

	// AIPlatformUrl specifies the URL for the AI Platform (deprecated, use AIPlatformRef)
	// +kubebuilder:validation:Optional
	AIPlatformUrl string `json:"aiPlatformUrl,omitempty"`

	// AIPlatformRef is a reference to the AIPlatform resource
	// +kubebuilder:validation:Required
	AIPlatformRef corev1.ObjectReference `json:"aiPlatformRef"`

	// Replicas specifies the number of replicas for the AIService
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=1
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	Replicas int32 `json:"replicas,omitempty"`

	// ServiceAccountName specifies the service account to be used by the AIService
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	ServiceAccountName string `json:"serviceAccountName,omitempty"`

	// ImagePullSecrets is a list of secret names for pulling container images from private registries
	// If specified, these secrets will be added to ALL pods created for this AIService
	// Use this when your container images are hosted in private registries like AWS ECR, Docker Hub, GCR, or ACR
	// +kubebuilder:validation:Optional
	ImagePullSecrets []corev1.LocalObjectReference `json:"imagePullSecrets,omitempty"`

	// Port specifies the service port
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=80
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=65535
	Port int32 `json:"port,omitempty"`

	// Env specifies environment variables for the AIService
	// +kubebuilder:validation:Optional
	Env map[string]string `json:"env,omitempty"`

	// Tolerations specifies the tolerations for the AIService pods
	// +kubebuilder:validation:Optional
	Tolerations []corev1.Toleration `json:"tolerations,omitempty"`

	// Affinity defines pod affinity and anti-affinity rules
	// +kubebuilder:validation:Optional
	Affinity corev1.Affinity `json:"affinity,omitempty"`

	// Resources defines the compute resources for the AIService pods
	// +kubebuilder:validation:Optional
	Resources corev1.ResourceRequirements `json:"resources,omitempty"`

	// Metrics configuration for monitoring
	// +kubebuilder:validation:Optional
	Metrics MetricsConfig `json:"metrics,omitempty"`

	// MTLS configuration for secure communication
	// +kubebuilder:validation:Optional
	MTLS MTLSConfig `json:"mtls,omitempty"`

	// ServiceTemplate is a template used to create Kubernetes services
	// +kubebuilder:validation:Optional
	ServiceTemplate corev1.Service `json:"serviceTemplate"`

	// ClusterDomain is the cluster domain for service DNS
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="cluster.local"
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$`
	ClusterDomain string `json:"clusterDomain,omitempty"`
}

// MetricsConfig defines the metrics configuration for monitoring
type MetricsConfig struct {
	// Enabled determines whether to scrape metrics
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=false
	Enabled bool `json:"enabled,omitempty"`

	// Path is the metrics endpoint path, default "/metrics"
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="/metrics"
	// +kubebuilder:validation:Pattern=`^/.*$`
	Path string `json:"path,omitempty"`

	// Port is the metrics port number
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=9090
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=65535
	Port int32 `json:"port,omitempty"`
}

// MTLSConfig defines the mTLS configuration for secure communication
type MTLSConfig struct {
	// Enabled determines whether to enable mTLS
	// +kubebuilder:validation:Required
	Enabled bool `json:"enabled"`

	// IssuerRef references the cert-manager Issuer for certificate generation
	// +kubebuilder:validation:Optional
	IssuerRef cmmeta.ObjectReference `json:"issuerRef,omitempty"`

	// SecretName is the name of the Secret containing TLS certificates
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MinLength=1
	SecretName string `json:"secretName,omitempty"`

	// DNSNames is the list of DNS names for the certificate
	// +kubebuilder:validation:Optional
	DNSNames []string `json:"dnsNames,omitempty"`

	// Termination specifies where TLS is terminated: "operator" or "mesh"
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="operator"
	// +kubebuilder:validation:Enum=operator;mesh
	Termination string `json:"termination,omitempty"`
}

// AIServiceStatus defines the observed state of AIService
type AIServiceStatus struct {
	SchemaJobId        string             `json:"schemaJobId,omitempty"`
	VectorDbStatus     string             `json:"vectorDbStatus,omitempty"`
	PlatformStatus     string             `json:"platformStatus,omitempty"`
	Conditions         []metav1.Condition `json:"conditions,omitempty"`
	ObservedGeneration int64              `json:"observedGeneration,omitempty"`
}

// AIService is the Schema for the aiservices API
// +k8s:openapi-gen=true
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:path=aiservices,scope=Namespaced,shortName=saia;aiservice
// +kubebuilder:printcolumn:name="Ready",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status",description="Service ready status"
// +kubebuilder:printcolumn:name="Replicas",type="integer",JSONPath=".spec.replicas",description="Number of replicas"
// +kubebuilder:printcolumn:name="Platform",type="string",JSONPath=".spec.aiPlatformRef.name",description="AI Platform reference"
// +kubebuilder:printcolumn:name="VectorDB",type="string",JSONPath=".status.vectorDbStatus",priority=1,description="VectorDB status"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp",description="Age of resource"
type AIService struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   AIServiceSpec   `json:"spec,omitempty"`
	Status AIServiceStatus `json:"status,omitempty"`
}

//+kubebuilder:object:root=true

// AIServiceList contains a list of AIService
type AIServiceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []AIService `json:"items"`
}

func init() {
	SchemeBuilder.Register(&AIService{}, &AIServiceList{})
}
