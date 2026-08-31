# Security and networking

Use the controls in this page together with your organization’s Kubernetes and Splunk security
standards.

## Credentials and secrets

- Store object-storage, registry, and Splunk credentials in Kubernetes Secrets or the approved
  secret-management system.
- Grant service accounts only the permissions required by their workloads.
- Avoid putting tokens or passwords in manifests committed to source control.
- Rotate credentials according to your organization’s policy.

## TLS

Ingress TLS protects client-to-ingress traffic when `spec.ingress.tls` is configured. Connections
from SAIA to a Splunk management endpoint can use the HTTPS endpoint configured for Splunk. The
standard deployment procedure does not enable TLS between the operator-managed services inside
the cluster.

Use a certificate chain trusted by the calling client or workload. Do not use disabled certificate
verification as a permanent configuration; it is useful only for isolating a certificate problem
during troubleshooting.

## Network controls

Restrict access to:

- Kubernetes API and operator webhooks.
- AI Platform service ports.
- Splunk management port `8089`.
- Object storage and private registry endpoints.
- Ingress endpoints exposed to users.

Network policies and security groups should allow only the required source and destination
traffic. Validate connectivity from the actual pod or node network where possible.

## Issuer and endpoint validation

For AI-tier CMP authentication, SAIA validates the token issuer and resolves it to a configured
Splunk endpoint. The endpoint mapping must remain within the operator-configured trusted endpoint
list. This prevents a token claim from causing an outbound request to an arbitrary host.

## Air-gapped environments

Treat image and model-artifact transfer as a controlled supply-chain process:

- Mirror only approved, versioned images.
- Verify image digests where supported.
- Keep the bill of materials with the deployment package.
- Scan transferred artifacts according to policy.
- Do not add uncontrolled outbound exceptions to the cluster firewall.
