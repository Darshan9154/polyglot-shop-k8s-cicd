# Access for the build server's self-hosted GitHub Actions runner.
#
# Why this is needed:
#
#   The pipeline's deploy job runs `helm upgrade` against this cluster from the build server.
#   Two separate things must be true, and both are easy to overlook because their absence
#   produces an error that points somewhere else:
#
#     1. The identity must be allowed to CALL the EKS API at all
#        (`eks:DescribeCluster`), which is an IAM permission.
#     2. The identity must be allowed to DO things INSIDE the cluster, which is an EKS access
#        entry — a completely separate mechanism that IAM does not imply.
#
#   Missing the first gives `AccessDenied` from the AWS API. Missing the second gives a
#   successful `aws eks update-kubeconfig` followed by `error: You must be logged in to the
#   server (Unauthorized)` from kubectl, which reads like a credential problem rather than a
#   missing grant.
#
# Why a separate role for the runner rather than widening the instance role:
#
#   The instance role is what any process on the build server inherits, including a Docker
#   build or a test that runs untrusted code. Granting it cluster-admin would mean a
#   compromised build step has full control of the cluster. Keeping the runner's permissions
#   in their own role means the instance role stays as narrow as it is today, and the cluster
#   grant can be audited and revoked on its own.
#
#   The instance role is still what the AWS SDK picks up by default, so the workflow assumes
#   this role explicitly before deploying.

data "aws_caller_identity" "build_server_account" {}

# The existing instance profile role, referenced rather than managed here: it is created in the
# build-server stack and this stack only needs to add permissions to it.
locals {
  build_server_role_name = "retail-store-build-server-role"
}

# ---------------------------------------------------------------------------
# 1. Permission to call the EKS API
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "runner_eks_describe" {
  statement {
    sid    = "DescribeClusterForKubeconfig"
    effect = "Allow"
    actions = [
      # Why DescribeCluster and not more: this is what `aws eks update-kubeconfig` calls to
      # fetch the cluster's endpoint and certificate authority. It is the only AWS API call the
      # deploy job needs, because everything after that goes through the Kubernetes API using
      # the token the access entry authorises.
      "eks:DescribeCluster",
      "eks:ListClusters",
    ]
    # Why scoped to this cluster and not "*": the permission is only ever used for this one
    # cluster, so there is no reason to allow it account-wide.
    resources = [aws_eks_cluster.this.arn]
  }
}

resource "aws_iam_policy" "runner_eks_describe" {
  name        = "${var.project_name}-${var.environment}-runner-eks"
  description = "Lets the CI runner read this cluster's endpoint and CA so it can deploy to it"
  policy      = data.aws_iam_policy_document.runner_eks_describe.json

  tags = {
    Name = "${var.project_name}-${var.environment}-runner-eks"
  }
}

resource "aws_iam_role_policy_attachment" "runner_eks_describe" {
  role       = local.build_server_role_name
  policy_arn = aws_iam_policy.runner_eks_describe.arn
}

# ---------------------------------------------------------------------------
# 2. Permission to act inside the cluster
# ---------------------------------------------------------------------------
# Why an access entry rather than editing the aws-auth ConfigMap: access entries are the
# current mechanism and are a first-class AWS resource, so they appear in Terraform state and
# in the API. Editing aws-auth by hand is the classic way to lock yourself out of a cluster,
# because a malformed ConfigMap cannot be fixed through the API path it just broke.
resource "aws_eks_access_entry" "build_server" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.build_server_account.account_id}:role/${local.build_server_role_name}"
  type          = "STANDARD"

  tags = {
    Name = "build-server-ci"
  }
}

# Why the admin policy and not something narrower:
#
#   The deploy job runs `helm upgrade --install` across five application charts and five
#   infrastructure charts. Helm creates, updates and deletes any Kubernetes object type a chart
#   contains, and needs read access to everything to compute a diff. There is no narrow
#   built-in policy that covers "deploy Helm charts" — the alternatives are the edit policy
#   (which excludes RBAC and namespace management) or this one.
#
#   A production setup would define a custom ClusterRole covering exactly the resources these
#   charts manage, and bind it to a namespace-scoped RoleBinding rather than ClusterRoleBinding.
#   That is a real improvement and a real piece of work; it is recorded here as a deliberate
#   simplification for a single-tenant test cluster rather than presented as correct.
resource "aws_eks_access_policy_association" "build_server" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.build_server.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.build_server]
}
