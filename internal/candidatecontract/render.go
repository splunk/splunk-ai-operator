package candidatecontract

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/slim"
	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

type Snapshot struct {
	Revision            int                    `json:"revision"`
	Profile             string                 `json:"profile"`
	Scope               string                 `json:"scope"`
	Qualification       string                 `json:"qualification"`
	MatrixPairStatus    string                 `json:"matrixPairStatus"`
	OperatorEnvironment map[string]string      `json:"operatorEnvironment"`
	RuntimePrefix       string                 `json:"runtimePrefix"`
	PlatformURLInput    string                 `json:"platformUrlInput"`
	AITK                Component              `json:"aitk"`
	Resources           []runtime.RawExtension `json:"resources"`
}

// The operator resolves images from process environment. Serialize offline
// render calls, restore that environment, and never read Kubernetes credentials.
var renderMu sync.Mutex

func Render(m *Manifest, profile string, matrix *Matrix) (*Snapshot, error) {
	return renderWithPlatformURL(m, profile, matrix, "")
}

func renderWithPlatformURL(m *Manifest, profile string, matrix *Matrix, platformURL string) (*Snapshot, error) {
	if err := m.Validate(); err != nil {
		return nil, err
	}
	if profile != "cpuOnly" && profile != "fullfeature" {
		return nil, fieldError("profile")
	}
	status, err := m.MatrixStatus(matrix)
	if err != nil {
		return nil, err
	}
	renderMu.Lock()
	defer renderMu.Unlock()
	for key, value := range m.OperatorEnvironment() {
		previous, exists := os.LookupEnv(key)
		if err := os.Setenv(key, value); err != nil {
			return nil, fieldError("operatorEnvironment." + key)
		}
		defer func() {
			if exists {
				_ = os.Setenv(key, previous)
			} else {
				_ = os.Unsetenv(key)
			}
		}()
	}
	scheme := runtime.NewScheme()
	for _, add := range []func(*runtime.Scheme) error{aiv1.AddToScheme, corev1.AddToScheme, appsv1.AddToScheme, batchv1.AddToScheme, autoscalingv2.AddToScheme, monitoringv1.AddToScheme, certmanagerv1.AddToScheme} {
		if err := add(scheme); err != nil {
			return nil, fmt.Errorf("render.scheme: %w", err)
		}
	}
	const namespace = "candidate-validation"
	carrier := m.Spec.Components["launchpadCarrier"]
	platform := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "candidate", Namespace: namespace, UID: "offline-platform"},
		Spec:       aiv1.AIPlatformSpec{Profile: aiv1.AIPlatformProfile(profile), Features: []aiv1.FeatureSpec{{Name: "agentruntime", Provider: carrier.Provider}, {Name: "slim"}}},
	}
	if profile == "fullfeature" {
		platform.Status.RayServiceName = "candidate-ray-head"
		platform.Status.Conditions = []metav1.Condition{{Type: "RayServiceStatusReady", Status: metav1.ConditionTrue}}
		if platformURL == "" {
			platformURL = "http://candidate-ray-head.candidate-validation.svc.cluster.local:8000"
		}
	}
	runtimeService := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "candidate-agentruntime-" + carrier.Provider, Namespace: namespace, UID: "offline-runtime"},
		Spec: aiv1.AIServiceSpec{
			Feature:               aiv1.FeatureSpec{Name: "agentruntime", Provider: carrier.Provider},
			RuntimeVersion:        m.Spec.RuntimeVersion,
			CheckpointDbSecretRef: m.Spec.Contract.SecretKeys.Name,
			AIPlatformRef:         corev1.ObjectReference{Name: platform.Name, Namespace: namespace},
			AIPlatformUrl:         platformURL,
		},
	}
	slimService := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "candidate-slim", Namespace: namespace, UID: "offline-slim"},
		Spec:       aiv1.AIServiceSpec{Feature: aiv1.FeatureSpec{Name: "slim"}, AIPlatformRef: corev1.ObjectReference{Name: platform.Name, Namespace: namespace}, AIPlatformUrl: platformURL},
	}
	if profile == "cpuOnly" {
		slimService.Spec.AgentRuntimeUrl = agentruntime.ServiceURL(runtimeService.Name, namespace, "")
	}
	// Synthetic credentials satisfy startup rendering only. They are never
	// returned in the snapshot and no PostgreSQL process is started or contacted.
	secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: m.Spec.Contract.SecretKeys.Name, Namespace: namespace}, Type: corev1.SecretTypeOpaque, Data: map[string][]byte{}}
	for _, key := range requiredSecretKeys {
		secret.Data[key] = []byte("offline-placeholder")
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(&aiv1.AIService{}, &aiv1.AIPlatform{}, &batchv1.Job{}).WithObjects(platform, runtimeService, slimService, secret).Build()
	ctx := context.Background()
	runtimeHandler := &agentruntime.AgentRuntimeReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(50)}
	err = runtimeHandler.Reconcile(ctx, runtimeService)
	if err == nil || !strings.Contains(err.Error(), "waiting for completion") {
		return nil, fmt.Errorf("render.schemaSetup: expected schema Job gate")
	}
	job := &batchv1.Job{}
	if err := c.Get(ctx, client.ObjectKey{Name: runtimeService.Status.SchemaJobId, Namespace: namespace}, job); err != nil {
		return nil, fmt.Errorf("render.schemaSetup: %w", err)
	}
	// This is a render fixture, not evidence of migration execution.
	job.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
	if err := c.Status().Update(ctx, job); err != nil {
		return nil, fmt.Errorf("render.schemaSetup: %w", err)
	}
	if err := runtimeHandler.Reconcile(ctx, runtimeService); err != nil {
		return nil, fmt.Errorf("render.runtime: %w", err)
	}
	slimHandler := &slim.SlimReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(50)}
	if err := slimHandler.Reconcile(ctx, slimService); err != nil {
		return nil, fmt.Errorf("render.slim: %w", err)
	}
	result := &Snapshot{Revision: m.Spec.Revision, Profile: profile, Scope: "offline operator render; schema Job completion simulated; no cluster, registry, database, or product calls", Qualification: "pending", MatrixPairStatus: status, OperatorEnvironment: m.OperatorEnvironment(), RuntimePrefix: m.Spec.Contract.RuntimeAPI.Prefix, AITK: m.Spec.Components["aitk"]}
	result.PlatformURLInput = platformURL
	for _, kind := range []string{"runtimeDeployment", "runtimeService", "schemaJob", "slimDeployment", "slimService"} {
		var object client.Object
		var name string
		switch kind {
		case "runtimeDeployment":
			object = &appsv1.Deployment{}
			name = runtimeService.Name + "-agentruntime-deployment"
		case "runtimeService":
			object = &corev1.Service{}
			name = runtimeService.Name + "-svc"
		case "schemaJob":
			object = &batchv1.Job{}
			name = job.Name
		case "slimDeployment":
			object = &appsv1.Deployment{}
			name = slimService.Name + "-slim-deployment"
		case "slimService":
			object = &corev1.Service{}
			name = slimService.Name + "-slim-service"
		}
		if err := c.Get(ctx, types.NamespacedName{Name: name, Namespace: namespace}, object); err != nil {
			return nil, fmt.Errorf("render.%s: %w", kind, err)
		}
		gvks, _, err := scheme.ObjectKinds(object)
		if err != nil || len(gvks) == 0 {
			return nil, fieldError("render.kind")
		}
		object.GetObjectKind().SetGroupVersionKind(gvks[0])
		object.SetResourceVersion("")
		// Remove simulated status from published resources.
		if j, ok := object.(*batchv1.Job); ok {
			j.Status = batchv1.JobStatus{}
		}
		result.Resources = append(result.Resources, runtime.RawExtension{Object: object})
	}
	if err := result.Check(m); err != nil {
		return nil, err
	}
	return result, nil
}

// Check compares actual handler output to the selected external contract.
func (s *Snapshot) Check(m *Manifest) error {
	var runtimeDeployment, slimDeployment *appsv1.Deployment
	var runtimeService, slimService *corev1.Service
	for _, resource := range s.Resources {
		switch object := resource.Object.(type) {
		case *appsv1.Deployment:
			if strings.Contains(object.Name, "agentruntime") {
				runtimeDeployment = object
			} else {
				slimDeployment = object
			}
		case *corev1.Service:
			if strings.Contains(object.Name, "agentruntime") {
				runtimeService = object
			} else {
				slimService = object
			}
		case *batchv1.Job:
			if len(object.Spec.Template.Spec.Containers) != 1 {
				return fieldError("render.schemaSetup.containers")
			}
			container := object.Spec.Template.Spec.Containers[0]
			if container.Image != m.Spec.Components["schemaSetup"].Image || len(container.Args) != 1 || !strings.Contains(container.Args[0], "-v ON_ERROR_STOP=1 -f "+m.Spec.Contract.SchemaEntryPoint.SQLPath) {
				return fieldError("render.schemaSetup")
			}
			if !secretReference(container, m.Spec.Contract.SecretKeys.Name) {
				return fieldError("render.schemaSetup.envFrom")
			}
		}
	}
	if runtimeDeployment == nil || slimDeployment == nil || runtimeService == nil || slimService == nil {
		return fieldError("render.resources")
	}
	if len(runtimeDeployment.Spec.Template.Spec.Containers) != 1 || len(slimDeployment.Spec.Template.Spec.Containers) != 1 || len(runtimeDeployment.Spec.Template.Spec.InitContainers) != 1 {
		return fieldError("render.containers")
	}
	runtimeContainer := runtimeDeployment.Spec.Template.Spec.Containers[0]
	slimContainer := slimDeployment.Spec.Template.Spec.Containers[0]
	if runtimeContainer.Image != m.Spec.Components["runtimeBase"].Image {
		return fieldError("render.runtime.image")
	}
	init := runtimeDeployment.Spec.Template.Spec.InitContainers[0]
	if init.Image != m.Spec.Components["launchpadCarrier"].Image || len(init.Args) != 1 || !strings.Contains(init.Args[0], "/payload/. /shared-packages/") {
		return fieldError("render.runtime.initContainers")
	}
	if slimContainer.Image != m.Spec.Components["slim"].Image {
		return fieldError("render.slim.image")
	}
	if !secretReference(runtimeContainer, m.Spec.Contract.SecretKeys.Name) {
		return fieldError("render.runtime.envFrom")
	}
	env := envMap(runtimeContainer)
	if env["AGENT_MODULE"] != m.Spec.Components["launchpadCarrier"].AgentModule || env["PYTHONPATH"] != "/shared-packages" {
		return fieldError("render.runtime.env")
	}
	if _, exists := env["AGENT_LOADERS"]; exists {
		return fieldError("render.runtime.env.AGENT_LOADERS")
	}
	for key := range env {
		if strings.HasPrefix(key, "PG_") || key == "DATABASE_URL" {
			return fieldError("render.runtime.secretValues")
		}
	}
	for _, container := range []corev1.Container{runtimeContainer, slimContainer} {
		for _, probe := range []*corev1.Probe{container.StartupProbe, container.LivenessProbe, container.ReadinessProbe} {
			if probe == nil || probe.HTTPGet == nil || probe.HTTPGet.Path != m.Spec.Contract.ReadinessAndHealth.Path || probe.HTTPGet.Port.IntVal != 8080 {
				return fieldError("render.probes")
			}
		}
	}
	if len(runtimeContainer.Ports) != 2 || len(slimContainer.Ports) != 2 || runtimeContainer.Ports[0].ContainerPort != m.Spec.Contract.RuntimeAPI.HTTPPort || runtimeContainer.Ports[1].ContainerPort != m.Spec.Contract.RuntimeAPI.MetricsPort || slimContainer.Ports[0].ContainerPort != m.Spec.Contract.SlimAPI.HTTPPort || slimContainer.Ports[1].ContainerPort != m.Spec.Contract.SlimAPI.MetricsPort {
		return fieldError("render.ports")
	}
	if runtimeService.Spec.Type != corev1.ServiceTypeClusterIP {
		return fieldError("render.runtime.service.type")
	}
	if len(runtimeService.Spec.Selector) == 0 {
		return fieldError("render.runtime.service.selector")
	}
	for key, value := range runtimeService.Spec.Selector {
		if runtimeDeployment.Spec.Template.Labels[key] != value {
			return fieldError("render.runtime.service.selector")
		}
	}
	if len(slimService.Spec.Selector) == 0 {
		return fieldError("render.slim.service.selector")
	}
	for key, value := range slimService.Spec.Selector {
		if slimDeployment.Spec.Template.Labels[key] != value {
			return fieldError("render.slim.service.selector")
		}
	}
	env = envMap(slimContainer)
	url, hasRuntime := env["AI_TIER_AGENT_RUNTIME_URL"]
	platform, hasPlatform := env["PLATFORM_URL"]
	if !hasRuntime || url != "http://"+runtimeService.Name+"."+runtimeService.Namespace+".svc.cluster.local:8080" {
		return fieldError("render.slim.env.AI_TIER_AGENT_RUNTIME_URL")
	}
	expectedPlatformURL := strings.TrimSuffix(strings.TrimRight(s.PlatformURLInput, "/"), "/ai-platform-models/v1")
	if !hasPlatform || platform != expectedPlatformURL {
		return fieldError("render.slim.env.PLATFORM_URL")
	}
	return nil
}

func secretReference(c corev1.Container, name string) bool {
	for _, source := range c.EnvFrom {
		if source.SecretRef != nil && source.SecretRef.Name == name {
			return true
		}
	}
	return false
}
func envMap(c corev1.Container) map[string]string {
	result := map[string]string{}
	for _, env := range c.Env {
		result[env.Name] = env.Value
	}
	return result
}
