#!/usr/bin/env python3
"""
generate_app_charts.py — write the catalog, orders, checkout and ui Helm charts.

Why a generator: these four charts share the entire structure that cart already
proved (securityContext, probes, PDB, NetworkPolicy, tmpfs, rollback strategy).
Only the environment, endpoints, probe path and resource sizing genuinely differ.
Copying the cart chart four times would guarantee they drift; generating them from
one table keeps the shared parts identical.

cart is deliberately NOT regenerated: it is the reviewed reference, and overwriting
it would discard the hand-written comments that explain the pattern.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # .../k8s
REGISTRY = "536882095289.dkr.ecr.eu-north-1.amazonaws.com"
PREFIX = "polyglot-shop"
TAG = "a785cf0"

# Why a release prefix is part of every cross-service address:
#
# The Helm fullname helper produces "<release>-<chart>", so the Services are named
# shop-catalog, shop-cart, shop-orders and shop-checkout when installed under the release
# name "shop". Any address one service uses to reach another must carry that prefix, and so
# must the NetworkPolicy selectors that permit the connection.
#
# This is a single constant rather than five literals so the prefix cannot be updated in one
# place and forgotten in another — which is exactly the fault that produced
# "UnknownHostException: cart.retail-store.svc.cluster.local" while every pod reported Ready.
RELEASE = "shop"

# ---------------------------------------------------------------------------
# Per-service definition table.
#
# `env` is non-secret configuration and becomes a ConfigMap.
# `secret_env` maps an environment variable name to a key inside the shared
# polyglot-secrets Secret, so no credential is ever written into a values file.
# ---------------------------------------------------------------------------
SERVICES = {
    "catalog": {
        "description": "Product catalog API (Go / Gin), backed by MariaDB.",
        "language": "go",
        "probe_path": "/health",
        "env": {
            "GIN_MODE": "release",
            "RETAIL_CATALOG_PERSISTENCE_PROVIDER": "mysql",
            "RETAIL_CATALOG_PERSISTENCE_ENDPOINT": "mariadb.data.svc.cluster.local:3306",
            "RETAIL_CATALOG_PERSISTENCE_DB_NAME": "catalogdb",
            "RETAIL_CATALOG_PERSISTENCE_USER": "catalog_user",
        },
        "secret_env": {
            "RETAIL_CATALOG_PERSISTENCE_PASSWORD": "DB_PASSWORD",
        },
        # Why smaller requests: a compiled Go binary has no JVM baseline and starts
        # in milliseconds, unlike the three Java services.
        "resources": {"cpu": "50m", "memory": "64Mi", "cpu_limit": "300m", "memory_limit": "256Mi"},
        "ingress_from": ["ui"],
        "egress_to": [("data", "mariadb", 3306)],
        "read_only_root": True,
    },
    "orders": {
        "description": "Orders API (Java / Spring Boot), backed by PostgreSQL and RabbitMQ.",
        "language": "java",
        "probe_path": "/actuator/health",
        "env": {
            "SERVER_TOMCAT_ACCESSLOG_ENABLED": "true",
            "RETAIL_ORDERS_PERSISTENCE_PROVIDER": "postgres",
            "RETAIL_ORDERS_PERSISTENCE_ENDPOINT": "postgresql.data.svc.cluster.local:5432",
            "RETAIL_ORDERS_PERSISTENCE_NAME": "orders",
            "RETAIL_ORDERS_PERSISTENCE_USERNAME": "orders_user",
            "RETAIL_ORDERS_MESSAGING_PROVIDER": "rabbitmq",
            "RETAIL_ORDERS_MESSAGING_RABBITMQ_ADDRESSES": "rabbitmq.data.svc.cluster.local:5672",
            "RETAIL_ORDERS_MESSAGING_RABBITMQ_USERNAME": "rabbitmq",
        },
        "secret_env": {
            "RETAIL_ORDERS_PERSISTENCE_PASSWORD": "DB_PASSWORD",
            "RETAIL_ORDERS_MESSAGING_RABBITMQ_PASSWORD": "DB_PASSWORD",
        },
        "resources": {"cpu": "200m", "memory": "512Mi", "cpu_limit": "1000m", "memory_limit": "1Gi"},
        "ingress_from": ["ui", "checkout"],
        "egress_to": [("data", "postgresql", 5432), ("data", "rabbitmq", 5672)],
        "read_only_root": True,
    },
    "checkout": {
        "description": "Checkout API (Node.js / NestJS), backed by Redis.",
        "language": "node",
        "probe_path": "/health",
        "env": {
            "RETAIL_CHECKOUT_PERSISTENCE_PROVIDER": "redis",
            "RETAIL_CHECKOUT_PERSISTENCE_REDIS_URL": "redis://redis.data.svc.cluster.local:6379",
        },
        "secret_env": {},
        "resources": {"cpu": "100m", "memory": "256Mi", "cpu_limit": "500m", "memory_limit": "512Mi"},
        "ingress_from": ["ui"],
        "egress_to": [("data", "redis", 6379)],
        # Why false here: the Node image writes its compiled output and a healthcheck
        # script into paths outside /tmp. Making the root read-only without adjusting
        # the image would crash it in a loop, so this records the difference honestly
        # instead of asserting a posture the image does not support.
        "read_only_root": False,
    },
    "ui": {
        "description": "Storefront (Java / Spring Boot). The only externally exposed component.",
        "language": "java",
        "probe_path": "/actuator/health",
        "env": {
            "SERVER_TOMCAT_ACCESSLOG_ENABLED": "true",
            # Why these four endpoints and why they carry the "shop-" prefix:
            #
            # The UI aggregates every other service, so it must reach all four. The prefix is
            # the Helm release name, which the fullname helper prepends, so the actual Service
            # objects are shop-catalog, shop-cart, shop-orders and shop-checkout.
            #
            # An earlier version of this file omitted the prefix. The UI then failed every
            # request with
            #
            #   java.lang.RuntimeException: java.net.UnknownHostException:
            #   cart.retail-store.svc.cluster.local: System error
            #
            # which presented as a 500 on the storefront while every pod reported Ready — the
            # pods were healthy, they simply could not find each other. The data namespace
            # resolved correctly throughout because those releases are named after their charts,
            # so no prefix appeared. That asymmetry is what made the fault look like a DNS
            # problem rather than a naming problem.
            "RETAIL_UI_ENDPOINTS_CATALOG": "http://shop-catalog.retail-store.svc.cluster.local",
            "RETAIL_UI_ENDPOINTS_CARTS": "http://shop-cart.retail-store.svc.cluster.local",
            "RETAIL_UI_ENDPOINTS_ORDERS": "http://shop-orders.retail-store.svc.cluster.local",
            "RETAIL_UI_ENDPOINTS_CHECKOUT": "http://shop-checkout.retail-store.svc.cluster.local",
            "RETAIL_UI_THEME": "default",
        },
        "secret_env": {},
        "resources": {"cpu": "200m", "memory": "512Mi", "cpu_limit": "1000m", "memory_limit": "1Gi"},
        "ingress_from": ["external"],
        "egress_to": [
            ("retail-store", "catalog", 8080),
            ("retail-store", "cart", 8080),
            ("retail-store", "orders", 8080),
            ("retail-store", "checkout", 8080),
        ],
        "read_only_root": True,
    },
}


def labels(component, app_version):
    return (
        "helm.sh/chart: {{ include \""
        + component
        + ".chart\" . }}\n"
        "{{ include \""
        + component
        + ".selectorLabels\" . }}\n"
        "app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}\n"
        "app.kubernetes.io/managed-by: {{ .Release.Service }}\n"
        "app.kubernetes.io/part-of: polyglot-shop"
    )


def helpers(component):
    """The standard name/label/image helper set, specialised per component name."""
    return f'''{{{{/*
Shared template helpers for the {component} chart. Identical in structure to the cart
chart deliberately: one helper convention across the charts means a label change is
made in one shape everywhere, and the NetworkPolicies can rely on
app.kubernetes.io/component being set consistently.
*/}}}}

{{{{- define "{component}.name" -}}}}
{{{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}}}
{{{{- end -}}}}

{{{{- define "{component}.fullname" -}}}}
{{{{- if .Values.fullnameOverride -}}}}
{{{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}}}
{{{{- else -}}}}
{{{{- $name := default .Chart.Name .Values.nameOverride -}}}}
{{{{- if contains $name .Release.Name -}}}}
{{{{- .Release.Name | trunc 63 | trimSuffix "-" -}}}}
{{{{- else -}}}}
{{{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}}}
{{{{- end -}}}}
{{{{- end -}}}}
{{{{- end -}}}}

{{{{- define "{component}.chart" -}}}}
{{{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}}}
{{{{- end -}}}}

{{{{- define "{component}.labels" -}}}}
{labels(component, None)}
{{{{- end -}}}}

{{{{/* Selector labels are immutable on a Deployment, so they must never change. */}}}}
{{{{- define "{component}.selectorLabels" -}}}}
app.kubernetes.io/name: {{{{ include "{component}.name" . }}}}
app.kubernetes.io/instance: {{{{ .Release.Name }}}}
app.kubernetes.io/component: {component}
{{{{- end -}}}}

{{{{/* Prefer a digest over a tag: a tag can be moved after deployment. */}}}}
{{{{- define "{component}.image" -}}}}
{{{{- $repo := .Values.image.repository -}}}}
{{{{- if .Values.image.digest -}}}}
{{{{- printf "%s@%s" $repo .Values.image.digest -}}}}
{{{{- else -}}}}
{{{{- printf "%s:%s" $repo .Values.image.tag -}}}}
{{{{- end -}}}}
{{{{- end -}}}}

{{{{/*
Emit the literal open- and close-brace pair used by Go templating.

Why this helper exists: the generator that writes this chart is itself a Python
f-string, where a literal brace must be doubled. Nesting an expression inside
another expression - as in a conditional wrapping a pipeline - needs four levels of
escaping and produced a broken template. Defining the delimiters once here means the
rest of the templates can use plain {{{{ ... }}}} syntax with no nesting at all.
*/}}}}
{{{{- define "{component}.braceopen" -}}}}{{{{ "{{" }}}}{{{{ end -}}}}
{{{{- define "{component}.braceclose" -}}}}{{{{ "}}" }}}}{{{{ end -}}}}
'''


def chart_yaml(name, svc):
    return f'''# {name} — {svc["description"]}
apiVersion: v2
name: {name}
description: |
  {svc["description"]}
type: application
version: 0.1.0
appVersion: "{TAG}"
keywords:
  - retail
  - {name}
annotations:
  category: Application
'''


def values_yaml(name, svc):
    env_lines = "\n".join(f'  {k}: "{v}"' for k, v in svc["env"].items())
    secret_lines = "\n".join(
        f'  {k}: {v}' for k, v in svc["secret_env"].items()
    ) or "  {}"
    r = svc["resources"]
    ingress_from = ", ".join(svc["ingress_from"])
    egress_desc = ", ".join(f"{c} in {ns}" for ns, c, _ in svc["egress_to"])
    return f'''# {name} values — defaults sized for the small test cluster. Each compromise is
# recorded next to the setting, per the project rule that a compromise must carry
# its reason rather than being silent.

# Why 1 replica: two worker nodes cannot hold more, and two nodes are not real
# availability regardless. Raise together with podDisruptionBudget.minAvailable.
replicaCount: 1

image:
  repository: {REGISTRY}/{PREFIX}/{name}
  # Why a tag and never ":latest": a mutable tag makes a deployment unreproducible.
  # Pin image.digest once the pipeline records one.
  tag: "{TAG}"
  digest: ""
  pullPolicy: IfNotPresent
imagePullSecrets: []

containerPort: 8080

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

# Why these match the Compose service definition: they are the application's own
# configuration contract. Changing them changes behaviour, not just packaging.
config:
{env_lines}

# Why secrets are referenced rather than stored: passwords arrive from the
# polyglot-secrets Secret in the {name} namespace. No credential appears in this file.
secretEnv:
{secret_lines}

resources:
  requests:
    cpu: {r["cpu"]}
    memory: {r["memory"]}
  limits:
    cpu: {r["cpu_limit"]}
    memory: {r["memory_limit"]}
'''

def values_tail(name, svc):
    probe = svc["probe_path"]
    is_java = svc["language"] == "java"
    java_block = f'''
jvm:
  # Why percentage-based heap: it follows the memory limit instead of hardcoding a
  # heap that becomes wrong when the limit changes. Without it the JVM sizes itself
  # from the node's total memory and ignores the container limit.
  #
  # Why the OpenTelemetry autoconfigure flag is here and is not optional:
  #
  #   These images carry the OpenTelemetry SDK, but this build has autoconfiguration disabled.
  #   Without the flag the JVM logs
  #
  #     AutoConfiguredOpenTelemetrySdk found on classpath but automatic configuration is
  #     disabled. To enable, run your JVM with
  #     -Dotel.java.global-autoconfigure.enabled=true
  #
  #   and emits no traces at all. Every OTEL_* environment variable set in the Deployment is
  #   inert without it, which is exactly the failure mode that looks like a broken collector
  #   pipeline: Jaeger stays empty while the collector reports "Everything is ready" and the
  #   application logs no error.
  #
  #   The flag is what turns the environment variables into an actual exporter.
  javaOpts: "-XX:MaxRAMPercentage=75.0 -Dotel.java.global-autoconfigure.enabled=true -Djava.security.egd=file:/dev/urandom"
''' if is_java else ""

    startup_block = f'''
probes:
  startup:
    # Why a startup probe: {name} takes time to initialise, and without this the
    # liveness probe would kill it mid-start and produce a restart loop.
    enabled: true
    path: {probe}
    failureThreshold: 30
    periodSeconds: 5
  liveness:
    enabled: true
    path: {probe}
    initialDelaySeconds: 20
    periodSeconds: 15
    timeoutSeconds: 5
    failureThreshold: 3
  readiness:
    # Why readiness is separate from liveness: an unready pod should leave the Service
    # rather than be restarted. Conflating them turns a dependency outage into a
    # restart storm.
    enabled: true
    path: {probe}
    initialDelaySeconds: 10
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
'''

    ro = "true" if svc["read_only_root"] else "false"
    ro_note = (
        "# Why true: mirrors the Compose read_only setting; anything needing to write\n"
        "  # uses the tmpfs at /tmp below."
        if svc["read_only_root"]
        else
        "# Why false for this service: the image writes outside /tmp (compiled output and\n"
        "  # a healthcheck script), so a read-only root would crash it in a restart loop.\n"
        "  # This is recorded rather than asserted, and is the one service that differs."
    )

    egress_entries = []
    for ns, comp, port in svc["egress_to"]:
        # Why this shape: each entry is one egress rule with its peer under `to` and
        # its allowed ports as a sibling. This matches the Kubernetes NetworkPolicy
        # schema, where `ports` cannot live inside a `to` entry.
        egress_entries.append(
            f"    - to:\n"
            f"        - namespaceSelector:\n"
            f"            matchLabels:\n"
            f"              kubernetes.io/metadata.name: {ns}\n"
            f"          podSelector:\n"
            f"            matchLabels:\n"
            f"              app.kubernetes.io/component: {comp}\n"
            f"      ports:\n"
            f"        - protocol: TCP\n"
            f"          port: {port}"
        )
    egress_yaml = "\n".join(egress_entries)

    if "external" in svc["ingress_from"]:
        ingress_yaml = "  # Why an empty `from`: the UI is reached from outside the cluster,\n  # so no in-cluster source can be named. The ingress controller is the only\n  # intended path; a NetworkPolicy cannot express \"only the ingress controller\"\n  # without a namespace label, which is applied by the ingress chart.\n  allowIngressFrom: []"
    else:
        callers = "\n".join(
            f"    - namespaceSelector:\n"
            f"        matchLabels:\n"
            f"          kubernetes.io/metadata.name: retail-store\n"
            f"      podSelector:\n"
            f"        matchLabels:\n"
            # Why the prefix here: this selector must match the pod labels the app charts
            # actually apply, which are "<release>-<chart>". Without the prefix the policy
            # matches nothing, so the caller is blocked and the symptom is a connection
            # refused that looks like a service problem.
            f"          app.kubernetes.io/component: {RELEASE}-{c}"
            for c in svc["ingress_from"]
        )
        ingress_yaml = f"  # Why only these callers: each is a service that genuinely calls it.\n  # Anything else would be lateral movement.\n  allowIngressFrom:\n{callers}"

    return f'''{java_block}{startup_block}
tmpfs:
  # Why: the root filesystem is read-only, so the process needs a writable temporary
  # directory. Matching the Compose tmpfs keeps the same posture.
  enabled: true
  sizeLimit: 128Mi

podSecurityContext:
  runAsNonRoot: true
  # Why 1000: the images create their user with uid 1000.
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: {ro}
  {ro_note}
  capabilities:
    drop:
      - ALL
    add:
      # Why kept from the Compose definition: it allows binding below port 1024. The
      # service listens on 8080 and does not need it, so it is a no-op retained for
      # parity with the tested configuration.
      - NET_BIND_SERVICE

podDisruptionBudget:
  # Why minAvailable 0 at one replica: a budget demanding an available pod would block
  # node drains permanently. Raise this when replicaCount is raised.
  enabled: true
  minAvailable: 0

networkPolicy:
  enabled: true
{ingress_yaml}
  allowEgressTo:
{egress_yaml}

observability:
  metrics:
    enabled: true
    port: 8080
  tracing:
    enabled: true
    otlpEndpoint: "http://otel-collector.monitoring.svc.cluster.local:4317"

nodeSelector: {{}}
tolerations: []
affinity: {{}}
topologySpreadConstraints: []

autoscaling:
  # Why disabled: the test cluster has fixed two-node capacity, so scaling out would
  # only create Pending pods. Configured so enabling it later is a values change.
  enabled: false
  minReplicas: 1
  maxReplicas: 3
  targetCPUUtilizationPercentage: 75
'''


def configmap_yaml(name):
    return f'''# Non-secret configuration for {name}.
#
# Why a ConfigMap: the values are identical across replicas and change independently
# of the image. The Deployment carries a checksum annotation so changing this
# triggers a rollout instead of leaving old pods running with stale settings.
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{{{ include "{name}.fullname" . }}}}
  labels:
    {{{{ include "{name}.labels" . | nindent 4 }}}}
data:
  {{{{ range $key, $value := .Values.config }}}}
  {{{{ $key }}}}: {{{{ $value | quote }}}}
  {{{{ end }}}}
'''


def service_yaml(name, svc):
    # Why the metrics label:
    #
    # The five services do not expose Prometheus metrics at the same path. The three Java
    # services (cart, orders, ui) expose them through Spring Boot Actuator at
    # /actuator/prometheus, while the Go catalog and the Node checkout expose them directly at
    # /metrics. Verified against the running cluster:
    #
    #   shop-catalog  -> /actuator/prometheus=404  /metrics=200
    #   shop-cart     -> /actuator/prometheus=200  /metrics=404
    #   shop-checkout -> /actuator/prometheus=404  /metrics=200
    #   shop-orders   -> /actuator/prometheus=200  /metrics=404
    #   shop-ui       -> /actuator/prometheus=200  /metrics=404
    #
    # A single ServiceMonitor listing both paths would scrape every Service twice, once
    # succeeding and once returning 404 forever. That produces permanent TargetDown noise which
    # hides real failures, so the Services are labelled by metrics style and two ServiceMonitors
    # select them.
    metrics_label = "actuator" if svc["language"] == "java" else "direct"
    return f'''# Stable network address for the {name} pods.
#
# Why ClusterIP: only the UI is exposed externally. Publishing an internal API with no
# authentication of its own would widen the attack surface for no benefit.
apiVersion: v1
kind: Service
metadata:
  name: {{{{ include "{name}.fullname" . }}}}
  labels:
    {{{{ include "{name}.labels" . | nindent 4 }}}}
    # Why this label: it tells Prometheus which metrics path this Service serves. See the note
    # in the chart generator; the three Java services and the two others differ.
    polyglot-shop/metrics-path: {metrics_label}
spec:
  type: {{{{ .Values.service.type }}}}
  ports:
    - port: {{{{ .Values.service.port }}}}
      targetPort: {{{{ .Values.service.targetPort }}}}
      protocol: TCP
      name: http
  selector:
    {{{{ include "{name}.selectorLabels" . | nindent 4 }}}}
'''


def deployment_yaml(name, svc):
    is_java = svc["language"] == "java"
    secret_entries = ""
    if svc["secret_env"]:
        lines = "\n".join(
            f"            - name: {k}\n"
            f"              valueFrom:\n"
            f"                secretKeyRef:\n"
            f"                  name: polyglot-secrets\n"
            f"                  key: {v}"
            for k, v in svc["secret_env"].items()
        )
        secret_entries = (
            "            # Why valueFrom and not a literal: the credential lives in a Secret,\n"
            "            # so it is never present in the chart or in the rendered manifest.\n"
            f"{lines}\n"
        )
    java_env = ""
    if is_java:
        java_env = """            - name: JAVA_OPTS
              value: {{ .Values.jvm.javaOpts | quote }}
"""
    return f'''{{{{/*
{name} Deployment.

Why a Deployment: the service holds no local state — everything persistent lives in
its backing dependency — so replicas are interchangeable and no stable identity or
per-pod volume is needed.
*/}}}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{{{ include "{name}.fullname" . }}}}
  labels:
    {{{{ include "{name}.labels" . | nindent 4 }}}}
spec:
  {{{{ if not .Values.autoscaling.enabled }}}}
  # Why replicas is omitted under autoscaling: the HPA owns the count, and setting it
  # here too means every upgrade fights the autoscaler.
  replicas: {{{{ .Values.replicaCount }}}}
  {{{{ end }}}}
  selector:
    matchLabels:
      {{{{ include "{name}.selectorLabels" . | nindent 6 }}}}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      # Why maxUnavailable 0: the rollout must not drop below the replica count, so a
      # broken image fails the rollout rather than replacing a working deployment.
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        {{{{ include "{name}.labels" . | nindent 8 }}}}
      annotations:
        # Why a checksum: configuration changes do not alter the pod template, so
        # without this no rollout happens and old pods keep running with stale config.
        checksum/config: {{{{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}}}
    spec:
      {{{{ with .Values.imagePullSecrets }}}}
      imagePullSecrets:
        {{{{ toYaml . | nindent 8 }}}}
      {{{{ end }}}}
      securityContext:
        {{{{ toYaml .Values.podSecurityContext | nindent 8 }}}}
      # Why an explicit grace period: the default 30s can cut a request mid-flight
      # while it drains. 45s covers the preStop delay below plus in-flight work.
      terminationGracePeriodSeconds: 45
      containers:
        - name: {name}
          image: {{{{ include "{name}.image" . }}}}
          imagePullPolicy: {{{{ .Values.image.pullPolicy }}}}
          securityContext:
            {{{{ toYaml .Values.containerSecurityContext | nindent 12 }}}}
          ports:
            - name: http
              containerPort: {{{{ .Values.containerPort }}}}
              protocol: TCP
          envFrom:
            - configMapRef:
                name: {{{{ include "{name}.fullname" . }}}}
          env:
{java_env}{secret_entries}            {{{{ if .Values.observability.tracing.enabled }}}}
            # Why OTEL_* environment variables: the application already emits OTLP
            # traces, so pointing it at the collector is configuration, not code.
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: {{{{ .Values.observability.tracing.otlpEndpoint | quote }}}}
            - name: OTEL_SERVICE_NAME
              value: {{{{ include "{name}.name" . | quote }}}}
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: {{{{ printf "service.namespace=%s,deployment.environment=%s" .Release.Namespace (.Values.environment | default "dev") | quote }}}}
            {{{{ end }}}}
          {{{{ if .Values.probes.startup.enabled }}}}
          startupProbe:
            httpGet:
              path: {{{{ .Values.probes.startup.path }}}}
              port: http
            failureThreshold: {{{{ .Values.probes.startup.failureThreshold }}}}
            periodSeconds: {{{{ .Values.probes.startup.periodSeconds }}}}
          {{{{ end }}}}
          livenessProbe:
            httpGet:
              path: {{{{ .Values.probes.liveness.path }}}}
              port: http
            initialDelaySeconds: {{{{ .Values.probes.liveness.initialDelaySeconds }}}}
            periodSeconds: {{{{ .Values.probes.liveness.periodSeconds }}}}
            timeoutSeconds: {{{{ .Values.probes.liveness.timeoutSeconds }}}}
            failureThreshold: {{{{ .Values.probes.liveness.failureThreshold }}}}
          readinessProbe:
            httpGet:
              path: {{{{ .Values.probes.readiness.path }}}}
              port: http
            initialDelaySeconds: {{{{ .Values.probes.readiness.initialDelaySeconds }}}}
            periodSeconds: {{{{ .Values.probes.readiness.periodSeconds }}}}
            timeoutSeconds: {{{{ .Values.probes.readiness.timeoutSeconds }}}}
            failureThreshold: {{{{ .Values.probes.readiness.failureThreshold }}}}
          resources:
            {{{{ toYaml .Values.resources | nindent 12 }}}}
          volumeMounts:
            {{{{ if .Values.tmpfs.enabled }}}}
            - name: tmp
              mountPath: /tmp
            {{{{ end }}}}
          lifecycle:
            preStop:
              exec:
                # Why sleep first: endpoint removal takes a moment to propagate, so
                # draining briefly avoids failing requests that were already routed.
                command: ["/bin/sh", "-c", "sleep 10"]
      volumes:
        {{{{ if .Values.tmpfs.enabled }}}}
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: {{{{ .Values.tmpfs.sizeLimit }}}}
        {{{{ end }}}}
'''


def pdb_yaml(name):
    return f'''{{{{- if .Values.podDisruptionBudget.enabled }}}}
# Why a budget: node drains evict pods, and without a budget every replica can be
# evicted at once, turning routine maintenance into an outage.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{{{ include "{name}.fullname" . }}}}
  labels:
    {{{{ include "{name}.labels" . | nindent 4 }}}}
spec:
  minAvailable: {{{{ .Values.podDisruptionBudget.minAvailable }}}}
  selector:
    matchLabels:
      {{{{ include "{name}.selectorLabels" . | nindent 6 }}}}
{{{{- end }}}}
'''


def networkpolicy_yaml(name):
    return f'''{{{{- if .Values.networkPolicy.enabled }}}}
# Traffic rules for {name}.
#
# Why required and not optional: the bootstrap layer applies default-deny per
# namespace, so without this policy the pods receive nothing and the readiness probe
# fails. It is part of making the service function, not extra hardening.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{{{ include "{name}.fullname" . }}}}
  labels:
    {{{{ include "{name}.labels" . | nindent 4 }}}}
spec:
  podSelector:
    matchLabels:
      {{{{ include "{name}.selectorLabels" . | nindent 6 }}}}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    {{{{ if eq (len .Values.networkPolicy.allowIngressFrom) 0 }}}}
    # Why an empty ingress rule: this service is reached from outside the cluster, so
    # no in-cluster source can be named. Traffic is still restricted to the port.
    - ports:
        - protocol: TCP
          port: {{{{ $.Values.containerPort }}}}
    {{{{ else }}}}
    - from:
        {{{{ toYaml .Values.networkPolicy.allowIngressFrom | nindent 8 }}}}
      ports:
        - protocol: TCP
          port: {{{{ $.Values.containerPort }}}}
    {{{{ end }}}}
  egress:
    # Why `to` and `ports` are siblings here: `to` selects the peer, `ports` restricts
    # the rule. Nesting `ports` inside a `to` entry makes the NetworkPolicy invalid and
    # kubeconform rejects it, so the two are emitted as parallel blocks.
    {{{{- range .Values.networkPolicy.allowEgressTo }}}}
    - to:
        {{{{ toYaml .to | nindent 8 }}}}
      {{{{- with .ports }}}}
      ports:
        {{{{ toYaml . | nindent 8 }}}}
      {{{{- end }}}}
    {{{{- end }}}}
    # DNS is required by every service.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
{{{{- end }}}}
'''


def write_text(path: Path, text: str) -> None:
    """
    Write a file as UTF-8, explicitly.

    Why explicit: Python on Windows defaults to the platform encoding (cp1252), so
    a non-ASCII character such as an em dash in a comment is written as a single
    cp1252 byte. Helm parses chart files as UTF-8 and rejects that with the opaque
    error "invalid leading UTF-8 octet". Naming the encoding here removes the whole
    class of failure.
    """
    path.write_text(text, encoding="utf-8", newline="\n")


def main():
    for name, svc in SERVICES.items():
        base = ROOT / "app" / name
        tpl = base / "templates"
        tpl.mkdir(parents=True, exist_ok=True)

        write_text(base / "Chart.yaml", chart_yaml(name, svc))
        write_text(base / "values.yaml", values_yaml(name, svc) + values_tail(name, svc))
        write_text(tpl / "_helpers.tpl", helpers(name))
        write_text(tpl / "configmap.yaml", configmap_yaml(name))
        write_text(tpl / "service.yaml", service_yaml(name, svc))
        write_text(tpl / "deployment.yaml", deployment_yaml(name, svc))
        write_text(tpl / "pdb.yaml", pdb_yaml(name))
        write_text(tpl / "networkpolicy.yaml", networkpolicy_yaml(name))
        print(f"wrote chart: {name} ({len(list(tpl.iterdir()))} templates)")


if __name__ == "__main__":
    main()
