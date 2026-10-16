# Resume guide — how to pick this up again

**Written:** 2026-10-13
**State at shutdown:** instance stopped, stack stopped gracefully, all data preserved.

## What is still running and what it costs

| Resource | State | Cost while stopped |
|---|---|---|
| EC2 `i-06bae5ecefeb6eb90` (`m7i-flex.large`) | **stopped** | none — no compute, no public IPv4 |
| EBS `vol-087ecac7048dc3257`, 60 GiB gp3 | attached, in-use | **about `$5.02/month`** (`$0.0836/GB-month`) |
| Everything else | does not exist | none |

Verified before stopping: **no** Elastic IPs, **no** NAT gateways, **no** load balancers,
**no** RDS instances, **no** EKS clusters. ECR had no repositories. The only billable
resource left is that one disk, which is what keeps the rebuild work, the Docker images,
the cloned repository and all database volumes available for tomorrow.

Nothing is deleted. The instance was **stopped, not terminated**; the volume is
delete-on-terminate, so a terminate would have destroyed it.

## What is preserved on that disk

- Docker images for all five services (`deployment-me-cart/orders/ui/catalog/checkout`)
- The repository clone at `/opt/polyglot-shop/source/polyglot-shop-k8s-cicd`
- All named volumes, including the catalog database with its 12 seeded products
- The toolchain: docker, compose, git, aws, kubectl, helm, eksctl 0.231.0, terraform, trivy, checkov
- Scan reports under `/var/log/retail-store-scans/` (before and after remediations)
- Scripts in `/root/*.sh` used during the work

Containers were stopped with `docker compose stop`, deliberately **not** `down -v`, so
the volumes still hold their data.

## Tomorrow: bring it back up

### 1. Start the instance

```powershell
aws ec2 start-instances --profile retail-store-dev --region eu-north-1 --instance-ids i-06bae5ecefeb6eb90
aws ec2 wait instance-running --profile retail-store-dev --region eu-north-1 --instance-ids i-06bae5ecefeb6eb90
aws ec2 describe-instances --profile retail-store-dev --region eu-north-1 --instance-ids i-06bae5ecefeb6eb90 --query 'Reservations[0].Instances[0].{State:State.Name,PublicIp:PublicIpAddress}' --output table
```

**The public IP will be different.** It is a dynamic address from the default VPC; the old
`16.170.247.8` is gone. Note the new one from the command above.

### 2. Re-allow the UI port for the new address

The security group rule references the instance, not the address, so it survives — but the
address it applies to has changed, which is fine. Only if the rule was removed:

```powershell
aws ec2 authorize-security-group-ingress --profile retail-store-dev --region eu-north-1 `
  --group-id <security-group-id> --protocol tcp --port 8888 --cidr 0.0.0.0/0
```

Safer alternative if you do not want the port open to the internet — tunnel instead, with
no security-group change at all:

```powershell
aws ssm start-session --target i-06bae5ecefeb6eb90 --region eu-north-1 `
  --document-name AWS-StartPortForwardingSession `
  --parameters '{"portNumber":["8888"],"localPortNumber":["8888"]}'
# then open http://localhost:8888
```

### 3. Start the stack again

```bash
cd /opt/polyglot-shop/source/polyglot-shop-k8s-cicd/deployment-me
docker compose start          # fastest: starts the containers already created
# or, to bring the stack back with fresh containers: docker compose up -d --wait
docker compose ps             # expect 9 healthy + rabbitmq without a healthcheck
```

### 4. Verify before trusting it

```bash
curl -s -o /dev/null -w 'ui=%{http_code}\n'      http://localhost:8888/
curl -s -o /dev/null -w 'ui_health=%{http_code}\n' http://localhost:8888/actuator/health
curl -s                                            http://localhost:8081/catalog/size
```

Expected: `ui=200`, `ui_health=200`, and `{"size":12}`.

## Where the project stands

| Step | Status |
|---|---|
| 1 Access and credentials | done — `devops-agent` with MFA, CLI profile `retail-store-dev` |
| 2 Source application | done — `polyglot-shop-k8s-cicd` at `a785cf0` |
| 3 Build server | done — Terraform, instance, toolchain |
| 5 Compose build and local test | done and verified — all 10 containers healthy |
| 4 Security scanning | **scans done and repeatable; push still gated** |
| 6 ECR push | blocked by the scan gate |
| 7 EKS | not started |
| 8 Observability | not started |
| 9 CI/CD pipeline | not started |

### The one blocker, precisely

Trivy still reports **20 CRITICAL / 157 HIGH** findings, down from the original
**33 / 248** after the retained fixes (Spring Boot 3.5.16, `amqp-client` 5.34.0, and
catalog's Go modules which cleared that image entirely).

The remaining Java findings need a **Spring Boot 4 migration** — attempted, one service
(`cart`) migrated successfully to **0 CRITICAL**, then reverted because the other two
services did not build and the repository was left in a worse state than it started. The
checkout findings are a separate problem: they need a `protobufjs` major bump and are
blocked by yarn 1, whose `resolutions` rejects ranged keys.

Nothing has been pushed to ECR, and no Kubernetes cluster exists. The application runs as
plain Docker Compose on the build server — **not on EKS**.

### Read before resuming

- `docs/step-1-access-credentials.md` — identity and CLI setup
- `docs/step-2-3-build-server-and-app.md` — provisioning, the app, and every failure
- `docs/step-4-security-scanning.md` — scan results, the migration attempt, and the exact
  blockers, including the `git` ownership problem that defeated the automated rollbacks

### Two lessons to carry forward

1. **Take a backup before any in-place migration.** Recovery here came from a POM tarball,
   not from git, because `git` refused the repository inside root-run scripts with
   `detected dubious ownership`.
2. **A repository that builds with known findings beats one that cannot build.** That is
   why the migration was reverted rather than left half-applied.
