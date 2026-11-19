package agentruntime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

type readinessFixture struct {
	ai    *aiv1.AIService
	dep   *appsv1.Deployment
	rs    *appsv1.ReplicaSet
	pods  []*corev1.Pod
	svc   *corev1.Service
	slice *discoveryv1.EndpointSlice
}

func newReadinessFixture(t *testing.T) *readinessFixture {
	t.Helper()
	ai := &aiv1.AIService{ObjectMeta: metav1.ObjectMeta{Name: "runtime", Namespace: "default", UID: "ai-uid", Generation: 3}, Spec: aiv1.AIServiceSpec{Feature: aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk"}, Replicas: 2}}
	setRuntimeCondition(ai, schemaReady, metav1.ConditionTrue, "Succeeded", "schema inputs applied")
	dep := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: ai.Name + "-agentruntime-deployment", Namespace: ai.Namespace, UID: "dep-uid", Generation: 4}, Spec: appsv1.DeploymentSpec{
		Replicas: ptr(int32(2)), Selector: &metav1.LabelSelector{MatchLabels: agentRuntimeSelectorLabels(ai)},
		Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: agentRuntimeSelectorLabels(ai)}, Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: ai.Name, Image: "runtime:test", ReadinessProbe: httpProbe("/health", 8080)}}}},
	}, Status: appsv1.DeploymentStatus{ObservedGeneration: 4, Replicas: 2, UpdatedReplicas: 2, ReadyReplicas: 2, AvailableReplicas: 2}}
	sch := buildAgentRuntimeTestScheme(t)
	require.NoError(t, controllerutil.SetControllerReference(ai, dep, sch))
	rs := &appsv1.ReplicaSet{ObjectMeta: metav1.ObjectMeta{Name: "runtime-rs", Namespace: ai.Namespace, UID: "rs-uid", Labels: agentRuntimeSelectorLabels(ai)}, Spec: appsv1.ReplicaSetSpec{Template: *dep.Spec.Template.DeepCopy()}}
	rs.Spec.Template.Labels[appsv1.DefaultDeploymentUniqueLabelKey] = "current"
	require.NoError(t, controllerutil.SetControllerReference(dep, rs, sch))
	svc := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: ServiceName(ai.Name), Namespace: ai.Namespace, UID: "svc-uid"}, Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeClusterIP, ClusterIP: "10.96.0.1", Selector: agentRuntimeSelectorLabels(ai), Ports: []corev1.ServicePort{{Name: "http", Port: 8080, TargetPort: intstr.FromInt32(8080)}}}}
	require.NoError(t, controllerutil.SetControllerReference(ai, svc, sch))
	slice := &discoveryv1.EndpointSlice{ObjectMeta: metav1.ObjectMeta{Name: "runtime-endpoints", Namespace: ai.Namespace, Labels: map[string]string{discoveryv1.LabelServiceName: svc.Name}}, AddressType: discoveryv1.AddressTypeIPv4, Ports: []discoveryv1.EndpointPort{{Name: ptr("http"), Port: ptr(int32(8080)), Protocol: ptr(corev1.ProtocolTCP)}}}
	require.NoError(t, controllerutil.SetControllerReference(svc, slice, sch))
	f := &readinessFixture{ai: ai, dep: dep, rs: rs, svc: svc, slice: slice}
	for i := 0; i < 2; i++ {
		ip := fmt.Sprintf("10.0.0.%d", i+1)
		pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: fmt.Sprintf("runtime-%d", i), Namespace: ai.Namespace, UID: types.UID(fmt.Sprintf("pod-%d", i)), Labels: agentRuntimeSelectorLabels(ai)}, Spec: *dep.Spec.Template.Spec.DeepCopy(), Status: corev1.PodStatus{
			Phase: corev1.PodRunning, PodIP: ip, PodIPs: []corev1.PodIP{{IP: ip}}, Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}}, ContainerStatuses: []corev1.ContainerStatus{{Name: ai.Name, Ready: true, State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{}}}},
		}}
		require.NoError(t, controllerutil.SetControllerReference(rs, pod, sch))
		f.pods = append(f.pods, pod)
		slice.Endpoints = append(slice.Endpoints, discoveryv1.Endpoint{Addresses: []string{ip}, Conditions: discoveryv1.EndpointConditions{Ready: ptr(true)}, TargetRef: &corev1.ObjectReference{Kind: "Pod", APIVersion: "v1", Namespace: ai.Namespace, Name: pod.Name, UID: pod.UID}})
	}
	return f
}

func (f *readinessFixture) reconciler(t *testing.T) *AgentRuntimeReconciler {
	t.Helper()
	objects := []client.Object{f.ai}
	for _, obj := range []client.Object{f.dep, f.rs, f.svc, f.slice} {
		switch o := obj.(type) {
		case *appsv1.Deployment:
			if o != nil {
				objects = append(objects, o)
			}
		case *appsv1.ReplicaSet:
			if o != nil {
				objects = append(objects, o)
			}
		case *corev1.Service:
			if o != nil {
				objects = append(objects, o)
			}
		case *discoveryv1.EndpointSlice:
			if o != nil {
				objects = append(objects, o)
			}
		}
	}
	for _, pod := range f.pods {
		objects = append(objects, pod)
	}
	scheme := buildAgentRuntimeTestScheme(t)
	c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(&aiv1.AIService{}, &appsv1.Deployment{}, &corev1.Pod{}).WithObjects(objects...).Build()
	return &AgentRuntimeReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(20)}
}

func TestRuntimeReadinessGates(t *testing.T) {
	cases := []struct {
		name         string
		mutate       func(*readinessFixture)
		kind, reason string
	}{
		{"healthy", func(f *readinessFixture) {}, "Ready", "Available"},
		{"missing deployment", func(f *readinessFixture) { f.dep = nil }, deploymentReady, "DeploymentMissing"},
		{"zero replicas", func(f *readinessFixture) { f.ai.Spec.Replicas = 0 }, deploymentReady, "ReplicaTargetMismatch"},
		{"stale deployment", func(f *readinessFixture) { f.dep.Status.ObservedGeneration-- }, deploymentReady, "DeploymentNotObserved"},
		{"partial update", func(f *readinessFixture) { f.dep.Status.UpdatedReplicas = 1 }, deploymentReady, "RolloutPending"},
		{"partial availability", func(f *readinessFixture) { f.dep.Status.AvailableReplicas = 1 }, deploymentReady, "RolloutPending"},
		{"old ready pods with new rollout", func(f *readinessFixture) { f.dep.Status.Replicas = 3 }, deploymentReady, "RolloutPending"},
		{"deployment selector", func(f *readinessFixture) { f.dep.Spec.Selector.MatchLabels = map[string]string{"app": "foreign"} }, deploymentReady, "SelectorMismatch"},
		{"old replica set", func(f *readinessFixture) { f.rs.Spec.Template.Spec.Containers[0].Image = "previous:image" }, deploymentReady, "PodsNotReady"},
		{"foreign replica set", func(f *readinessFixture) { f.rs.OwnerReferences[0].UID = "other-deployment" }, deploymentReady, "PodsNotReady"},
		{"probe failing", func(f *readinessFixture) { f.pods[0].Status.ContainerStatuses[0].Ready = false }, deploymentReady, "PodsNotReady"},
		{"pod readiness gate failing", func(f *readinessFixture) { f.pods[0].Status.Conditions[0].Status = corev1.ConditionFalse }, deploymentReady, "PodsNotReady"},
		{"missing container status", func(f *readinessFixture) { f.pods[0].Status.ContainerStatuses = nil }, deploymentReady, "PodsNotReady"},
		{"missing probe", func(f *readinessFixture) { f.pods[0].Spec.Containers[0].ReadinessProbe = nil }, deploymentReady, "PodsNotReady"},
		{"terminating pod", func(f *readinessFixture) {
			f.pods[0].DeletionTimestamp = ptr(metav1.Now())
			f.pods[0].Finalizers = []string{"test"}
		}, deploymentReady, "PodsNotReady"},
		{"missing service", func(f *readinessFixture) { f.svc = nil }, serviceReady, "ServiceMissing"},
		{"service selector", func(f *readinessFixture) { f.svc.Spec.Selector = map[string]string{"app": "foreign"} }, serviceReady, "SelectorMismatch"},
		{"headless service", func(f *readinessFixture) { f.svc.Spec.ClusterIP = corev1.ClusterIPNone }, serviceReady, "ServiceUnavailable"},
		{"service port", func(f *readinessFixture) { f.svc.Spec.Ports[0].TargetPort = intstr.FromInt32(9090) }, serviceReady, "ServicePortMismatch"},
		{"no slices", func(f *readinessFixture) { f.slice = nil }, endpointReady, "EndpointsPending"},
		{"no endpoints", func(f *readinessFixture) { f.slice.Endpoints = nil }, endpointReady, "EndpointsPending"},
		{"nonready endpoints", func(f *readinessFixture) {
			for i := range f.slice.Endpoints {
				f.slice.Endpoints[i].Conditions.Ready = ptr(false)
			}
		}, endpointReady, "EndpointsPending"},
		{"unknown endpoint readiness", func(f *readinessFixture) {
			for i := range f.slice.Endpoints {
				f.slice.Endpoints[i].Conditions.Ready = nil
			}
		}, endpointReady, "EndpointsPending"},
		{"metrics only", func(f *readinessFixture) {
			f.slice.Ports[0].Name = ptr("metrics")
			f.slice.Ports[0].Port = ptr(int32(9090))
		}, endpointReady, "EndpointsPending"},
		{"foreign service uid", func(f *readinessFixture) { f.slice.OwnerReferences[0].UID = "old-service" }, endpointReady, "EndpointSliceMismatch"},
		{"foreign pod uid", func(f *readinessFixture) { f.slice.Endpoints[0].TargetRef.UID = "old-pod" }, endpointReady, "EndpointTargetMismatch"},
		{"wrong target namespace", func(f *readinessFixture) { f.slice.Endpoints[0].TargetRef.Namespace = "other" }, endpointReady, "EndpointTargetMismatch"},
		{"wrong address", func(f *readinessFixture) { f.slice.Endpoints[0].Addresses = []string{"10.0.0.99"} }, endpointReady, "EndpointTargetMismatch"},
		{"terminating endpoints", func(f *readinessFixture) {
			for i := range f.slice.Endpoints {
				f.slice.Endpoints[i].Conditions.Terminating = ptr(true)
			}
		}, endpointReady, "EndpointsPending"},
		{"publish not ready cannot bypass probe", func(f *readinessFixture) {
			f.svc.Spec.PublishNotReadyAddresses = true
			f.pods[0].Status.ContainerStatuses[0].Ready = false
		}, deploymentReady, "PodsNotReady"},
		{"stale schema condition", func(f *readinessFixture) { f.ai.Status.Conditions[0].ObservedGeneration-- }, schemaReady, "Succeeded"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newReadinessFixture(t)
			tc.mutate(f)
			r := f.reconciler(t)
			require.NoError(t, r.observeReadiness(context.Background(), f.ai))
			c := meta.FindStatusCondition(f.ai.Status.Conditions, tc.kind)
			require.NotNil(t, c)
			assert.Equal(t, tc.reason, c.Reason)
			ready := meta.FindStatusCondition(f.ai.Status.Conditions, "Ready")
			require.NotNil(t, ready)
			assert.Equal(t, f.ai.Generation, ready.ObservedGeneration)
			want := metav1.ConditionFalse
			if tc.name == "healthy" {
				want = metav1.ConditionTrue
			}
			assert.Equal(t, want, ready.Status)
		})
	}
}

type readinessReadFailure struct{ client.Client }

func (c readinessReadFailure) List(ctx context.Context, list client.ObjectList, opts ...client.ListOption) error {
	if _, ok := list.(*discoveryv1.EndpointSliceList); ok {
		return errors.New("private-error-canary")
	}
	return c.Client.List(ctx, list, opts...)
}

func TestRuntimeReadinessObservationErrorIsNotHealthyOrLeaked(t *testing.T) {
	f := newReadinessFixture(t)
	r := f.reconciler(t)
	r.Client = readinessReadFailure{r.Client}
	require.Error(t, r.observeReadiness(context.Background(), f.ai))
	assert.Equal(t, metav1.ConditionFalse, meta.FindStatusCondition(f.ai.Status.Conditions, "Ready").Status)
	for _, c := range f.ai.Status.Conditions {
		assert.NotContains(t, c.Message, "private-error-canary")
	}
}

func TestRuntimeReadinessTransitionsAreStable(t *testing.T) {
	f := newReadinessFixture(t)
	r := f.reconciler(t)
	ctx := context.Background()
	require.NoError(t, r.observeReadiness(ctx, f.ai))
	before := f.ai.DeepCopy().Status.Conditions
	require.NoError(t, r.observeReadiness(ctx, f.ai))
	assert.Equal(t, before, f.ai.Status.Conditions)
	slice := &discoveryv1.EndpointSlice{}
	require.NoError(t, r.Get(ctx, client.ObjectKeyFromObject(f.slice), slice))
	slice.Endpoints = nil
	require.NoError(t, r.Update(ctx, slice))
	require.NoError(t, r.observeReadiness(ctx, f.ai))
	assertConditionFalse(t, f.ai.Status.Conditions, "Ready")
	slice.Endpoints = f.slice.Endpoints
	require.NoError(t, r.Update(ctx, slice))
	require.NoError(t, r.observeReadiness(ctx, f.ai))
	assertConditionTrue(t, f.ai.Status.Conditions, "Ready")
}

func installHealthyRuntime(t *testing.T, r *AgentRuntimeReconciler, ai *aiv1.AIService) {
	t.Helper()
	ctx := context.Background()
	dep := &appsv1.Deployment{}
	require.NoError(t, r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-agentruntime-deployment"}, dep))
	// Fake clients do not allocate resource UIDs or Service addresses.
	dep.UID = "healthy-deployment"
	require.NoError(t, r.Update(ctx, dep))
	dep.Status = appsv1.DeploymentStatus{ObservedGeneration: dep.Generation, Replicas: 1, UpdatedReplicas: 1, ReadyReplicas: 1, AvailableReplicas: 1}
	require.NoError(t, r.Status().Update(ctx, dep))
	rs := &appsv1.ReplicaSet{ObjectMeta: metav1.ObjectMeta{Name: ai.Name + "-rs", Namespace: ai.Namespace, UID: "healthy-rs", Labels: agentRuntimeSelectorLabels(ai)}, Spec: appsv1.ReplicaSetSpec{Template: *dep.Spec.Template.DeepCopy()}}
	require.NoError(t, controllerutil.SetControllerReference(dep, rs, r.Scheme))
	require.NoError(t, r.Create(ctx, rs))
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: ai.Name + "-pod", Namespace: ai.Namespace, UID: "healthy-pod", Labels: agentRuntimeSelectorLabels(ai)}, Spec: *dep.Spec.Template.Spec.DeepCopy(), Status: corev1.PodStatus{Phase: corev1.PodRunning, PodIP: "10.0.0.8", Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}}, ContainerStatuses: []corev1.ContainerStatus{{Name: WorkloadName(ai.Name), Ready: true, State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{}}}}}}
	require.NoError(t, controllerutil.SetControllerReference(rs, pod, r.Scheme))
	require.NoError(t, r.Create(ctx, pod))
	svc := &corev1.Service{}
	require.NoError(t, r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: ServiceName(ai.Name)}, svc))
	svc.UID = "healthy-service"
	svc.Spec.ClusterIP = "10.96.0.8"
	require.NoError(t, r.Update(ctx, svc))
	slice := &discoveryv1.EndpointSlice{ObjectMeta: metav1.ObjectMeta{Name: ai.Name + "-endpoints", Namespace: ai.Namespace, Labels: map[string]string{discoveryv1.LabelServiceName: svc.Name}}, AddressType: discoveryv1.AddressTypeIPv4, Ports: []discoveryv1.EndpointPort{{Name: ptr("http"), Port: ptr(int32(8080))}}, Endpoints: []discoveryv1.Endpoint{{Addresses: []string{pod.Status.PodIP}, Conditions: discoveryv1.EndpointConditions{Ready: ptr(true)}, TargetRef: &corev1.ObjectReference{Kind: "Pod", Namespace: ai.Namespace, Name: pod.Name, UID: pod.UID}}}}
	require.NoError(t, controllerutil.SetControllerReference(svc, slice, r.Scheme))
	require.NoError(t, r.Create(ctx, slice))
}

func TestRuntimeReadySurvivesSchemaTTLAndUnrelatedGeneration(t *testing.T) {
	r, ai, job := schemaTestReconciler(t)
	ctx := context.Background()
	job.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
	require.NoError(t, r.Status().Update(ctx, job))
	require.NoError(t, r.Reconcile(ctx, ai))
	assertConditionFalse(t, ai.Status.Conditions, "Ready")
	installHealthyRuntime(t, r, ai)
	require.NoError(t, r.Reconcile(ctx, ai))
	assertConditionTrue(t, ai.Status.Conditions, "Ready")
	logRuntimeConditions(t, "healthy", ai)
	before := ai.DeepCopy()
	require.NoError(t, r.Reconcile(ctx, ai))
	assert.Equal(t, before.ResourceVersion, ai.ResourceVersion, "unchanged readiness must not write status")
	assert.Equal(t, before.Status, ai.Status)
	require.NoError(t, r.Delete(ctx, job))
	require.NoError(t, r.Reconcile(ctx, ai))
	assertConditionTrue(t, ai.Status.Conditions, "Ready")
	logRuntimeConditions(t, "schema-job-removed-after-success", ai)
	ai.Generation++
	require.NoError(t, r.Update(ctx, ai))
	require.NoError(t, r.Reconcile(ctx, ai))
	assertConditionTrue(t, ai.Status.Conditions, "Ready")
	for _, c := range ai.Status.Conditions {
		assert.Equal(t, ai.Generation, c.ObservedGeneration)
	}
	jobs := &batchv1.JobList{}
	require.NoError(t, r.List(ctx, jobs))
	assert.Empty(t, jobs.Items)
	secret := &corev1.Secret{}
	require.NoError(t, r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: ai.Spec.CheckpointDbSecretRef}, secret))
	secret.Data["rotation"] = []byte("changed")
	require.NoError(t, r.Update(ctx, secret))
	require.ErrorContains(t, r.Reconcile(ctx, ai), "waiting for schema Job completion")
	assertConditionFalse(t, ai.Status.Conditions, "Ready")
	assert.Equal(t, metav1.ConditionUnknown, meta.FindStatusCondition(ai.Status.Conditions, deploymentReady).Status)
	assert.Empty(t, agentRuntimeSchemaStatus(t, ai).AppliedHash)
	logRuntimeConditions(t, "changed-schema-inputs", ai)
}

func logRuntimeConditions(t *testing.T, phase string, ai *aiv1.AIService) {
	t.Helper()
	raw, err := json.Marshal(struct {
		Phase      string               `json:"phase"`
		Generation int64                `json:"generation"`
		Status     aiv1.AIServiceStatus `json:"status"`
	}{phase, ai.Generation, ai.Status})
	require.NoError(t, err)
	t.Logf("conditionSnapshot=%s", raw)
}

type failingRuntimeStatusClient struct{ client.Client }
type failingRuntimeStatusWriter struct{ client.SubResourceWriter }

func (c failingRuntimeStatusClient) Status() client.SubResourceWriter {
	return failingRuntimeStatusWriter{c.Client.Status()}
}
func (w failingRuntimeStatusWriter) Update(ctx context.Context, obj client.Object, opts ...client.SubResourceUpdateOption) error {
	return apierrors.NewConflict(schema.GroupResource{Group: aiv1.GroupVersion.Group, Resource: "aiservices"}, obj.GetName(), errors.New("concurrent spec change"))
}

func TestRuntimeStatusPersistenceFailureIsReturned(t *testing.T) {
	r, ai, _ := schemaTestReconciler(t)
	ai.Generation++
	r.Client = failingRuntimeStatusClient{r.Client}
	err := r.Reconcile(context.Background(), ai)
	require.Error(t, err)
	assert.True(t, apierrors.IsConflict(err), "%v", err)
}

func TestRuntimeDeploymentPreservesControllerRevisionWithoutTemplateChurn(t *testing.T) {
	r, ai, job := schemaTestReconciler(t)
	ctx := context.Background()
	job.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
	require.NoError(t, r.Status().Update(ctx, job))
	require.NoError(t, r.Reconcile(ctx, ai))
	dep := &appsv1.Deployment{}
	key := client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-agentruntime-deployment"}
	require.NoError(t, r.Get(ctx, key, dep))
	dep.Annotations[deploymentRevisionAnnotation] = "3"
	require.NoError(t, r.Update(ctx, dep))
	before := dep.DeepCopy()
	// Upstream bookkeeping must not enter the Pod template either.
	ai.Annotations = map[string]string{deploymentRevisionAnnotation: "999"}
	require.NoError(t, r.Reconcile(ctx, ai))
	require.NoError(t, r.Get(ctx, key, dep))
	assert.Equal(t, "3", dep.Annotations[deploymentRevisionAnnotation])
	assert.Equal(t, before.Spec.Template, dep.Spec.Template)
	assert.NotContains(t, dep.Spec.Template.Annotations, deploymentRevisionAnnotation)
	assert.Equal(t, before.ResourceVersion, dep.ResourceVersion)
}
