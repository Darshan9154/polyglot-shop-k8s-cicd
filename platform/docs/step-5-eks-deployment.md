# Step 5 — Running the application on EKS

**Status: complete and verified.** The Polyglot Shop runs on a real EKS cluster, deployed
from the Helm charts in `k8s/`, with images pulled from ECR.

## Verified evidence

```
kubectl get pods -A (application + data namespaces)
data           dynamodb-local-0    1/1  Running
data           mariadb-0           1/1  Running
data           postgresql-0        1/1  Running
data           rabbitmq-0          1/1  Running
data           redis-0             1/1  Running
retail-store   shop-cart-7456dfd949-z7452     1/1  Running
retail-store   shop-catalog-5f76fd697f-vb2wk  1/1  Running
retail-store   shop-checkout-b7cbc98f9-rjrsf  1/1  Running
retail-store   shop-orders-54b56b5b5-l8znk    1/1  Running
retail-store   shop-ui-75fcf67fc5-tc7h7       1/1  Running
```

Through a port-forward to the UI service:

```
ui_http=200
ui_bytes=19973
product_mentions=18
title=Demo Store
catalog_page=200 bytes=20639
```

`ui_bytes=19973` is the same byte count the local Compose deployment returned, so this is
the same application serving the same page — not a placeholder or a degraded variant.
`catalog_page=200` proves the UI reached the catalog service, which reached MariaDB.

## Cluster

| Item | Value |
|---|---|
| Cluster | `polyglot-shop-dev`, Kubernetes 1.31 |
| Region | `eu-north-1` |
| Nodes | 2 × `m7i-flex.large` (2 vCPU / 8 GiB), one in `eu-north-1b`, one in `eu-north-1c` |
| Add-ons | `vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver` |
| Storage | `gp3` StorageClass (default), provisioner `ebs.csi.aws.com` |
| API endpoint | restricted to the operator's address, not open |
| Terraform | 19 resources, `terraform plan` reports no drift |

Helm releases: `shop` (retail-store), `mariadb`/`postgresql`/`redis`/`rabbitmq`/`dynamodb-local` (data).

## Failures encountered, and what each one taught

These are recorded because each cost real time and several are reusable across any EKS
deployment.

### 1. The EKS access entry mode must be set at cluster creation

```
InvalidRequestException: The cluster's authentication mode must be set to one of
[API, API_AND_CONFIG_MAP] to perform this operation.
```

The cluster created with the default `CONFIG_MAP` mode, so `aws_eks_access_entry` failed.
Because the node group depended on its access entry, **no nodes were created either** — the
cluster looked successfully built while having nothing to schedule onto.

Fix: `access_config { authentication_mode = "API_AND_CONFIG_MAP" }`. A follow-on mistake made
this worse: an `ignore_changes = [access_config]` lifecycle block meant the correction was
silently suppressed and the same error reappeared. That block is gone.

### 2. Installing an ARM instance type with an x86 AMI

```
InvalidParameterException: [t4g.small] is not a valid instance type for requested amiType AL2_x86_64
```

`t4g` is Graviton. The application images are single-architecture x86, so switching the AMI to
ARM would only move the failure to image pull with "no matching manifest". The instance list
must be one architecture and must match `ami_type`.

### 3. t3.small cannot hold this workload — memory limits, not just requests

t3.small has 2 GiB, of which only ~1.43 GiB is allocatable once the EKS system daemonsets run.
After the five backing services and five application services:

```
Allocated resources:  memory  1308Mi (89%)  3764Mi (257%)
FailedScheduling: 0/2 nodes are available: 2 Insufficient memory.
```

Two pods could never schedule. The 89% of *requests* is what blocks scheduling; the **257% of
limits** is the more serious figure, because limits that far above capacity mean the first
memory spike triggers node-level OOM eviction of whichever pods happen to be largest. Nodes
were resized to `m7i-flex.large` (~6.9 GiB allocatable each).

### 4. Default VPC subnets carry no EKS tags

```
FailedScheduling: 0/3 nodes are available: 3 node(s) had volume node affinity conflict
```

The AWS cloud provider discovers a cluster's subnets through
`kubernetes.io/cluster/<cluster-name>` on the subnet. The default VPC subnets have no such tag,
so the scheduler could not determine node zones and could not reason about EBS volume topology.
Claims bound to volumes in `1c` were unschedulable while nodes sat in `1a`/`1b`.

Fix: `subnet-tags.tf` applies the cluster tag and the `elb` role tag via Terraform, so it is
not a console click that disappears when a subnet is replaced.

### 5. A cluster's control plane subnets cannot be changed

```
InvalidParameterException: Provided subnets belong to the AZs 'eu-north-1b,eu-north-1c'.
But they should belong to the exact set of AZs '...' in which subnets were provided during
cluster creation.
```

One variable fed both the cluster and the node group. Narrowing it to fix the volume-affinity
problem tried to modify the control plane, and the apply failed **after** destroying the node
group — leaving a cluster with no workers. Now `cluster_subnet_ids` and `subnet_ids` are
separate variables, and the distinction is documented in both.

### 6. EBS volumes are bound to one availability zone, and EKS picks the zone

A managed node group takes a subnet list and EKS chooses the zone. Both nodes landed in
`eu-north-1c` while two volumes had been created in `eu-north-1b` during an earlier node
generation. Terraform cannot pin a managed node group to a zone.

Fix: for the two stranded claims, scale the StatefulSet to zero, delete the claim, scale back
up. The new claim binds in the zone the nodes are in, because the charts use
`WaitForFirstConsumer`. Data was empty test data in both cases.

### 7. The EKS-created `gp2` StorageClass is not a default and uses a removed provisioner

```
gp2   kubernetes.io/aws-ebs      ← deprecated in-tree provisioner, removed from recent Kubernetes
```

Two separate problems: the class had **no `is-default-class` annotation**, so claims received
no class at all; and its provisioner no longer exists, so even a correctly assigned claim could
not be satisfied by the installed CSI driver. The symptom is misleading:

```
pod has unbound immediate PersistentVolumeClaims
```

which reads like a capacity problem. Fixed by applying `gp3` (provisioner `ebs.csi.aws.com`)
as the default and removing the default marker from `gp2`.

### 8. RabbitMQ refused to start over its Erlang cookie

```
Cookie file /var/lib/rabbitmq/.erlang.cookie must be accessible by owner only
Kernel pid terminated (application_controller)
```

The image creates the cookie during its own initialisation and Kubernetes widens its
permissions via `fsGroup`. An init container now creates it if absent and forces mode `0400`:

```
cookie mode: 400 rabbitmq
```

The readiness probe also needed a longer timeout — `rabbitmq-diagnostics -q ping` exceeded the
one-second default, and a timed-out probe is indistinguishable from a failed broker.

### 9. Service addresses must include the Helm release prefix

```
java.net.UnknownHostException: cart.retail-store.svc.cluster.local: System error
```

The UI returned 500 while every pod reported `Ready`. The app charts are installed under the
release name `shop`, so the Services are `shop-cart`, `shop-catalog` and so on — but the UI's
endpoints, its egress NetworkPolicy and the data services' ingress policies all referenced
unprefixed names.

The naming asymmetry is what made this look like a DNS fault: the `data` namespace releases are
named after their charts, so those names have no prefix and resolved correctly.

### 10. The umbrella chart vendors its subcharts

After fixing a subchart, `helm upgrade` on the umbrella still deployed the old content, because
`helm dependency build` had copied the subcharts into `app/umbrella/charts/`. The source chart
was correct and the packaged copy was stale. Any subchart change needs a dependency rebuild
before the umbrella is upgraded.

## Cost

| Item | Rate |
|---|---|
| EKS control plane | ~$0.10/hour, billed whether or not anything runs |
| 2 × `m7i-flex.large` | ~$0.102/hour each |
| EBS (node root + 5 × PVC + PV) | ~$0.08/GB-month |
| CloudWatch control-plane logs | per GB ingested |

**Roughly $0.30/hour while it exists.** The control plane is the part that surprises people:
it bills continuously, so an idle cluster costs about $2.40 overnight.

## Tearing down

```bash
# 1. Delete the Helm releases first, so load balancers and PVCs are cleaned up
helm --kube-context <ctx> uninstall shop -n retail-store
helm --kube-context <ctx> uninstall mariadb postgresql redis rabbitmq dynamodb-local -n data

# 2. Remove the namespaces and their claims
kubectl --context <ctx> delete pvc --all -n data
kubectl --context <ctx> delete ns retail-store data monitoring

# 3. Destroy the cluster
cd infra/terraform/eks && terraform destroy
```

## Known limitations of this deployment

Recorded rather than glossed over:

1. **Both nodes are not guaranteed to be in different zones.** This run happened to place one
   node in each of `1b` and `1c`, but a managed node group does not guarantee zone spread. A
   zone failure can therefore take the whole workload down. Real availability needs either
   three node groups pinned per zone or an autoscaler with zone-aware balancing.
2. **No TLS and no domain.** The UI is exposed through an internet-facing ALB, verified at
   `http://k8s-polyglotshop-31af1f576f-1786269146.eu-north-1.elb.amazonaws.com/`. That is the
   load balancer's own DNS name, so traffic is plaintext and the address changes if the load
   balancer is recreated. See `step-6-ingress-and-loadbalancer.md`.
3. **Alertmanager has no receiver**, so alerts evaluate but are not delivered anywhere.

## Exposure added after this step

The storefront was subsequently published through an internet-facing Application Load Balancer
using the AWS Load Balancer Controller. All four paths verified `200` through it:

```
/                  -> 200  19973 bytes
/catalog           -> 200  20639 bytes
/cart              -> 200   8685 bytes
/actuator/health   -> 200     49 bytes
```

The byte count matching the Compose deployment confirms the same application end to end:
load balancer → UI pod → catalog service → MariaDB. Details, the two configuration failures, and
the cost are in [step-6-ingress-and-loadbalancer.md](step-6-ingress-and-loadbalancer.md).
