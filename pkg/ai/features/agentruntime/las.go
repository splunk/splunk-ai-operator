package agentruntime

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/cli"
	"helm.sh/helm/v3/pkg/release"
	"helm.sh/helm/v3/pkg/storage/driver"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	lasChartVersion                   = "0.3.4"
	lasChartSHA256                    = "31dab99c9b1c6ddfb8672a4a9a287a044d50bb628665c641eb2b1170833df953"
	lasOwnerLabel                     = "ai.splunk.com/aiservice-uid"
	defaultAgentRuntimeHTTPPort int32 = 8080
)

//go:embed chart/langgraph-cloud-0.3.4.tgz
var lasChartArchive []byte

// LASReconciler replaces the direct-managed agentruntime workload with LAS.
type LASReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

func (r *LASReconciler) Reconcile(ctx context.Context, ai *aiv1.AIService) error {
	if ai.Spec.Feature.LAS == nil || ai.Spec.Feature.LAS.Image.Repository == "" || ai.Spec.Feature.LAS.Image.Tag == "" || ai.Spec.Feature.LAS.AssistantID == "" {
		return r.fail(ctx, ai, "ConfigurationInvalid", errors.New("agentruntime requires las.image.repository, las.image.tag, and las.assistantId"))
	}
	if err := r.checkSecrets(ctx, ai); err != nil {
		return r.fail(ctx, ai, "DependenciesUnavailable", err)
	}
	chartDigest := sha256.Sum256(lasChartArchive)
	if hex.EncodeToString(chartDigest[:]) != lasChartSHA256 {
		return r.fail(ctx, ai, "ChartInvalid", errors.New("embedded LAS chart digest does not match the pinned chart"))
	}
	chart, err := loader.LoadArchive(bytes.NewReader(lasChartArchive))
	if err != nil || chart.Metadata.Version != lasChartVersion {
		return r.fail(ctx, ai, "ChartInvalid", fmt.Errorf("embedded LAS chart is not version %s", lasChartVersion))
	}
	config, err := r.helmConfig(ctx, ai.Namespace)
	if err != nil {
		return r.fail(ctx, ai, "HelmConfigurationFailed", err)
	}
	name := lasReleaseName(ai.Name)
	values := lasValues(ai)
	current, err := action.NewStatus(config).Run(name)
	if err != nil && !errors.Is(err, driver.ErrReleaseNotFound) {
		return r.fail(ctx, ai, "HelmStatusFailed", err)
	}
	if current != nil && current.Labels[lasOwnerLabel] != string(ai.UID) {
		return r.fail(ctx, ai, "ReleaseOwnershipConflict", fmt.Errorf("Helm release %q is not owned by this AIService", name))
	}
	replaceUninstalled := current != nil && current.Info.Status == release.StatusUninstalled
	if replaceUninstalled {
		current = nil
	}

	if current == nil {
		if err := r.setCondition(ctx, ai, metav1.ConditionUnknown, "Installing", fmt.Sprintf("Installing LAS chart %s as Helm release %s", lasChartVersion, name)); err != nil {
			return err
		}
		r.event(ai, corev1.EventTypeNormal, "LASInstalling", fmt.Sprintf("Installing Helm release %s", name))
		install := action.NewInstall(config)
		install.ReleaseName = name
		install.Namespace = ai.Namespace
		install.Replace = replaceUninstalled
		install.Labels = map[string]string{lasOwnerLabel: string(ai.UID)}
		install.Wait = true
		install.Atomic = true
		install.Timeout = 5 * time.Minute
		current, err = install.RunWithContext(ctx, chart, values)
		if err != nil {
			return r.fail(ctx, ai, "HelmInstallFailed", err)
		}
		r.event(ai, corev1.EventTypeNormal, "LASInstalled", fmt.Sprintf("Installed Helm release %s revision %d", name, current.Version))
	} else {
		needsUpgrade := !sameValues(current.Config, values) || current.Chart.Metadata.Version != lasChartVersion || current.Info.Status != release.StatusDeployed
		if !needsUpgrade {
			if err := r.checkDeployments(ctx, ai, name); apierrors.IsNotFound(err) {
				needsUpgrade = true
			}
		}
		if needsUpgrade {
			if err := r.setCondition(ctx, ai, metav1.ConditionUnknown, "Upgrading", fmt.Sprintf("Upgrading LAS Helm release %s", name)); err != nil {
				return err
			}
			r.event(ai, corev1.EventTypeNormal, "LASUpgrading", fmt.Sprintf("Upgrading Helm release %s", name))
			upgrade := action.NewUpgrade(config)
			upgrade.Namespace = ai.Namespace
			upgrade.Labels = map[string]string{lasOwnerLabel: string(ai.UID)}
			upgrade.Wait = true
			upgrade.Atomic = true
			upgrade.Timeout = 5 * time.Minute
			current, err = upgrade.RunWithContext(ctx, name, chart, values)
			if err != nil {
				return r.fail(ctx, ai, "HelmUpgradeFailed", err)
			}
			r.event(ai, corev1.EventTypeNormal, "LASUpgraded", fmt.Sprintf("Upgraded Helm release %s to revision %d", name, current.Version))
		}
	}

	if err := r.checkDeployments(ctx, ai, name); err != nil {
		return r.fail(ctx, ai, "WorkloadsNotReady", err)
	}
	if err := r.ensureStableService(ctx, ai, name); err != nil {
		return r.fail(ctx, ai, "ServiceFailed", err)
	}
	if err := r.removeLegacyResources(ctx, ai); err != nil {
		return r.fail(ctx, ai, "LegacyCleanupFailed", err)
	}
	wasReady := meta.IsStatusConditionTrue(ai.Status.Conditions, "Ready")
	if err := r.setCondition(ctx, ai, metav1.ConditionTrue, "LASReady", fmt.Sprintf("LAS Helm release %s revision %d is deployed; API and queue are ready", name, current.Version)); err != nil {
		return err
	}
	if !wasReady {
		r.event(ai, corev1.EventTypeNormal, "LASReady", fmt.Sprintf("Helm release %s revision %d is ready", name, current.Version))
	}
	return nil
}

func (r *LASReconciler) Finalize(ctx context.Context, ai *aiv1.AIService) (finalizeErr error) {
	defer func() {
		if finalizeErr != nil {
			r.event(ai, corev1.EventTypeWarning, "LASUninstallFailed", finalizeErr.Error())
		}
	}()
	config, err := r.helmConfig(ctx, ai.Namespace)
	if err != nil {
		return err
	}
	name := lasReleaseName(ai.Name)
	current, err := action.NewStatus(config).Run(name)
	if errors.Is(err, driver.ErrReleaseNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if current.Info.Status == release.StatusUninstalled {
		return nil
	}
	if current.Labels[lasOwnerLabel] != string(ai.UID) {
		return fmt.Errorf("refusing to uninstall Helm release %q: owner UID does not match AIService", name)
	}
	r.event(ai, corev1.EventTypeNormal, "LASUninstalling", fmt.Sprintf("Uninstalling Helm release %s", name))
	uninstall := action.NewUninstall(config)
	uninstall.Wait = true
	uninstall.Timeout = 5 * time.Minute
	if _, err := uninstall.Run(name); err != nil && !errors.Is(err, driver.ErrReleaseNotFound) {
		return err
	}
	r.event(ai, corev1.EventTypeNormal, "LASUninstalled", fmt.Sprintf("Uninstalled Helm release %s", name))
	return nil
}

func (r *LASReconciler) helmConfig(ctx context.Context, namespace string) (*action.Configuration, error) {
	config := new(action.Configuration)
	err := config.Init(cli.New().RESTClientGetter(), namespace, "secret", func(format string, args ...interface{}) {
		logf.FromContext(ctx).V(1).Info(fmt.Sprintf(format, args...))
	})
	return config, err
}

func lasReleaseName(serviceName string) string {
	name := "las-" + serviceName
	if len(name) <= 34 {
		return name
	}
	digest := sha256.Sum256([]byte(serviceName))
	return name[:25] + "-" + hex.EncodeToString(digest[:4])
}

func lasValues(ai *aiv1.AIService) map[string]interface{} {
	values := map[string]interface{}{
		"fullnameOverride": lasReleaseName(ai.Name) + "-langgraph-cloud",
		"images": map[string]interface{}{"apiServerImage": map[string]interface{}{
			"repository": ai.Spec.Feature.LAS.Image.Repository, "tag": ai.Spec.Feature.LAS.Image.Tag, "pullPolicy": "IfNotPresent",
		}},
		"config": map[string]interface{}{"existingSecretName": ai.Spec.Feature.LicenseSecretRef},
		"queue":  map[string]interface{}{"enabled": true},
		"apiServer": map[string]interface{}{
			"deployment": map[string]interface{}{
				"resources":      map[string]interface{}{"requests": map[string]interface{}{"cpu": "250m"}},
				"startupProbe":   map[string]interface{}{"timeoutSeconds": 5},
				"readinessProbe": map[string]interface{}{"timeoutSeconds": 5},
				"livenessProbe":  map[string]interface{}{"timeoutSeconds": 5},
			},
			"service": map[string]interface{}{"type": "ClusterIP"},
		},
		"postgres": map[string]interface{}{"external": map[string]interface{}{
			"enabled": true, "existingSecretName": ai.Spec.Feature.PostgresSecretRef,
		}},
		"redis": map[string]interface{}{"external": map[string]interface{}{
			"enabled": true, "existingSecretName": ai.Spec.Feature.RedisSecretRef,
		}},
		"mongo": map[string]interface{}{"enabled": false},
	}
	if len(ai.Spec.ImagePullSecrets) > 0 {
		refs := make([]map[string]string, 0, len(ai.Spec.ImagePullSecrets))
		for _, ref := range ai.Spec.ImagePullSecrets {
			refs = append(refs, map[string]string{"name": ref.Name})
		}
		values["images"].(map[string]interface{})["imagePullSecrets"] = refs
	}
	return values
}

func sameValues(a, b map[string]interface{}) bool {
	left, errA := json.Marshal(a)
	right, errB := json.Marshal(b)
	return errA == nil && errB == nil && bytes.Equal(left, right)
}

func (r *LASReconciler) checkSecrets(ctx context.Context, ai *aiv1.AIService) error {
	for _, ref := range []struct{ name, key string }{
		{ai.Spec.Feature.LicenseSecretRef, "langgraph_cloud_license_key"},
		{ai.Spec.Feature.PostgresSecretRef, "postgres_connection_url"},
		{ai.Spec.Feature.RedisSecretRef, "redis_connection_url"},
	} {
		if ref.name == "" {
			return fmt.Errorf("LAS Secret reference for key %s is empty", ref.key)
		}
		secret := &corev1.Secret{}
		if err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: ref.name}, secret); err != nil {
			return fmt.Errorf("LAS Secret %q unavailable: %w", ref.name, err)
		}
		if len(secret.Data[ref.key]) == 0 {
			return fmt.Errorf("LAS Secret %q is missing nonempty key %q", ref.name, ref.key)
		}
	}
	return nil
}

func (r *LASReconciler) checkDeployments(ctx context.Context, ai *aiv1.AIService, name string) error {
	for _, suffix := range []string{"-langgraph-cloud-api-server", "-langgraph-cloud-queue"} {
		deployment := &appsv1.Deployment{}
		deploymentName := name + suffix
		if err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: deploymentName}, deployment); err != nil {
			return fmt.Errorf("LAS Deployment %s unavailable: %w", deploymentName, err)
		}
		if deployment.Spec.Replicas == nil || deployment.Status.ObservedGeneration < deployment.Generation || deployment.Status.ReadyReplicas < *deployment.Spec.Replicas {
			return fmt.Errorf("LAS Deployment %s is not ready", deploymentName)
		}
	}
	return nil
}

// Preserve the AIService's established in-cluster DNS name and port while the
// old workload is replaced. The chart also provides its own API Service.
func (r *LASReconciler) ensureStableService(ctx context.Context, ai *aiv1.AIService, releaseName string) error {
	service := &corev1.Service{ObjectMeta: metav1.ObjectMeta{
		Name: agentRuntimeServiceName(ai.Name), Namespace: ai.Namespace,
	}}
	existing := &corev1.Service{}
	if err := r.Get(ctx, client.ObjectKeyFromObject(service), existing); err == nil {
		if !metav1.IsControlledBy(existing, ai) {
			return fmt.Errorf("refusing to replace Service %s: it is not controlled by this AIService", service.Name)
		}
	} else if !apierrors.IsNotFound(err) {
		return err
	}
	if err := controllerutil.SetControllerReference(ai, service, r.Scheme); err != nil {
		return err
	}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, service, func() error {
		if service.ResourceVersion != "" && !metav1.IsControlledBy(service, ai) {
			return fmt.Errorf("refusing to replace Service %s: owner changed", service.Name)
		}
		service.Spec.Type = corev1.ServiceTypeClusterIP
		service.Spec.Selector = map[string]string{
			"app.kubernetes.io/name":      "langgraph-cloud",
			"app.kubernetes.io/instance":  releaseName,
			"app.kubernetes.io/component": releaseName + "-langgraph-cloud-api-server",
		}
		service.Spec.Ports = []corev1.ServicePort{{
			Name: "http", Port: defaultAgentRuntimeHTTPPort, TargetPort: intstr.FromInt(8000),
		}}
		return nil
	})
	return err
}

func (r *LASReconciler) setCondition(ctx context.Context, ai *aiv1.AIService, status metav1.ConditionStatus, reason, message string) error {
	before := ai.DeepCopy()
	// Conditions from the former direct-managed runtime describe resources LAS no longer uses.
	ready := meta.FindStatusCondition(ai.Status.Conditions, "Ready")
	if ready == nil {
		ai.Status.Conditions = nil
	} else {
		ai.Status.Conditions = []metav1.Condition{*ready}
	}
	condition := metav1.Condition{Type: "Ready", Status: status, Reason: reason, Message: message, ObservedGeneration: ai.Generation}
	meta.SetStatusCondition(&ai.Status.Conditions, condition)
	ai.Status.ObservedGeneration = ai.Generation
	if err := r.Status().Patch(ctx, ai, client.MergeFrom(before)); err != nil {
		return err
	}
	return nil
}

func (r *LASReconciler) fail(ctx context.Context, ai *aiv1.AIService, reason string, cause error) error {
	message := cause.Error()
	if err := r.setCondition(ctx, ai, metav1.ConditionFalse, reason, message); err != nil {
		return fmt.Errorf("%s; updating AIService status: %w", message, err)
	}
	r.event(ai, corev1.EventTypeWarning, reason, message)
	return cause
}

func (r *LASReconciler) event(ai *aiv1.AIService, eventType, reason, message string) {
	if r.Recorder != nil {
		r.Recorder.Event(ai, eventType, reason, message)
	}
}
