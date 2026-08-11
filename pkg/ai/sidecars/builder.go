package sidecars

import (
	"context"
	"encoding/json"
	"fmt"
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
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	syaml "sigs.k8s.io/yaml"
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
		sc.SplunkCustomResourceRef.Name == "" &&
		sc.SecretRef.Name == "" &&
		sc.VaultFilePath == "" {
		return nil
	}

	if sc.SecretRef.Name == "" {
		return fmt.Errorf("sidecars.otel requires a Kubernetes secretRef; vault-backed telemetry is not yet supported for the OTel collector path")
	}

	// seed or update the ConfigMap
	if err := s.reconcileOtelConfigMap(ctx, p); err != nil {
		return fmt.Errorf("reconcile otel configmap: %w", err)
	}

	// load raw YAML
	cm := &corev1.ConfigMap{}
	name := fmt.Sprintf("%s-otel-config", p.Name)
	if err := s.Client.Get(ctx, types.NamespacedName{Name: name, Namespace: p.Namespace}, cm); err != nil {
		return fmt.Errorf("get ConfigMap %q: %w", name, err)
	}
	raw := []byte(cm.Data["otel-config.yaml"])

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

// reconcileOtelConfigMap bootstraps a `<CR>-otel-config` ConfigMap on first create.
// Endpoint remains a backward-compatible HEC fallback for that initial render.
// Existing ConfigMaps are migrated only when HECEndpoint is explicit; Endpoint
// is now the management/JWKS URL and must not overwrite a user-managed HEC URL.
func (s *Builder) reconcileOtelConfigMap(ctx context.Context, p *aiApi.AIPlatform) error {
	logger := log.FromContext(ctx)
	// Use V(1) for verbose logging - reduces noise
	logger.V(1).Info("Reconciling OpenTelemetry ConfigMap")

	cmName := fmt.Sprintf("%s-otel-config", p.Name)
	cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: cmName, Namespace: p.Namespace}}

	_, err := controllerutil.CreateOrUpdate(ctx, s.Client, cm, func() error {
		if cm.Data == nil {
			cm.Data = map[string]string{}
		}
		if existing, exists := cm.Data["otel-config.yaml"]; !exists {
			content := s.renderOtelConf(ctx, p)
			yamlBytes, err := syaml.Marshal(content)
			if err != nil {
				return fmt.Errorf("marshaling otel config: %w", err)
			}
			cm.Data["otel-config.yaml"] = string(yamlBytes)
		} else if p.Spec.SplunkConfiguration.HECEndpoint != "" {
			updated, err := updateOtelHECEndpoint(existing, p.Spec.SplunkConfiguration.HECEndpoint)
			if err != nil {
				return err
			}
			cm.Data["otel-config.yaml"] = updated
		}
		return controllerutil.SetOwnerReference(p, cm, s.Scheme)
	})
	if err != nil {
		return fmt.Errorf("create/update otel-config ConfigMap: %w", err)
	}
	return nil
}

func effectiveHECEndpoint(sc aiApi.SplunkConfigurationSpec) string {
	if sc.HECEndpoint != "" {
		return sc.HECEndpoint
	}
	return sc.Endpoint
}

const operatorManagedSplunkCAFile = "/etc/splunk-ca/ca.crt"

// updateOtelHECEndpoint migrates only operator-managed fields on the Splunk HEC
// exporter. Existing ConfigMaps may contain user customizations, so the rest of
// the collector configuration is preserved. The legacy CA path is removed only
// when it exactly matches the mount previously managed by this operator. With
// no desired CA reference in this API version, newly generated HTTPS settings
// opt into verification bypass while existing explicit policy is preserved.
// HTTP carries no operator-generated TLS settings.
func updateOtelHECEndpoint(configYAML, hecBase string) (string, error) {
	var config map[string]interface{}
	if err := syaml.Unmarshal([]byte(configYAML), &config); err != nil {
		return "", fmt.Errorf("parsing existing otel config: %w", err)
	}
	exportersValue, exists := config["exporters"]
	if !exists {
		return configYAML, nil
	}
	exporters, ok := exportersValue.(map[string]interface{})
	if !ok {
		return "", fmt.Errorf("existing otel config has malformed exporters map")
	}
	splunkHECValue, exists := exporters["splunk_hec"]
	if !exists {
		return configYAML, nil
	}
	splunkHEC, ok := splunkHECValue.(map[string]interface{})
	if !ok {
		return "", fmt.Errorf("existing otel config has malformed splunk_hec exporter")
	}
	changed := false
	desired := fmt.Sprintf("%s/services/collector", hecBase)
	if current, _ := splunkHEC["endpoint"].(string); current != desired {
		splunkHEC["endpoint"] = desired
		changed = true
	}

	isHTTPS := strings.HasPrefix(strings.ToLower(hecBase), "https://")
	tlsConfig, hasTLS := splunkHEC["tls"].(map[string]interface{})
	if hasTLS {
		removedManagedCA := false
		if caFile, _ := tlsConfig["ca_file"].(string); caFile == operatorManagedSplunkCAFile {
			delete(tlsConfig, "ca_file")
			removedManagedCA = true
			changed = true
		}

		if isHTTPS {
			// If a custom CA remains, preserve its verification policy. When the
			// operator-managed CA is removed, restore the historical no-CA
			// fail-open behavior because its paired false value was also generated
			// by the operator. Otherwise preserve any explicit policy (including
			// false) and default only when the key is absent.
			if _, hasCAFile := tlsConfig["ca_file"]; !hasCAFile {
				_, hasSkipVerify := tlsConfig["insecure_skip_verify"]
				if skipVerify, _ := tlsConfig["insecure_skip_verify"].(bool); removedManagedCA && !skipVerify {
					tlsConfig["insecure_skip_verify"] = true
					changed = true
				} else if !removedManagedCA && !hasSkipVerify {
					tlsConfig["insecure_skip_verify"] = true
					changed = true
				}
			}
		} else if _, ok := tlsConfig["insecure_skip_verify"].(bool); removedManagedCA && ok {
			// The legacy operator emitted ca_file and insecure_skip_verify as a
			// pair. Remove that paired policy for HTTP regardless of its boolean
			// value; there is no TLS handshake to configure.
			delete(tlsConfig, "insecure_skip_verify")
			changed = true
		} else if skipVerify, ok := tlsConfig["insecure_skip_verify"].(bool); ok && skipVerify {
			// This key is emitted by renderOtelConf for HTTPS without a CA. It is
			// meaningless on an effective HTTP listener, so remove only that
			// known generated value and retain all other custom TLS fields.
			delete(tlsConfig, "insecure_skip_verify")
			changed = true
		}

		if len(tlsConfig) == 0 {
			delete(splunkHEC, "tls")
			changed = true
		}
	} else if isHTTPS {
		splunkHEC["tls"] = map[string]interface{}{"insecure_skip_verify": true}
		changed = true
	}

	if !changed {
		return configYAML, nil
	}
	yamlBytes, err := syaml.Marshal(config)
	if err != nil {
		return "", fmt.Errorf("marshaling migrated otel config: %w", err)
	}
	return string(yamlBytes), nil
}

// renderOtelConf builds the OpenTelemetry Collector config map data.
func (s *Builder) renderOtelConf(ctx context.Context, cr *aiApi.AIPlatform) map[string]interface{} {
	secret := &corev1.Secret{}
	key := types.NamespacedName{Name: cr.Spec.SplunkConfiguration.SecretRef.Name, Namespace: cr.Namespace}
	if err := s.Client.Get(ctx, key, secret); err != nil {
		return map[string]interface{}{"error": fmt.Sprintf("loading secret %q: %v", key.Name, err)}
	}

	token, ok := secret.Data["hec_token"]
	if !ok {
		return map[string]interface{}{"error": "hec_token field not found in secret"}
	}

	// HEC ingestion and management/JWKS are separate Splunk listeners. Keep
	// HECEndpoint scoped to OTel; Endpoint remains the JWT issuer used by
	// SAIA/Slim. The fallback preserves pre-existing custom resources.
	hecBase := effectiveHECEndpoint(cr.Spec.SplunkConfiguration)
	endpoint := fmt.Sprintf("%s/services/collector", hecBase)
	metricsIndexName, exists := os.LookupEnv("SPLUNK_METRICS_INDEX_NAME")
	if !exists {
		metricsIndexName = "_metrics"
	}
	splunkHECExporter := map[string]interface{}{
		"token":               string(token),
		"endpoint":            endpoint,
		"source":              "otel",
		"sourcetype":          "otel",
		"index":               metricsIndexName,
		"disable_compression": false,
		"timeout":             "10s",
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
	}
	if strings.HasPrefix(strings.ToLower(hecBase), "https://") {
		splunkHECExporter["tls"] = map[string]interface{}{"insecure_skip_verify": true}
	}
	return map[string]interface{}{
		"exporters": map[string]interface{}{
			"splunk_hec": splunkHECExporter,
		},
		"processors": map[string]interface{}{"batch": map[string]interface{}{}},
		"receivers": map[string]interface{}{
			"prometheus": map[string]interface{}{
				"config": map[string]interface{}{
					"scrape_configs": []map[string]interface{}{
						{
							"job_name":        fmt.Sprintf("%s-job", cr.Name),
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
