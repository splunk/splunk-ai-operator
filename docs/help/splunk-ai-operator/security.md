# Security and networking

Use the controls in this page together with your organization’s Kubernetes and Splunk security
standards.

## Credentials and secrets

- Store object-storage, registry, and Splunk credentials in Kubernetes Secrets or the approved
  secret-management system.
- Create referenced Secrets in the same namespace as the `AIPlatform` unless a field explicitly
  documents another scope. For internal Splunk, follow the namespace-local Secret naming rule in
  [Configure Splunk integration](splunk-integration.md#internal-splunk).
- Grant service accounts only the permissions required by their workloads.
- Avoid putting tokens or passwords in manifests committed to source control.
- Rotate credentials according to your organization’s policy.

The current Ray reconciliation path reads static object-storage credentials from a Secret and
snapshots them into an operator-generated `RayService` and ConfigMap. Treat those generated
resources as sensitive, restrict their RBAC, and prefer release-supported workload identity where
available. Secret-only handling of static Ray object-storage credentials requires an operator code
change.

## TLS

Leave `AIPlatform.spec.ingress` disabled. External Ray and Weaviate exposure is not supported for
customer use in this release because the operator does not add authentication or authorization to
those routes. TLS on a separately deployed SAIA or SLIM Ingress, Route, or proxy protects incoming
client traffic only; it does not modify CA trust for outbound Splunk connections.

For SAIA and SLIM issuer validation over HTTPS, the certificate subject alternative name must
match the DNS name or IP address in the configured issuer URL. The certificate chain must terminate
at a CA trusted by both workload images. This release exposes neither a custom issuer CA-bundle
field nor a supported setting to disable issuer certificate verification. A deliberately insecure
one-off client request can help diagnose a certificate problem, but it is not a supported
production configuration.

## Network controls

Restrict access to:

- Kubernetes API and operator webhooks.
- AI Platform service ports.
- Splunk management port `8089`.
- Object storage and private registry endpoints.
- Ingress endpoints exposed to users.

Network policies and security groups should allow only the required source and destination
traffic. Validate each required direction from its actual source network. A node or installer
laptop test does not prove that a pod, browser, or external Splunk host has the same route.

## Issuer and endpoint validation

For AI-tier CMP authentication, the operator writes the configured issuer URLs to the generated
SAIA and SLIM `SPLUNK_ISSUERS` allowlists. It does not generate an issuer-to-endpoint mapping.
Splunk's `oauth2_settings.issuer_uri`, the JWT `iss` claim, the configured trusted issuer, and the
reachable management URL must all match exactly. For HTTPS, the certificate must cover that URL's
host name or IP address and chain to a trusted certificate authority.

Each issuer expands both the authentication trust boundary and the set of management hosts that
the workloads can contact. Configure only controlled Splunk endpoints and limit egress to those
destinations.

## Release security boundaries

- The operator is cluster-scoped and uses cluster-wide RBAC. `watchNamespace` is not a namespace
  isolation control in this release.
- External Ray and Weaviate exposure through `AIPlatform.spec.ingress` is not supported. Leave it
  disabled and use a separately secured Service, ingress, Route, or proxy for SAIA and SLIM.
- HEC/OpenTelemetry export is not supported in this release. Keep the OpenTelemetry workload
  sidecar disabled.

## Air-gapped environments

Treat image and model-artifact transfer as a controlled supply-chain process:

- Mirror only approved, versioned images.
- Verify image digests where supported.
- Keep the bill of materials with the deployment package.
- Scan transferred artifacts according to policy.
- Do not add uncontrolled outbound exceptions to the cluster firewall.
