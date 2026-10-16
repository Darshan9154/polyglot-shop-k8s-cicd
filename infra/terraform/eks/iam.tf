# IAM roles for the EKS cluster, its nodes, and the EBS CSI driver.
#
# Why these are defined here rather than using the AWS-managed roles: a cluster needs a
# role that can be assumed by the EKS service itself, and a node group needs a role that
# can be assumed by EC2. Neither exists until it is created, so this is unavoidable setup.
# The policies attached are the AWS-managed ones, which keeps the permissions reviewable
# against AWS documentation rather than being a hand-rolled policy nobody can audit.

# ---------------------------------------------------------------------------
# Control plane role
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect = "Allow"

    # Why the service principal and not an account: EKS assumes this role on behalf of the
    # control plane. Without the SourceAccount condition any AWS account could attempt to
    # assume it, so the condition is the part that actually makes the trust safe.
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.project_name}-${var.environment}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  description        = "Role assumed by the EKS control plane for ${var.project_name}-${var.environment}"

  tags = {
    Name = "${var.project_name}-${var.environment}-eks-cluster"
  }
}

# Why this managed policy and what it grants: it lets the control plane manage the network
# interfaces and security groups it creates for the cluster endpoint and each node ENI.
# Without it the cluster fails to create with an error about elastic network interfaces.
resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Why this is attached despite being deprecated: the EKS service still requires the VPC
# resource controller permissions on some cluster operations even when the VPC CNI add-on
# manages them itself. Omitting it produces a cluster that looks healthy but cannot create
# node network interfaces.
resource "aws_iam_role_policy_attachment" "cluster_vpc_resource_controller" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# ---------------------------------------------------------------------------
# Node group role
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.project_name}-${var.environment}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  description        = "Role assumed by worker nodes in ${var.project_name}-${var.environment}"

  tags = {
    Name = "${var.project_name}-${var.environment}-eks-node"
  }
}

# Why each of these three and what breaks without it:
#
#   AmazonEKSWorkerNodePolicy       the kubelet needs to describe itself to the control
#                                   plane and register the node. Without it nodes never
#                                   join and the node group reports DEGRADED.
#
#   AmazonEKS_CNI_Policy            the VPC CNI add-on assigns each pod an IP address from
#                                   the subnet. Without it pods get no address and every
#                                   pod sits in ContainerCreating forever — a failure that
#                                   looks like a scheduling problem but is not.
#
#   AmazonEC2ContainerRegistryReadOnly
#                                   this is what lets the nodes pull the application images
#                                   from ECR with no imagePullSecret at all. It is the
#                                   reason the charts specify no pull credentials.
locals {
  node_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  # Why for_each rather than count: the policy ARNs are the identity of each attachment. With
  # count, removing an entry from the middle of the list would shift every subsequent index
  # and Terraform would detach and reattach unrelated policies.
  for_each = toset(local.node_policies)

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# EBS CSI driver role (IRSA)
# ---------------------------------------------------------------------------
# Why this exists: the charts define PersistentVolumeClaims for MariaDB, PostgreSQL, Redis,
# RabbitMQ, DynamoDB Local, Prometheus and Loki. On EKS those claims are satisfied by EBS
# volumes, and something has to call the EBS API to create and attach them. Since EKS 1.23
# that is no longer built into the node's own credentials — it needs the EBS CSI driver
# with its own IAM permissions, granted through IRSA.
#
# Why IRSA and not node-instance-role permissions: attaching EBS permissions to the node
# role would let every pod on the node create, attach and delete any EBS volume in the
# account. IRSA scopes the permission to the one service account that needs it.

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    # Why both conditions: the first restricts the assumption to the EBS CSI driver's
    # service account, the second restricts it to a token issued for this cluster. Either
    # alone is insufficient — the first can be spoofed by another cluster's service account
    # with the same name, and the second would let any service account in this cluster
    # assume the role.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.project_name}-${var.environment}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json
  description        = "IRSA role for the EBS CSI driver, which provisions PersistentVolumes"

  tags = {
    Name = "${var.project_name}-${var.environment}-ebs-csi"
  }
}

# Why the AWS-managed policy: it is the documented set of permissions for the driver
# (volume create, attach, detach, snapshot, describe). Hand-rolling it would be a good way
# to miss a permission that only fails on a rarely taken code path.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
