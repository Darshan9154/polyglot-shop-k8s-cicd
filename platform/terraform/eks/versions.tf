# Terraform and provider version constraints.
#
# Why pin the provider to a major version: the AWS provider makes breaking changes between
# major versions, and an unpinned provider means a `terraform init` months from now can
# produce a plan that differs from the one that was reviewed.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Why no remote backend: this is a single-operator test deployment. A remote backend
  # (S3 plus DynamoDB for locking) is the right answer for a team, and it would add an S3
  # bucket and a DynamoDB table to a project running on a fixed credit budget. State is
  # local and gitignored. Moving to a remote backend is a one-block change here.
}

provider "aws" {
  region = var.aws_region

  # Why default tags: every resource this stack creates is attributable. When the cluster
  # is forgotten and billing starts climbing, the tags are what make the cost visible.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
      # Why an explicit cost tag: EKS costs money continuously, unlike the stopped build
      # server. This tag is what a cost report filters on to find it.
      CostCenter = "retail-store-devops-agent"
    }
  }
}
