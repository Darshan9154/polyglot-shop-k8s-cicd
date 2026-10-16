# iam.tf - the identity the build server runs as.
#
# Why a role and not copied keys: the plan is explicit that the server gets an
# instance profile. The instance then holds no long-lived AWS credentials at
# all, so a compromise of the instance does not leak a person's access key.

# Why SSM rather than SSH: AWS Systems Manager Session Manager gives an
# audited shell with no inbound port and no key pair to lose or rotate. This
# managed policy is what lets the agent register the instance with SSM.
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid     = "AllowEc2ToAssumeThisRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "build_server" {
  name               = "${var.project_name}-build-server-role"
  description        = "Instance role for the ${var.project_name} build server; SSM shell access and ECR image pushes only."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  # Why force_detach_policies: when this server is torn down for good, the role
  # must be deletable without a manual detach step first.
  force_detach_policies = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Component   = "build-server"
  }
}

# Why this exact policy: it is the AWS-managed policy for Session Manager. It
# grants the agent the channel, command, and message permissions it needs and
# nothing else.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.build_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Why this exact policy: the build server pushes images to Amazon ECR in Step 4
# and needs to fetch an authorisation token, create repositories and layers, and
# upload them. PowerUser is the managed policy scoped to exactly that; the
# read-only variant cannot push, and AdministratorAccess would be far too much.
resource "aws_iam_role_policy_attachment" "ecr_power_user" {
  role       = aws_iam_role.build_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# Why the profile: EC2 instances cannot wear a role directly; the profile is the
# container EC2 attaches when the instance launches.
resource "aws_iam_instance_profile" "build_server" {
  name = "${var.project_name}-build-server-profile"
  role = aws_iam_role.build_server.name

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Component   = "build-server"
  }
}
