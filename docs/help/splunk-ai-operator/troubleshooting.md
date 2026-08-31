# Troubleshooting

Start with the custom resource status, Kubernetes events, operator logs, and the status of the
managed pods.

## Platform is not ready

```bash
kubectl get aiplatform <platform-name> -n <namespace>
kubectl describe aiplatform <platform-name> -n <namespace>
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

Test port `8089` from a cluster node or diagnostic pod:

```bash
nc -zv <splunk-host> 8089
curl -skS -o /dev/null -w '%{http_code}\n' \
  'https://<splunk-host>:8089/services/authorization/tokens-keys?output_mode=json'
```

An HTTP `200` confirms that the endpoint and JWKS path are reachable. If strict TLS verification
fails, install the correct CA chain and verify the certificate name; do not treat `curl -k` as the
production fix.

## JWT issuer or token errors

For AI-tier authentication, verify:

1. The token has the expected token type.
2. The issuer is trusted.
3. A bare issuer identity has an `SPLUNK_ISSUER_ENDPOINTS` mapping.
4. The mapped endpoint is present in `SPLUNK_ISSUERS`.
5. SAIA can retrieve JWKS from the mapped endpoint.
6. Splunk accepts the token through the current-context check.

The modern CMP format is `typ=at+jwt` with `token_type=splunk.cmp`. Legacy deployments may use
`type=Splunk.interactive`.

## Browser cannot call SAIA V2

SAIA V2 Agent mode makes a direct browser request to the SAIA V2 service. Check:

- ingress or proxy routing;
- DNS resolution from the browser environment;
- CORS and authorization headers;
- TLS trust in the browser;
- network policy and security-group rules; and
- SOCKS proxy configuration when the service is private.

A single `kubectl port-forward` is sufficient only for the endpoint and port it forwards. A SOCKS
proxy or reverse proxy is needed when the browser must reach multiple private endpoints or ports.

## Collect diagnostics

```bash
kubectl get aiplatform <platform-name> -n <namespace> -o yaml
kubectl get pods -n <namespace> -o wide
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
kubectl logs -n splunk-ai-operator-system \
  -l control-plane=controller-manager --tail=300
```

Remove or redact secrets, tokens, and private keys before sharing diagnostics.
