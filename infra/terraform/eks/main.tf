# The EKS cluster, its node group, and the add-ons that make it usable.

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# OIDC provider — the basis for IRSA
# ---------------------------------------------------------------------------
# Why this is created before the cluster resources that use it: the EBS CSI role's trust
# policy references this provider's ARN, so Terraform must know it first. The dependency is
# expressed through the reference itself rather than an explicit depends_on.
#
# Why the thumbprint is fetched rather than hardcoded: it is a hash of the certificate chain
# of the OIDC issuer. Hardcoding the widely-copied value works until AWS rotates the
# certificate, at which point every IRSA token fails and the failure is hard to attribute.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = {
    Name = "${var.project_name}-${var.environment}-oidc"
  }
}

# Why this local exists: the trust policy conditions need the issuer URL without its scheme
# prefix. Getting this wrong is the most common IRSA mistake — the role is created, the
# service account annotation looks correct, and the token is still rejected with an opaque
# error because the condition key never matches.
locals {
  oidc_provider_url = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = "${var.project_name}-${var.environment}"
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  # Why this must be set explicitly: the default is CONFIG_MAP, which rejects the
  # aws_eks_access_entry resources below with
  #
  #   InvalidRequestException: The cluster's authentication mode must be set to one of
  #   [API, API_AND_CONFIG_MAP] to perform this operation.
  #
  # The failure is indirect and expensive to diagnose: the access entries fail, the node
  # group depends on one of them, so no nodes are created either, and the cluster looks
  # like it was built correctly until you notice there is nothing to schedule onto.
  #
  # Why API_AND_CONFIG_MAP and not API: access entries are the current mechanism, but
  # keeping the aws-auth ConfigMap active means there is still a working way to grant
  # access if an access entry is misconfigured. API-only leaves no fallback path, which is
  # how a cluster becomes unreachable.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    # Why cluster_subnet_ids and NOT subnet_ids: the control plane's subnets are fixed at
    # creation and EKS rejects any later change to the set of availability zones:
    #
    #   InvalidParameterException: Provided subnets belong to the AZs 'eu-north-1b,eu-north-1c'.
    #   But they should belong to the exact set of AZs 'eu-north-1b,eu-north-1c,eu-north-1a' in
    #   which subnets were provided during cluster creation.
    #
    # The node group uses a separate, narrower list. Using one variable for both conflated two
    # independent settings and broke a cluster rebuild; see the variable definitions.
    subnet_ids = var.cluster_subnet_ids

    # Why the endpoint is public with an open CIDR by default: it is the only way to reach
    # the API from the build server and from a workstation. The narrow alternative is
    # documented in the README. This is the one deliberate exposure in the stack, and it is
    # stated rather than buried.
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.endpoint_public_access_cidrs
  }

  # Why which log types and not all of them: each type is billed per GB. Audit is the record
  # of every API change and is the one worth paying for. The others (authenticator,
  # controllerManager, scheduler) add cost and are rarely read on a short-lived cluster.
  enabled_cluster_log_types = var.enable_cluster_logging ? ["audit", "authenticator"] : []

  # Why there is no lifecycle block ignoring access_config here:
  #
  # An earlier version of this file ignored changes to access_config to stop a manual
  # console edit from being reverted. That was wrong and it cost a rebuild cycle: the
  # ignore also suppressed the authentication_mode setting, so Terraform reported
  # "8 to add, 0 to change" and renewed the access entries against a cluster that was
  # still in CONFIG_MAP mode. The entries failed exactly as before.
  #
  # authentication_mode is a real, Terraform-managed setting that EKS updates in place.
  # Suppressing it hides a change that matters. Access entries themselves are managed by
  # the resources further down, so there is nothing here that needs protecting.

  tags = {
    Name = "${var.project_name}-${var.environment}"
    # Why a prominent tag: EKS bills continuously. This is what a cost report or a console
    # filter uses to find a cluster that was left running.
    Billing = "hourly-control-plane"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_iam_role_policy_attachment.cluster_vpc_resource_controller,
  ]
}

# ---------------------------------------------------------------------------
# Access entries — who may administer the cluster
# ---------------------------------------------------------------------------
# Why access entries rather than the aws-auth ConfigMap: access entries are the current
# mechanism and are a first-class AWS resource, so they are visible in Terraform state and
# in the API. The aws-auth ConfigMap is a Kubernetes object that can drift, and editing it
# incorrectly is the classic way to lock yourself out of a cluster.
#
# Why this matters immediately: without an access entry, the IAM user that created the
# cluster has no permission inside it. `kubectl` returns a permissions error while the
# cluster itself is perfectly healthy.
resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"

  tags = {
    Name = "admin-access"
  }
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_caller_identity.current.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    # Why cluster-wide scope: this is the deploying identity on a test cluster. A production
    # cluster would scope the grant to namespaces and give a separate break-glass role.
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# Why the node role also gets an access entry: EKS nodes must be able to authenticate to the
# control plane to register. Without this entry the nodes boot, run their bootstrap script,
# and are rejected with an authorization error — the node group reports DEGRADED and no pods
# ever schedule. On clusters created before access entries this was handled by the aws-auth
# ConfigMap, which is why the requirement is easy to miss.
resource "aws_eks_access_entry" "node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.node.arn
  # Why EC2_LINUX and not STANDARD: this entry type is specifically for nodes, and EKS uses
  # it to grant the node the permissions it needs to join.
  type = "EC2_LINUX"

  tags = {
    Name = "node-access"
  }
}

# ---------------------------------------------------------------------------
# Managed node group
# ---------------------------------------------------------------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project_name}-${var.environment}-nodes"
  node_role_arn   = aws_iam_role.node.arn

  # Why the subnets are ordered as given: EKS places nodes across them, and the ordering
  # determines which AZs are tried first when capacity is constrained.
  subnet_ids = var.subnet_ids

  # Why a list of instance types rather than one: EKS selects an available type from the
  # list. If the first choice is out of capacity in an AZ, the next is used. A single type
  # turns a transient capacity shortage into a failed apply.
  instance_types = var.node_instance_types
  ami_type       = var.node_ami_type
  capacity_type  = "ON_DEMAND"

  # Why ON_DEMAND and not SPOT: spot instances can be reclaimed with two minutes' notice,
  # which for a database-backed test deployment means an interrupted test and a node that
  # disappears mid-deployment. The saving is not worth the unpredictability at this size.

  disk_size = var.node_disk_size_gb

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    # Why 1: nodes are replaced one at a time. With two nodes this keeps one serving while
    # the other is replaced, so a version update does not take the whole workload down.
    # With desired_size 2 and max_unavailable 2, both nodes would drain at once.
    max_unavailable = 1
  }

  # Why this block exists: Terraform can propose a change to desired_size that the cluster
  # autoscaler or a manual scale has already applied. Ignoring it prevents an apply from
  # fighting a deliberate operational change.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  labels = {
    role        = "worker"
    environment = var.environment
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-nodes"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_policies,
    aws_eks_access_entry.node,
  ]
}

# ---------------------------------------------------------------------------
# Add-ons
# ---------------------------------------------------------------------------
# Why these are managed add-ons rather than installed by hand: EKS tracks the compatible
# version of each for the cluster's Kubernetes version, so an upgrade path exists. Versions
# installed manually drift out of support silently.
#
# Why no version is pinned below: `resolve_conflicts_on_create = "OVERWRITE"` combined with
# an omitted version lets EKS choose the default compatible version for the cluster
# version. Pinning a version here would need updating every time the cluster version
# changes, and a stale pin fails the add-on update with a compatibility error.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"

  # Why not "OVERWRITE" on update: this add-on manages pod IP addresses. Overwriting an
  # existing configuration could discard settings made deliberately.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  # Why coredns depends on nodes specifically: it runs as pods, so it cannot become healthy
  # until a node exists. Creating it first leaves it stuck and the apply times out.
  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.this]
}

# Why the EBS CSI driver is installed as an add-on: it needs the IRSA role created above,
# and installing it through EKS is what lets EKS keep it compatible with the cluster
# version. Without this add-on, every PersistentVolumeClaim in the charts stays Pending with
# the misleading message "no persistent volumes available for this claim".
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}
