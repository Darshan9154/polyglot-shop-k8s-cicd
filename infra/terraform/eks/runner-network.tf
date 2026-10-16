# Network access to the cluster API from the build server.
#
# Why this is required, and why the symptom is misleading:
#
#   From inside the VPC, the EKS API endpoint resolves to its PRIVATE address rather than its
#   public one. The build server is in the same VPC, so it gets the private address:
#
#     dial tcp 172.31.36.96:443: i/o timeout
#
#   That makes the public endpoint allow-list irrelevant to this path — adding the build
#   server's public IP there does not help, because no traffic ever goes to the public address.
#   What matters is the cluster's security group.
#
#   The cluster security group allows inbound only from ITSELF (so nodes can talk to the control
#   plane). The build server's security group is not a member, so its connections to 443 are
#   dropped and the failure appears as a timeout rather than a permission error — which reads
#   like a network fault or a credentials problem, not a missing security group rule.
#
# Why the rule is scoped to the build server's security group and not a CIDR:
#
#   A CIDR rule would allow anything that can reach that address range. Referencing the
#   security group means the permission follows the instance identity: it applies to whatever
#   carries that group, and it is revoked by removing the group from the instance.
#
# Why 443 only:
#
#   The API server listens on 443 and nothing else needs to reach the control plane from the
#   build server. Allowing the full port range would open paths that are not used.
#
# Why this is managed in Terraform rather than clicked in the console:
#
#   An access rule that exists only in the console is invisible to anyone reading this
#   configuration, and it disappears the moment the cluster security group is recreated. The
#   dependency on a security group created by the build-server stack is explicit here.

# The build server's security group, read by the tags that stack applies.
data "aws_instance" "build_server" {
  # Why by instance id and not by a hardcoded group id or name: the group is created by the
  # build-server stack and its name carries a generated suffix. Hardcoding that would break when
  # the stack is reapplied; looking it up by a tag assumes a tag that stack may not set.
  # Resolving it through the instance is exact — it is the group the instance actually carries —
  # and it fails loudly if the instance is replaced rather than silently matching the wrong group.
  instance_id = var.build_server_instance_id
}

resource "aws_security_group_rule" "cluster_api_from_build_server" {
  # Why for_each: an instance can carry more than one security group. One rule per group means
  # the permission applies whichever group the traffic is evaluated against, rather than
  # depending on an assumption about which one that is.
  for_each = var.enable_runner_api_access ? toset(data.aws_instance.build_server.vpc_security_group_ids) : toset([])

  # Why the cluster's own security group rather than a new one: the control plane ENIs already
  # carry it, and EKS manages those. Adding a rule to the existing group is the supported way to
  # grant API access from inside the VPC.
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"

  # Why source_security_group_id and not cidr_blocks: the permission is tied to the instance's
  # identity rather than to an address that can be reassigned.
  source_security_group_id = each.value

  # Why no apostrophe in the description: AWS restricts security group descriptions to a
  # limited character set that excludes the single quote. Terraform reports this as a
  # validation failure naming the exact restriction, which is far better than discovering it at
  # apply time.
  description = "Kubernetes API access from the build server CI runner for helm and kubectl deploy"
}
