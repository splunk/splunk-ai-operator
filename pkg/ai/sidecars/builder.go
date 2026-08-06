package sidecars

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"reflect"
	"strings"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	syaml "sigs.k8s.io/yaml"
)

const (
	otelConfigDataKey              = "otel-config.yaml"
	otelConfigManagementAnnotation = "ai.splunk.com/otel-config-management"
	otelConfigVersionAnnotation    = "ai.splunk.com/otel-config-version"
	otelConfigHashAnnotation       = "ai.splunk.com/otel-config-hash"
	otelConfigManaged              = "managed"
	otelConfigUserManaged          = "user"
	// Version 1 is the unannotated legacy format. Bump this value whenever
	// the operator-generated config schema or security defaults change.
	otelConfigVersion = "2"
)

// Sidecar encapsulates RayService generation logic.
type Builder struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
	ai       *aiApi.AIPlatform
}

// New returns a new Builder for the given AIPlatform instance.
func New(client client.Client, scheme *runtime.Scheme, recorder record.EventRecorder, ai *aiApi.AIPlatform) *Builder {
	return &Builder{
		Client:   client,
		ai:       ai,
		Scheme:   scheme,
		Recorder: recorder,
	}
}

// Reconcile orchestrates individual sidecar reconcilers
func (s *Builder) Reconcile(ctx context.Context, p *aiApi.AIPlatform) error {
	if err := s.reconcileEnvoyConfig(ctx, p); err != nil {
		return err
	}
	if err := s.reconcileOpenTelemetryCollector(ctx, p); err != nil {
		return err
	}
	if err := s.reconcilePrometheusRule(ctx, p); err != nil {
		return err
	}
	if err := s.reconcilePodMonitor(ctx, p); err != nil {
		return err
	}

	return nil
}

// createOrUpdateConfigMap is a helper to create or patch a ConfigMap owned by the RayService
func (s *Builder) createOrUpdateConfigMap(
	ctx context.Context,
	name string,
	data map[string]string,
) error {
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: s.ai.Namespace,
		},
		Data: data,
	}
	if err := controllerutil.SetControllerReference(s.ai, cm, s.Scheme); err != nil {
		return err
	}

	found := &corev1.ConfigMap{}
	err := s.Get(ctx, types.NamespacedName{Name: name, Namespace: s.ai.Namespace}, found)
	if apierrors.IsNotFound(err) {
		return s.Create(ctx, cm)
	} else if err != nil {
		return err
	}

	if !reflect.DeepEqual(found.Data, data) {
		found.Data = data
		return s.Update(ctx, found)
	}
	return nil
}

func ResolveImage(key, defaultValue string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	if defaultValue == "" {
		defaultValue = "otel/opentelemetry-collector-contrib:0.122.1"
	}
	return defaultValue
}

// reconcileEnvoyConfig ensures the Envoy sidecar ConfigMap exists and is up-to-date
func (s *Builder) reconcileEnvoyConfig(ctx context.Context, p *aiApi.AIPlatform) error {
	if !p.Spec.Sidecars.Envoy {
		return nil
	}

	cmName := fmt.Sprintf("%s-envoy-config", p.Name)
	data := map[string]string{
		"envoy.yaml": renderEnvoyConf(),
	}
	return s.createOrUpdateConfigMap(ctx, cmName, data)
}

// reconcileOpenTelemetryCollector ensures an Otel Collector CR exists in sidecar mode
// using YAML→JSON conversion and CreateOrUpdate for idempotency.
func (s *Builder) reconcileOpenTelemetryCollector(ctx context.Context, p *aiApi.AIPlatform) error {
	if !p.Spec.Sidecars.Otel {
		return nil
	}

	sc := p.Spec.SplunkConfiguration
	if sc.Endpoint == "" &&
		sc.HECEndpoint == "" &&
		sc.SplunkCustomResourceRef.Name == "" &&
		sc.SecretRef.Name == "" &&
		sc.VaultFilePath == "" {
		return nil
	}

	if sc.SecretRef.Name == "" {
		return fmt.Errorf("sidecars.otel requires a Kubernetes secretRef; vault-backed telemetry is not yet supported for the OTel collector path")
	}

	// Seed or update the ConfigMap. Recognized endpoint-only legacy configs are
	// fail-closed in place and accompanied by a Warning Event, but remain
	// nonfatal so unrelated AIPlatform reconciliation is not blocked.
	if err := s.reconcileOtelConfigMap(ctx, p); err != nil {
		return fmt.Errorf("reconcile otel configmap: %w", err)
	}

	// load raw YAML
	cm := &corev1.ConfigMap{}
	name := fmt.Sprintf("%s-otel-config", p.Name)
	if err := s.Client.Get(ctx, types.NamespacedName{Name: name, Namespace: p.Namespace}, cm); err != nil {
		return fmt.Errorf("get ConfigMap %q: %w", name, err)
	}
	raw := []byte(cm.Data[otelConfigDataKey])

	// YAML → JSON
	jsonBytes, err := syaml.YAMLToJSON(raw)
	if err != nil {
		return fmt.Errorf("yaml to json conversion: %w", err)
	}

	// unmarshal into map[string]interface{}
	var cfg map[string]interface{}
	if err := json.Unmarshal(jsonBytes, &cfg); err != nil {
		return fmt.Errorf("json unmarshal: %w", err)
	}

	// construct spec
	specMap := map[string]interface{}{
		"mode":  "sidecar",
		"image": ResolveImage("RELATED_IMAGE_OTEL_COLLECTOR", s.ai.Spec.Images.OTelImage),
		"env": []map[string]interface{}{
			{"name": "SPLUNK_ACCESS_TOKEN", "valueFrom": map[string]interface{}{"secretKeyRef": map[string]interface{}{"name": s.ai.Spec.SplunkConfiguration.SecretRef.Name, "key": "hec_token"}}},
			{"name": "POD_NAME", "valueFrom": map[string]interface{}{"fieldRef": map[string]interface{}{"fieldPath": "metadata.name"}}},
			{"name": "NAMESPACE", "valueFrom": map[string]interface{}{"fieldRef": map[string]interface{}{"fieldPath": "metadata.namespace"}}},
			{"name": "CLUSTER_NAME", "value": s.ai.Spec.ClusterDomain},
		},
		"config": cfg,
	}

	// Mount the same CACertRef Secret SAIA/SLIM already trust (AIP-4614 Part
	// C), so the OTel sidecar can verify Splunk's HEC certificate. Absent
	// CACertRef, renderOtelConf relies on the collector image's system trust
	// store (see below) — correct only for a publicly trusted HEC certificate.
	if ref := p.Spec.SplunkConfiguration.CACertRef; ref != nil && ref.Name != "" {
		key := ref.Key
		if key == "" {
			key = "ca.crt"
		}
		specMap["volumes"] = []map[string]interface{}{
			{
				"name": "splunk-ca",
				// Project only the CA key, not the whole Secret — CACertRef may
				// point at a leaf-cert Secret (e.g. the installer's
				// ai-splunk-server-tls) that also holds tls.key, which must
				// never land in this container's filesystem.
				"secret": map[string]interface{}{
					"secretName": ref.Name,
					"items":      []map[string]interface{}{{"key": key, "path": key}},
				},
			},
		}
		specMap["volumeMounts"] = []map[string]interface{}{
			{"name": "splunk-ca", "mountPath": "/etc/splunk-ca", "readOnly": true},
		}
	}

	// CreateOrUpdate the Collector
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(schema.GroupVersionKind{Group: "opentelemetry.io", Version: "v1beta1", Kind: "OpenTelemetryCollector"})
	u.SetName(s.ai.Name + "-otel-coll")
	u.SetNamespace(s.ai.Namespace)

	_, err = controllerutil.CreateOrUpdate(ctx, s.Client, u, func() error {
		u.Object["spec"] = specMap
		u.SetLabels(map[string]string{"app": s.ai.Name + "-ray"})
		if len(u.GetFinalizers()) == 0 {
			u.SetFinalizers([]string{"opentelemetrycollector.opentelemetry.io/finalizer"})
		}
		return controllerutil.SetOwnerReference(s.ai, u, s.Scheme)
	})
	if err != nil {
		return fmt.Errorf("create/update OpenTelemetryCollector: %w", err)
	}
	return nil
}

// reconcileOtelConfigMap maintains the operator-generated OTel config while
// preserving user-managed ConfigMaps. New ConfigMaps carry a management mode,
// schema version, and the hash of the last content written by the operator.
// A hash mismatch means that someone edited the content after the operator's
// last write; the ConfigMap is then marked user-managed and is not overwritten.
//
// ConfigMaps created by older operator releases have no annotations. We migrate
// only canonical, platform-owned configs matching the frozen legacy schema;
// mutable operator-generated leaves (token, endpoint, index) are ignored while
// fingerprinting so Secret/spec/environment drift does not strand the old
// insecure TLS default. Anything else is conservatively classified as
// user-managed. A user may opt out explicitly with the "user" annotation.
func (s *Builder) reconcileOtelConfigMap(ctx context.Context, p *aiApi.AIPlatform) error {
	logger := log.FromContext(ctx)
	// Use V(1) for verbose logging - reduces noise
	logger.V(1).Info("Reconciling OpenTelemetry ConfigMap")

	cmName := fmt.Sprintf("%s-otel-config", p.Name)
	existing := &corev1.ConfigMap{}
	getErr := s.Client.Get(ctx, types.NamespacedName{Name: cmName, Namespace: p.Namespace}, existing)
	if getErr != nil && !apierrors.IsNotFound(getErr) {
		return fmt.Errorf("get OpenTelemetry ConfigMap %q: %w", cmName, getErr)
	}
	if getErr == nil {
		management := existing.Annotations[otelConfigManagementAnnotation]
		switch {
		case management == otelConfigUserManaged:
			ownershipChanged, ownershipErr := relinquishOtelConfigOwnership(existing, p, s.Scheme)
			if ownershipErr != nil {
				return fmt.Errorf("relinquishing user-managed OpenTelemetry ConfigMap %q ownership: %w", cmName, ownershipErr)
			}
			if ownershipChanged {
				if err := s.Client.Update(ctx, existing); err != nil {
					return fmt.Errorf("relinquishing user-managed OpenTelemetry ConfigMap %q ownership: %w", cmName, err)
				}
			}
			if _, exists := existing.Data[otelConfigDataKey]; !exists {
				return fmt.Errorf("user-managed ConfigMap %q is missing %q", cmName, otelConfigDataKey)
			}
			return nil
		case management != "" && management != otelConfigManaged:
			markOtelConfigUserManaged(existing)
			if _, err := relinquishOtelConfigOwnership(existing, p, s.Scheme); err != nil {
				return fmt.Errorf("relinquishing user-managed OpenTelemetry ConfigMap %q ownership: %w", cmName, err)
			}
			if err := s.Client.Update(ctx, existing); err != nil {
				return fmt.Errorf("marking OpenTelemetry ConfigMap %q user-managed: %w", cmName, err)
			}
			if _, exists := existing.Data[otelConfigDataKey]; !exists {
				return fmt.Errorf("user-managed ConfigMap %q is missing %q", cmName, otelConfigDataKey)
			}
			logger.Info("Preserving OpenTelemetry ConfigMap with unknown management annotation", "configMap", cmName, "value", management)
			return nil
		case management == "":
			legacy, legacyErr := isOwnedLegacyOtelConfig(existing, p, s.Scheme)
			if legacyErr != nil {
				return fmt.Errorf("classifying OpenTelemetry ConfigMap %q: %w", cmName, legacyErr)
			}
			if !legacy {
				markOtelConfigUserManaged(existing)
				if _, err := relinquishOtelConfigOwnership(existing, p, s.Scheme); err != nil {
					return fmt.Errorf("relinquishing user-managed OpenTelemetry ConfigMap %q ownership: %w", cmName, err)
				}
				if err := s.Client.Update(ctx, existing); err != nil {
					return fmt.Errorf("marking OpenTelemetry ConfigMap %q user-managed: %w", cmName, err)
				}
				if _, exists := existing.Data[otelConfigDataKey]; !exists {
					return fmt.Errorf("user-managed ConfigMap %q is missing %q", cmName, otelConfigDataKey)
				}
				logger.Info("Preserving pre-existing user-managed OpenTelemetry ConfigMap", "configMap", cmName)
				return nil
			}
		}
	}

	content, err := s.renderOtelConf(ctx, p)
	if err != nil {
		// Existing CRs admitted before hecEndpoint became mandatory can still
		// have an unannotated, operator-generated config containing the old
		// insecure TLS default. Even when we cannot render the new config (for
		// example, until the user supplies hecEndpoint), fail closed immediately
		// instead of leaving that collector with certificate verification off.
		// This deliberately changes only the known legacy TLS stanza; the
		// endpoint remains untouched until an explicit HECEndpoint is supplied.
		if getErr == nil {
			securedLegacy, secureErr := s.secureLegacyOtelConfig(ctx, p, existing)
			if secureErr != nil {
				return fmt.Errorf("rendering otel config: %v; securing legacy config: %w", err, secureErr)
			}
			if securedLegacy {
				logger.Info("Using fail-closed legacy OpenTelemetry config while waiting for an explicit HEC endpoint", "configMap", cmName)
				if s.Recorder != nil {
					s.Recorder.Eventf(p, corev1.EventTypeWarning, "LegacyHECEndpointRequired",
						"Secured the legacy OTel exporter in ConfigMap %s but preserved its existing endpoint. Set spec.splunkConfiguration.hecEndpoint explicitly; endpoint is the management/JWKS URL and is not used as a new-config fallback.", cmName)
				}
				// Continue so reconcileOpenTelemetryCollector copies the secured
				// ConfigMap into the live Collector spec. The Warning Event keeps the
				// migration visible without blocking unrelated platform stages.
				return nil
			}
		}
		return fmt.Errorf("rendering otel config: %w", err)
	}
	yamlBytes, err := syaml.Marshal(content)
	if err != nil {
		return fmt.Errorf("marshaling otel config: %w", err)
	}
	desiredYAML := string(yamlBytes)

	cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: cmName, Namespace: p.Namespace}}
	missingUserConfigData := false

	_, err = controllerutil.CreateOrUpdate(ctx, s.Client, cm, func() error {
		operatorManaged := false
		if cm.Data == nil {
			cm.Data = map[string]string{}
		}
		if cm.Annotations == nil {
			cm.Annotations = map[string]string{}
		}

		existingYAML, exists := cm.Data[otelConfigDataKey]
		management := cm.Annotations[otelConfigManagementAnnotation]
		switch {
		case management == otelConfigUserManaged:
			// Explicit opt-out: preserve the ConfigMap byte-for-byte.
			if !exists {
				missingUserConfigData = true
			}
		case management != "" && management != otelConfigManaged:
			// Unknown values are never an invitation to overwrite user data.
			markOtelConfigUserManaged(cm)
			logger.Info("Preserving OpenTelemetry ConfigMap with unknown management annotation", "configMap", cmName, "value", management)
			if !exists {
				missingUserConfigData = true
			}
		case !exists:
			// A ConfigMap created between the read above and CreateOrUpdate is
			// pre-existing user state, not a blank object we are free to adopt.
			if cm.ResourceVersion != "" {
				markOtelConfigUserManaged(cm)
				missingUserConfigData = true
			} else {
				setManagedOtelConfig(cm, desiredYAML)
				operatorManaged = true
			}
		case management == otelConfigManaged:
			lastAppliedHash := cm.Annotations[otelConfigHashAnnotation]
			if lastAppliedHash != "" && lastAppliedHash != otelConfigHash(existingYAML) {
				// Content drift after our last write is an intentional user edit.
				markOtelConfigUserManaged(cm)
				logger.Info("Preserving user-edited OpenTelemetry ConfigMap", "configMap", cmName)
			} else {
				// A missing hash with an explicit "managed" annotation means the
				// user is asking the operator to (re-)adopt this ConfigMap.
				setManagedOtelConfig(cm, desiredYAML)
				operatorManaged = true
			}
		case management == "":
			legacyMetadata, legacyErr := hasLegacyOtelConfigMetadata(cm, p, s.Scheme)
			legacy := false
			if legacyErr == nil && legacyMetadata {
				legacy, legacyErr = isLegacyOperatorOtelConfig(existingYAML, content, p)
			}
			if legacyErr != nil {
				logger.Info("Preserving unrecognized OpenTelemetry ConfigMap", "configMap", cmName, "reason", legacyErr.Error())
				markOtelConfigUserManaged(cm)
			} else if legacy {
				setManagedOtelConfig(cm, desiredYAML)
				operatorManaged = true
				logger.Info("Migrated legacy operator-generated OpenTelemetry ConfigMap", "configMap", cmName, "version", otelConfigVersion)
			} else {
				markOtelConfigUserManaged(cm)
				logger.Info("Preserving pre-existing user-managed OpenTelemetry ConfigMap", "configMap", cmName)
			}
		}
		// Only operator-managed content is lifecycle-owned by AIPlatform. User-
		// managed content relinquishes this platform's reference while preserving
		// unrelated owners, so deleting AIPlatform cannot garbage-collect config
		// that the operator explicitly promised to preserve.
		if operatorManaged {
			return controllerutil.SetOwnerReference(p, cm, s.Scheme)
		}
		_, relinquishErr := relinquishOtelConfigOwnership(cm, p, s.Scheme)
		return relinquishErr
	})
	if err != nil {
		return fmt.Errorf("create/update otel-config ConfigMap: %w", err)
	}
	if missingUserConfigData {
		return fmt.Errorf("user-managed ConfigMap %q is missing %q", cmName, otelConfigDataKey)
	}
	return nil
}

// relinquishOtelConfigOwnership removes only the AIPlatform owner reference
// that this reconciler would set. Other lifecycle owners are left untouched.
func relinquishOtelConfigOwnership(cm *corev1.ConfigMap, p *aiApi.AIPlatform, scheme *runtime.Scheme) (bool, error) {
	hasPlatformOwner, err := controllerutil.HasOwnerReference(cm.OwnerReferences, p, scheme)
	if err != nil || !hasPlatformOwner {
		return false, err
	}
	if err := controllerutil.RemoveOwnerReference(p, cm, scheme); err != nil {
		return false, err
	}
	return true, nil
}

// renderOtelConf builds the OpenTelemetry Collector config map data.
func (s *Builder) renderOtelConf(ctx context.Context, cr *aiApi.AIPlatform) (map[string]interface{}, error) {
	secret := &corev1.Secret{}
	key := types.NamespacedName{Name: cr.Spec.SplunkConfiguration.SecretRef.Name, Namespace: cr.Namespace}
	if err := s.Client.Get(ctx, key, secret); err != nil {
		return nil, fmt.Errorf("loading secret %q: %w", key.Name, err)
	}

	token, ok := secret.Data["hec_token"]
	if !ok {
		return nil, fmt.Errorf("hec_token field not found in secret %q", key.Name)
	}

	// HECEndpoint (port 8088) is the ingestion URL. Endpoint is the Splunk
	// management/JWKS listener (normally port 8089) and is deliberately never
	// used as a fallback: doing so can send telemetry to the wrong listener.
	hecBase := cr.Spec.SplunkConfiguration.HECEndpoint
	if hecBase == "" {
		return nil, fmt.Errorf("splunkConfiguration.hecEndpoint must be set for the OTel sidecar to ship telemetry")
	}
	endpoint := fmt.Sprintf("%s/services/collector", hecBase)
	metricsIndexName, exists := os.LookupEnv("SPLUNK_METRICS_INDEX_NAME")
	if !exists {
		metricsIndexName = "_metrics"
	}

	// Verify the HEC certificate against the same CA SAIA/SLIM trust when
	// CACertRef is set (mounted at /etc/splunk-ca by the caller). Absent
	// CACertRef, default to verifying against the collector image's system
	// trust store (insecure_skip_verify: false) rather than silently skipping
	// verification — correct for a publicly trusted certificate, and fails
	// loudly (connection refused/cert error) instead of silently accepting
	// any certificate when the deployment actually needs a private CA.
	tlsConfig := otelTLSConfig(cr.Spec.SplunkConfiguration.CACertRef)

	return buildOtelConfig(cr.Name, string(token), endpoint, metricsIndexName, tlsConfig), nil
}

func otelTLSConfig(ref *aiApi.CABundleRef) map[string]interface{} {
	tlsConfig := map[string]interface{}{"insecure_skip_verify": false}
	if ref != nil && ref.Name != "" {
		key := ref.Key
		if key == "" {
			key = "ca.crt"
		}
		tlsConfig["ca_file"] = "/etc/splunk-ca/" + key
	}
	return tlsConfig
}

func buildOtelConfig(platformName, token, endpoint, metricsIndexName string, tlsConfig map[string]interface{}) map[string]interface{} {
	return map[string]interface{}{
		"exporters": map[string]interface{}{
			"splunk_hec": map[string]interface{}{
				"token":               token,
				"endpoint":            endpoint,
				"source":              "otel",
				"sourcetype":          "otel",
				"index":               metricsIndexName,
				"disable_compression": false,
				"timeout":             "10s",
				"tls":                 tlsConfig,
				"splunk_app_name":     "OpenTelemetry-Collector Splunk Exporter",
				"splunk_app_version":  "v0.0.1",
				"heartbeat":           map[string]interface{}{"interval": "30s"},
				"telemetry": map[string]interface{}{
					"enabled": true,
					"extra_attributes": map[string]interface{}{
						"custom_key":   "custom_value",
						"dataset_name": "SplunkCloudBeaverStack",
					},
					"override_metrics_names": map[string]interface{}{
						"otelcol_exporter_splunkhec_heartbeats_failed": "app_heartbeats_failed_total",
						"otelcol_exporter_splunkhec_heartbeats_sent":   "app_heartbeats_success_total",
					},
				},
			},
		},
		"processors": map[string]interface{}{"batch": map[string]interface{}{}},
		"receivers": map[string]interface{}{
			"prometheus": map[string]interface{}{
				"config": map[string]interface{}{
					"scrape_configs": []map[string]interface{}{
						{
							"job_name":        fmt.Sprintf("%s-job", platformName),
							"scrape_interval": "30s",
							"metrics_path":    "/metrics",
							"static_configs": []map[string]interface{}{{
								"targets": []string{"localhost:8080"},
								"labels":  map[string]string{"pod": "${POD_NAME}", "namespace": "${NAMESPACE}"},
							}},
						},
					},
				},
			},
		},
		"service": map[string]interface{}{
			"pipelines": map[string]interface{}{
				"metrics": map[string]interface{}{
					"exporters":  []string{"splunk_hec"},
					"processors": []string{"batch"},
					"receivers":  []string{"prometheus"},
				},
			},
			"telemetry": map[string]interface{}{
				"metrics": map[string]interface{}{
					"readers": []map[string]interface{}{{"pull": map[string]interface{}{"exporter": map[string]interface{}{"prometheus": map[string]interface{}{"host": "0.0.0.0", "port": 8888}}}}},
				},
			},
		},
	}
}

func setManagedOtelConfig(cm *corev1.ConfigMap, config string) {
	cm.Data[otelConfigDataKey] = config
	cm.Annotations[otelConfigManagementAnnotation] = otelConfigManaged
	cm.Annotations[otelConfigVersionAnnotation] = otelConfigVersion
	cm.Annotations[otelConfigHashAnnotation] = otelConfigHash(config)
}

func markOtelConfigUserManaged(cm *corev1.ConfigMap) {
	if cm.Annotations == nil {
		cm.Annotations = map[string]string{}
	}
	cm.Annotations[otelConfigManagementAnnotation] = otelConfigUserManaged
	delete(cm.Annotations, otelConfigVersionAnnotation)
	delete(cm.Annotations, otelConfigHashAnnotation)
}

func otelConfigHash(config string) string {
	return fmt.Sprintf("%x", sha256.Sum256([]byte(config)))
}

// isLegacyOperatorOtelConfig recognizes configs emitted by old versions of
// this builder. It first tries exact content generated from current inputs,
// then falls back to a strict structural fingerprint that ignores only the
// fields the old operator generated from mutable inputs (token, endpoint and
// metrics index). The call site additionally requires the AIPlatform owner
// reference and exactly one data entry. Non-canonical YAML, comments, extra
// fields and changes to any operator-static field remain user-managed.
func isLegacyOperatorOtelConfig(existingYAML string, desired map[string]interface{}, p *aiApi.AIPlatform) (bool, error) {
	candidates := []map[string]interface{}{desired}

	// Releases before TLS verification was made secure emitted true whenever
	// no private CA was configured.
	if ref := p.Spec.SplunkConfiguration.CACertRef; ref == nil || ref.Name == "" {
		legacyTLS, err := cloneOtelConfig(desired)
		if err != nil {
			return false, err
		}
		if err := setOtelExporterField(legacyTLS, "tls", map[string]interface{}{"insecure_skip_verify": true}); err != nil {
			return false, err
		}
		candidates = append(candidates, legacyTLS)
	}

	// ConfigMaps generated before hecEndpoint was honored used Endpoint (the
	// management/JWKS listener) for HEC. Try both that legacy endpoint alone
	// and in combination with the legacy insecure TLS default.
	if oldBase := p.Spec.SplunkConfiguration.Endpoint; oldBase != "" {
		legacyEndpoint, err := cloneOtelConfig(desired)
		if err != nil {
			return false, err
		}
		if err := setOtelExporterField(legacyEndpoint, "endpoint", fmt.Sprintf("%s/services/collector", oldBase)); err != nil {
			return false, err
		}
		candidates = append(candidates, legacyEndpoint)

		if ref := p.Spec.SplunkConfiguration.CACertRef; ref == nil || ref.Name == "" {
			legacyEndpointAndTLS, err := cloneOtelConfig(legacyEndpoint)
			if err != nil {
				return false, err
			}
			if err := setOtelExporterField(legacyEndpointAndTLS, "tls", map[string]interface{}{"insecure_skip_verify": true}); err != nil {
				return false, err
			}
			candidates = append(candidates, legacyEndpointAndTLS)
		}
	}

	for _, candidate := range candidates {
		candidateYAML, err := syaml.Marshal(candidate)
		if err != nil {
			return false, fmt.Errorf("marshaling legacy config candidate: %w", err)
		}
		if string(candidateYAML) == existingYAML {
			return true, nil
		}
	}

	return hasLegacyOperatorOtelShape(existingYAML, p.Name)
}

func isOwnedLegacyOtelConfig(cm *corev1.ConfigMap, p *aiApi.AIPlatform, scheme *runtime.Scheme) (bool, error) {
	metadataMatches, err := hasLegacyOtelConfigMetadata(cm, p, scheme)
	if err != nil || !metadataMatches {
		return false, err
	}
	return hasLegacyOperatorOtelShape(cm.Data[otelConfigDataKey], p.Name)
}

func hasLegacyOtelConfigMetadata(cm *corev1.ConfigMap, p *aiApi.AIPlatform, scheme *runtime.Scheme) (bool, error) {
	if cm.Name != p.Name+"-otel-config" || cm.Namespace != p.Namespace ||
		len(cm.Data) != 1 || len(cm.BinaryData) != 0 ||
		len(cm.Labels) != 0 || len(cm.Annotations) != 0 ||
		len(cm.OwnerReferences) != 1 {
		return false, nil
	}
	if _, exists := cm.Data[otelConfigDataKey]; !exists {
		return false, nil
	}
	ownedByPlatform, err := controllerutil.HasOwnerReference(cm.OwnerReferences, p, scheme)
	if err != nil || !ownedByPlatform {
		return false, err
	}
	// HasOwnerReference compares GVK/name but not UID. Never adopt an orphaned
	// ConfigMap left by a deleted same-name AIPlatform.
	return p.UID != "" && cm.OwnerReferences[0].UID == p.UID, nil
}

// secureLegacyOtelConfig is the fail-closed upgrade path for an existing CR
// that cannot yet render a v2 config (most commonly because HECEndpoint is
// absent). It changes only the legacy insecure TLS stanza. Keeping the
// ConfigMap unannotated lets a later reconcile fully adopt it after the user
// supplies the newly required fields.
func (s *Builder) secureLegacyOtelConfig(ctx context.Context, p *aiApi.AIPlatform, cm *corev1.ConfigMap) (bool, error) {
	legacy, err := isOwnedLegacyOtelConfig(cm, p, s.Scheme)
	if err != nil || !legacy {
		return false, err
	}
	existingYAML := cm.Data[otelConfigDataKey]

	config := map[string]interface{}{}
	if err := syaml.Unmarshal([]byte(existingYAML), &config); err != nil {
		return false, fmt.Errorf("unmarshaling legacy config: %w", err)
	}
	exporter, err := splunkHECExporter(config)
	if err != nil {
		return false, err
	}
	tls, ok := exporter["tls"].(map[string]interface{})
	if !ok {
		return false, nil
	}
	if !reflect.DeepEqual(tls, map[string]interface{}{"insecure_skip_verify": true}) {
		// A previous fail-closed pass already secured this recognized legacy
		// config. It is safe to keep copying it to the live Collector until the
		// CR gains an explicit HEC endpoint.
		return true, nil
	}
	// Do not introduce ca_file here: reconcileOpenTelemetryCollector cannot
	// update the Collector's CA volume while rendering is invalid. System-root
	// verification is a safe, fail-closed intermediate state.
	exporter["tls"] = map[string]interface{}{"insecure_skip_verify": false}
	securedYAML, err := syaml.Marshal(config)
	if err != nil {
		return false, fmt.Errorf("marshaling secured legacy config: %w", err)
	}
	cm.Data[otelConfigDataKey] = string(securedYAML)
	if err := s.Client.Update(ctx, cm); err != nil {
		return false, fmt.Errorf("updating legacy ConfigMap %q: %w", cm.Name, err)
	}
	return true, nil
}

func hasLegacyOperatorOtelShape(existingYAML, platformName string) (bool, error) {
	config := map[string]interface{}{}
	if err := syaml.Unmarshal([]byte(existingYAML), &config); err != nil {
		return false, nil
	}

	// Old operator output was produced by syaml.Marshal. Refuse to structurally
	// adopt files with comments or alternate formatting because those are a
	// strong signal that a user intentionally edited the ConfigMap.
	canonical, err := syaml.Marshal(config)
	if err != nil {
		return false, fmt.Errorf("marshaling legacy config fingerprint: %w", err)
	}
	if string(canonical) != existingYAML {
		return false, nil
	}

	exporter, err := splunkHECExporter(config)
	if err != nil {
		return false, nil
	}
	_, tokenOK := exporter["token"].(string)
	endpoint, endpointOK := exporter["endpoint"].(string)
	_, indexOK := exporter["index"].(string)
	if !tokenOK || !endpointOK || !indexOK || !isLegacyGeneratedHECEndpoint(endpoint) {
		return false, nil
	}
	tls, ok := exporter["tls"].(map[string]interface{})
	if !ok || !isKnownGeneratedOtelTLS(tls) {
		return false, nil
	}

	const dynamicValue = "__operator_generated_dynamic_value__"
	exporter["token"] = dynamicValue
	exporter["endpoint"] = dynamicValue
	exporter["index"] = dynamicValue
	exporter["tls"] = map[string]interface{}{"insecure_skip_verify": dynamicValue}
	expected := buildOtelConfig(
		platformName,
		dynamicValue,
		dynamicValue,
		dynamicValue,
		map[string]interface{}{"insecure_skip_verify": dynamicValue},
	)

	actualJSON, err := json.Marshal(config)
	if err != nil {
		return false, fmt.Errorf("marshaling legacy config fingerprint: %w", err)
	}
	expectedJSON, err := json.Marshal(expected)
	if err != nil {
		return false, fmt.Errorf("marshaling expected legacy config fingerprint: %w", err)
	}
	return string(actualJSON) == string(expectedJSON), nil
}

func isKnownGeneratedOtelTLS(tls map[string]interface{}) bool {
	if reflect.DeepEqual(tls, map[string]interface{}{"insecure_skip_verify": true}) ||
		reflect.DeepEqual(tls, map[string]interface{}{"insecure_skip_verify": false}) {
		return true
	}
	if len(tls) != 2 || tls["insecure_skip_verify"] != false {
		return false
	}
	caFile, ok := tls["ca_file"].(string)
	secretKey := strings.TrimPrefix(caFile, "/etc/splunk-ca/")
	return ok && strings.HasPrefix(caFile, "/etc/splunk-ca/") && len(validation.IsConfigMapKey(secretKey)) == 0
}

func isLegacyGeneratedHECEndpoint(endpoint string) bool {
	parsed, err := url.ParseRequestURI(endpoint)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" ||
		parsed.RawQuery != "" || parsed.Fragment != "" {
		return false
	}
	return strings.HasSuffix(parsed.EscapedPath(), "/services/collector")
}

func splunkHECExporter(config map[string]interface{}) (map[string]interface{}, error) {
	exporters, ok := config["exporters"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("otel config has no exporters map")
	}
	exporter, ok := exporters["splunk_hec"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("otel config has no splunk_hec exporter map")
	}
	return exporter, nil
}

func cloneOtelConfig(config map[string]interface{}) (map[string]interface{}, error) {
	raw, err := json.Marshal(config)
	if err != nil {
		return nil, fmt.Errorf("marshaling otel config clone: %w", err)
	}
	clone := map[string]interface{}{}
	if err := json.Unmarshal(raw, &clone); err != nil {
		return nil, fmt.Errorf("unmarshaling otel config clone: %w", err)
	}
	return clone, nil
}

func setOtelExporterField(config map[string]interface{}, field string, value interface{}) error {
	exporters, ok := config["exporters"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("otel config has no exporters map")
	}
	splunkHEC, ok := exporters["splunk_hec"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("otel config has no splunk_hec exporter map")
	}
	splunkHEC[field] = value
	return nil
}

// renderEnvoyConf generates the Envoy configuration for the given AIPlatform.
func renderEnvoyConf() string {
	return `
    static_resources:
      clusters:
        - name: sais_backend
          connect_timeout: 0.25s
          type: STRICT_DNS
          lb_policy: ROUND_ROBIN
          load_assignment:
            cluster_name: sais_backend
            endpoints:
              - lb_endpoints:
                  - endpoint:
                      address:
                        socket_address:
                          address: 127.0.0.1  # Backend service address
                          port_value: 8080  # Backend service port

      listeners:
        - name: listener_0
          address:
            socket_address: { address: 0.0.0.0, port_value: 10000 }
          filter_chains:
            - filters:
                - name: envoy.filters.network.http_connection_manager
                  typed_config:
                    "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                    codec_type: AUTO
                    stat_prefix: ingress_http
                    route_config:
                      name: local_route
                      virtual_hosts:
                        - name: local_service
                          domains: ["*"]
                          routes:
                            - match: { prefix: "/" }
                              route:
                                cluster: sais_backend
                                timeout: 0s
                            - match: { prefix: "/testtenant" }
                              route:
                                cluster: sais_backend
                                timeout: 0s
                              typed_per_filter_config:
                                envoy.filters.http.lua:
                                  "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.LuaPerRoute
                                  source_code:
                                    inline_string: |
                                      function envoy_on_request(request_handle)
                                        -- Log request info
                                        local authorizationHeader = request_handle:headers():get("Authorization")

                                        -- Check if the Authorization header is missing
                                        if authorizationHeader == nil or authorizationHeader == "" then
                                          request_handle:logErr("Authorization header is missing")
                                          -- Send a 400 Bad Request response using correct syntax
                                          request_handle:respond(
                                            { [":status"] = "400", ["content-type"] = "text/plain" },
                                            "Bad Request: Authorization header is missing"
                                          )
                                          return
                                        end

                                        -- Extract pass4SymmKey by removing the 'Splunk ' prefix
                                        local prefix = "Splunk "
                                        if string.sub(authorizationHeader, 1, string.len(prefix)) == prefix then
                                          local pass4SymmKeyHeader = string.sub(authorizationHeader, string.len(prefix) + 1)
                                          local pass4SymmKeyEnv = os.getenv("PASS4SYMMKEY")

                                          -- Compare the extracted key with the expected key
                                          if pass4SymmKeyHeader ~= pass4SymmKeyEnv then
                                            request_handle:logErr("Invalid pass4SymmKey")
                                            -- Send a 401 Unauthorized response using correct syntax
                                            request_handle:respond(
                                              { [":status"] = "401", ["content-type"] = "text/plain" },
                                              "Unauthorized: Invalid pass4SymmKey"
                                            )
                                            return
                                          end
                                        else
                                          request_handle:logErr("Invalid Authorization header format")
                                          -- Send a 400 Bad Request response using correct syntax
                                          request_handle:respond(
                                            { [":status"] = "400", ["content-type"] = "text/plain" },
                                            "Bad Request: Invalid Authorization header format"
                                          )
                                          return
                                        end
                                      end

                                      function envoy_on_response(response_handle)
                                        -- Log when the response is sent back from /testtenant
                                        response_handle:logInfo("Goodbye from /testtenant.")
                                      end

                    http_filters:
                      - name: envoy.filters.http.lua
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
                          default_source_code:
                            inline_string: |
                              function envoy_on_request(request_handle)
                                -- Check if the request is from sais_service (you can use custom headers to identify)
                                local serviceName = request_handle:headers():get("X-Service-Name")
                                if serviceName == "sais_service" then
                                  -- Add the pass4SymmKey to the Authorization header
                                  local pass4SymmKeyEnv = os.getenv("PASS4SYMMKEY")
                                  if pass4SymmKeyEnv then
                                    local authorizationHeader = "Splunk " .. pass4SymmKeyEnv
                                    request_handle:headers():add("Authorization", authorizationHeader)
                                    request_handle:logInfo("Authorization header added to request from sais_service")
                                  else
                                    request_handle:logErr("pass4SymmKey environment variable is not set")
                                  end
                                end
                              end
                          source_codes:
                            hello.lua:
                              inline_string: |
                                function envoy_on_request(request_handle)
                                  request_handle:logInfo("Hello World.")
                                end
                            bye.lua:
                              inline_string: |
                                function envoy_on_response(response_handle)
                                  response_handle:logInfo("Bye Bye.")
                                end
                      - name: envoy.filters.http.router
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

`
}
