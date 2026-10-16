# Polyglot Shop â€” Kubernetes deployment (Helm, from scratch)

Production-grade Helm charts and manifests for the Polyglot Shop application,
written from the `deployment-me/docker-compose.yml` service definitions rather than
derived from the repository's existing `k8-manifests/`.

## Why Helm and not raw manifests

The application has five services and five backing services, all sharing one image
repository layout, one registry, one namespace convention, and one set of secret
names. Raw manifests would duplicate that boilerplate about thirty times and drift
the moment one service is changed. Helm gives one parameterised definition per
component, and the differences live in `values.yaml` where they are reviewable.

## Layout

```
k8s/
â”œâ”€â”€ app/                        # the five application services
â”‚   â”œâ”€â”€ cart/                   # Java  Â· DynamoDB (local)      Â· published 8082
â”‚   â”œâ”€â”€ catalog/                # Go    Â· MariaDB               Â· published 8081
â”‚   â”œâ”€â”€ orders/                 # Java  Â· PostgreSQL + RabbitMQ Â· published 8083
â”‚   â”œâ”€â”€ checkout/               # Node  Â· Redis                 Â· published 8085
â”‚   â”œâ”€â”€ ui/                     # Java  Â· aggregates the four   Â· published 8888
â”‚   â””â”€â”€ umbrella/               # installs all five in one release
â”œâ”€â”€ infra/                      # the backing services
â”‚   â”œâ”€â”€ mariadb/                # catalog's relational store
â”‚   â”œâ”€â”€ postgresql/             # orders' relational store
â”‚   â”œâ”€â”€ redis/                  # checkout's session store
â”‚   â”œâ”€â”€ rabbitmq/               # orders' message broker
â”‚   â””â”€â”€ dynamodb-local/         # cart's key-value store
â”œâ”€â”€ observability/              # metrics, logs, traces
â”‚   â”œâ”€â”€ kube-prometheus-stack/  # Prometheus + Grafana + alerting
â”‚   â”œâ”€â”€ opentelemetry-collector/
â”‚   â”œâ”€â”€ jaeger/
â”‚   â””â”€â”€ loki/
â””â”€â”€ bootstrap/                  # namespace, secrets, storage, policies
```

## Why the application and its dependencies are separate charts

The five application services are deployed by this project. The five backing
services are infrastructure: they hold state, they have different upgrade and
backup requirements, and in a real environment they would more likely be managed
databases. Keeping them in separate charts means the application chart can be
pointed at managed endpoints without touching the workloads, which is the single
most likely change this deployment will undergo.

## Install order

Dependencies first, then the application, then observability:

```bash
kubectl apply -f bootstrap/                     # namespace, secrets, storage classes
helm upgrade --install mariadb     infra/mariadb
helm upgrade --install postgresql  infra/postgresql
helm upgrade --install redis       infra/redis
helm upgrade --install rabbitmq    infra/rabbitmq
helm upgrade --install dynamodb    infra/dynamodb-local
helm upgrade --install shop        app/umbrella  -n retail-store
helm upgrade --install monitoring  observability/kube-prometheus-stack -n monitoring
```

Every chart is installable on its own. The umbrella chart exists for convenience,
not because the individual charts depend on it.

## Production-grade decisions applied throughout

Each chart implements these, and the templates carry a comment explaining why:

- **No `:latest`.** Images are pinned by tag and, by preference, by digest. A tag
  can be moved; a digest cannot.
- **Container security context** on every workload: `runAsNonRoot`,
  `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem` where the image
  supports it, all capabilities dropped, `seccompProfile: RuntimeDefault`.
  This mirrors the `cap_drop`, `read_only` and `no-new-privileges` the Compose
  file already used, so the posture is preserved rather than lost in the move.
- **Resource requests and limits on every container.** Requests are what the
  scheduler reserves; without them a node can be oversubscribed and pods get
  evicted under pressure.
- **Liveness, readiness and startup probes**, taken from the health endpoints the
  Compose file documents (`/actuator/health`, `/health`). Startup probes exist
  because these are JVM services that can take tens of seconds to become ready.
- **Rolling updates** with `maxUnavailable: 0` so a deploy never takes the service
  below capacity, plus a `PodDisruptionBudget` for voluntary disruptions.
- **Secrets never in values files.** Passwords come from a Kubernetes Secret
  created out of band; the charts reference it by name.
- **Labels and annotations** that make the workloads findable by Prometheus and
  traceable to a release.
- **NetworkPolicies** so each service can reach only the dependencies it needs.

## Where compromises were made, and why

The target cluster is deliberately small because the project runs against a fixed
credit budget, with the EKS control plane costing about `$0.10/hour` on its own.
Where a genuine production setup would differ, the choice is recorded in the
chart's `values.yaml` next to the setting:

- **Replicas default to 1** rather than 3. Three replicas across two nodes is not
  real high availability anyway, and it triples the resource footprint. The
  `replicaCount` value exists so this is a one-line change on a properly sized
  cluster.
- **In-cluster stateful dependencies** (MariaDB, PostgreSQL, Redis, RabbitMQ,
  DynamoDB Local) rather than managed services. This is the right call for a test
  cluster and the wrong call for production, where these would be RDS/ElastiCache
  or an operator-managed cluster. The application charts take a host/port so
  switching is a values change.
- **Storage is `gp2`-based dynamic provisioning** to match what EKS provides by
  default. Production would use `gp3` with explicit IOPS.
- **Observability retention is short** (7 days) because the storage costs come out
  of the same budget. See `observability/README.md` for the full list of
  observability tradeoffs.

These are sizing and cost tradeoffs, not correctness tradeoffs. Nothing here is a
security shortcut, and no probe or policy was weakened to make something pass.

## What has been verified, and what has not

Everything below was checked locally or on the build server. **No cluster exists yet**,
so nothing has been installed against a real API server.

```
SUMMARY  lint_failures=0  validation_failures=0
```

| Check | Result |
|---|---|
| `helm lint` on all 13 charts | **0 failures** |
| `helm template` + `kubeconform -strict` on rendered output | **all valid** |
| bootstrap manifests (namespaces, secret, storage docs, NetworkPolicies) | **10 objects valid** |
| umbrella chart renders every subchart | **25 objects valid** |
| cross-chart consistency: infra `component` labels vs application egress rules | matched |

Verified totals: **14 charts, 117 files, 74 template files**.

Run the whole sweep with:

```bash
platform/charts/tools/validate-all.sh          # lint, render, schema-validate, consistency check
```

Three real bugs were found by this process and fixed, none of which `helm lint` alone
would have caught:

1. Every egress rule had `ports` nested inside a `to` peer. The schema forbids this â€”
   `ports` is a sibling of `to`. `helm lint` passed while the objects were invalid.
2. The chart generators wrote files in the platform's default encoding, so non-ASCII
   characters broke chart parsing with `invalid leading UTF-8 octet`.
3. Chart values with hyphens in the key (`otlp-grpc`) need `index`, not quoted-key
   access, which is a template parse error.

Still unverified, and only checkable on a real cluster: whether the ECR images pull, how
the workloads behave under the resource limits chosen here, and whether the storage class
binds. Those are the first things to check after the EKS cluster exists.

