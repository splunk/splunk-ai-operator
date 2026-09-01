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

Traffic between AI-tier workloads inside the cluster uses HTTP in this release. Workload TLS and
mTLS are not supported.

When SAIA or SLIM is published through a customer-managed Ingress, Route, load balancer, or reverse
proxy, terminate TLS at that access point and forward traffic to the generated Service over HTTP.
This protects the client-to-access-point connection; it does not enable TLS inside the cluster.

HTTPS from SAIA or SLIM to an external Splunk issuer is a separate outbound connection. The host in
the configured issuer URL must match the certificate's subject alternative name, and the
certificate chain must already be trusted by the relevant workload image. Custom CA bundles and
certificate-verification overrides for external issuer connections are not supported in this
release. See [Configure Splunk integration](splunk-integration.md#tls-and-certificates).

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
