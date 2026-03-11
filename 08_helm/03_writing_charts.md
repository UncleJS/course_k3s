# Writing Helm Charts
> Module 08 · Lesson 03 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents
- [Overview](#overview)
- [Chart Structure](#chart-structure)
- [Chart.yaml](#chartyaml)
- [values.yaml](#valuesyaml)
- [Templates and Go Templating](#templates-and-go-templating)
- [Built-in Objects](#built-in-objects)
- [Template Functions and Pipelines](#template-functions-and-pipelines)
- [Named Templates with _helpers.tpl](#named-templates-with-_helperstpl)
- [Conditional Logic and Loops](#conditional-logic-and-loops)
- [NOTES.txt](#notestxt)
- [Chart Dependencies](#chart-dependencies)
- [Testing Charts](#testing-charts)
- [Packaging and Publishing](#packaging-and-publishing)
- [Lab](#lab)

---

## Overview

Writing your own Helm chart lets you package your application with all its Kubernetes resources, make it configurable through values, and share it with your team or the community. This lesson builds a complete chart from scratch.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Chart Structure

```
mychart/
├── Chart.yaml          # Chart metadata (name, version, description)
├── values.yaml         # Default configuration values
├── charts/             # Chart dependencies (sub-charts)
├── templates/          # Kubernetes manifest templates
│   ├── _helpers.tpl    # Named templates and helpers
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── configmap.yaml
│   ├── hpa.yaml
│   ├── serviceaccount.yaml
│   └── NOTES.txt       # Post-install instructions
└── .helmignore         # Files to exclude when packaging
```

Create a new chart skeleton:
```bash
helm create mychart
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Chart.yaml

```yaml
# mychart/Chart.yaml
apiVersion: v2                # Helm 3 chart API version
name: mychart
description: A sample k3s course Helm chart
type: application             # or "library" for shared templates

# Chart version (semver) — bump when chart templates change
version: 0.1.0

# App version — the version of the application being packaged
appVersion: "1.0.0"

# Optional metadata
home: https://github.com/myorg/mychart
sources:
  - https://github.com/myorg/mychart
maintainers:
  - name: Your Name
    email: you@example.com
keywords:
  - nginx
  - web
annotations:
  category: WebServer
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## values.yaml

```yaml
# mychart/values.yaml
# Default values — users override with --values or --set

replicaCount: 1

image:
  repository: nginx
  tag: ""              # defaults to Chart.appVersion if empty
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80

ingress:
  enabled: false
  className: traefik
  host: chart.example.com
  tls: false
  tlsSecret: ""

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi

autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80

config:
  logLevel: info
  appPort: 8080
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Templates and Go Templating

Templates use Go's `text/template` syntax extended by Helm's Sprig library.

```yaml
# mychart/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "mychart.fullname" . }}
  labels:
    {{- include "mychart.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "mychart.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "mychart.selectorLabels" . | nindent 8 }}
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - name: http
          containerPort: {{ .Values.config.appPort }}
          protocol: TCP
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Built-in Objects

| Object | Content |
|--------|---------|
| `.Values` | Merged values (defaults + user overrides) |
| `.Chart` | Contents of `Chart.yaml` |
| `.Release.Name` | Release name (e.g., `my-nginx`) |
| `.Release.Namespace` | Install namespace |
| `.Release.IsInstall` | `true` on first install |
| `.Release.IsUpgrade` | `true` on upgrade |
| `.Files` | Non-template files in the chart |
| `.Capabilities.KubeVersion` | Kubernetes version info |

```yaml
# Examples
{{ .Release.Name }}-{{ .Chart.Name }}          # my-nginx-mychart
{{ .Values.image.repository }}:{{ .Values.image.tag }}  # nginx:1.25
{{ .Chart.AppVersion }}                          # 1.0.0
{{ .Release.Namespace }}                         # default
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Template Functions and Pipelines

```yaml
# String functions
{{ .Values.name | upper }}           # MYAPP
{{ .Values.name | lower }}           # myapp
{{ .Values.name | quote }}           # "myapp"
{{ .Values.name | trunc 63 }}        # truncate to 63 chars
{{ .Values.name | trimSuffix "-" }}  # remove trailing dash

# Default values
{{ .Values.image.tag | default .Chart.AppVersion }}
{{ .Values.config.logLevel | default "info" }}

# Type conversion
{{ .Values.port | toString }}
{{ .Values.replicaCount | int }}

# YAML formatting
{{- toYaml .Values.resources | nindent 10 }}
# Produces:
#           requests:
#             cpu: 100m
#             memory: 128Mi

# Required (fail if not set)
{{ required "A valid .Values.host entry required!" .Values.ingress.host }}

# Indent and nindent
{{ "some: yaml" | indent 4 }}   # indents all lines 4 spaces
{{ "some: yaml" | nindent 4 }}  # adds newline then indents
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Named Templates with _helpers.tpl

```yaml
# mychart/templates/_helpers.tpl

{{/*
Expand the name of the chart.
*/}}
{{- define "mychart.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name: release + chart, truncated to 63 chars.
*/}}
{{- define "mychart.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := .Chart.Name }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels for all resources.
*/}}
{{- define "mychart.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "mychart.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "mychart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mychart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

Use with `{{ include "mychart.fullname" . }}`.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Conditional Logic and Loops

```yaml
# Conditional: optional ingress
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "mychart.fullname" . }}
spec:
  rules:
  - host: {{ .Values.ingress.host }}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: {{ include "mychart.fullname" . }}
            port:
              number: {{ .Values.service.port }}
{{- if .Values.ingress.tls }}
  tls:
  - hosts: [{{ .Values.ingress.host | quote }}]
    secretName: {{ .Values.ingress.tlsSecret | default (printf "%s-tls" (include "mychart.fullname" .)) }}
{{- end }}
{{- end }}
```

```yaml
# Range loop: create ConfigMap from a map value
{{- if .Values.extraEnv }}
env:
{{- range $key, $value := .Values.extraEnv }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
{{- end }}
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## NOTES.txt

Printed to stdout after `helm install`:

```
# mychart/templates/NOTES.txt
1. Get the application URL by running these commands:
{{- if .Values.ingress.enabled }}
  http{{ if .Values.ingress.tls }}s{{ end }}://{{ .Values.ingress.host }}/
{{- else if contains "NodePort" .Values.service.type }}
  export NODE_PORT=$(kubectl get svc {{ include "mychart.fullname" . }} \
    -o jsonpath="{.spec.ports[0].nodePort}")
  export NODE_IP=$(kubectl get nodes \
    -o jsonpath="{.items[0].status.addresses[0].address}")
  echo http://$NODE_IP:$NODE_PORT
{{- else if contains "ClusterIP" .Values.service.type }}
  export POD_NAME=$(kubectl get pods -l "app.kubernetes.io/instance={{ .Release.Name }}" \
    -o jsonpath="{.items[0].metadata.name}")
  kubectl port-forward $POD_NAME 8080:{{ .Values.config.appPort }}
  echo "Visit http://127.0.0.1:8080"
{{- end }}
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Chart Dependencies

```yaml
# Chart.yaml — declare dependencies
dependencies:
- name: postgresql
  version: "12.x.x"
  repository: https://charts.bitnami.com/bitnami
  condition: postgresql.enabled   # only install if values.postgresql.enabled=true
- name: redis
  version: "17.x.x"
  repository: https://charts.bitnami.com/bitnami
  condition: redis.enabled
```

```bash
# Download dependencies into charts/
helm dependency update mychart

# List dependencies
helm dependency list mychart
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Testing Charts

```bash
# Lint (syntax check)
helm lint mychart

# Render templates locally (no cluster needed)
helm template my-release mychart --values labs/values-override.yaml

# Dry-run against cluster (validates against API)
helm install my-release mychart \
  --values labs/values-override.yaml \
  --dry-run --debug

# Run helm tests (tests are pods that run and exit 0)
helm install my-release mychart
helm test my-release
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Packaging and Publishing

```bash
# Package into a .tgz archive
helm package mychart
# Creates: mychart-0.1.0.tgz

# Create/update a chart repository index
helm repo index . --url https://charts.example.com

# Push to OCI registry
helm registry login ghcr.io -u <user> -p <token>
helm push mychart-0.1.0.tgz oci://ghcr.io/myorg/charts

# Install from local package
helm install my-release mychart-0.1.0.tgz
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab

The `labs/mychart/` directory contains a complete working chart skeleton. Try:

```bash
# Lint
helm lint labs/mychart

# Render templates
helm template demo labs/mychart --values labs/values-override.yaml

# Install
helm install demo labs/mychart \
  --namespace helm-lab \
  --create-namespace \
  --values labs/values-override.yaml

# Verify
kubectl get all -n helm-lab

# Try upgrading with ingress enabled
helm upgrade demo labs/mychart \
  --namespace helm-lab \
  --values labs/values-override.yaml \
  --set ingress.enabled=true \
  --set ingress.host=demo.example.com

# Uninstall
helm uninstall demo -n helm-lab
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
