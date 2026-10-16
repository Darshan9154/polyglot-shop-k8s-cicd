# Observability stack — deployed and verified

Metrics, logs and traces on the EKS cluster, with Grafana as the single pane.

## Verified working

**Prometheus scrapes the application.** All five services report `up`:

```
shop-catalog  /metrics               -> up
shop-checkout /metrics               -> up
shop-cart     /actuator/prometheus   -> up
shop-orders   /actuator/prometheus   -> up
shop-ui       /actuator/prometheus   -> up

jvm_memory_used_bytes              -> 24 series
http_server_requests_seconds_count -> 22 series
go_goroutines                      -> 15 series
```

**Grafana answers through all three datasources**, which is the check that matters — a
datasource can be configured and still be broken:

```
Grafana -> Prometheus  25 series
Grafana -> Loki        {"status":"success"}
Grafana -> Jaeger      3 services
```

**Traces flow end to end**, with real spans naming real operations:

```
otelcol_receiver_accepted_spans{receiver="otlp"}                    412
otelcol_processor_memory_limiter_accepted_spans                     412
otelcol_exporter_sent_spans{exporter="otlp_grpc/jaeger"}            412

Jaeger services: ["jaeger-all-in-one", "cart", "ui"]
trace 1ffd656917f0a8ff2ea64dc022d618d7   7 spans, 4ms
trace e7ebccf268886cb564bc6436b69f1124   7 spans, 4.3ms
  op=send - {+baseurl}/catalog/size                  4.3ms
  op=sendCollection - {+baseurl}/catalog/products    3.89ms
```

The `412 accepted` equal to `412 sent` is the evidence that nothing is being dropped between
receiver and exporter.

## What is running

| Component | Pods | Purpose |
|---|---|---|
| Prometheus | 1 | metrics storage, alert evaluation |
| Alertmanager | 1 | alert routing (no receiver configured) |
| Grafana | 1 | dashboards, datasource aggregation |
| kube-state-metrics | 1 | Kubernetes object metrics |
| node-exporter | 2 | node-level CPU, memory, filesystem, network |
| Loki | 1 | log storage |
| Jaeger | 1 | trace storage and UI |
| OpenTelemetry Collector | 1 | trace ingest, batching, forwarding |

## Reaching the UIs

Neither Grafana nor Jaeger is exposed to the internet, deliberately — both would otherwise be
reachable without authentication. Use a port-forward:

```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
kubectl -n monitoring port-forward svc/jaeger 16686:16686
# http://localhost:3000   and   http://localhost:16686
```

Grafana credentials:

```bash
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath='{.data.admin-user}' | base64 -d ; echo
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo
```

## Five failures, and what each taught

### 1. `node-exporter` could not be admitted

```
is forbidden: violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true,
hostPID=true), hostPath volumes (volumes "proc", "sys", "root"), hostPort 9100
```

The DaemonSet reported `DESIRED 0` with no pods. node-exporter reads node metrics through
`/proc`, `/sys` and the host network — that is its function, and no Pod Security Standard
permits it. Kubernetes has no per-pod exemption, so the namespace level had to change.

The `monitoring` namespace is now `enforce: privileged`, with `audit` and `warn` still
`restricted` — so every privileged pod is still recorded in the audit log and reported by
kubectl. The relaxation is permissive but not silent. The application and its databases remain
under `restricted`, where host access is impossible.

Without node metrics, the most likely failure on a small cluster — a node running out of memory
or disk — would have been invisible.

### 2. A single ServiceMonitor would have scraped every service twice

The five services do not expose metrics at the same path. Verified against the running cluster:

```
shop-catalog  -> /actuator/prometheus=404  /metrics=200
shop-cart     -> /actuator/prometheus=200  /metrics=404
shop-checkout -> /actuator/prometheus=404  /metrics=200
shop-orders   -> /actuator/prometheus=200  /metrics=404
shop-ui       -> /actuator/prometheus=200  /metrics=404
```

One ServiceMonitor listing both paths on the same port scrapes every Service **twice** — once
succeeding, once returning 404 on every interval forever. Prometheus would report half the
targets as permanently down, and that noise would hide a real failure.

Fixed by labelling each Service `polyglot-shop/metrics-path` (`actuator` or `direct`) and using
two ServiceMonitors. A service added later that lacks the label simply is not scraped — visible
as a missing target rather than a permanently failing one.

### 3. Loki would not start: a configuration key that does not exist

```
failed parsing config: yaml: unmarshal errors:
  line 44: field ingestion_burst_size_policy not found in type validation.plain
```

`ingestion_burst_size_policy` is not a Loki setting. The correct key is
`ingestion_rate_strategy`. Loki validates its config strictly and refuses to start on an unknown
field, which is helpful once you know the field is wrong — the message names it precisely.

### 4. The collector image tag did not exist

```
failed to resolve reference "docker.io/otel/opentelemetry-collector-contrib:0.115.0": not found
```

`0.115.0` was a guess and had never existed. The tag was then read from the registry's tag list —
`0.162.0` is the newest stable release — rather than assumed again. Collector versions are
published frequently and no version is obvious.

### 5. The collector's component names are deprecated

```
"otlp" alias is deprecated; use "otlp_grpc" instead
"resourcedetection" alias is deprecated; use "resource_detection" instead
```

The exporter had been named `otlp`, which is the **receiver's** name; it worked only through a
deprecated alias. Both names were confirmed against the binary's own component list
(`otelcol-contrib components`) rather than assumed.

### 6. Tracing was disabled in the application images

```
AutoConfiguredOpenTelemetrySdk found on classpath but automatic configuration is disabled.
To enable, run your JVM with -Dotel.java.global-autoconfigure.enabled=true
```

This was the most instructive failure, because **nothing looked broken**. The collector reported
"Everything is ready", the application logged no error, and every pod was `Ready`. But every
OTEL_* environment variable was inert, and Jaeger stayed empty.

The OpenTelemetry SDK is in these images, but this build has autoconfiguration disabled. The fix
is a JVM flag, now set in the charts:

```
-XX:MaxRAMPercentage=75.0 -Dotel.java.global-autoconfigure.enabled=true
```

The lesson: an exporter that is configured but disabled is indistinguishable from a working one
until you check the counters. `otelcol_receiver_accepted_spans` at zero was the only signal.

### 7. The service address did not resolve

The application charts point OTLP at `otel-collector.monitoring.svc.cluster.local:4317`, but the
Helm fullname helper names the Service `otel-collector-opentelemetry-collector`. The short name
did not resolve, so spans would have been dropped on a name-resolution error.

This is the **third** occurrence of the same class of bug in this project (the cart's DynamoDB
endpoint and the UI's service endpoints were the others). Fixed with the alias-Service pattern,
which is now used in two places.

## Cost

The observability stack adds about **$0.02/hour** in EBS storage:

| Volume | Size |
|---|---|
| Prometheus | 10 GiB |
| Loki | 5 GiB |
| Alertmanager | 2 GiB |

## Limitations

1. **Loki receives no logs yet.** The datasource is configured and reachable, and Loki runs, but
   nothing ships pod logs into it — that needs a collecting agent (a DaemonSet such as Alloy or
   Promtail, or the collector's `filelog` receiver with host access). Until then, log panels in
   Grafana will be empty. Metrics and traces are complete; logs are not.
2. **Alertmanager has no receiver.** Alerts evaluate and are visible in its UI, but nothing is
   delivered anywhere. Routing needs a real Slack, email or PagerDuty endpoint.
3. **Prometheus retention is 3 days**, sized to the budget rather than to a production policy.
4. **Jaeger stores traces in memory** and loses history on restart.
5. **Node memory limits are at 100% of allocatable capacity.** Requests are at 33%, so nothing is
   Pending and the scheduler is content — but the limits are oversubscribed, so a genuine memory
   spike would cause node-level eviction. A third node would remove that risk.
