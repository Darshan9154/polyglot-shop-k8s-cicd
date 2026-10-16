#!/usr/bin/env python3
"""
generate_infra_charts.py — write the backing-service Helm charts.

These are the five dependencies the application needs: MariaDB (catalog), PostgreSQL
(orders), Redis (checkout), RabbitMQ (orders) and DynamoDB Local (cart).

Why StatefulSets: unlike the application services, these hold data and need a stable
network identity. A StatefulSet gives each pod a predictable name and its own
PersistentVolumeClaim that survives a reschedule. A Deployment with a shared volume
would lose the data on any re-scheduling that lands on another node.

Why these charts exist at all rather than using managed services: the project runs
against a fixed credit budget, and managed equivalents (RDS, ElastiCache, Amazon MQ)
cost per hour. The application charts take a host and port, so switching to managed
services later is a values change, not a rewrite. That tradeoff is recorded in the
values files rather than hidden.

Every chart here is written to the same standard as the application charts: explicit
resource requests and limits, security contexts, probes, a PDB and a NetworkPolicy.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # .../k8s
DATA_NS = "data"

# ---------------------------------------------------------------------------
# Definition table. `component` is the value the application NetworkPolicies select
# on, so it must match the app charts exactly or traffic is blocked.
# ---------------------------------------------------------------------------
INFRA = {
    "mariadb": {
        "description": "MariaDB 10.9 — the catalog service's product database.",
        "image": "mariadb",
        "tag": "10.9",
        "component": "mariadb",
        "port": 3306,
        "port_name": "mysql",
        "env": {
            "MYSQL_DATABASE": "catalogdb",
            "MYSQL_USER": "catalog_user",
            # Why MYSQL_ALLOW_EMPTY_PASSWORD is NOT reproduced: the Compose file set it to
            # true alongside a real password, which is redundant at best and a hazard at
            # worst. The password comes from the Secret instead.
        },
        "secret_env": {
            # Why MYSQL_ROOT_PASSWORD: the image refuses to initialise without it.
            "MYSQL_ROOT_PASSWORD": "DB_PASSWORD",
            "MYSQL_PASSWORD": "DB_PASSWORD",
        },
        "storage": "2Gi",
        "storage_mount": "/var/lib/mysql",
        "probe": {
            "readiness": {"command": ["sh", "-c", "mysqladmin ping -h 127.0.0.1 -u root -p\"$MYSQL_ROOT_PASSWORD\""]},
            "liveness": {"tcpSocket": True},
        },
        "resources": {"cpu": "100m", "memory": "256Mi", "cpu_limit": "500m", "memory_limit": "512Mi"},
        "startup_failure_threshold": 30,
        "run_as_user": 999,
        # Why 999: the MariaDB image's own mysql user, so the volume is writable.
        "allow_ingress_from_app": ["catalog"],
    },
    "postgresql": {
        "description": "PostgreSQL 16 — the orders service's order database.",
        "image": "postgres",
        "tag": "16.1",
        "component": "postgresql",
        "port": 5432,
        "port_name": "postgresql",
        "env": {
            "POSTGRES_DB": "orders",
            "POSTGRES_USER": "orders_user",
            # Why PGDATA is moved to a subdirectory: initialising directly into the mount
            # root makes the volume look non-empty on restart, and the image then refuses
            # to initialise. This is the documented workaround.
            "PGDATA": "/var/lib/postgresql/data/pgdata",
        },
        "secret_env": {
            "POSTGRES_PASSWORD": "DB_PASSWORD",
        },
        "storage": "2Gi",
        "storage_mount": "/var/lib/postgresql/data",
        "probe": {
            "readiness": {"command": ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]},
            "liveness": {"command": ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]},
        },
        "resources": {"cpu": "100m", "memory": "256Mi", "cpu_limit": "500m", "memory_limit": "512Mi"},
        "startup_failure_threshold": 30,
        "run_as_user": 999,
        "allow_ingress_from_app": ["orders"],
    },
    "redis": {
        "description": "Redis 6 — the checkout service's session store.",
        "image": "redis",
        "tag": "6.0-alpine",
        "component": "redis",
        "port": 6379,
        "port_name": "redis",
        "env": {},
        "secret_env": {},
        "storage": "1Gi",
        "storage_mount": "/data",
        "probe": {
            "readiness": {"command": ["redis-cli", "ping"]},
            "liveness": {"tcpSocket": True},
        },
        "resources": {"cpu": "50m", "memory": "64Mi", "cpu_limit": "250m", "memory_limit": "256Mi"},
        "startup_failure_threshold": 20,
        "run_as_user": 999,
        "allow_ingress_from_app": ["checkout"],
    },
    "rabbitmq": {
        "description": "RabbitMQ 3 — the orders service's message broker.",
        "image": "rabbitmq",
        "tag": "3-management",
        "component": "rabbitmq",
        "port": 5672,
        "port_name": "amqp",
        "extra_ports": [{"name": "management", "port": 15672}],
        "env": {
            "RABBITMQ_DEFAULT_USER": "rabbitmq",
        },
        "secret_env": {
            "RABBITMQ_DEFAULT_PASS": "DB_PASSWORD",
        },
        "storage": "1Gi",
        "storage_mount": "/var/lib/rabbitmq",
        "probe": {
            # Why rabbitmq-diagnostics rather than a TCP check: a bound port only proves
            # the process is listening, not that the broker is ready to accept publishes.
            "readiness": {"command": ["rabbitmq-diagnostics", "-q", "ping"]},
            "liveness": {"tcpSocket": True},
        },
        "resources": {"cpu": "100m", "memory": "256Mi", "cpu_limit": "500m", "memory_limit": "512Mi"},
        "startup_failure_threshold": 20,
        "run_as_user": 999,
        "allow_ingress_from_app": ["orders"],
        # Why a longer probe timeout for this service only: rabbitmq-diagnostics is a shell
        # command that connects to the broker over the Erlang distribution protocol. It
        # routinely takes longer than the one-second default, and a timed-out probe is
        # indistinguishable from a failed broker.
        "probe_timeout_seconds": 15,
    },
    "dynamodb-local": {
        "description": "DynamoDB Local 1.20 — the cart service's key-value store.",
        "image": "amazon/dynamodb-local",
        "tag": "1.20.0",
        "component": "dynamodb",
        "port": 8000,
        "port_name": "dynamodb",
        # Why -sharedDb and an in-container data path: without -sharedDb each client
        # credential pair gets its own isolated database, so the cart service would appear
        # to lose data whenever the SDK used a different key.
        "args": ["-jar", "DynamoDBLocal.jar", "-sharedDb", "-dbPath", "/home/dynamodblocal/data"],
        "env": {},
        "secret_env": {},
        "storage": "1Gi",
        "storage_mount": "/home/dynamodblocal/data",
        "probe": {
            "readiness": {"tcpSocket": True},
            "liveness": {"tcpSocket": True},
        },
        "resources": {"cpu": "100m", "memory": "256Mi", "cpu_limit": "500m", "memory_limit": "512Mi"},
        "startup_failure_threshold": 20,
        "run_as_user": 1000,
        "allow_ingress_from_app": ["cart"],
        # Why an alias: the cart chart's endpoint is dynamodb.data.svc.cluster.local. This
        # chart's Service would otherwise be dynamodb-local, and DNS for the endpoint the
        # application uses would not resolve at all.
        "service_alias": "dynamodb",
    },
}


def write_text(path: Path, text: str) -> None:
    """Write UTF-8 explicitly; the platform default breaks chart parsing."""
    path.write_text(text, encoding="utf-8", newline="\n")


def chart_yaml(name, svc):
    return f'''# {name} — {svc["description"]}
#
# Why this is a separate chart from the application: it holds state, has different
# backup and upgrade requirements, and in a production environment would most likely
# be a managed service. Keeping it separate means the application chart can be pointed
# at a managed endpoint without changing any workload definition.
apiVersion: v2
name: {name}
description: |
  {svc["description"]}

  Deployed in-cluster for the test environment to avoid managed-service hourly costs.
  The application charts accept a host and port, so moving to RDS/ElastiCache/Amazon MQ
  is a values change rather than a rewrite.
type: application
version: 0.1.0
appVersion: "{svc["tag"]}"
keywords:
  - retail
  - data
annotations:
  category: Infrastructure
'''


def values_yaml(name, svc):
    env_lines = "\n".join(f'  {k}: "{v}"' for k, v in svc["env"].items())
    secret_lines = "\n".join(f'  {k}: {v}' for k, v in svc["secret_env"].items())
    if not env_lines:
        env_lines = "  {}"
    if not secret_lines:
        secret_lines = "  {}"
    r = svc["resources"]
    return f'''# {name} values.

image:
  repository: {svc["image"]}
  # Why a pinned tag: a database image on a floating tag can change its on-disk format
  # between restarts, which is the worst possible surprise for stored data.
  tag: "{svc["tag"]}"
  pullPolicy: IfNotPresent
imagePullSecrets: []

# Why 1 replica and not a cluster: this is a single-node test deployment with a 2-node
# cluster and a fixed budget. A real deployment uses an operator (the MariaDB or
# CloudNativePG operator) or a managed service, both of which own replication. Scaling
# this to 2 replicas manually would produce two independent databases, not a cluster —
# that would be worse than one, so it is left at 1 deliberately.
replicaCount: 1

component: {svc["component"]}
port: {svc["port"]}
portName: {svc["port_name"]}
{f'extraPorts: {svc["extra_ports"]}' if svc.get("extra_ports") else ""}
{f'args: {svc["args"]}' if svc.get("args") else ""}

# Why non-secret configuration only: credentials are referenced from the
# polyglot-secrets Secret in the {DATA_NS} namespace, so no password appears here.
config:
{env_lines}

# Maps an environment variable name to a key in the shared Secret.
secretEnv:
{secret_lines}

# Why an explicit storageClass of "" rather than a name: an empty value means "use the
# cluster default". The bootstrap folder documents the requirement that exactly one
# default StorageClass exists. Set a name here to override.
persistence:
  enabled: true
  storageClass: ""
  size: {svc["storage"]}
  # Why Retain and not Delete: deleting the StatefulSet must not silently destroy the
  # database. A claim left behind after `helm uninstall` is a deliberate paper trail.
  reclaimPolicyNote: "PVCs are left in place on uninstall; delete them explicitly."

resources:
  requests:
    cpu: {r["cpu"]}
    memory: {r["memory"]}
  limits:
    cpu: {r["cpu_limit"]}
    memory: {r["memory_limit"]}

# Why a long startup allowance: a database performs first-time initialisation on an
# empty volume, which takes far longer than a normal start. Without this the liveness
# probe kills it mid-initialisation, the volume is left half-written, and the next start
# fails differently. This is the single most common way a first database deploy fails.
startupProbe:
  enabled: true
  failureThreshold: {svc["startup_failure_threshold"]}
  periodSeconds: 10

podSecurityContext:
  runAsNonRoot: true
  # Why this uid: it is the image's own non-root user, so the mounted volume is writable
  # without relaxing the file mode.
  runAsUser: {svc["run_as_user"]}
  runAsGroup: {svc["run_as_user"]}
  fsGroup: {svc["run_as_user"]}
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  # Why readOnlyRootFilesystem is false for databases: they legitimately write to paths
  # outside their data directory (socket files, logs, PID files, lock files). Forcing it
  # would require enumerating and mounting every such path and is fragile across image
  # updates. Capabilities are still dropped and escalation is still blocked, which are
  # the controls that actually matter here.
  readOnlyRootFilesystem: false
  capabilities:
    drop:
      - ALL

podDisruptionBudget:
  enabled: true
  # Why 0: with a single replica, requiring one available pod would block every node
  # drain forever. For a stateful single instance the honest statement is that a
  # disruption is unavoidable; the protection is the volume, not a budget.
  minAvailable: 0

networkPolicy:
  enabled: true
  # Why the application namespace is named and the component is named: the policy allows
  # exactly one application service to reach exactly this dependency. That is what stops
  # a compromised pod in the app namespace from reading another service's database.
  #
  # Why the "shop-" prefix: the application charts are installed under the release name
  # "shop", so their pods carry app.kubernetes.io/component labels of the form "shop-catalog".
  # Selecting on the bare chart name matches nothing, and the result is a database that
  # silently refuses every connection from the service that needs it.
  allowIngressFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: retail-store
      podSelector:
        matchLabels:
          app.kubernetes.io/component: shop-{svc["allow_ingress_from_app"][0]}
'''


def helpers(name):
    return f'''{{{{/*
Shared template helpers for {name}. Same convention as the application charts so that
labels, selectors and naming stay consistent across the whole deployment.
*/}}}}

{{{{- define "{name}.name" -}}}}
{{{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}}}
{{{{- end -}}}}

{{{{- define "{name}.fullname" -}}}}
{{{{- if .Values.fullnameOverride -}}}}
{{{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}}}
{{{{- else -}}}}
{{{{- $n := default .Chart.Name .Values.nameOverride -}}}}
{{{{- if contains $n .Release.Name -}}}}
{{{{- .Release.Name | trunc 63 | trimSuffix "-" -}}}}
{{{{- else -}}}}
{{{{- printf "%s-%s" .Release.Name $n | trunc 63 | trimSuffix "-" -}}}}
{{{{- end -}}}}
{{{{- end -}}}}
{{{{- end -}}}}

{{{{- define "{name}.chart" -}}}}
{{{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}}}
{{{{- end -}}}}

{{{{- define "{name}.labels" -}}}}
helm.sh/chart: {{{{ include "{name}.chart" . }}}}
{{{{ include "{name}.selectorLabels" . }}}}
{{{{- if .Chart.AppVersion }}}}
app.kubernetes.io/version: {{{{ .Chart.AppVersion | quote }}}}
{{{{- end }}}}
app.kubernetes.io/managed-by: {{{{ .Release.Service }}}}
app.kubernetes.io/part-of: polyglot-shop
{{{{- end -}}}}

{{{{/*
Selector labels.

app.kubernetes.io/component uses the component value rather than the chart name on
purpose: the application NetworkPolicies select on this exact value, so it is the
contract between the application and its dependency.
*/}}}}
{{{{- define "{name}.selectorLabels" -}}}}
app.kubernetes.io/name: {{{{ include "{name}.name" . }}}}
app.kubernetes.io/instance: {{{{ .Release.Name }}}}
app.kubernetes.io/component: {{{{ .Values.component }}}}
{{{{- end -}}}}

{{{{/* Headless service name used for the StatefulSet's stable identity. */}}}}
{{{{- define "{name}.headless" -}}}}
{{{{- printf "%s-headless" (include "{name}.fullname" .) | trunc 63 | trimSuffix "-" -}}}}
{{{{- end -}}}}
'''


def statefulset_yaml(name, svc):
    secret_block = ""
    if svc["secret_env"]:
        lines = "\n".join(
            f"            - name: {k}\n"
            f"              valueFrom:\n"
            f"                secretKeyRef:\n"
            f"                  name: polyglot-secrets\n"
            f"                  key: {v}"
            for k, v in svc["secret_env"].items()
        )
        secret_block = (
            "            # Why valueFrom: the credential lives in a Secret and is never\n"
            "            # part of the chart, the values file or the rendered manifest.\n"
            f"{lines}\n"
        )

    # Why RabbitMQ specifically needs an init container:
    #
    # The Erlang distribution layer refuses to start unless the cookie file is readable by its
    # owner and nobody else:
    #
    #   Cookie file /var/lib/rabbitmq/.erlang.cookie must be accessible by owner only
    #   Kernel pid terminated (application_controller)
    #
    # The image creates that file during its own initialisation, and Kubernetes applies the
    # pod's fsGroup to it, which widens the permissions. The container then exits during
    # prelaunch and crash-loops with no application-level error to point at.
    #
    # The init container below runs before the main container as the same non-root uid, creates
    # the cookie if it is absent, and forces mode 0400. It is a no-op on restart, when the file
    # already has the right mode.
    init_container = ""
    if name == "rabbitmq":
        init_container = """      initContainers:
        # Why this exists: see the note above. The cookie must be owner-readable only, and the
        # image's own creation of it is widened by fsGroup.
        - name: fix-erlang-cookie
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          securityContext:
            {{- toYaml .Values.containerSecurityContext | nindent 12 }}
          # Why an explicit shell: the file's mode is the whole point, and there is no
          # kubectl-level equivalent that survives a restart of the pod.
          command:
            - /bin/sh
            - -c
            - |
              set -e
              COOKIE=/var/lib/rabbitmq/.erlang.cookie
              if [ ! -f "$COOKIE" ]; then
                # Why a generated value rather than a fixed one: each RabbitMQ instance should
                # have its own cookie. Allowing nodes to authenticate to a predictable shared
                # value would be a weakness if the broker were ever clustered.
                head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \\n' > "$COOKIE"
              fi
              chmod 0400 "$COOKIE"
              echo "cookie mode: $(stat -c '%a %U' "$COOKIE")"
          # Why the data volume is mounted here: the cookie lives inside the data directory,
          # which is where the main container expects it.
          volumeMounts:
            - name: data
              mountPath: ##STORAGE_MOUNT##
"""
        init_container = init_container.replace("##STORAGE_MOUNT##", svc["storage_mount"])


    args_block = ""
    if svc.get("args"):
        args_block = f"""          args:
{chr(10).join(f'            - {a!r}' for a in svc["args"])}
"""

    ports_block = f"""            - name: {svc["port_name"]}
              containerPort: {svc["port"]}
              protocol: TCP
"""
    for p in svc.get("extra_ports", []):
        ports_block += f"""            - name: {p["name"]}
              containerPort: {p["port"]}
              protocol: TCP
"""

    ready = svc["probe"]["readiness"]
    live = svc["probe"]["liveness"]

    def probe_body(spec, indent):
        """
        Emit a probe handler at a fixed indentation.

        Why this takes an explicit indent and emits whole lines: the previous version
        prefixed an indented block and then indented it again, which produced a
        handler at one depth and a port line at another. That is invalid YAML, and
        Helm reports it as "did not find expected key" many lines later. Emitting
        every line with its own indent removes the arithmetic.
        """
        pad = " " * indent
        body = ""
        if spec.get("tcpSocket"):
            body += f"{pad}tcpSocket:\n{pad}  port: {svc['port_name']}\n"
        else:
            lines = "".join(f"{pad}    - {c!r}\n" for c in spec["command"])
            body += f"{pad}exec:\n{pad}  command:\n{lines}"
        # Why a timeout is emitted for every probe: the default is one second, and
        # rabbitmq-diagnostics alone takes longer than that to answer. The result was a
        # startup probe that timed out every time and a broker that never became ready,
        # reported as "Startup probe failed: command timed out: rabbitmq-diagnostics -q ping
        # timed out after 1s". The application was healthy; the probe could not prove it.
        body += f"{pad}timeoutSeconds: {svc.get('probe_timeout_seconds', 5)}\n"
        return body

    ready_12 = probe_body(ready, 12)
    live_12 = probe_body(live, 12)

    return f'''{{{{/*
{name} StatefulSet.

Why StatefulSet and not Deployment: this service owns its data and needs a stable
identity. The StatefulSet gives the pod a predictable name and its own
PersistentVolumeClaim, so the data follows the pod across reschedules. A Deployment
with a shared volume would lose data the first time the pod moved to another node.

Why the volumeClaimTemplate and not a bare PVC: the template lets the StatefulSet own
the claim's lifecycle, so the claim is created with the pod and is not deleted when
the pod is removed.
*/}}}}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{{{ include "{name}.fullname" . }}}}
  labels:
    {{{{ include "{name}.labels" . | nindent 4 }}}}
spec:
  serviceName: {{{{ include "{name}.headless" . }}}}
  replicas: {{{{ .Values.replicaCount }}}}
  selector:
    matchLabels:
      {{{{ include "{name}.selectorLabels" . | nindent 6 }}}}
  # Why OnDelete: an automatic rollout of a database can leave a partially migrated
  # volume. OnDelete makes the restart an explicit operator action.
  updateStrategy:
    type: OnDelete
  template:
    metadata:
      labels:
        {{{{ include "{name}.labels" . | nindent 8 }}}}
    spec:
      securityContext:
        {{{{ toYaml .Values.podSecurityContext | nindent 8 }}}}
      # Why 60 seconds: a database needs time to flush and close its files cleanly
      # after SIGTERM. The default 30s can cut that short and force recovery on the
      # next start, which is exactly the failure a stateful service must avoid.
      terminationGracePeriodSeconds: 60
{init_container}      containers:
        - name: {name}
          image: "{{{{ .Values.image.repository }}}}:{{{{ .Values.image.tag }}}}"
          imagePullPolicy: {{{{ .Values.image.pullPolicy }}}}
          securityContext:
            {{{{ toYaml .Values.containerSecurityContext | nindent 12 }}}}
{args_block}          ports:
{ports_block}          envFrom:
            - configMapRef:
                name: {{{{ include "{name}.fullname" . }}}}
          env:
{secret_block}          {{{{ if .Values.startupProbe.enabled }}}}
          # Why a startup probe: first-time initialisation of an empty volume is far
          # slower than a normal start. Without this the liveness probe kills the
          # process mid-initialisation and leaves a half-written volume.
          startupProbe:
{ready_12}            failureThreshold: {{{{ .Values.startupProbe.failureThreshold }}}}
            periodSeconds: {{{{ .Values.startupProbe.periodSeconds }}}}
          {{{{ end }}}}
          livenessProbe:
{live_12}            initialDelaySeconds: 30
            periodSeconds: 20
            failureThreshold: 5
          readinessProbe:
{ready_12}            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 5
          resources:
            {{{{ toYaml .Values.resources | nindent 12 }}}}
          volumeMounts:
            - name: data
              mountPath: {svc["storage_mount"]}
  {{{{ if .Values.persistence.enabled }}}}
  volumeClaimTemplates:
    - metadata:
        name: data
        labels:
          {{{{ include "{name}.labels" . | nindent 10 }}}}
      spec:
        accessModes:
          - ReadWriteOnce
        {{{{ if .Values.persistence.storageClass }}}}
        storageClassName: {{{{ .Values.persistence.storageClass }}}}
        {{{{ end }}}}
        resources:
          requests:
            storage: {{{{ .Values.persistence.size }}}}
  {{{{ end }}}}
'''


def services_yaml(name, svc):
    extra = ""
    for p in svc.get("extra_ports", []):
        extra += f"""    - name: {p["name"]}
      port: {p["port"]}
      targetPort: {p["port"]}
      protocol: TCP
"""
    # Why an optional alias Service:
    #
    # The cart chart declares its dependency endpoint as
    # "http://dynamodb.data.svc.cluster.local:8000", but this chart's Service is named
    # "dynamodb-local" after the chart. DNS could not resolve the name the application was
    # configured to use, so the cart pod crash-looped with a connection failure while every
    # other service was healthy.
    #
    # The alias exists so the address the application uses and the name of the dependency chart
    # do not have to be the same. The alternative would be to rename the chart, which would
    # make the chart name less accurate, or to edit the application's endpoint, which would
    # couple the application to the chart's naming.
    alias = ""
    if svc.get("service_alias"):
        alias = f"""---
apiVersion: v1
kind: Service
metadata:
  name: {svc["service_alias"]}
  labels:
    {{{{ include "{name}.labels" . | nindent 4 }}}}
  annotations:
    # Why an annotation: it records that this Service is an alias and not the primary address,
    # so a future reader does not "fix" the duplication by deleting one of the two.
    polyglot-shop/alias-for: {{{{ include "{name}.fullname" . }}}}
spec:
  type: ClusterIP
  ports:
    - name: {svc["port_name"]}
      port: {svc["port"]}
      targetPort: {svc["port_name"]}
      protocol: TCP
  selector:
    {{{{ include "{name}.selectorLabels" . | nindent 4 }}}}
"""
    return f'''{{{{/*
Two Services, on purpose.

The headless Service (clusterIP: None) gives the StatefulSet its stable per-pod DNS
name and is what `serviceName` refers to. The regular ClusterIP Service gives clients
a single address, which is what the application charts connect to at
{name}.data.svc.cluster.local. Collapsing these into one would either break the
StatefulSet's identity or make clients resolve every pod individually.
*/}}}}
apiVersion: v1
kind: Service
metadata:
  name: {{{{ include "{name}.headless" . }}}}
  labels:
    {{{{ include "{name}.labels" . | nindent 4 }}}}
spec:
  clusterIP: None
  ports:
    - name: {svc["port_name"]}
      port: {svc["port"]}
      targetPort: {svc["port_name"]}
      protocol: TCP
  selector:
    {{{{ include "{name}.selectorLabels" . | nindent 4 }}}}
---
apiVersion: v1
kind: Service
metadata:
  name: {{{{ include "{name}.fullname" . }}}}
  labels:
    {{{{ include "{name}.labels" . | nindent 4 }}}}
spec:
  type: ClusterIP
  ports:
    - name: {svc["port_name"]}
      port: {svc["port"]}
      targetPort: {svc["port_name"]}
      protocol: TCP
{extra}  selector:
    {{{{ include "{name}.selectorLabels" . | nindent 4 }}}}
{alias}'''


def configmap_yaml(name):
    return f'''# Non-secret configuration for {name}.
#
# Why credentials are absent here: they come from the polyglot-secrets Secret. This
# ConfigMap is safe to read, and is the object to inspect when diagnosing a connection
# problem, without exposing a password.
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


def pdb_yaml(name):
    return f'''{{{{- if .Values.podDisruptionBudget.enabled }}}}
# Why a budget at all on a single replica: it documents that a disruption of this
# dependency is unavoidable, and keeps the intent explicit rather than leaving the
# question open. The real protection for a stateful service is the volume.
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
# Why the source is restricted to one application component: this is the control that
# stops a compromised pod in the application namespace from reading a database it has
# no business reading. The default-deny in the data namespace blocks everything else.
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
    # Why `from` and `ports` are siblings: `ports` belongs to the rule, not to the peer.
    # Nesting it under a peer produces an invalid NetworkPolicy.
    - from:
        {{{{ toYaml .Values.networkPolicy.allowIngressFrom | nindent 8 }}}}
      ports:
        - protocol: TCP
          port: {{{{ .Values.port }}}}
  egress:
    # A database needs no outbound access except DNS. Anything more would be a path out
    # of a component that should be a leaf.
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


def main():
    for name, svc in INFRA.items():
        base = ROOT / "infra" / name
        tpl = base / "templates"
        tpl.mkdir(parents=True, exist_ok=True)

        write_text(base / "Chart.yaml", chart_yaml(name, svc))
        write_text(base / "values.yaml", values_yaml(name, svc))
        write_text(tpl / "_helpers.tpl", helpers(name))
        write_text(tpl / "statefulset.yaml", statefulset_yaml(name, svc))
        write_text(tpl / "service.yaml", services_yaml(name, svc))
        write_text(tpl / "configmap.yaml", configmap_yaml(name))
        write_text(tpl / "pdb.yaml", pdb_yaml(name))
        write_text(tpl / "networkpolicy.yaml", networkpolicy_yaml(name))
        print(f"wrote infra chart: {name}")


if __name__ == "__main__":
    main()
