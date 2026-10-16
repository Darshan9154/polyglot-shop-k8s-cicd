# Step 2/3 — Build server provisioned and application running

**Status:** complete. The build server exists, the toolchain is installed, the source is
cloned, and the Compose stack for `polyglot-shop-k8s-cicd` is built, running, and verified.

**Recorded:** 2026-10-13
**Region:** `eu-north-1` (Europe, Stockholm)
**AWS profile:** `retail-store-dev` (IAM user `devops-agent`)

## Outcome in one table

| Item | Value |
|---|---|
| Instance ID | `i-06bae5ecefeb6eb90` |
| Instance type | `m7i-flex.large` (2 vCPU / 8 GiB) |
| Root volume | `vol-087ecac7048dc3257`, gp3, **60 GiB**, encrypted, delete-on-terminate |
| Availability Zone | `eu-north-1b` |
| Access | AWS Systems Manager Session Manager only; **no inbound security-group rule, no key pair** |
| Repository | `https://github.com/Darshan9154/polyglot-shop-k8s-cicd.git` at `a785cf0888e3770ef2e3edf1d64868edcc934e10` |
| Source path on instance | `/opt/polyglot-shop/source/polyglot-shop-k8s-cicd` |
| Compose file used | `/opt/polyglot-shop/source/polyglot-shop-k8s-cicd/deployment-me/docker-compose.yml` |

## What was built

### 1. Terraform for the build server

Files live in `infra/terraform/build-server/`:

- `versions.tf` — Terraform minimum version and the pinned AWS provider major version.
- `variables.tf` — region, names, instance type, disk size, CPU credit mode, repository settings.
- `iam.tf` — instance role and instance profile with exactly two managed policies:
  `AmazonSSMManagedInstanceCore` (shell access without SSH) and
  `AmazonEC2ContainerRegistryPowerUser` (push images to ECR later).
- `main.tf` — Ubuntu 22.04 AMI lookup by Canonical's owner ID, the no-ingress security
  group, and the instance itself with IMDSv2 enforced.
- `bootstrap.sh.tftpl` — first-boot installer for the whole toolchain.

Verification of the final reconciliation:

```
Plan: 0 to add, 1 to change, 0 to destroy.
```

No resource is recreated by that change.

### 2. Toolchain on the instance (vendor-reported versions)

| Tool | Purpose |
|---|---|
| Docker Engine + Compose plugin (compose 5.6.0) | build and run the application stack |
| git | clone and refresh the source |
| AWS CLI v2 | AWS API calls from the pipeline |
| kubectl | Kubernetes operations in later steps |
| Helm | chart packaging and release in later steps |
| eksctl `0.231.0` | EKS cluster operations |
| Terraform | infrastructure from the server |
| Trivy | image vulnerability scanning (Step 4) |
| Checkov | IaC misconfiguration scanning (Step 4) |
| SSM agent | shell without SSH |

## Application deployment

### Clone

```
HEAD=a785cf0888e3770ef2e3edf1d64868edcc934e10
```

### Compose validation

```
COMPOSE_CONFIG=valid
services: checkout-redis, checkout, orders-db, orders, rabbitmq, carts-db, cart,
          catalog-db, catalog, ui
```

The compose file defines `DB_PASSWORD` through `deployment-me/.env`. Only the variable
name is recorded here; the value is not.

### Build

```
BUILD_STATUS=success
deployment-me-catalog:latest    295MB
deployment-me-checkout:latest   994MB
deployment-me-cart:latest       743MB
deployment-me-orders:latest     1.11GB
deployment-me-ui:latest         1.11GB
```

### Run and verify

Container state:

```
cart=running/healthy        carts-db=running/healthy
catalog=running/healthy     catalog-db=running/healthy
checkout=running/healthy    checkout-redis=running/healthy
orders=running/healthy      orders-db=running/healthy
ui=running/healthy          rabbitmq=running (no healthcheck in compose)
```

HTTP checks:

```
ui home            -> 200 (19973 bytes, product markup present)
ui health          -> 200
catalog /catalog/products -> 200, 3718 bytes
catalog /catalog/size     -> {"size":12}
catalog /catalog/tags     -> 200
catalog /health    -> 200
cart health        -> 200
orders health      -> 200
checkout health    -> 200
rabbitmq ping      -> "Ping succeeded", management UI 200
```

Database: `catalogdb.products` contains **12** rows, so the catalog is serving real data.

Published ports: ui 8888, catalog 8081, cart 8082, orders 8083, checkout 8085,
orders-db 5432, cart/carts-db 8082, checkout-redis 6379, rabbitmq 5672/15672.

## Failures and fixes

### Failure 1 — `t3.medium` rejected by the account

- **Where:** `terraform apply`, `RunInstances`.
- **What we saw:** `InvalidParameterCombination: The specified instance type is not
  eligible for Free Tier.`
- **Root cause:** on accounts created on or after 2025-07-15 the free-tier-eligible
  instance types are `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`,
  `c7i-flex.large`, `m7i-flex.large`. `t3.medium` is not on that list.
- **Fix:** provisioned `t3.small` first, then moved to `m7i-flex.large` (2 vCPU / 8 GiB)
  after the sizing problem below.

### Failure 2 — t3.small CPU throttling stalled the build

- **Where:** first `docker compose build`.
- **What we saw:** CloudWatch CPU pinned at `19.99–20.01%` average, the SSM agent
  stopped answering, and build steps crawled.
- **Root cause:** t3.small earns 24 CPU credits/hour and, in standard credit mode,
  hard-throttles to its 20% baseline. Four JVM/Node image builds need sustained CPU.
- **Fix:** stopped the instance, changed the type to `m7i-flex.large` (no burst-credit
  model, so no throttle), and grew the disk to 60 GiB.

### Failure 3 — root volume could not be resized while attached

- **Where:** disk growth from 30 GiB to 60 GiB.
- **What we saw:** the volume cannot be modified in place on a running instance.
- **Fix:** stopped the instance, ran `modify-volume --size 60`, started it again, then
  grew the partition and filesystem online (`growpart` + `resize2fs`).
  Verified: `/dev/root 58G 4.2G 54G 8% /`.

### Failure 4 — bootstrap aborted at the eksctl step

- **Where:** first boot, `bootstrap.sh.tftpl`.
- **What we saw:** `sha256sum: 'standard input': no properly formatted SHA256 checksum
  lines found`, then the script exited.
- **Root cause:** the checksums were piped into `sha256sum`, so it read standard input
  instead of a named file, and `set -e` ended the script early. The tools scheduled
  after eksctl therefore never installed.
- **Fix:** rewrote the check to compare the two digests explicitly, retry once, and warn
  and continue instead of aborting the whole bootstrap.

### Failure 5 — eksctl checksum compared two digests at once

- **Where:** fixed eksctl installer.
- **What we saw:** `actual` and `expected` printed differently, although the first
  digest was correct.
- **Root cause:** the checksum file lists two matching lines for the same asset name —
  `eksctl_Linux_amd64.tar.gz` and `eksctl_Linux_amd64.tar.gz.sbom.json` — so capturing
  all matches concatenated two digests.
- **Fix:** take the first matching line only. Result: `eksctl_version=0.231.0`.

### Failure 6 — Terraform template parsing of shell expansions

- **Where:** `templatefile()` rendering of `bootstrap.sh.tftpl`.
- **What we saw:** `Invalid character; This character is not used within the language`
  and later `Invalid template control keyword; "url_effective"`.
- **Root cause:** shell `${...}` expansions inside a Terraform template are read as
  Terraform interpolations, and a literal curl format string `%{url_effective}` starts a
  Terraform template directive.
- **Fix:** every shell expansion is written as `$` `$` `{...}` in the template, and the
  fragile curl format string was removed in favour of the literal release asset name,
  which the checksum still verifies.

### Failure 7 — catalog route 404

- **Where:** functional verification.
- **What we saw:** `/catalogue` returned 404 while `/health` returned 200.
- **Root cause:** this repository serves the catalog API under `/catalog/...`, not the
  `/catalogue` path used by the upstream sample.
- **Fix:** verified against the real routes: `/catalog/products` 200,
  `/catalog/size` → `{"size":12}`.

### Note — `UP_STATUS=degraded` is cosmetic

`docker compose up --wait` reported `degraded` only because the `rabbitmq` service has no
healthcheck in the compose file, so there is no health state for `--wait` to observe.
RabbitMQ itself answers: `Ping succeeded` and its management UI returns 200. Nine of the
ten services are `healthy`.

## Public access (added on request)

The storefront is reachable in a browser at:

```
http://16.170.247.8:8888/
```

Verified from a machine outside AWS:

```
PUBLIC_UI_STATUS=200
PUBLIC_UI_BYTES=19973
PUBLIC_PRODUCT_MENTIONS=22
PUBLIC_HEALTH_STATUS=200
```

Only port **8888** was opened, and only for this UI. The Terraform variables file carries
`ui_allowed_cidr`, which defaults to `0.0.0.0/0` (open to the internet). Set it to a
single address, for example `203.0.113.7/32`, to narrow access.

**Why the other ports stay closed:** the compose file also publishes MariaDB (3306),
Postgres (5432), Redis (6379), DynamoDB Local (8000), and the RabbitMQ management console
(15672). The first four hold application data, and the RabbitMQ console ships with default
credentials. None of them are reachable from the internet, and the security group has no
rule that would allow it.

**Why the address can change:** the instance uses a dynamic public IPv4 from the default
VPC. It changed once during this step (from `13.61.15.244` to `16.170.247.8`) when the
security group was replaced. For a stable address, associate an Elastic IP; note that an
associated public IPv4 bills at `$0.005/hour` whether or not the instance runs.

**Exposure warning:** an internet-open storefront on a build server is a testing
convenience, not a safe resting state. When browser testing is finished, narrow
`ui_allowed_cidr` or stop the instance. The `/utility/*` and `/chaos/*` endpoints in the
sample application are intentionally disruptive and are reachable through this port.

## Cost position at the time of writing

- EC2 `m7i-flex.large` in Stockholm: **$0.09077/hour** while running (queried from the
  AWS Price List for this region).
- EBS gp3 60 GiB: **$0.0836/GB-month** → about **$5.02/month** while the volume exists.
- Public IPv4: **$0.005/hour** while attached to a running instance.
- Stopping the instance removes compute and IPv4 charges; the EBS volume continues to
  bill until it is deleted.

## Open items

1. No inbound rule exists, so the UI is not reachable from the internet. Use Session
   Manager port forwarding to open it locally:
   `aws ssm start-session --target i-06bae5ecefeb6eb90 --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["8888"],"localPortNumber":["8888"]}'`
2. Budget alerts at $25 / $50 / $75 are still not saved.
3. ECR repositories are still absent; images currently exist only on the instance.
4. Terraform declares `instance_type = "m7i-flex.large"` and 60 GiB, matching the live
   instance, but the live instance was adjusted outside Terraform; a future plan shows
   no recreation.
5. The repository is cloned on the instance and needed no credentials because it is
   public; no GitHub credential is stored there.
