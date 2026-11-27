// Package upgrade checks whether the installed AgentRuntime resources can be
// handed to a controller that enforces network policies.
package upgrade

import (
	"context"
	"errors"
	"fmt"
	"net/url"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	rayoutils "github.com/ray-project/kuberay/ray-operator/controllers/ray/utils"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	networkingv1 "k8s.io/api/networking/v1"
	policyv1 "k8s.io/api/policy/v1"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/validation/field"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	platformCRDName = "aiplatforms.ai.splunk.com"
	serviceCRDName  = "aiservices.ai.splunk.com"
)

// CheckCluster performs the read-only preflight against the release's cluster.
func CheckCluster(ctx context.Context, cfg *rest.Config) error {
	scheme := runtime.NewScheme()
	for _, add := range []func(*runtime.Scheme) error{
		aiv1.AddToScheme, apiextensionsv1.AddToScheme, networkingv1.AddToScheme, policyv1.AddToScheme,
	} {
		if err := add(scheme); err != nil {
			return err
		}
	}
	reader, err := client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		return fmt.Errorf("create upgrade preflight client: %w", err)
	}
	return check(ctx, reader)
}

func check(ctx context.Context, reader client.Reader) error {
	platformCRD, err := getCRD(ctx, reader, platformCRDName)
	if err != nil {
		return err
	}
	serviceCRD, err := getCRD(ctx, reader, serviceCRDName)
	if err != nil {
		return err
	}
	var platforms aiv1.AIPlatformList
	if platformCRD != nil {
		if err := reader.List(ctx, &platforms); err != nil {
			return fmt.Errorf("list saved AIPlatforms: %w", err)
		}
	}
	var services aiv1.AIServiceList
	if serviceCRD != nil {
		if err := reader.List(ctx, &services); err != nil {
			return fmt.Errorf("list saved AIServices: %w", err)
		}
	}

	// The controller reads a generated child's policy from its owning platform.
	// Older children can still carry a stale copy or have no policy field.
	type managedChild struct {
		platform *aiv1.AIPlatform
		provider string
	}
	managed := make(map[client.ObjectKey]managedChild)
	platformsByKey := make(map[client.ObjectKey]*aiv1.AIPlatform)
	var problems []error
	for i := range platforms.Items {
		platform := &platforms.Items[i]
		if platform.DeletionTimestamp != nil {
			continue
		}
		platformsByKey[client.ObjectKeyFromObject(platform)] = platform
		for j, feature := range platform.Spec.Features {
			if feature.Name != "agentruntime" {
				continue
			}
			child := client.ObjectKey{
				Namespace: platform.Namespace,
				Name:      agentruntime.FeatureAIServiceName(platform.Name, feature.Provider),
			}
			managed[child] = managedChild{platform, feature.Provider}
			path := field.NewPath("spec", "features").Index(j).Child("networkPolicy")
			if err := validatePolicy(feature.NetworkPolicy, path, false, true, platform); err != nil {
				problems = append(problems, fmt.Errorf("AIPlatform %s: %w", client.ObjectKeyFromObject(platform), err))
			}
		}
	}

	// Check generated names even when an earlier controller has yet to create
	// the corresponding AIService. Existing customer resources are left alone.
	existing := make(map[client.ObjectKey]*aiv1.AIService)
	runtimeServices := make([]*aiv1.AIService, 0, len(services.Items))
	for i := range services.Items {
		service := &services.Items[i]
		key := client.ObjectKeyFromObject(service)
		existing[key] = service
		if service.DeletionTimestamp != nil || service.Spec.Feature.Name != "agentruntime" {
			continue
		}
		runtimeServices = append(runtimeServices, service)
		child, generated := managed[key]
		if generated && service.Spec.Feature.Provider == child.provider && controlledByPlatform(service, child.platform) {
			continue
		}
		reference := service.Spec.AIPlatformRef
		if reference.Namespace == "" {
			reference.Namespace = service.Namespace
		}
		routePlatform := platformsByKey[client.ObjectKey{Namespace: reference.Namespace, Name: reference.Name}]
		path := field.NewPath("spec", "features", "networkPolicy")
		if err := validatePolicy(service.Spec.Feature.NetworkPolicy, path, true, service.Spec.Metrics.Enabled, routePlatform); err != nil {
			problems = append(problems, fmt.Errorf("AIService %s: %w", key, err))
		} else if err := validateManagedRayURL(service, routePlatform); err != nil {
			problems = append(problems, fmt.Errorf("AIService %s: %w", key, err))
		}
	}
	if len(managed) == 0 && len(runtimeServices) == 0 {
		return nil
	}

	if !hasNetworkPolicySchema(platformCRD, true) || !hasNetworkPolicySchema(serviceCRD, false) {
		return errors.New("stage the updated AIPlatform and AIService CRDs before upgrading the operator")
	}
	for key, child := range managed {
		if service, found := existing[key]; found {
			if !controlledByPlatform(service, child.platform) || service.Spec.Feature.Name != "agentruntime" ||
				service.Spec.Feature.Provider != child.provider || service.DeletionTimestamp != nil {
				problems = append(problems, fmt.Errorf("AIService %s conflicts with the AgentRuntime managed by AIPlatform %s", key, client.ObjectKeyFromObject(child.platform)))
			}
		} else if err := checkOwnership(ctx, reader, key, nil); err != nil {
			problems = append(problems, err)
		}
	}
	for _, service := range runtimeServices {
		if err := checkOwnership(ctx, reader, client.ObjectKeyFromObject(service), service); err != nil {
			problems = append(problems, err)
		}
	}
	return errors.Join(problems...)
}

func controlledByPlatform(service *aiv1.AIService, platform *aiv1.AIPlatform) bool {
	owner := metav1.GetControllerOf(service)
	return owner != nil && owner.APIVersion == aiv1.GroupVersion.String() && owner.Kind == "AIPlatform" &&
		owner.Name == platform.Name && owner.UID == platform.UID
}

// A standalone runtime can supply its own model origin. Validate its routing
// against the same stable Service name the controller uses for its allowlist.
func validateManagedRayURL(service *aiv1.AIService, platform *aiv1.AIPlatform) error {
	if !service.Spec.Feature.NetworkPolicy.ManagedRay || service.Spec.AIPlatformUrl == "" {
		return nil
	}
	headName, err := rayoutils.GenerateHeadServiceName(rayoutils.RayServiceCRD, rayv1.RayClusterSpec{}, platform.Name)
	if err != nil {
		return errors.New("managedRay could not resolve the RayService head Service name")
	}
	domain := service.Spec.ClusterDomain
	if domain == "" {
		domain = "cluster.local"
	}
	origin, err := url.Parse(service.Spec.AIPlatformUrl)
	expected := fmt.Sprintf("%s.%s.svc.%s", headName, platform.Namespace, domain)
	if err != nil || origin.Hostname() != expected || origin.Port() != "8000" {
		return errors.New("managedRay requires spec.aiPlatformUrl to use the referenced AIPlatform's head Service on port 8000")
	}
	return nil
}

func validatePolicy(cfg *aiv1.AgentRuntimeNetworkPolicy, path *field.Path, requireSLIM, metricsEnabled bool, routePlatform *aiv1.AIPlatform) error {
	if cfg == nil {
		return field.Required(path, "save the AgentRuntime allowlist before upgrading the operator")
	}
	errs := cfg.Validate(path, requireSLIM)
	errs = append(errs, cfg.ValidateMetrics(path, metricsEnabled)...)
	if cfg.ManagedRay && (routePlatform == nil || routePlatform.Spec.ResolvedProfile() != aiv1.AIPlatformProfileFullFeature) {
		errs = append(errs, field.Invalid(path.Child("managedRay"), true, "requires a fullfeature AIPlatform"))
	}
	return errs.ToAggregate()
}

func getCRD(ctx context.Context, reader client.Reader, name string) (*apiextensionsv1.CustomResourceDefinition, error) {
	var crd apiextensionsv1.CustomResourceDefinition
	err := reader.Get(ctx, client.ObjectKey{Name: name}, &crd)
	if apierrors.IsNotFound(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read CustomResourceDefinition %s: %w", name, err)
	}
	return &crd, nil
}

func hasNetworkPolicySchema(crd *apiextensionsv1.CustomResourceDefinition, platform bool) bool {
	if crd == nil || crd.DeletionTimestamp != nil {
		return false
	}
	for _, version := range crd.Spec.Versions {
		if version.Name != aiv1.GroupVersion.Version || !version.Served || version.Schema == nil || version.Schema.OpenAPIV3Schema == nil {
			continue
		}
		spec := version.Schema.OpenAPIV3Schema.Properties["spec"]
		features := spec.Properties["features"]
		if platform {
			if features.Items == nil || features.Items.Schema == nil {
				return false
			}
			features = *features.Items.Schema
		}
		policy := features.Properties["networkPolicy"]
		return policy.Type == "object" &&
			policy.Properties["dns"].Type == "object" &&
			policy.Properties["postgresql"].Type == "object" &&
			policy.Properties["slim"].Type == "object" &&
			policy.Properties["metrics"].Type == "object" &&
			policy.Properties["runtimeEgress"].Type == "array" &&
			policy.Properties["metricsDisabled"].Type == "boolean" &&
			policy.Properties["managedRay"].Type == "boolean"
	}
	return false
}

func checkOwnership(ctx context.Context, reader client.Reader, key client.ObjectKey, service *aiv1.AIService) error {
	runtimePolicy, schemaPolicy, budget := agentruntime.ManagedResourceNames(key.Name)
	objects := []struct {
		kind string
		name string
		obj  client.Object
	}{
		{"NetworkPolicy", runtimePolicy, &networkingv1.NetworkPolicy{}},
		{"NetworkPolicy", schemaPolicy, &networkingv1.NetworkPolicy{}},
		{"PodDisruptionBudget", budget, &policyv1.PodDisruptionBudget{}},
	}
	var problems []error
	for _, object := range objects {
		objectKey := client.ObjectKey{Namespace: key.Namespace, Name: object.name}
		err := reader.Get(ctx, objectKey, object.obj)
		switch {
		case apierrors.IsNotFound(err):
		case err != nil:
			problems = append(problems, fmt.Errorf("read %s %s: %w", object.kind, objectKey, err))
		case service == nil || !metav1.IsControlledBy(object.obj, service):
			problems = append(problems, fmt.Errorf("%s %s already exists and is not controlled by AIService %s", object.kind, objectKey, key))
		}
	}
	return errors.Join(problems...)
}
