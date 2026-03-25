# cert-manager and Let's Encrypt TLS
> Module 07 · Lesson 03 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents
- [Overview](#overview)
- [What is cert-manager?](#what-is-cert-manager)
- [Installing cert-manager](#installing-cert-manager)
- [ClusterIssuers: Let's Encrypt Staging and Production](#clusterissuers-lets-encrypt-staging-and-production)
- [HTTP-01 Challenge](#http-01-challenge)
- [HTTP-01 Challenge Sequence](#http-01-challenge-sequence)
- [DNS-01 Challenge](#dns-01-challenge)
- [Requesting Certificates](#requesting-certificates)
- [Certificate Lifecycle](#certificate-lifecycle)
- [Automatic Certificate via Ingress Annotation](#automatic-certificate-via-ingress-annotation)
- [Automatic Certificate via IngressRoute](#automatic-certificate-via-ingressroute)
- [Certificate Renewal](#certificate-renewal)
- [Troubleshooting Certificates](#troubleshooting-certificates)
- [Lab](#lab)

---

## Overview

cert-manager is the de facto certificate management solution for Kubernetes. It automates requesting, issuing, and renewing TLS certificates from Let's Encrypt (and other CAs). Combined with Traefik, you get automatic HTTPS for all your services.

```mermaid
sequenceDiagram
    participant T as Traefik
    participant CM as cert-manager
    participant LE as Let's Encrypt
    participant DNS as DNS Provider

    T->>CM: Ingress with cert-manager annotation detected
    CM->>LE: Request certificate for domain.com
    LE->>CM: Challenge: prove you own domain.com
    CM->>DNS: Create TXT record _acme-challenge.domain.com (DNS-01)
    DNS-->>LE: TXT record verified
    LE-->>CM: Certificate issued
    CM->>T: TLS Secret created
    T-->>Internet: HTTPS with valid cert
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## What is cert-manager?

cert-manager extends Kubernetes with certificate-related Custom Resource Definitions:

| CRD | Purpose |
|-----|---------|
| `ClusterIssuer` | Certificate authority config (cluster-wide) |
| `Issuer` | Certificate authority config (namespace-scoped) |
| `Certificate` | Request a specific certificate |
| `CertificateRequest` | Low-level certificate signing request |
| `Order` | ACME order lifecycle |
| `Challenge` | ACME challenge lifecycle |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Installing cert-manager

```bash
# Method 1: kubectl (official manifests)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Method 2: Helm (recommended for production)
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --set global.leaderElection.namespace=cert-manager

# Verify installation
kubectl get pods -n cert-manager
# NAME                                      READY   STATUS
# cert-manager-xxxx                         1/1     Running
# cert-manager-cainjector-xxxx              1/1     Running
# cert-manager-webhook-xxxx                 1/1     Running
```

> Wait for all three pods to be `Running` before creating issuers.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## ClusterIssuers: Let's Encrypt Staging and Production

Always test with the **staging** issuer first — Let's Encrypt production has strict rate limits (5 certificates per registered domain per week).

```yaml
# Staging — use for testing, certificate is NOT trusted by browsers
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
    - http01:
        ingress:
          class: traefik
```

```yaml
# Production — use after staging works; certificates are browser-trusted
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: traefik
```

```bash
kubectl apply -f labs/cert-manager-issuer.yaml

# Verify
kubectl get clusterissuer
# NAME                   READY   AGE
# letsencrypt-staging    True    30s
# letsencrypt-prod       True    30s
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## HTTP-01 Challenge

The HTTP-01 challenge proves domain ownership by serving a token at:
`http://<domain>/.well-known/acme-challenge/<token>`

Requirements:
- Your domain's DNS A record must point to the cluster's public IP
- Port 80 must be publicly accessible
- Traefik must be able to create a temporary `Ingress` for the challenge

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## HTTP-01 Challenge Sequence

The HTTP-01 flow involves tight cooperation between cert-manager, Traefik, and the Let's Encrypt ACME server. The entire process typically completes in 30–90 seconds:

```mermaid
sequenceDiagram
    participant Dev as "Developer"
    participant K8S as "Kubernetes API"
    participant CM as "cert-manager"
    participant T as "Traefik (:80)"
    participant LE as "Let's Encrypt ACME"

    Dev->>K8S: Apply Ingress with<br/>cert-manager.io/cluster-issuer annotation
    K8S->>CM: Ingress detected — Certificate needed
    CM->>LE: POST /acme/new-order (domain: myapp.example.com)
    LE-->>CM: Order created — HTTP-01 challenge token issued
    CM->>K8S: Create temporary Ingress for<br/>/.well-known/acme-challenge/TOKEN
    K8S->>T: New Ingress rule pushed to Traefik
    CM->>LE: POST /acme/challenge — "I'm ready"
    LE->>T: GET http://myapp.example.com/.well-known/acme-challenge/TOKEN
    T-->>LE: 200 OK + token value
    LE-->>CM: Challenge validated
    LE-->>CM: Certificate issued (PEM)
    CM->>K8S: Create Secret (tls.crt + tls.key)
    CM->>K8S: Delete temporary challenge Ingress
    Note over K8S: Certificate CR status → Ready<br/>Secret available for Traefik
    T->>K8S: Mount TLS secret on websecure entrypoint
```

If the challenge fails, check: (1) port 80 is open in your firewall, (2) DNS resolves to the correct IP, (3) the temporary Ingress was created (`kubectl get ingress -A` during the challenge). cert-manager retries automatically with exponential backoff.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## DNS-01 Challenge

The DNS-01 challenge proves domain ownership by creating a DNS TXT record. It works even if port 80 is not publicly accessible (good for internal/private clusters) and supports wildcard certificates.

```yaml
# Example: DNS-01 with Cloudflare
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-dns-key
    solvers:
    - dns01:
        cloudflare:
          email: you@example.com
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
```

```yaml
# Cloudflare API token secret
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: "<your-cloudflare-api-token>"
```

Supported DNS providers: Cloudflare, Route53, Google Cloud DNS, Azure DNS, DigitalOcean, and many more via [webhook solvers](https://cert-manager.io/docs/configuration/acme/dns01/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Requesting Certificates

### Explicit Certificate Resource
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-com-tls
  namespace: default
spec:
  secretName: example-com-tls    # Where the cert will be stored
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - example.com
  - www.example.com
  - api.example.com
  # Wildcard requires DNS-01:
  # - "*.example.com"
  duration: 2160h       # 90 days (default for Let's Encrypt)
  renewBefore: 360h     # renew 15 days before expiry
```

```bash
# Watch certificate status
kubectl get certificate
kubectl describe certificate example-com-tls

# Check the resulting TLS secret
kubectl get secret example-com-tls -o yaml
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Automatic Certificate via Ingress Annotation

The easiest method — annotate your `Ingress` and cert-manager does the rest:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
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
            name: myapp
            port:
              number: 80
  tls:
  - hosts:
    - myapp.example.com
    secretName: myapp-tls   # cert-manager will populate this
```

cert-manager watches for Ingresses with this annotation and automatically creates a `Certificate` resource.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Certificate Lifecycle

Every `Certificate` resource in cert-manager goes through a predictable lifecycle of sub-resources. Understanding each stage helps you pinpoint exactly where a stuck certificate is failing:

```mermaid
flowchart TD
    CERT(["Certificate CR created<br/>(spec.dnsNames, issuerRef)"])
    CR["CertificateRequest created<br/>(contains CSR)"]
    ORD["Order created<br/>(ACME order for the domain)"]
    CHAL["Challenge created<br/>(HTTP-01 or DNS-01)"]
    VAL{"Challenge<br/>validated?"}
    FAIL(["Challenge failed<br/>retry with backoff"])
    ISSUE["Certificate issued by CA<br/>(PEM bytes returned)"]
    SEC["Secret created or updated<br/>(tls.crt + tls.key)"]
    READY(["Certificate: Ready = True<br/>NotBefore / NotAfter set"])
    RENEW{"Now > NotAfter<br/>minus renewBefore?"}
    RENEW_LOOP["New CertificateRequest<br/>created automatically"]

    CERT --> CR --> ORD --> CHAL --> VAL
    VAL -->|"No"| FAIL
    FAIL -.->|"retry"| CHAL
    VAL -->|"Yes"| ISSUE --> SEC --> READY
    READY --> RENEW
    RENEW -->|"Yes — renew now"| RENEW_LOOP
    RENEW_LOOP --> CR
    RENEW -->|"No — check again later"| READY

    style READY fill:#22c55e,color:#fff
    style FAIL fill:#fee2e2,color:#ef4444
    style RENEW_LOOP fill:#fef9c3,color:#854d0e
```

The default `renewBefore` is 30 days before expiry (Let's Encrypt certificates expire after 90 days, so renewal triggers at day 60). cert-manager continuously monitors all `Certificate` resources and schedules renewal jobs automatically — no cron jobs or external tooling needed.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Automatic Certificate via IngressRoute

For Traefik `IngressRoute`, use a `Certificate` resource and reference the secret:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-cert
spec:
  secretName: myapp-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames: [myapp.example.com]
---
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: myapp-secure
spec:
  entryPoints: [websecure]
  routes:
  - match: Host(`myapp.example.com`)
    kind: Rule
    services:
    - name: myapp
      port: 80
  tls:
    secretName: myapp-tls   # references cert-manager-created secret
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Certificate Renewal

cert-manager automatically renews certificates before they expire (default: 15 days before). No manual action required.

```bash
# Check certificate expiry
kubectl get certificate -A
# NAMESPACE   NAME        READY   SECRET      AGE
# default     myapp-cert  True    myapp-tls   10d

# See detailed status including expiry
kubectl describe certificate myapp-cert | grep -A5 "Renewal Time"

# Force an immediate renewal (if needed)
kubectl delete secret myapp-tls
# cert-manager will re-issue automatically

# Or annotate to trigger renewal
kubectl annotate certificate myapp-cert \
  cert-manager.io/renew-immediately="true"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Troubleshooting Certificates

```bash
# Step 1: Check certificate status
kubectl describe certificate myapp-cert

# Step 2: Check ACME Order
kubectl get orders -A
kubectl describe order myapp-cert-<hash>

# Step 3: Check Challenge
kubectl get challenges -A
kubectl describe challenge myapp-cert-<hash>-<hash>

# Step 4: Check cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager --tail=50 | grep -i error

# Step 5: Test HTTP-01 accessibility (from outside the cluster)
curl http://myapp.example.com/.well-known/acme-challenge/test
```

### Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `Certificate not ready` | Challenge failing | Check Order and Challenge events |
| `Connection refused` on challenge | Port 80 blocked | Open firewall port 80 |
| DNS doesn't resolve | DNS not propagated | Wait for DNS TTL, or check DNS record |
| `Rate limit exceeded` | Too many cert requests | Use staging issuer; wait 1 week |
| `ClusterIssuer not ready` | Wrong ACME credentials | Check email / API token |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab

See [`labs/cert-manager-issuer.yaml`](labs/cert-manager-issuer.yaml) and [`labs/ingressroute-tls.yaml`](labs/ingressroute-tls.yaml).

```bash
# 1. Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# 2. Create issuers (edit email address first)
kubectl apply -f labs/cert-manager-issuer.yaml

# 3. Deploy app with TLS IngressRoute
kubectl apply -f labs/ingressroute-tls.yaml

# 4. Watch certificate issuance
kubectl get certificate -w

# 5. Verify TLS
curl -v https://myapp.example.com/ 2>&1 | grep -E "SSL|subject|issuer"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
