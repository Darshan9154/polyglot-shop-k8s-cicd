# IAM for the AWS Load Balancer Controller.
#
# Why this is needed at all:
#
#   A Kubernetes Service of type LoadBalancer and an Ingress both require something to call the
#   Elastic Load Balancing API to create and configure the load balancer. Until recently that
#   was the cloud provider built into the control plane. It is deprecated, and on a current
#   cluster the supported path is the AWS Load Balancer Controller running as a workload with
#   its own IAM permissions.
#
#   Without it, an Ingress is accepted by the API server but nothing acts on it: no load
#   balancer is created, the Ingress has no address, and the only symptom is that the host
#   never responds.
#
# Why IRSA rather than attaching permissions to the node role:
#
#   The controller's policy can create and delete load balancers, target groups and security
#   groups across the whole account. Attaching that to the node's instance role would grant
#   those permissions to every pod on every node. IRSA scopes the grant to the controller's own
#   service account, which is the only identity that needs it.

data "aws_iam_policy_document" "lb_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    # Why both conditions: the subject restricts the assumption to the controller's service
    # account, and the audience restricts it to a token minted for this cluster. The subject
    # alone could be satisfied by a different cluster with a same-named service account; the
    # audience alone would allow any service account in this cluster to assume the role.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "${var.project_name}-${var.environment}-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume_role.json
  description        = "IRSA role for the AWS Load Balancer Controller"

  tags = {
    Name = "${var.project_name}-${var.environment}-lb-controller"
  }
}

# Why the policy is written here rather than attaching the AWS-managed policy:
#
#   There is no AWS-managed policy for this controller — the upstream project publishes a JSON
#   document that has to be attached. Writing it here keeps the exact permission set visible in
#   the repository and under version control, instead of being fetched at install time by a
#   script nobody reviews.
#
# Why the resource scopes are not narrowed further:
#
#   Several of these actions are called before the resource exists, so they cannot be scoped to
#   a specific ARN (`CreateLoadBalancer`, `CreateTargetGroup`). The tagging conditions on the
#   mutating actions are what prevent the controller from touching load balancers belonging to
#   another cluster or project. Narrowing further would break the controller in ways that only
#   appear at runtime.
data "aws_iam_policy_document" "lb_controller" {
  # -- Discovery: read the network and cluster shape to decide where to place the load balancer
  #
  # Why `ec2:GetSecurityGroupsForVpc` is listed separately from `ec2:Describe*`:
  #
  #   `Describe*` is a wildcard over actions beginning with that word. It does not cover
  #   `GetSecurityGroupsForVpc`, which is a distinct action name. With only the wildcard, the
  #   controller created the load balancer and then failed to complete reconciliation:
  #
  #     AccessDenied: not authorized to perform: ec2:GetSecurityGroupsForVpc
  #
  #   The failure is easy to miss because the load balancer does get created and the Ingress
  #   does get an address. What is missing is the security group reconciliation, which is what
  #   attaches the rules that let traffic reach the targets — so the endpoint can exist and
  #   still refuse connections.
  #
  # Why this is written as an explicit list rather than a broader wildcard: widening the
  # wildcard further would grant read access to far more than the controller needs, and the
  # omission of a single action is exactly the kind of thing the error message names precisely.
  statement {
    sid    = "DescribeNetworkAndCluster"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:GetSecurityGroupsForVpc",
      "elasticloadbalancing:Describe*",
    ]
    resources = ["*"]
  }

  # -- Security groups
  #
  # Why the controller manages security groups at all: it creates one per load balancer and one
  # per target group, then attaches them. Without these the load balancer exists but no traffic
  # reaches the pods, which looks like an application failure.
  statement {
    sid    = "ManageSecurityGroups"
    effect = "Allow"
    actions = [
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = ["*"]
  }

  # -- Load balancers
  statement {
    sid    = "ManageLoadBalancers"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:CreateTargetGroup",
    ]
    resources = ["*"]
  }

  # Why the tagging condition only appears on the mutating actions: create calls cannot be
  # constrained by a resource ARN because the ARN does not exist yet. Restricting delete and
  # update by the cluster tag is what stops the controller from removing another cluster's load
  # balancer if it is ever pointed at a shared account.
  statement {
    sid    = "ModifyOwnedLoadBalancerResources"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:SetWebAcl",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = [aws_eks_cluster.this.name]
    }
  }

  # Why this statement exists separately: the controller tags the load balancer at creation, and
  # the create call itself has no existing tag for the condition above to match. Without this
  # the first apply fails with an AccessDenied on AddTags.
  statement {
    sid       = "TagOnCreate"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:AddTags"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "elasticloadbalancing:CreateAction"
      values = [
        "CreateLoadBalancer",
        "CreateListener",
        "CreateRule",
        "CreateTargetGroup",
      ]
    }
  }

  # -- Service load balancers: the controller must be able to read the node's VPC so it can
  # attach the load balancer to the right subnets.
  statement {
    sid       = "ReadCallerIdentity"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole", "iam:GetServerCertificate", "iam:ListServerCertificates"]
    resources = ["*"]
  }

  # -- Certificates: needed only when a TLS listener is configured. Included so that adding a
  # certificate later does not require an IAM change, which would be an easy thing to forget.
  statement {
    sid       = "UseCertificates"
    effect    = "Allow"
    actions   = ["acm:ListCertificates", "acm:DescribeCertificate", "acm:GetCertificate"]
    resources = ["*"]
  }

  # -- Shield and WAF: the controller reads their state when the corresponding annotations are
  # set. Read-only.
  statement {
    sid    = "ReadShieldAndWaf"
    effect = "Allow"
    actions = [
      "shield:GetSubscriptionState",
      "shield:DescribeProtection",
      "shield:CreateProtection",
      "shield:DeleteProtection",
      "wafv2:GetWebACL",
      "wafv2:GetWebACLForResource",
      "wafv2:AssociateWebACL",
      "wafv2:DisassociateWebACL",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lb_controller" {
  name        = "${var.project_name}-${var.environment}-lb-controller"
  description = "Permissions for the AWS Load Balancer Controller to manage ALBs for this cluster"
  policy      = data.aws_iam_policy_document.lb_controller.json

  tags = {
    Name = "${var.project_name}-${var.environment}-lb-controller"
  }
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}
