# Customer-Managed Ingress TLS Certificate Requirements

## Purpose and boundary

This guide defines the certificate responsibilities and verification steps for
on-premises AI-Tier and Splunk AI POD deployments that expose SAIA or SLIM
through a customer-managed ingress gateway. The customer/platform team selects,
configures, and operates that gateway and provides its certificate and private
key.

The approved transport boundary is TLS from external callers to the ingress
gateway, followed by HTTP from the gateway to the SAIA and SLIM services. There
is no TLS between workloads inside the cluster. A certificate on the gateway
does not change this backend transport model, and it does not establish that the
gateway's cryptographic implementation is FIPS validated.

The operator does not issue, store, renew, or rotate the customer's ingress
certificate. These requirements apply to the customer-managed gateway. The
operator's generic `AIPlatform.spec.ingress` is a separate feature and does not
configure the SAIA or SLIM customer gateway. For the repository-backed route
inventory, see [On-Prem Customer-Managed Ingress Investigation](customer-managed-fips-ingress-requirements.md).

## Customer and platform responsibilities

The customer/platform team is responsible for:

1. Selecting the gateway DNS name or names and making them resolvable from
   every intended caller network.
2. Obtaining certificates from its approved PKI or certificate authority and
   maintaining the associated private keys in an approved secret or key
   management system.
3. Installing the certificate, private key, and required intermediate chain
   using the selected gateway's supported configuration. Keep private keys out
   of source control, Jira, test logs, and support bundles.
4. Configuring the gateway to present the certificate for the matching SNI
   hostname and to forward the required SAIA or SLIM paths to their HTTP
   backends without unintended path, query, or header changes.
5. Ensuring every intended caller trusts the issuing chain and validates the
   certificate name and validity period. Do not disable certificate
   verification to make a test pass.
6. Owning certificate issuance, renewal, revocation, replacement, and rotation
   before expiry, including any required client trust-bundle updates.
7. Applying the customer's approved TLS protocol, cipher, key, and cryptographic
   module policy at the gateway. The selected security owner must identify the
   exact approved profile; this guide does not choose protocol versions, cipher
   suites, key types, or key sizes on the customer's behalf.

AI-Tier and Splunk AI POD do not manage this certificate lifecycle. The
customer-provided gateway must forward to the deployed SAIA and SLIM Services
over HTTP on port `8080`, or use the deployment's documented HTTP Route/service
handoff. Do not add workload TLS or mTLS for this design.

## Certificate requirements

| Property | Requirement | Verification |
|---|---|---|
| Service identity | The leaf certificate must identify the exact customer gateway FQDN used by the caller. For DNS names, include the name as a `dNSName` in Subject Alternative Name (SAN); do not rely on the Common Name alone. | Inspect the presented leaf certificate and make a strict client connection using the same FQDN as SNI and the verification name. |
| Trust chain | The issuing chain must terminate at a CA trusted by the intended clients. The gateway must present the leaf and any required intermediate certificates. | Verify from each intended caller network with the customer's approved CA bundle and without insecure/skip-verification options. |
| Validity | The certificate must be within its `notBefore` and `notAfter` dates, and have sufficient remaining lifetime for the customer's renewal process. | Inspect certificate dates and test with a client whose clock is correct. |
| Server use | The certificate profile must permit TLS server authentication and comply with the issuing PKI's certificate policy. | Inspect the certificate's extended key usage and policy with the PKI/security owner. |
| Cryptography | The gateway's effective TLS configuration, key type/size, signature algorithm, and cryptographic provider must meet the customer's approved FIPS policy. | Record the effective gateway configuration and the applicable cryptographic module validation evidence. A successful HTTPS handshake alone is not evidence of FIPS operation. |
| Key custody | The private key must be protected by the customer's approved PKI/secret-management controls and readable only by the gateway components that need it. | Review gateway secret access and handling without exporting or logging the private key. |
| Renewal and rotation | The customer must have a documented renewal and rotation process that updates the gateway without an outage and maintains caller trust. | Perform the rotation check in the isolated reference test environment and record the new public certificate fingerprint and handshake result. |

RFC 9525 defines DNS service identity verification through the SAN `dNSName`
and says the Common Name is no longer a valid server identity source. See the
[RFC Editor text for RFC 9525](https://www.rfc-editor.org/rfc/rfc9525.html).
For FIPS-based TLS implementation configuration, follow the customer's current
security policy and applicable NIST guidance, such as [NIST SP 800-52 Rev. 2](https://csrc.nist.gov/pubs/sp/800/52/r2/final). NIST currently lists that publication as under review, so this guide intentionally does not copy a static cipher or key profile into customer instructions.

## Endpoint mapping

Use the deployed service names, ports, and gateway handoff for the selected
platform. The customer's gateway owns the public certificate and external TLS
endpoint.

| Caller | Gateway endpoint | Backend handoff |
|---|---|---|
| Browser using Splunk AI Assistant | `https://<saia-fqdn>/` | SAIA Service over HTTP port `8080`; preserve the SAIA API paths. |
| Splunk Enterprise using Splunk AI Toolkit outside the cluster | `https://<slim-fqdn>/tenant/slim-api/v1alpha1` | SLIM Service over HTTP port `8080`; preserve the API prefix, remaining path, query, and headers. |
| Splunk/AITK inside the cluster | Not applicable to this ingress certificate | Use the deployment-supported SLIM `ClusterIP` endpoint over HTTP; this path does not test gateway TLS. |

The default AI POD OpenShift Routes are HTTP and target the SAIA and SLIM
Services on port `8080`; they do not terminate TLS. On k0s, inspect the current
Service exposure before configuring the gateway. Do not assume a fixed
NodePort, public address, or DNS name.

## Safe verification procedure

Run these checks in the internal reference environment and later, if needed,
from each customer caller network. Use a non-production hostname and test
certificates for negative cases. Do not place private keys or bearer tokens in
the commands, logs, or evidence.

Set the gateway hostname and a CA bundle already trusted by the intended
caller:

```bash
HOST="<customer-gateway-fqdn>"
CA_BUNDLE="<path-to-approved-ca-bundle.pem>"
```

Check the presented chain, SNI selection, and DNS name using strict verification:

```bash
openssl s_client \
  -connect "${HOST}:443" \
  -servername "${HOST}" \
  -verify_hostname "${HOST}" \
  -verify_return_error \
  -CAfile "${CA_BUNDLE}" \
  -showcerts </dev/null
```

Inspect a public leaf certificate PEM obtained from the gateway's presented
chain or the customer's approved PKI export. This command reads only the public
certificate, not the private key:

```bash
LEAF_CERT_PEM="<path-to-public-leaf-certificate.pem>"
openssl x509 -in "${LEAF_CERT_PEM}" -noout \
  -subject -issuer -dates -fingerprint -sha256 \
  -ext subjectAltName -ext extendedKeyUsage
```

The `s_client` output includes the server's public certificate chain. Do not
copy or attach any private-key file. The actual cryptographic-module FIPS status
must be evidenced separately from the gateway deployment and configuration.

For an application-level positive check, use the documented health route or a
non-sensitive API operation available in the deployed image, and retain strict
certificate verification:

```bash
curl --fail --show-error --silent \
  --cacert "${CA_BUNDLE}" \
  "https://${HOST}/health"
```

The health path verifies that the selected host routes to a healthy backend;
it does not prove the gateway's FIPS mode. If the selected deployment does not
publish `/health` on that hostname, use its documented health path or test
operation instead.

### Reference-path certificate cases

Run negative cases only on an isolated internal reference gateway. Each
negative case must use a client that performs strict certificate validation.

| Case | Expected result |
|---|---|
| Valid, trusted certificate with matching SAN | TLS verification succeeds and the routed health/API check returns its expected response. |
| Expired certificate | Client verification fails because the certificate is outside its validity period. |
| Untrusted issuer or missing required intermediate | Client verification fails against the approved CA bundle. |
| Hostname mismatch | Client hostname verification fails, even if the gateway presents the certificate and completes the TLS handshake. |
| Rotation to a new valid certificate | After the gateway reloads the new certificate, strict verification succeeds; the presented public fingerprint and chain match the replacement certificate. If the issuing CA changes, confirm the planned trust-bundle update before rotation. |

For rotation, stage the new certificate and key using the gateway's supported
secret-update procedure, confirm the controller has loaded them, and repeat the
strict SNI, hostname, chain, and application checks. Confirm the old certificate
is no longer served after the documented cutover. Never compare or publish
private-key contents.

## Evidence to retain

Record only the information needed to reproduce the checks:

- platform and gateway/controller version, image reference, and immutable
  image digest;
- the gateway FQDN and the caller network used for the check;
- the presented certificate's issuer, SAN, validity dates, EKU, and SHA-256
  fingerprint;
- the trusted CA bundle source, effective TLS protocol/cipher, and gateway
  cryptographic module/FIPS validation reference;
- positive and negative case results, timestamps, and relevant sanitized
  controller/client error messages; and
- the rotated certificate's public fingerprint and successful post-rotation
  verification result.

Do not attach private keys, raw Kubernetes Secret output, bearer tokens, or full
unredacted diagnostic logs. A successful TLS test proves the observed client
and gateway behavior for that test; it does not by itself establish FIPS
validation or customer policy approval.

## Scope limits

This guide defines certificate ownership, interoperability requirements, and a
verification sequence. It does not install or manage Traefik, change customer
installation scripts, establish an organization-wide cipher/key profile, or
qualify a FIPS cryptographic module. The internal reference test still needs an
available FIPS-capable Traefik image/configuration and recorded runtime
evidence before the reference path can be called verified.

For Kubernetes `kubernetes.io/tls` Secrets, Kubernetes documents the required
`tls.crt` and `tls.key` keys but does not validate that the certificate and key
are semantically valid when the Secret is created. See [Kubernetes Secret documentation](https://kubernetes.io/docs/concepts/configuration/secret/).
