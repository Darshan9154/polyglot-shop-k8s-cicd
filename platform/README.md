# Platform — the deployment for this application

Everything in this directory was added to deploy, observe and operate the application in
`../src`. The application itself is unchanged from how it arrived; this is the platform around
it.

**If you are new here, read this file first.** It says what exists, what order to install it in,
and which parts are production-grade versus deliberately sized down for a test cluster.

## Layout

```
platform/
├── bootstrap/        Cluster-level objects applied once with kubectl
├── charts/           Helm charts — the workloads
│   ├── app/          The five services and the umbrella that installs them together
│   ├── infra/        The backing services: databases, cache, broker
│   ├── observability/ Prometheus stack config, OpenTelemetry, Jaeger, Loki
│   └── tools/        Chart generators and validators
├── terraform/        The infrastructure
│   ├── eks/          The Kubernetes cluster and its IAM
│   └── build-server/ The build server that hosts the CI runner
├── scripts/          Operational scripts
└── docs/             Step-by-step records of how this was built
```

## What each part is for

### `bootstrap/` — apply first, once per cluster

Plain Kubernetes manifests, not a chart, because these do not vary per environment:

| File | What it creates |
|---|---|
| `00-namespaces.yaml` | `retail-store`, `data`, `monitoring` with Pod Security levels |
| `01-secrets.yaml` | The shared database password, per namespace |
| `02-storage-prerequisites.yaml` | Documents the storage class requirement |
| `03-network-policies-default-deny.yaml` | Default-deny plus DNS, per namespace |
| `04-storageclass-gp3.yaml` | The `gp3` StorageClass the charts depend on |

```bash
kubectl apply -f platform/bootstrap/
```

### `charts/app/` — the five services

`cart`, `catalog`, `orders`, `checkout`, `ui`, plus `umbrella` which installs all five as one
release. Each chart ships a Deployment, Service, ConfigMap, PodDisruptionBudget and
NetworkPolicy.

The `ui` chart is the only externally reachable component. `ui-ingress.yaml` at the chart level
publishes it through an ALB.

### `charts/infra/` — the backing services

`mariadb` (catalog), `postgresql` (orders), `redis` (checkout), `rabbitmq` (orders),
`dynamodb-local` (cart). These are **StatefulSets** because they hold data and need a stable
identity.

They run in-cluster to avoid managed-service hourly costs. The application charts address them by
host and port, so pointing at RDS or ElastiCache instead is a values change, not a rewrite.

### `charts/observability/` — metrics, logs, traces

The OpenTelemetry collector, Jaeger and Loki are charts here. The Prometheus/Grafana/Alertmanager
stack uses the upstream chart, configured by `charts/observability/kube-prometheus-stack/`.

### `terraform/` — the infrastructure

`eks/` creates the cluster, node group, IAM roles (including the IRSA roles for the EBS CSI
driver and the load balancer controller), subnet discovery tags and the API access rules.
`build-server/` creates the machine that hosts the CI runner.

### `scripts/` — operational commands

Including `install-runner.sh` (the self-hosted CI runner), `push-images-ecr.sh` (manual image
push, predating the pipeline) and the chart validation scripts under `charts/tools/`.

## Install order

Dependencies before the application, then observability.

```bash
# 1. Cluster-level objects
kubectl apply -f platform/bootstrap/

# 2. Backing services
for c in mariadb postgresql redis rabbitmq dynamodb-local; do
  helm upgrade --install "$c" "platform/charts/infra/$c" -n data --wait
done

# 3. The application
helm upgrade --install shop platform/charts/app/umbrella -n retail-store --wait

# 4. Observability (needs its own namespace first)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring -f platform/charts/observability/kube-prometheus-stack/values-small-cluster.yaml
```

## Where to start reading

| If you want to know… | Read |
|---|---|
| How this was built, step by step, including every failure | `docs/step-*.md` |
| How the deployment is structured and why | `charts/README.md` |
| How to run and observe the stack | `charts/observability/README.md` |
| How the CI/CD pipeline works | `docs/step-8-cicd-pipeline.md` |

## Conventions this repository follows

- **Images are pinned by tag, preferably digest.** No chart references `:latest` for its own
  workload. A tag can be moved; a digest cannot.
- **Every container has resource requests and limits.** Requests are what the scheduler reserves;
  limits cap a runaway process.
- **Security context on every workload**: non-root, no privilege escalation, capabilities dropped,
  seccomp. The application and databases run under the `restricted` Pod Security Standard.
- **Secrets are never in values files.** They come from Kubernetes Secrets created out of band.
- **Every compromise is labelled in the values file it appears in**, with the reason and the
  production alternative. Nothing is sized down silently.

## What a production deployment would change

Recorded so the gaps are known rather than discovered:

1. **Replicas are 1.** Three replicas across two nodes is not real availability. `replicaCount` is
   a value, so this is a one-line change on a larger cluster.
2. **The backing services run in-cluster.** Production would use managed services or an operator,
   which brings replication and backups.
3. **Storage is `gp3` without explicit IOPS.**
4. **Prometheus retains 3 days** and Jaeger stores traces in memory, so trace history is lost on
   restart.
5. **No TLS and no domain.** The ALB serves plaintext HTTP.
6. **Loki receives no logs** — no collector agent is installed yet, so log panels are empty.
   Metrics and traces are complete.
7. **The CI runner holds cluster admin**, because Helm needs to create and delete arbitrary
   object types. A namespace-scoped custom ClusterRole is the correct improvement.
