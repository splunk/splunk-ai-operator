# Troubleshooting

Start with the custom resource status, Kubernetes events, operator logs, and the readiness of the
managed pods, Services, and endpoints. A successful reconciliation condition alone does not prove
that every application endpoint is ready.

## Platform is not ready

```bash
kubectl get aiplatform <platform-name> -n <namespace>
kubectl describe aiplatform <platform-name> -n <namespace>
kubectl get aiservice -n <namespace>
kubectl get pods,services,endpoints -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

Find failed conditions:

```bash
kubectl get aiplatform <platform-name> -n <namespace> \
  -o jsonpath='{.status.conditions}'
```

## Pods are pending

Check scheduling events and verify that the cluster has the requested CPU, memory, GPU, and
persistent storage capacity:

```bash
kubectl get pods -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
kubectl get nodes --show-labels
```

For GPU workloads, confirm that the device plugin is installed and that taints, tolerations,
labels, and affinity rules match.

If an event reports that a ServiceAccount does not exist, either remove the explicit
`serviceAccountName` override so the service can use its operator/default account, or create the
named account and required RBAC in the workload namespace. The workload namespace itself must
exist before you apply an `AIPlatform` resource.

## Image pull failures

```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl get secret -n <namespace>
```

Confirm the image name, tag or digest, registry access, and image-pull secret. In an air-gapped
environment, confirm that every required image was mirrored to the private registry.

## Object storage or model failures

Check the object-storage path, region, endpoint, credentials, and workload service-account
permissions. Confirm that the Ray workers can reach the object store from their network namespace.

## Weaviate or persistent-volume failures

```bash
kubectl get pvc -n <namespace>
kubectl describe pvc <pvc-name> -n <namespace>
kubectl get statefulset -n <namespace>
```

Confirm that the storage class exists, the requested capacity is available, and the volume access
mode is supported.

## Splunk connectivity failures

Test the exact issuer URL from a SAIA or SLIM pod network. For example, the SAIA v2 image includes
Python, so you can make a strict-TLS request from its running API container:

```bash
kubectl exec -n <namespace> \
  deployment/<aiservice-name>-saia-v2-deployment \
  -c saia-v2-api -- \
  python3 -c 'import json, urllib.request; response = urllib.request.urlopen(
    "https://<splunk-host>:8089/services/authorization/tokens-keys?output_mode=json",
    timeout=10); print(response.status, type(json.load(response)).__name__)'
```

Run the Python argument on one line if your shell does not preserve the formatting. An HTTP `200`
with a parsed JSON response confirms that the pod can route to the token-key endpoint, validate its
certificate, and receive JSON. Inspect the returned token-key data separately when authentication
still fails. A node or laptop test does not prove pod connectivity because routing and network
policies can differ.

As a diagnostic only, a request with certificate verification disabled can distinguish a routing
problem from a certificate problem. It is not a service configuration workaround. This release
does not expose a custom external-issuer CA-bundle field; production requires a certificate chain
already trusted by the workload image.

## JWT issuer or token errors

For AI-tier authentication, verify:

1. Decode a newly issued token without logging or sharing it and record its exact `iss` value.
2. Confirm that the exact URL appears in `AIPlatform.spec.splunkConfiguration.trustedIssuers`, or
   equals the endpoint derived from the internal Splunk reference.
3. Confirm that the operator-generated allowlist contains it:

   ```bash
   kubectl get configmap <aiservice-name>-saia-config -n <namespace> \
     -o jsonpath='{.data.SPLUNK_ISSUERS}{"\n"}'
   ```

4. Confirm that the running v2 API process has the same value:

   ```bash
   kubectl exec -n <namespace> \
     deployment/<aiservice-name>-saia-v2-deployment \
     -c saia-v2-api -- printenv SPLUNK_ISSUERS
   ```

5. Confirm that the issuer's native token-key route is reachable from the SAIA and SLIM workload
   network with strict TLS verification.
6. Obtain a fresh token after changing Splunk's configured issuer.

The operator does not generate `SPLUNK_ISSUER_ENDPOINTS` or translate one issuer identity to a
different management endpoint.

## Browser cannot call SAIA

The browser calls the published SAIA base URL. The front-door SAIA nginx Service routes v1 and v2
API paths internally; customers do not select a separate Kubernetes v2 endpoint. Check:

- ingress or proxy routing;
- DNS resolution from the browser environment;
- CORS and authorization headers;
- TLS trust in the browser;
- network policy and security-group rules; and
- SOCKS proxy configuration when the service is private.

Do not use `AIPlatform.spec.ingress` for SAIA, and leave it disabled in this release. Use the SAIA
Service exposure described in [Deploy the AI Platform](deploy-platform.md#expose-saia) or another
release-supported proxy. Confirm that the public route ultimately targets
`<AIPlatform-name>-saia-saia-service` on port `8080`.

A single `kubectl port-forward` is sufficient only for the endpoint and port it forwards. A SOCKS
proxy or reverse proxy is needed when the browser must reach multiple private endpoints or ports.

## Collect diagnostics

```bash
kubectl get aiplatform <platform-name> -n <namespace> -o yaml
kubectl get aiservice -n <namespace> -o yaml
kubectl get pods -n <namespace> -o wide
kubectl get services,endpoints,ingress -n <namespace> -o wide
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
kubectl logs -n splunk-ai-operator-system \
  -l control-plane=controller-manager --tail=300
```

Remove or redact secrets, tokens, and private keys before sharing diagnostics.
