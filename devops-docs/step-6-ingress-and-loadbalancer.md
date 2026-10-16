# Exposing the storefront: AWS Load Balancer Controller

The UI is reachable from the internet at:

```
http://k8s-polyglotshop-31af1f576f-1786269146.eu-north-1.elb.amazonaws.com/
```

That address is the load balancer's own DNS name. It is stable for the life of the load
balancer but is **not** a domain you control, and it changes if the load balancer is recreated.

## Verified

```
/                  -> 200  19973 bytes
/catalog           -> 200  20639 bytes
/cart              -> 200   8685 bytes
/actuator/health   -> 200     49 bytes
```

`19973` bytes is the same page the Docker Compose deployment served and the same size the
port-forward returned, so the storefront is intact end to end: load balancer → UI pod →
catalog service → MariaDB.

## Why the AWS Load Balancer Controller rather than a Service of type LoadBalancer

On an EKS 1.31 cluster, a `Service` of type `LoadBalancer` is served by the deprecated in-tree
cloud provider, which provisions a Classic Load Balancer. The Ingress route uses the AWS Load
Balancer Controller installed in the cluster, which provisions an ALB with proper target
groups, health checks and path routing, and lets several Ingresses share one load balancer.

Required because a current cluster ships no controller: without it an Ingress is accepted by the
API server and then silently ignored. The symptom is that no load balancer ever appears and the
Ingress has no address — there is no error to read on the Ingress itself.

## What runs where

| Object | Namespace | Purpose |
|---|---|---|
| `aws-load-balancer-controller` | `kube-system` | watches Ingress and Service objects, calls the ELB API |
| IngressClass `alb` | cluster-scoped | created by the controller; selects it for an Ingress |
| Ingress `shop-ui` | `retail-store` | routes `/` to the `shop-ui` Service |
| TargetGroupBinding | `retail-store` | created by the controller; registers pod IPs with the target group |
| IAM role `polyglot-shop-dev-lb-controller` | — | IRSA role; no access keys stored anywhere |

## Why only the UI is exposed

The UI is the only component meant to face the internet. It aggregates catalog, cart, orders and
checkout internally over ClusterIP Services. Publishing those four would expose internal APIs
that have no edge protection — the cart API would accept any request that reaches it.

If the catalog API needs to be reachable for testing, add a second Ingress with the same
`alb.ingress.kubernetes.io/group.name: polyglot-shop` annotation and it will attach to this same
load balancer rather than provisioning another one.

## Two failures worth recording

### Health check timeout must be smaller than the interval

```
ValidationError: Health check timeout '10' must be smaller than the interval '5'
```

The first version set a 10-second timeout with a 5-second interval. ELB rejects that outright,
and the controller retries forever, so **no load balancer is created and no address ever
appears**. The only evidence is this message in the controller log — the Ingress itself looks
fine. Now `interval: 10`, `timeout: 5`, which leaves a 5-second margin for the JVM health
endpoint on its first call after a cold start.

### `ec2:Describe*` does not cover `ec2:GetSecurityGroupsForVpc`

```
AccessDenied: not authorized to perform: ec2:GetSecurityGroupsForVpc
```

`Describe*` is a wildcard over actions beginning with the word "Describe". It does **not** match
`GetSecurityGroupsForVpc`, which is a separate action name. The consequence is subtle: the load
balancer is created and the Ingress gets its address, but security group reconciliation fails —
and the security group rules are what allow traffic to reach the targets. The endpoint exists
and refuses connections.

The action is now listed explicitly in the IRSA policy. This is the kind of omission that is
easy to miss precisely because the visible outcome (an address) looks like success.

## Cost

| Item | Rate |
|---|---|
| Application Load Balancer | ~$0.0225/hour (~$16/month) |
| Load balancer capacity units | per LCU/hour, based on traffic |
| Data processed | per GB |

The ALB adds roughly **$0.02–0.03/hour** on top of the cluster's ~$0.30/hour. It is deleted
when the Ingress is removed, because the controller owns its lifecycle — but note that the
load balancer must be gone **before** `terraform destroy`, or its security group blocks VPC
teardown.

## Limitations

1. **No TLS.** There is no domain name, so there is no certificate to attach. Traffic is
   plaintext HTTP. Adding TLS means pointing a domain at this load balancer, requesting an ACM
   certificate, and adding a listener annotation — no change to the routing.
2. **No host restriction.** A single catch-all rule serves every hostname, so the load balancer
   answers to its own DNS name and to its IP directly. Host-based routing needs a domain.
3. **The endpoint is world-reachable.** Anyone with the address reaches the storefront. That is
   the point of the test, but it is not a deployment posture: a real one would restrict the
   listener, add TLS, and add authentication.
4. **`/utility/*` and `/chaos/*` are reachable** through this endpoint if the application exposes
   them. The same caveat was recorded for the Compose deployment's published port.
