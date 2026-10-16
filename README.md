# Polyglot Shop — Kubernetes deployment and CI/CD

A retail store application deployed to Amazon EKS, with a Helm chart per service, Terraform for
the infrastructure, a CI/CD pipeline, and an observability stack. Everything needed to build it
from nothing is in this repository.

> **This repository is based on the AWS Containers Retail Sample** (`aws-containers/retail-store-sample-app`).
> The application source in `src/` is that project. The `platform/` directory and the two CI/CD
> workflows are the deployment built around it. The sample's own Terraform examples, docs and
> pipeline files have been removed: they are not used by this deployment, and leaving them in place
> made it impossible to tell which parts were which.

## Layout

```
platform/               The deployment — start here
├── bootstrap/          Cluster-level objects, applied once with kubectl
├── charts/             Helm charts
│   ├── app/            The five services + umbrella
│   ├── infra/          mariadb, postgresql, redis, rabbitmq, dynamodb-local
│   ├── observability/  Prometheus config, OpenTelemetry collector, Jaeger, Loki
│   └── tools/          Chart generators and validators
├── terraform/
│   ├── eks/            The cluster, node group, IAM, IRSA roles
│   └── build-server/   The machine that hosts the CI runner
├── scripts/            Operational scripts
└── docs/               Step-by-step build records, including every failure

src/                    The application source (cart, catalog, checkout, orders, ui)
deployment-me/          A Docker Compose deployment of the same application
.github/workflows/      build-and-push-ecr.yml and deploy-eks.yml
```

**Read [`platform/README.md`](./platform/README.md) next.** It covers what each component is for,
the install order, and the compromises made for a test cluster.

## The five services

| Service | Language | Backing service |
|---|---|---|
| `ui` | Java / Spring Boot | — (aggregates the other four) |
| `catalog` | Go / Gin | MariaDB |
| `cart` | Java / Spring Boot | DynamoDB Local |
| `orders` | Java / Spring Boot | PostgreSQL + RabbitMQ |
| `checkout` | Node.js / NestJS | Redis |

## CI/CD

| Workflow | What it does |
|---|---|
| `build-and-push-ecr.yml` | Builds each service image, scans it with Trivy, pushes to ECR tagged with the commit SHA |
| `deploy-eks.yml` | Renders the charts, then `helm upgrade`s the cluster with automatic rollback on failure |

Both run on a **self-hosted runner on the build server**. That is a requirement rather than a
preference: from inside the VPC the EKS API endpoint resolves to its private address, and the
cluster's security group allows port 443 only from that machine. **No AWS credential is stored in
this repository** — the runner uses the instance's IAM role.

## Rebuilding from scratch

The order matters; each step depends on the one before it.

```bash
# 1. Infrastructure — the build server, then the cluster
cd platform/terraform/build-server && terraform init && terraform apply
cd ../eks                           && terraform init && terraform apply

# 2. Cluster-level objects
kubectl apply -f platform/bootstrap/

# 3. Backing services, then the application
for c in mariadb postgresql redis rabbitmq dynamodb-local; do
  helm upgrade --install "$c" "platform/charts/infra/$c" -n data --wait
done
helm upgrade --install shop platform/charts/app/umbrella -n retail-store --wait

# 4. Observability
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring -f platform/charts/observability/kube-prometheus-stack/values-small-cluster.yaml
```

Images are built by the pipeline. To build and push by hand, use
`platform/scripts/push-images-ecr.sh`.

## Conventions

- **Images pinned by tag or digest.** A tag can be moved; a digest cannot.
- **Resource requests and limits on every container.** Requests are what the scheduler reserves.
- **Security context on every workload**: non-root, no privilege escalation, capabilities dropped,
  seccomp. The application and its databases run under the `restricted` Pod Security Standard.
- **Secrets never in values files** — they come from Kubernetes Secrets created out of band.
- **Every compromise is labelled where it appears**, with the reason and the production
  alternative. Nothing is sized down silently.

## Licence

The application source is the AWS Containers Retail Sample. See `LICENSE` and the `ATTRIBUTION.md`
files under `src/`.
