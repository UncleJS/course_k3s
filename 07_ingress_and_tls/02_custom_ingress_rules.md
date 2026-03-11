# Custom Ingress Rules
> Module 07 · Lesson 02 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents
- [Overview](#overview)
- [Standard Kubernetes Ingress](#standard-kubernetes-ingress)
- [Traefik IngressRoute CRD](#traefik-ingressroute-crd)
- [Path-Based Routing](#path-based-routing)
- [Host-Based Routing](#host-based-routing)
- [Middleware: Redirects and Headers](#middleware-redirects-and-headers)
- [Middleware: Rate Limiting](#middleware-rate-limiting)
- [Middleware: BasicAuth](#middleware-basicauth)
- [Weighted Traffic Splitting](#weighted-traffic-splitting)
- [TCP and UDP Routing](#tcp-and-udp-routing)
- [Lab](#lab)

---

## Overview

This lesson goes deep on routing rules — from simple path-based routing to advanced Traefik middleware chains. You'll build progressively more complex routing setups using both the standard Kubernetes `Ingress` resource and Traefik's native `IngressRoute` CRD.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Standard Kubernetes Ingress

The standard `Ingress` resource works with any Ingress controller (not just Traefik). It's portable and simpler but has fewer features.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-ingress
  annotations:
    # Traefik-specific annotations
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  rules:
  - host: myapp.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp-svc
            port:
              number: 80
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-svc
            port:
              number: 8080
  tls:
  - hosts:
    - myapp.example.com
    secretName: myapp-tls
```

### Path Types

| Type | Behaviour |
|------|-----------|
| `Exact` | `/foo` matches only `/foo` |
| `Prefix` | `/foo` matches `/foo`, `/foo/bar`, `/foobar` |
| `ImplementationSpecific` | Controller-dependent |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Traefik IngressRoute CRD

The `IngressRoute` CRD gives full access to Traefik's routing engine, including complex rule combinations, middleware chains, and priority ordering.

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: myapp-route
spec:
  entryPoints:
  - websecure
  routes:
  - match: Host(`myapp.example.com`) && PathPrefix(`/`)
    kind: Rule
    priority: 10
    middlewares:
    - name: secure-headers
    services:
    - name: myapp-svc
      port: 80
  tls:
    secretName: myapp-tls
```

### Rule Operators

| Operator | Example |
|----------|---------|
| `Host()` | `Host(`api.example.com`)` |
| `PathPrefix()` | `PathPrefix(`/api/v1`)` |
| `Path()` | `Path(`/health`)` |
| `Method()` | `Method(`POST`)` |
| `Headers()` | `Headers(`X-API-Version`, `2`)` |
| `&&` | Combine with AND |
| `\|\|` | Combine with OR |
| `!` | Negate |
| `ClientIP()` | `ClientIP(`10.0.0.0/8`)` |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Path-Based Routing

Route different URL paths to different backend services:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: path-routing
spec:
  entryPoints: [web]
  routes:
  # API — higher priority (more specific)
  - match: Host(`example.com`) && PathPrefix(`/api`)
    kind: Rule
    priority: 20
    services:
    - name: api-service
      port: 8080

  # Static assets
  - match: Host(`example.com`) && PathPrefix(`/static`)
    kind: Rule
    priority: 15
    services:
    - name: cdn-service
      port: 80

  # Catch-all frontend
  - match: Host(`example.com`)
    kind: Rule
    priority: 10
    services:
    - name: frontend-service
      port: 3000
```

> **Priority matters!** Higher numbers are evaluated first. Always set higher priority for more specific rules.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Host-Based Routing

Route different hostnames to different services (virtual hosting):

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: host-routing
spec:
  entryPoints: [websecure]
  routes:
  - match: Host(`app.example.com`)
    kind: Rule
    services:
    - name: main-app
      port: 80

  - match: Host(`api.example.com`)
    kind: Rule
    services:
    - name: api-gateway
      port: 8080

  - match: Host(`admin.example.com`)
    kind: Rule
    middlewares:
    - name: admin-auth
    services:
    - name: admin-panel
      port: 9000
  tls:
    secretName: wildcard-example-com
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Middleware: Redirects and Headers

Middleware transforms requests before they hit the backend. Apply middleware by name in your routes.

### HTTP → HTTPS Redirect

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: https-redirect
spec:
  redirectScheme:
    scheme: https
    permanent: true   # 301 redirect
---
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: http-catch
spec:
  entryPoints: [web]
  routes:
  - match: Host(`example.com`)
    kind: Rule
    middlewares:
    - name: https-redirect
    services:
    - name: frontend
      port: 80
```

### Security Headers

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: secure-headers
spec:
  headers:
    sslRedirect: true
    forceSTSHeader: true
    stsSeconds: 31536000
    stsIncludeSubdomains: true
    stsPreload: true
    contentTypeNosniff: true
    browserXssFilter: true
    referrerPolicy: "strict-origin-when-cross-origin"
    customResponseHeaders:
      X-Frame-Options: DENY
      Content-Security-Policy: "default-src 'self'"
```

### Strip Path Prefix

When your backend doesn't expect a path prefix:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: strip-api-prefix
spec:
  stripPrefix:
    prefixes:
    - /api
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Middleware: Rate Limiting

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
spec:
  rateLimit:
    average: 100    # requests per second (average)
    burst: 50       # allowed burst above average
    period: 1s
    sourceCriterion:
      ipStrategy:
        depth: 1    # use X-Forwarded-For[last]
```

Apply to sensitive routes:
```yaml
routes:
- match: Host(`api.example.com`) && PathPrefix(`/login`)
  kind: Rule
  middlewares:
  - name: rate-limit
  services:
  - name: auth-service
    port: 8080
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Middleware: BasicAuth

```bash
# Generate credentials (htpasswd)
htpasswd -nb admin SecretPass | base64

# Or use openssl
echo $(htpasswd -nb admin SecretPass) | base64
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: basic-auth-secret
type: Opaque
stringData:
  users: "admin:$apr1$xyz..."   # htpasswd-format credentials
---
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: admin-auth
spec:
  basicAuth:
    secret: basic-auth-secret
    removeHeader: true   # Don't forward auth header to backend
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Weighted Traffic Splitting

Traefik supports canary/blue-green deployments via weighted services:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: TraefikService
metadata:
  name: weighted-app
spec:
  weighted:
    services:
    - name: app-v1
      port: 80
      weight: 80   # 80% of traffic
    - name: app-v2
      port: 80
      weight: 20   # 20% of traffic (canary)
---
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: canary-route
spec:
  entryPoints: [websecure]
  routes:
  - match: Host(`app.example.com`)
    kind: Rule
    services:
    - name: weighted-app
      kind: TraefikService
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## TCP and UDP Routing

Traefik also handles non-HTTP traffic:

```yaml
# TCP routing (e.g., PostgreSQL passthrough)
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRouteTCP
metadata:
  name: postgres-route
spec:
  entryPoints:
  - postgres    # must define a TCP entrypoint in Traefik config
  routes:
  - match: HostSNI(`db.example.com`)
    services:
    - name: postgres-svc
      port: 5432
  tls:
    passthrough: true   # TLS is handled by PostgreSQL itself
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab

See [`labs/ingress-basic.yaml`](labs/ingress-basic.yaml) — it includes:
- A demo app Deployment + Service
- A standard `Ingress` resource with path routing
- A Traefik `IngressRoute` with the `https-redirect` middleware
- A `secure-headers` middleware

```bash
kubectl apply -f labs/ingress-basic.yaml

# Test routing
curl -H "Host: demo.example.com" http://<NODE_IP>/
curl -H "Host: demo.example.com" http://<NODE_IP>/api/

# View routes in Traefik dashboard
kubectl port-forward -n kube-system deploy/traefik 9000:9000
# http://localhost:9000/dashboard/
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
