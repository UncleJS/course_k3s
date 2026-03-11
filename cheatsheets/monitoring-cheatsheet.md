# Monitoring Cheatsheet

> Mastering k3s Course | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents

- [Prometheus Stack Install](#prometheus-stack-install)
- [Key PromQL Queries](#key-promql-queries)
- [kubectl for Monitoring Resources](#kubectl-for-monitoring-resources)
- [Grafana Access](#grafana-access)
- [PrometheusRule Template](#prometheusrule-template)
- [Alertmanager Receiver Templates](#alertmanager-receiver-templates)
- [Silence Management](#silence-management)
- [ServiceMonitor Template](#servicemonitor-template)
- [Alert Testing](#alert-testing)

---

## Prometheus Stack Install

```bash
# Add repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager + node-exporter)
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.retention=30d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=longhorn \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi

# Install with values file
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f prometheus-values.yaml

# Upgrade
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f prometheus-values.yaml

# Check CRDs installed
kubectl get crd | grep monitoring.coreos.com
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Key PromQL Queries

| Query | Description |
|-------|-------------|
| `up` | All scrape targets (1=up, 0=down) |
| `up{job="kubernetes-nodes"}` | Node scrape health |
| `node_cpu_seconds_total` | CPU time by mode |
| `100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` | CPU usage % per node |
| `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100` | Available memory % |
| `node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100` | Root disk free % |
| `kube_pod_status_phase{phase!="Running",phase!="Succeeded"}` | Pods not running or succeeded |
| `rate(container_cpu_usage_seconds_total{container!=""}[5m])` | Container CPU usage rate |
| `container_memory_working_set_bytes{container!=""}` | Container memory usage |
| `kube_deployment_status_replicas_unavailable > 0` | Deployments with unavailable replicas |

### Useful PromQL Patterns

```promql
# Top 5 pods by CPU usage (last 5m)
topk(5, rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m]))

# Memory usage > 80% of limit
container_memory_working_set_bytes
  / on(container, pod, namespace)
  kube_pod_container_resource_limits{resource="memory"}
  > 0.8

# Pod restarts in last hour
increase(kube_pod_container_status_restarts_total[1h]) > 0

# HTTP error rate (5xx)
rate(http_requests_total{status_code=~"5.."}[5m])
  / rate(http_requests_total[5m]) * 100

# Request latency P99
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))

# Disk I/O
rate(node_disk_read_bytes_total[5m])
rate(node_disk_written_bytes_total[5m])

# Network traffic
rate(node_network_receive_bytes_total{device!="lo"}[5m])
rate(node_network_transmit_bytes_total{device!="lo"}[5m])

# PVC usage %
(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100

# Etcd leader exists
etcd_server_has_leader == 1
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## kubectl for Monitoring Resources

```bash
# All monitoring namespace resources
kubectl get all -n monitoring

# Prometheus pods
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus -c prometheus

# Grafana pods
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana

# Alertmanager pods
kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager

# Node exporter
kubectl get pods -n monitoring -l app.kubernetes.io/name=node-exporter

# PVCs
kubectl get pvc -n monitoring

# Services (to check ports)
kubectl get svc -n monitoring

# CRD-based resources
kubectl get prometheuses -n monitoring
kubectl get alertmanagers -n monitoring
kubectl get prometheusrules -n monitoring
kubectl get servicemonitors -n monitoring
kubectl get podmonitors -n monitoring
kubectl get scrapeconfigs -n monitoring

# Check Prometheus targets via API
kubectl exec -n monitoring deploy/prometheus-kube-prometheus-prometheus \
  -- wget -qO- localhost:9090/api/v1/targets | python3 -m json.tool | head -50
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Grafana Access

```bash
# Port-forward
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
# Visit: http://localhost:3000  (admin/admin or set password)

# Get admin password
kubectl get secret prometheus-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d

# NodePort access (temporary)
kubectl patch svc prometheus-grafana -n monitoring \
  -p '{"spec":{"type":"NodePort"}}'
kubectl get svc prometheus-grafana -n monitoring

# Create Ingress for Grafana
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
spec:
  ingressClassName: traefik
  rules:
    - host: grafana.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: prometheus-grafana
                port:
                  number: 80
EOF
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## PrometheusRule Template

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: app-alerts
  namespace: monitoring
  labels:
    release: prometheus   # must match Prometheus selector
spec:
  groups:
    - name: app.rules
      interval: 30s
      rules:
        # Recording rule
        - record: job:http_requests:rate5m
          expr: rate(http_requests_total[5m])

        # Alert rule
        - alert: HighErrorRate
          expr: |
            rate(http_requests_total{status_code=~"5.."}[5m])
            / rate(http_requests_total[5m]) > 0.05
          for: 5m
          labels:
            severity: warning
            team: backend
          annotations:
            summary: "High HTTP error rate on {{ $labels.service }}"
            description: "Error rate is {{ $value | humanizePercentage }} for {{ $labels.service }}"

        - alert: PodCrashLooping
          expr: rate(kube_pod_container_status_restarts_total[15m]) * 60 * 15 > 0
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash looping"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Alertmanager Receiver Templates

```yaml
# alertmanager-config.yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: app-alerts
  namespace: monitoring
  labels:
    alertmanagerConfig: main
spec:
  route:
    groupBy: ['alertname', 'namespace']
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 12h
    receiver: 'slack-alerts'
    routes:
      - matchers:
          - name: severity
            value: critical
        receiver: 'pagerduty'

  receivers:
    # Slack receiver
    - name: 'slack-alerts'
      slackConfigs:
        - apiURL:
            name: slack-webhook
            key: url
          channel: '#alerts'
          sendResolved: true
          title: '[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .CommonLabels.alertname }}'
          text: >-
            {{ range .Alerts }}
              *Alert:* {{ .Annotations.summary }}
              *Description:* {{ .Annotations.description }}
              *Severity:* {{ .Labels.severity }}
            {{ end }}

    # Email receiver
    - name: 'email-ops'
      emailConfigs:
        - to: 'ops@example.com'
          from: 'alertmanager@example.com'
          smarthost: 'smtp.example.com:587'
          authUsername: 'alertmanager@example.com'
          authPassword:
            name: smtp-secret
            key: password
          sendResolved: true
          headers:
            subject: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Silence Management

```bash
# Port-forward Alertmanager
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093 -n monitoring

# Create silence via amtool
amtool --alertmanager.url=http://localhost:9093 silence add \
  alertname=HighErrorRate \
  --duration=2h \
  --author="ops-team" \
  --comment="Investigating issue"

# List silences
amtool --alertmanager.url=http://localhost:9093 silence query

# Expire silence
amtool --alertmanager.url=http://localhost:9093 silence expire <silence-id>

# Via API (curl)
curl -X POST http://localhost:9093/api/v2/silences \
  -H "Content-Type: application/json" \
  -d '{
    "matchers": [{"name": "alertname", "value": "HighErrorRate", "isRegex": false}],
    "startsAt": "2026-01-01T00:00:00Z",
    "endsAt": "2026-01-01T02:00:00Z",
    "createdBy": "ops",
    "comment": "Investigating"
  }'
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## ServiceMonitor Template

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: my-app
  namespaceSelector:
    matchNames:
      - production
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Alert Testing

```bash
# Check Prometheus targets
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring
# Visit: http://localhost:9090/targets

# Check active alerts
curl http://localhost:9090/api/v1/alerts | python3 -m json.tool

# Test alert expression
curl "http://localhost:9090/api/v1/query?query=ALERTS{alertstate='firing'}" | python3 -m json.tool

# Check Alertmanager alerts
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093 -n monitoring
curl http://localhost:9093/api/v2/alerts | python3 -m json.tool

# Send test alert to Alertmanager
curl -H "Content-Type: application/json" \
  -d '[{"labels":{"alertname":"TestAlert","severity":"warning","instance":"test"},"annotations":{"summary":"Test alert"}}]' \
  http://localhost:9093/api/v2/alerts
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
