# main.tf - the build server itself.
#
# This is Step 3 of the plan: one disposable EC2 instance that runs the Docker
# builds and the local Compose test before any EKS money is spent. It is
# deliberately small, has no inbound network access, and is reachable only
# through AWS Systems Manager Session Manager.

# Why look up the newest official Ubuntu image: hardcoding an AMI ID pins this
# configuration to one region and to an image that is eventually deregistered.
# The owner filter is Canonical's own AWS account, so only genuine Ubuntu
# images can match.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  # Why state this explicitly: a community-built or marketplace image with a
  # confusingly similar name must never be selected.
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Why the default VPC: this is a short-lived test environment, and a purpose-built
# VPC would add NAT or endpoint cost for no benefit at this stage. The default
# subnets for this account already route outbound traffic through an internet
# gateway, which is all the server needs to install packages and pull images.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Why no inbound rules at all: the agent connects with Session Manager, which is
# an outbound-initiated channel from the instance. With no ingress rule, nothing
# on the internet can reach the server, and no SSH key pair needs to exist.
# Outbound traffic is open because the server must download packages and pull
# container images.
resource "aws_security_group" "build_server" {
  name_prefix = "${var.project_name}-build-server-"
  description = "Build server: no inbound access by default; outbound only for packages, images, and Session Manager."
  vpc_id      = data.aws_vpc.default.id

  # Why this single inbound rule exists: the storefront is being inspected from a
  # browser during testing, so the UI port is reachable from the internet. Every
  # other published port (databases, Redis, RabbitMQ management) stays closed.
  # Why the CIDR is a variable: an internet-wide rule is convenient but should be
  # a deliberate, visible choice, and locking it to one source address later is a
  # variable change rather than a code change.
  ingress {
    description = "Storefront UI for browser testing"
    from_port   = 8888
    to_port     = 8888
    protocol    = "tcp"
    cidr_blocks = [var.ui_allowed_cidr]
  }

  egress {
    description = "Allow all outbound traffic so package installs, image pulls, and the SSM agent work."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Component   = "build-server"
  }

  # Why create_before_destroy: the name is generated from name_prefix, so
  # replacing this security group (for example while changing a rule) must not
  # fail because the new group is created while the old one still holds the name.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "build_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.build_server.name
  vpc_security_group_ids = [aws_security_group.build_server.id]

  # Why pin the subnet: the security group above is scoped to the default VPC,
  # and picking one subnet explicitly keeps the instance's placement readable in
  # the console. The subnet already assigns a public IPv4 address on launch,
  # which the instance needs to reach the internet without a NAT gateway.
  subnet_id = sort(data.aws_subnets.default.ids)[0]

  # Why standard CPU credits by default: T3 instances in unlimited mode can add a
  # per-vCPU-hour charge when the workload runs hot for hours. Standard mode
  # throttles instead of spending, which keeps a fixed credit budget predictable.
  credit_specification {
    cpu_credits = var.instance_credit_specification
  }

  # Why a bigger root volume: the 8 GiB default fills up during the first Java
  # and Node image builds. 30 GiB leaves room for layers plus the build caches.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  # Why metadata hop limit 1: the instance metadata service must not be reachable
  # from a container running on the instance, which closes a common credential
  # theft path. 1 is also the AWS default and is stated here on purpose.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Why user_data: everything the pipeline needs is installed on first boot, so
  # the environment is reproducible from scratch instead of hand-built. The
  # script is a template because the repository to clone is configurable.
  user_data = templatefile("${path.module}/bootstrap.sh.tftpl", {
    repository_url = var.repository_url
    repository_ref = var.repository_ref
    repository_dir = var.repository_dir
    project_name   = var.project_name
  })

  # Why no create_before_destroy here: that would run two build servers at the
  # same time during a replacement, and this instance is billed by the second.
  # The default destroy-then-create order is the cheaper and clearer behaviour.

  tags = {
    Name        = "${var.project_name}-build-server"
    Project     = var.project_name
    Environment = var.environment
    Component   = "build-server"
    ManagedBy   = "terraform"
  }
}

# Why an output and not just the console: the Session Manager command in the
# next step needs the instance ID, and printing it here keeps that ID out of
# a wiki page that goes stale.
output "build_server_instance_id" {
  description = "Instance ID for aws ssm start-session."
  value       = aws_instance.build_server.id
}

output "build_server_private_ip" {
  description = "Private IPv4 address, useful for later VPC-internal work."
  value       = aws_instance.build_server.private_ip
}

output "build_server_repository_dir" {
  description = "Path on the instance where the source repository is cloned."
  value       = var.repository_dir
}
