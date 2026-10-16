# versions.tf - pin the tools that provision this server.
#
# Why pin: Terraform and the AWS provider both change behaviour between major
# versions. Without a constraint, an upgrade on any machine could silently
# change what this configuration plans and applies.

terraform {
  # Why this floor: the configuration uses syntax that is stable in Terraform
  # 1.5 and newer. Anything older is refused instead of guessed at.
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      # Why 6.x: a major-version boundary, so a new AWS provider release cannot
      # change this plan's behaviour mid-project. Patch and minor upgrades stay
      # allowed on purpose, so security fixes arrive without an edit here.
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  # Why explicit: the whole project lives in one region. Being explicit here
  # stops a stray AWS_DEFAULT_REGION on a machine from moving the build server
  # somewhere unexpected.
  region = var.aws_region
}
