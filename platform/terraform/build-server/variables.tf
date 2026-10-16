# variables.tf - the knobs a person can turn without editing main.tf.
#
# Every value below has a default that matches the project plan, so a plain
# `terraform apply` reproduces the documented build server. Defaults are
# deliberately conservative on cost and on exposure.

variable "aws_region" {
  description = "AWS region for every resource in this stack."
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Short name used to tag and prefix resources, so the bill and the console stay readable."
  type        = string
  default     = "retail-store"
}

variable "environment" {
  description = "Environment tag. This stack is the disposable development/staging build server."
  type        = string
  default     = "dev"
}

variable "instance_type" {
  description = "EC2 instance type for the build server. m7i-flex.large is 2 vCPU / 8 GiB and free-tier eligible on accounts created on or after 2025-07-15. t3.medium is rejected by this account with InvalidParameterCombination because it is not a free-tier-eligible type; t3.small throttles at its 20% CPU baseline, which stalls multi-language image builds."
  type        = string
  default     = "m7i-flex.large"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB. 60 GiB leaves room for Docker layers, build caches, and the language toolchains without a mid-build disk-full failure."
  type        = number
  default     = 60

  # Why a floor: Docker images plus Maven/Go/Node build caches do not fit in a
  # tiny volume, and a full disk mid-build wastes far more money than the disk.
  validation {
    condition     = var.root_volume_size_gb >= 20
    error_message = "root_volume_size_gb must be at least 20 GiB so Docker builds do not fill the disk."
  }
}

variable "ui_allowed_cidr" {
  description = "Source address range allowed to reach the storefront UI on port 8888. The default is open to the internet so the app can be opened in a browser during testing; narrow this to a single address for a less exposed setup. Database, Redis, and RabbitMQ ports are never opened."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.ui_allowed_cidr, 0))
    error_message = "ui_allowed_cidr must be a valid CIDR block, for example 203.0.113.7/32."
  }
}

variable "instance_credit_specification" {
  description = "CPU credit mode. standard caps CPU-credit spend at the cost of throttling; unlimited allows sustained bursting for an extra per-vCPU-hour charge."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "unlimited"], var.instance_credit_specification)
    error_message = "instance_credit_specification must be either standard or unlimited."
  }
}

variable "repository_url" {
  description = "Public Git repository cloned onto the build server for the pipeline."
  type        = string
  default     = "https://github.com/aws-containers/retail-store-sample-app.git"
}

variable "repository_ref" {
  description = "Optional branch, tag, or commit to check out after cloning. Empty string keeps the repository default branch."
  type        = string
  default     = ""

  # Why a validation on a commit-ish: shell metacharacters here would be
  # interpreted by the bootstrap script on the instance, so only a safe
  # commit-ish alphabet is accepted.
  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]*$", var.repository_ref))
    error_message = "repository_ref may only contain letters, digits, dot, underscore, slash, and hyphen."
  }
}

variable "repository_dir" {
  description = "Absolute path on the instance where the repository is cloned."
  type        = string
  default     = "/opt/retail-store/source/retail-store-sample-app"

  # Why no trailing slash and an absolute path: the bootstrap script uses this
  # value directly in shell, so a relative or trailing-slash path would put the
  # clone somewhere other than the script expects.
  validation {
    condition     = can(regex("^/[A-Za-z0-9._/-]+$", var.repository_dir))
    error_message = "repository_dir must be an absolute path using letters, digits, dot, underscore, slash, and hyphen."
  }
}
