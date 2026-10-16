# Outputs — the values needed to talk to the cluster and to the cost report.
#
# Why these are outputs rather than something to look up in the console: the next steps
# (configuring kubectl, applying the charts, checking the hourly cost) all need them, and
# having Terraform print them removes the chance of reading a stale value from the console.

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint for the cluster."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes version the control plane is running."
  value       = aws_eks_cluster.this.version
}

output "cluster_certificate_authority" {
  description = "Base64 certificate authority data for the cluster."
  value       = aws_eks_cluster.this.certificate_authority[0].data
  # Why sensitive: it is not a secret in the sense of granting access, but it is part of the
  # kubeconfig and printing it to the terminal on every apply is noise.
  sensitive = true
}

output "oidc_provider_arn" {
  description = "ARN of the cluster's OIDC provider, used to build IRSA trust policies."
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "node_role_arn" {
  description = "IAM role assumed by the worker nodes."
  value       = aws_iam_role.node.arn
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller, needed as a Helm value."
  value       = aws_iam_role.lb_controller.arn
}

output "vpc_id" {
  description = "VPC the cluster runs in, needed for the load balancer controller's Helm values."
  value       = var.vpc_id
}

output "configure_kubectl_command" {
  description = "Command that writes a kubeconfig context for this cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name} --profile retail-store-dev"
}

output "hourly_cost_estimate" {
  description = "Rough hourly cost of this cluster, so it is visible rather than discovered on a bill."
  # Why this is an output and not just a note in the README: it sits next to the apply
  # output, which is exactly the moment someone decides whether to leave the cluster up.
  value = <<-EOT
    Control plane            : ~$0.10/hr  (fixed, does not scale down)
    ${var.node_desired_size} x worker nodes        : ~$0.042/hr each for t3.small, more for m7i-flex.large
    EBS volumes (node + PVCs): ~$0.08/GB-month
    CloudWatch control logs  : per GB ingested

    Order of magnitude: roughly $0.20/hr while it exists.
    The control plane bills whether or not any workload is running, so a cluster left up
    overnight costs about $2.40 with nothing deployed to it.

    Tear down with: terraform destroy
  EOT
}

# Why a warning rather than a blocker: this output exists so that the cost is in front of the
# person who just ran apply, at the moment they are most likely to act on it.
output "teardown_reminder" {
  description = "What to do when the cluster is no longer needed."
  value       = "Delete the in-cluster LoadBalancers before terraform destroy, or the ELB's security group will block VPC deletion. See the eks README."
}
