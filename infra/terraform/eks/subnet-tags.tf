# Subnet tagging for EKS cluster discovery.
#
# Why these tags are not optional and not cosmetic:
#
#   When an EKS cluster is created with a node group placed into subnets, the AWS cloud
#   provider inside the cluster needs to know which subnets belong to it. That information
#   comes from a tag on the subnet:
#
#       kubernetes.io/cluster/<cluster-name> = shared
#
#   Without the tag, several things degrade — and they degrade quietly:
#
#     * the scheduler cannot determine each node's availability zone from the provider, so it
#       cannot reason about EBS volume topology at all. Claim-bound pods then fail with
#       "node(s) had volume node affinity conflict" even when a correctly zoned node exists.
#     * a Service of type LoadBalancer has no tagged subnet to place the load balancer in, so
#       it stays in <pending> forever with no obvious cause.
#
#   The default VPC subnets carry no such tag. That is the trap: the cluster is created
#   successfully, the nodes join, pods schedule — and then the first StatefulSet with a volume
#   in a different zone than the node reveals that a fundamental piece of discovery is missing.
#
# Why `shared` and not `owned`: `owned` means this cluster is the only one that may use the
# subnet. The default VPC subnets may be used by other resources, so `shared` is the accurate
# statement. Choosing `owned` here would be both wrong and hard to undo.
#
# Why this is managed in Terraform rather than applied once by hand: a cluster that works
# because someone clicked a tag in the console stops working the moment a subnet is replaced
# or another environment is built from the same code. The tag is part of the infrastructure.

resource "aws_ec2_tag" "subnet_cluster" {
  # Why for_each over the subnets actually in use: only the subnets the node group occupies
  # need the tag. Tagging unrelated subnets would advertise capacity the cluster does not use.
  for_each = var.tag_subnets_for_eks ? toset(var.subnet_ids) : toset([])

  resource_id = each.value
  key         = "kubernetes.io/cluster/${aws_eks_cluster.this.name}"
  value       = "shared"
}

# Why the role tag as well: it is what marks a subnet as eligible for public load balancers.
# Without it, a Service of type LoadBalancer cannot place an internet-facing load balancer,
# which is how the UI would be exposed if it were published through a Service rather than
# reached by port-forward.
resource "aws_ec2_tag" "subnet_elb_role" {
  for_each = var.tag_subnets_for_eks ? toset(var.subnet_ids) : toset([])

  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}
