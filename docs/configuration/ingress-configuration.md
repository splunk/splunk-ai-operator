# Ingress Configuration for AIPlatform

This guide shows you how to expose your AI Platform services to the internet using Kubernetes Ingress.

## Quick Start

**Enable external access with a custom domain:**

```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: my-ai-platform
spec:
  # ... other config ...
  ingress:
    enabled: true
    className: nginx  # Your Ingress controller (nginx, traefik, alb, etc.)
    hosts:
      - host: ai.mycompany.com
        paths:
          - path: /
            pathType: Prefix
```

After deployment:
1. Get the LoadBalancer IP: `kubectl get ingress my-ai-platform`
2. Point your DNS `ai.mycompany.com` to that IP
3. Access your AI API: `https://ai.mycompany.com/v1/chat`

## Why Use Ingress?

**Without Ingress:**
- Services only accessible inside Kubernetes cluster
- Need port-forwarding: `kubectl port-forward svc/my-platform-serve 8000:8000`
- Can't use custom domain names
- No HTTPS/TLS termination

**With Ingress:**
- ✅ Access from anywhere with your domain
- ✅ Automatic HTTPS with cert-manager
- ✅ Single IP for all services
- ✅ Path-based routing (/, /dashboard, /weaviate)
- ✅ Add authentication, rate limiting, CORS

## Overview

The operator creates an Ingress resource that routes traffic to:
- **/** → Ray Serve (port 8000) - Your AI inference API
- **/dashboard** → Ray Dashboard (port 8265) - Monitoring UI
- **/weaviate** → Weaviate (port 80) - Vector database

## Basic Configuration

```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: my-ai-platform
  namespace: ai-platform
spec:
  # ... other spec fields ...

  ingress:
    enabled: true
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
    hosts:
      - host: ai.example.com
        paths:
          - path: /
            pathType: Prefix
          - path: /dashboard
            pathType: Prefix
    tls:
      - hosts:
          - ai.example.com
        secretName: ai-platform-tls
```

### Complete Example with Multiple Services

```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: my-ai-platform
  namespace: ai-platform
spec:
  # ... other spec fields ...

  ingress:
    enabled: true
    className: nginx
    annotations:
      # TLS annotations
      cert-manager.io/cluster-issuer: letsencrypt-prod

      # Rate limiting
      nginx.ingress.kubernetes.io/limit-rps: "100"

      # CORS settings
      nginx.ingress.kubernetes.io/enable-cors: "true"
      nginx.ingress.kubernetes.io/cors-allow-origin: "*"

      # Timeouts (important for long-running AI inference)
      nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
      nginx.ingress.kubernetes.io/proxy-send-timeout: "300"

    hosts:
      # Main inference endpoint
      - host: inference.example.com
        paths:
          - path: /
            pathType: Prefix

      # Dashboard access
      - host: dashboard.example.com
        paths:
          - path: /
            pathType: Prefix

      # Vector database access
      - host: vectordb.example.com
        paths:
          - path: /
            pathType: Prefix

    tls:
      - hosts:
          - inference.example.com
        secretName: inference-tls
      - hosts:
          - dashboard.example.com
        secretName: dashboard-tls
      - hosts:
          - vectordb.example.com
        secretName: vectordb-tls
```

## Path Routing

The operator automatically routes paths to the appropriate service based on the path prefix:

| Path Pattern | Routes To | Port | Purpose |
|--------------|-----------|------|---------|
| `/` (default) | Ray Serve | 8000 | AI inference endpoints |
| `/dashboard` | Ray Dashboard | 8265 | Monitoring UI |
| `/weaviate` | Weaviate | 80 | Vector database API |

### Custom Path Examples

```yaml
spec:
  ingress:
    enabled: true
    hosts:
      - host: ai.example.com
        paths:
          # Ray Serve inference at root
          - path: /
            pathType: Prefix

          # Ray Dashboard
          - path: /dashboard
            pathType: Prefix

          # Weaviate vector DB
          - path: /weaviate
            pathType: Prefix
```

## IngressSpec Fields

### `enabled` (bool)
Enable or disable Ingress creation. When disabled, any existing Ingress will be deleted.

```yaml
ingress:
  enabled: true
```

### `className` (string)
Ingress class to use (e.g., `nginx`, `traefik`, `alb`).

```yaml
ingress:
  className: nginx
```

### `annotations` (map[string]string)
Annotations to add to the Ingress resource. Use these for configuring your Ingress controller.

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    cert-manager.io/cluster-issuer: letsencrypt-prod
```

### `hosts` ([]IngressHost)
List of hosts and their path configurations.

```yaml
ingress:
  hosts:
    - host: ai.example.com
      paths:
        - path: /
          pathType: Prefix
```

#### IngressHost Fields

- **`host`** (string) - The fully qualified domain name
- **`paths`** ([]IngressPath) - List of paths for this host

#### IngressPath Fields

- **`path`** (string) - URL path (e.g., `/`, `/dashboard`)
- **`pathType`** (string) - Type of path matching:
  - `Prefix` - Match path prefix (recommended)
  - `Exact` - Match exact path only
  - `ImplementationSpecific` - Depends on Ingress controller

### `tls` ([]IngressTLS)
TLS configuration for HTTPS.

```yaml
ingress:
  tls:
    - hosts:
        - ai.example.com
      secretName: ai-platform-tls
```

#### IngressTLS Fields

- **`hosts`** ([]string) - List of hosts covered by this certificate
- **`secretName`** (string) - Name of the TLS Secret containing cert and key

## Common Ingress Controller Examples

### NGINX Ingress Controller

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    # SSL configuration
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"

    # Timeouts for long-running inference
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"

    # Request size limits (for large model inputs)
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"

    # Rate limiting
    nginx.ingress.kubernetes.io/limit-rps: "50"
```

### AWS ALB Ingress Controller

```yaml
ingress:
  enabled: true
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-west-2:123456789012:certificate/abc123
```

### Traefik

```yaml
ingress:
  enabled: true
  className: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
```

## TLS/HTTPS Configuration

### Using cert-manager

```yaml
ingress:
  enabled: true
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: ai.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
        - ai.example.com
      secretName: ai-platform-tls  # cert-manager will create this
```

### Using Pre-existing TLS Secret

```yaml
# First create the secret:
# kubectl create secret tls ai-platform-tls \
#   --cert=path/to/cert.pem \
#   --key=path/to/key.pem

ingress:
  enabled: true
  hosts:
    - host: ai.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
        - ai.example.com
      secretName: ai-platform-tls
```

## Disabling Ingress

To disable Ingress and remove the resource:

```yaml
spec:
  ingress:
    enabled: false
```

Or simply omit the `ingress` field entirely.

## Events

The operator emits the following events for Ingress management:

| Event | Type | Description |
|-------|------|-------------|
| `IngressCreating` | Normal | Starting to create Ingress resource |
| `IngressCreated` | Normal | Ingress resource created successfully |
| `IngressCreationFailed` | Warning | Failed to create/update Ingress |

## Troubleshooting

### Check Ingress Status

```bash
# View Ingress resource
kubectl get ingress -n ai-platform

# Describe for events and status
kubectl describe ingress <platform-name> -n ai-platform

# Check Ingress controller logs
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller
```

### Check Events

```bash
# View operator events for Ingress
kubectl get events -n ai-platform --field-selector involvedObject.name=<platform-name>,reason=IngressCreating
kubectl get events -n ai-platform --field-selector involvedObject.name=<platform-name>,reason=IngressCreated
kubectl get events -n ai-platform --field-selector involvedObject.name=<platform-name>,reason=IngressCreationFailed
```

### Common Issues

**Issue**: Ingress created but not routing traffic
- Check that the Ingress controller is installed and running
- Verify the `className` matches your Ingress controller
- Check service endpoints: `kubectl get endpoints -n ai-platform`

**Issue**: TLS certificate not working
- Verify cert-manager is installed (if using cert-manager)
- Check Certificate resource: `kubectl get certificate -n ai-platform`
- Check cert-manager logs for certificate issuance errors

**Issue**: 502/504 Gateway errors
- Check Ray Serve service is ready: `kubectl get svc <platform-name>-serve -n ai-platform`
- Increase timeout annotations (see NGINX example above)
- Check Ray Serve pod logs for application errors

## Best Practices

1. **Always use TLS in production** - Configure valid certificates
2. **Set appropriate timeouts** - AI inference can take time, increase timeouts
3. **Configure rate limiting** - Protect your infrastructure from overload
4. **Use request size limits** - Prevent memory exhaustion from large payloads
5. **Monitor Ingress metrics** - Watch request rates, latencies, and errors
6. **Use separate hostnames** - Don't expose dashboard publicly if not needed

## Security Considerations

- **Don't expose the Ray Dashboard publicly** unless necessary - it contains sensitive cluster information
- **Use authentication** - Add auth annotations for your Ingress controller
- **Restrict Weaviate access** - Consider internal-only access for the vector database
- **Enable SSL/TLS** - Always encrypt traffic in production
- **Use network policies** - Restrict which pods can access Ray services

## Example: Production Setup

```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: prod-ai-platform
  namespace: ai-platform
spec:
  # ... other spec fields ...

  ingress:
    enabled: true
    className: nginx
    annotations:
      # TLS
      cert-manager.io/cluster-issuer: letsencrypt-prod
      nginx.ingress.kubernetes.io/ssl-redirect: "true"

      # Security
      nginx.ingress.kubernetes.io/auth-type: basic
      nginx.ingress.kubernetes.io/auth-secret: ai-platform-auth

      # Performance
      nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
      nginx.ingress.kubernetes.io/proxy-body-size: "50m"
      nginx.ingress.kubernetes.io/limit-rps: "100"

      # Monitoring
      nginx.ingress.kubernetes.io/enable-access-log: "true"

    hosts:
      # Only expose inference endpoint publicly
      - host: inference.prod.example.com
        paths:
          - path: /
            pathType: Prefix

    tls:
      - hosts:
          - inference.prod.example.com
        secretName: prod-inference-tls
```

## Integration with the legacy `mtls` field

The `mtls` field currently creates a one-way, server-authentication TLS
listener on the AIService nginx deployment. Despite its legacy name, it does
not request or validate client certificates and therefore does not implement
mutual TLS.

- **Ingress** handles external TLS termination (client → Ingress)
- **`mtls`** provisions the AIService nginx server certificate and TLS listener

Ingress-to-service HTTPS routing must be configured separately. Use a service
mesh or gateway that validates client certificates when true mutual TLS is
required.

```yaml
spec:
  # External TLS via Ingress
  ingress:
    enabled: true
    tls:
      - hosts:
          - ai.example.com
        secretName: external-tls

  # One-way server TLS on the AIService nginx listener (legacy field name)
  mtls:
    enabled: true
    termination: operator
    issuerRef:
      name: internal-ca
      kind: ClusterIssuer
```
