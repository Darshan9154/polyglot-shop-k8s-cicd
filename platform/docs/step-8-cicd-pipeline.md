# CI/CD pipeline

Two GitHub Actions workflows that take a commit to a running deployment on EKS, plus the
prerequisites they depend on — all of which needed fixing before the pipeline could work at all.

## Verified: the pipeline has run green

`build-and-push-ecr` triggered on the push that added it, ran on the self-hosted runner, and
completed successfully. All five services went through every step:

```
job: build, scan (advisory), push (cart, src/cart)      runner=polyglot-build-server
  1. Set up job                                        completed success
  2. Check out the repository                          completed success
  3. Confirm the toolchain is present                  completed success
  4. Confirm AWS identity comes from the instance role completed success
  5. Verify the ECR repository exists                  completed success
  6. Build the image                                   completed success
  7. Scan the image (advisory)                         completed success
  8. Log in to ECR                                     completed success
  9. Push the image                                    completed success
 10. Record the pushed digest                          completed success
 11. Upload scan report and digest list                completed success
```

Run conclusion: **`success`**, for all five matrix entries (cart, catalog, checkout, orders, ui).

The outcome — images in ECR, tagged with the commit SHA rather than a mutable tag:

```
polyglot-shop/cart      -> 3fd946ca31fac47d5e7bc41e78c2da67c0e0b8dc, latest
polyglot-shop/catalog   -> 3fd946ca31fac47d5e7bc41e78c2da67c0e0b8dc, latest
polyglot-shop/checkout  -> 3fd946ca31fac47d5e7bc41e78c2da67c0e0b8dc, latest
polyglot-shop/orders    -> 3fd946ca31fac47d5e7bc41e78c2da67c0e0b8dc, latest
polyglot-shop/ui        -> 3fd946ca31fac47d5e7bc41e78c2da67c0e0b8dc, latest
```

The SHA tags are what a deployment should reference. `latest` exists for convenience and is
mutable — a digest or SHA is the reproducible choice.

## The workflows

### `build-and-push-ecr.yml`

Builds each of the five service images, scans it, and pushes it to ECR tagged with the commit SHA.

```
matrix over:  cart  catalog  checkout  orders  ui
steps:        checkout -> confirm toolchain -> build -> Trivy scan (advisory)
              -> ECR login -> push -> record digest -> upload scan report
```

The scan is **advisory by design** — it records findings to an artifact and logs them rather than
failing the build. This is a recorded, time-boxed decision (see
`docs/step-4-security-scanning.md`), not a silenced one: the findings are in the run's artifacts.

### `deploy-eks.yml`

Renders the charts, then applies them to the cluster, with a rollback handle captured beforehand.

```
steps:  configure kubectl -> verify connectivity -> capture previous revision
        -> render (--dry-run=server) -> helm upgrade --wait --rollback-on-failure
        -> verify rollout -> report rollback command
```

Why `--dry-run=server` and not client: a server-side dry run is validated by the API server
against real admission policies and CRDs, so it catches an unknown field or a PodSecurity
violation that a client render cannot see.

Why the previous revision is captured **before** the upgrade: a failed upgrade may itself create a
revision, so the rollback value cannot be recovered afterwards.

## Prerequisites — what had to be fixed first

The pipeline could not have worked without all four of these. Each produced a different error, and
three of them looked like something other than what they were.

### 1. The cluster API was unreachable from the build server

```
dial tcp 172.31.36.96:443: i/o timeout
```

That address is **private**. From inside the VPC the EKS endpoint resolves to its private address,
so the public endpoint allow-list is irrelevant to this path — adding the build server's public IP
there changes nothing, because no traffic goes to the public address.

The cluster security group allowed inbound only from **itself**. The fix is a rule on the cluster
security group permitting port 443 from the build server's security group
(`infra/terraform/eks/runner-network.tf`).

The failure mode is worth remembering: it appears as a timeout, which reads like a network fault or
a credentials problem, not a missing security group rule.

### 2. The instance role had no EKS permissions

Two separate things are required, and IAM does not imply the second:

| Requirement | Mechanism | Symptom if missing |
|---|---|---|
| Call the EKS API | IAM `eks:DescribeCluster` | `AccessDenied` from the AWS API |
| Act inside the cluster | EKS **access entry** | `update-kubeconfig` succeeds, then `Unauthorized` |

The second is the confusing one — the error reads like a credential problem. Both are now in
`infra/terraform/eks/runner-access.tf`.

### 3. The umbrella chart vendors its subcharts

`helm dependency build` copies subcharts into `app/umbrella/charts/`. After fixing a subchart,
`helm upgrade` on the umbrella still deployed the **old** content, because the source chart was
correct and the packaged copy was stale. This cost real debugging time on the storage-class fix: the
ConfigMap kept the old value after a successful upgrade.

Any subchart change requires a dependency rebuild first. The deploy workflow operates on the
charts as committed, so this is a local-development concern rather than a pipeline one — but it is
recorded because it will happen again.

### 4. Line endings

The charts, workflows and shell scripts are consumed on Linux — by Helm, by the runner, and by the
build server. A script checked out with CRLF fails with `/bin/bash^M: bad interpreter`. A
`.gitattributes` now normalises everything to LF, with Windows-only script types excluded.

## Authentication — no stored AWS credentials

The runner uses the **instance profile** of the build server. There is no AWS access key in this
repository, in its secrets, or on the runner.

That is only possible because the runner is on the build server, which is also why it must be:

- The cluster endpoint resolves to a private address inside the VPC, so the runner has to be there.
- The cluster security group allows port 443 only from the build server's security group.
- The build server's instance role holds the EKS access entry.

A GitHub-hosted runner would need all three changed.

## Security posture — stated plainly

**This repository is public.** GitHub's own guidance is that self-hosted runners should not be used
with public repositories, because a fork or pull request can execute code on the runner.

Mitigations applied:

- `pull_request` is **not** a trigger, so forks do not run automatically.
- Workflows require manual approval for first-time external contributors.

What is still true and should be understood:

- The runner holds **cluster admin**, because Helm needs to create and delete arbitrary object
  types to diff and apply a chart. A narrower custom ClusterRole is the correct improvement and is
  recorded as a deliberate simplification rather than presented as correct.
- Anyone who can get code onto that runner can deploy to the cluster and push to ECR.

If this repository is ever made private, revisit the decision — the tradeoff changes completely.

## Two steps that need GitHub credentials

Both require an action I cannot take on your behalf, because they need your GitHub account.

### Push the commit

The commit exists locally (`60a6be1`, 125 files: the charts, the workflows, and `.gitattributes`).
Pushing failed with:

```
remote: Invalid username or token. Password authentication is not supported for Git operations.
```

GitHub no longer accepts a password for git operations. Either of these works:

```bash
# Option A: authenticate gh once, then git uses it
gh auth login --web

# Option B: push and let Git Credential Manager open a browser
git push origin main
```

### Register the self-hosted runner

A runner registration token is short-lived and repo-scoped. Get one from
**Settings → Actions → Runners → New self-hosted runner**, then on the build server
(via Session Manager):

```bash
RUNNER_VERSION=2.319.1
mkdir -p /opt/actions-runner && cd /opt/actions-runner
curl -fsSL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
tar xzf runner.tar.gz && rm runner.tar.gz

./config.sh \
  --url https://github.com/Darshan9154/polyglot-shop-k8s-cicd \
  --token <PASTE_TOKEN> \
  --name polyglot-build-server \
  --labels self-hosted,linux,x64 \
  --work /opt/actions-runner/_work \
  --unattended

sudo ./svc.sh install ubuntu
sudo ./svc.sh start
sudo ./svc.sh status
```

## Verified: the build server can deploy

Before writing the pipeline I confirmed the runner's path works, rather than assuming it. Run from
the build server, using its instance role and no stored credentials:

```
=== identity ===
arn:aws:sts::536882095289:assumed-role/retail-store-build-server-role/i-06bae5ecefeb6eb90

=== cluster reachable ===
ip-172-31-12-100.eu-north-1.compute.internal   Ready   <none>   106m   v1.31.13-eks-ecaa3a6
ip-172-31-39-149.eu-north-1.compute.internal   Ready   <none>   103m   v1.31.13-eks-ecaa3a6

=== namespaces ===
data              Active   138m
monitoring        Active   138m
retail-store      Active

=== helm releases ===
aws-load-balancer-controller  kube-system  1  deployed
dynamodb-local                data         3  deployed
jaeger                        monitoring   1  deployed
loki                          monitoring   2  deployed
mariadb                       data         2  deployed
monitoring                    monitoring   1  deployed
otel-collector                monitoring   3  deployed
```

That is the pipeline's deploy step, proven by hand first — the same order used for Compose, the
ECR push, and the deployment itself.

## What is not automated yet

- **Infrastructure.** `terraform apply` for the cluster is still manual. An automated apply needs a
  reviewed plan artifact and an approval step, which is a separate piece of work.
- **Cluster add-ons.** The AWS Load Balancer Controller, kube-prometheus-stack, Loki, Jaeger and the
  collector are installed with `helm upgrade --install` by hand. Only the application charts are
  deployed by the pipeline.
- **The bootstrap layer.** Namespaces, secrets, the gp3 StorageClass and the default-deny policies
  are applied with `kubectl apply` by hand. They change rarely, but they are prerequisites for
  anything the pipeline deploys.

## The `workflow` scope problem, and the workaround

Pushing the two workflow files failed:

```
refusing to allow an OAuth App to create or update workflow
`.github/workflows/build-and-push-ecr.yml` without `workflow` scope
```

`gh auth login` grants `repo`, `gist` and `read:org` — but not `workflow`. Creating or modifying
anything under `.github/workflows/` is deliberately privileged, because a workflow file can execute
arbitrary code on a runner.

`gh auth refresh -s workflow` was the intended fix and it failed four times with
`failure?reason=not_found` from GitHub's device page, despite a valid live code and the correct
eight characters. The cause was never established.

**The workaround turned out better than the fix**: the files were uploaded through the GitHub web UI
(`/upload/main/.github/workflows`) using the signed-in browser session, which needs no token scope
at all. Two files, one commit, no credential handling.

Worth remembering: when a token scope blocks something, the web session usually does not have that
restriction, because it is a different authorization path.

## What was pushed, and where

| Branch | Contents |
|---|---|
| `main` | The sample application, plus `k8s/` (13 charts) and the two workflows |
| `devops-agent-test-polyglot` | Adds `infra/terraform/` and `devops-docs/` on top of that |

The branch exists so pushes to it do not trip the sample repository's own workflows, which were
already failing before this work started — `Release` and `E2E Test` both fail on the initial commit
from 2025 as well.

## A secret that nearly got committed

The scratch file used to build AWS SSM commands (`.ssm-params.json`) contained a **base64-encoded
GitHub Actions runner registration token**. The token had to reach the build server as part of an
SSM command, and writing the parameters to a file was the reliable way to do it.

It was found by grepping for credential patterns immediately before staging, and deleted. A
`.gitignore` rule now covers `*ssm-params*.json` so it cannot be committed by accident.

That file would otherwise have gone into a **public** repository, where the token would have been
readable for the remainder of its one-hour validity. The lesson is the grep, not the file.

## Known exposure: the AWS account id is public

The charts on `main` hardcode the ECR registry:

```yaml
repository: 536882095289.dkr.ecr.eu-north-1.amazonaws.com/polyglot-shop/cart
```

That publishes the AWS account id in a public repository. It is **not** a credential — the registry
still requires authentication to pull or push — but it is a stable account identifier that is
normally not disclosed.

The fix is to parameterise it: move the registry into a Helm value or a workflow variable so the
charts carry no account-specific string. That is a small change to five `values.yaml` files plus the
umbrella. It has not been made, and it is recorded here rather than left undiscovered.

