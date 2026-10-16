# Input variables for the EKS cluster.
#
# Why every value below has a default: the defaults encode the decisions made for this
# project's constraints, and an override is an explicit, reviewable change rather than an
# undocumented edit to a resource block.

variable "aws_region" {
  description = "AWS region. Stockholm, matching the build server, so ECR pulls stay in-region."
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Name used for the cluster and as the Project tag on every resource."
  type        = string
  default     = "polyglot-shop"
}

variable "environment" {
  description = "Environment name, used in tags and in the cluster name."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Person or team accountable for these resources."
  type        = string
  default     = "devops-agent"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.31"

  # Why 1.31 and not the newest available: 1.31 is a version with mature support in the
  # EKS add-on ecosystem, and the application charts were validated against the 1.31
  # schema. Checking out the newest version would mean validating against a schema that
  # may differ from what the cluster accepts.
}

variable "vpc_id" {
  description = "VPC to place the cluster in. The default VPC is used to avoid NAT gateway cost."
  type        = string
  # Why the default VPC: a purpose-built VPC with private subnets needs a NAT gateway for
  # pod egress to ECR, which costs roughly $32/month plus data processing. That is a third
  # of this project's entire credit allowance, for an isolation benefit that a test cluster
  # with a two-day lifetime does not need. Recorded here rather than left implicit.
  default = "vpc-056f37e655aa540ae"
}

variable "cluster_subnet_ids" {
  description = "Subnets for the EKS control plane. Fixed at cluster creation and cannot be changed later."
  type        = list(string)

  # Why this is a SEPARATE variable from the node group subnets, and why that distinction cost
  # a cluster rebuild to learn:
  #
  # The EKS control plane places network interfaces into the subnets given at creation time.
  # EKS refuses to change that set afterwards:
  #
  #   InvalidParameterException: Provided subnets belong to the AZs 'eu-north-1b,eu-north-1c'.
  #   But they should belong to the exact set of AZs 'eu-north-1b,eu-north-1c,eu-north-1a' in
  #   which subnets were provided during cluster creation.
  #
  # An earlier version of this configuration used one variable for both the cluster and the
  # node group. Narrowing it to two zones to fix a volume-affinity problem therefore tried to
  # modify the control plane, and the whole apply failed — after the node group had already
  # been destroyed, leaving the cluster with no worker nodes at all.
  #
  # The two sets are genuinely independent and must stay that way:
  #   * the control plane needs every zone the cluster was created with
  #   * the node group needs only the zones where its volumes live
  default = [
    "subnet-02e0e3fd0b1d03ff0", # eu-north-1b
    "subnet-0544ab32c6ab6e005", # eu-north-1c
    "subnet-06871eb57c6567d0e", # eu-north-1a
  ]
}

variable "subnet_ids" {
  description = "Subnets for the managed node group only. Independent of the control plane subnets."
  type        = list(string)

  # Why only these two of the three zones: EBS volumes are created in a specific availability
  # zone and cannot be moved. A pod whose claim is bound to a volume in eu-north-1c can only
  # run on a node in eu-north-1c.
  #
  # The first attempt listed all three subnets. Nodes came up in eu-north-1a and eu-north-1b
  # while several volumes lived in eu-north-1c, producing
  #
  #   FailedScheduling: 0/3 nodes are available: 3 node(s) had volume node affinity conflict
  #
  # Restricting the node group to the two zones that hold the volumes removes the conflict,
  # because WaitForFirstConsumer binding places each pod in the zone its volume already
  # occupies, and a node is always present there.
  default = [
    "subnet-02e0e3fd0b1d03ff0", # eu-north-1b — holds the PostgreSQL and DynamoDB volumes
    "subnet-0544ab32c6ab6e005", # eu-north-1c — holds the MariaDB, Redis and RabbitMQ volumes
  ]
}

variable "tag_subnets_for_eks" {
  description = "Add the EKS cluster discovery tags to the subnets used by the node group."
  type        = bool
  # Why this is a variable and not left as a console action: the tags are what let the AWS
  # cloud provider discover which subnets belong to this cluster, for volume topology and for
  # load balancer placement. A cluster that works because someone clicked a tag in the console
  # is a cluster that breaks when a subnet is replaced, so Terraform manages them.
  default = true
}

variable "build_server_instance_id" {
  description = "Instance id of the build server that hosts the CI runner, used to grant it API access."
  type        = string
  # Why this is a variable rather than nothing at all: the build server is managed by a
  # different Terraform stack (infra/terraform/build-server), so this stack cannot reference it
  # as a resource. Naming it here keeps the dependency explicit and reviewable.
  default = "i-06bae5ecefeb6eb90"
}

variable "enable_runner_api_access" {
  description = "Grant the build server's CI runner network and IAM access to the cluster API."
  type        = bool

  # Why this exists as a switch: granting a CI runner cluster access is a deliberate exposure.
  # On a cluster where deployment is done by hand, the rule should not exist at all. Keeping it
  # as a variable means the decision is recorded in configuration rather than implied by whether
  # someone happened to create a security group rule.
  #
  # The consequence of enabling it is documented in runner-access.tf: the runner holds cluster
  # admin, because Helm needs to create and delete arbitrary object types.
  default = true
}

variable "node_instance_types" {
  description = "Instance types for the managed node group. Must match node_ami_type architecture."
  type        = list(string)

  # Why m7i-flex.large and NOT t3.small, which was tried first and failed:
  #
  # t3.small has 2 GiB of RAM, and after the EKS system daemonsets (VPC CNI, kube-proxy,
  # EBS CSI node, CoreDNS) each node reports only about 1.43 GiB allocatable. Deploying the
  # five backing services and the five application services consumed that completely:
  #
  #   Allocated resources:
  #     memory  1308Mi (89%)  3764Mi (257%)
  #
  #   FailedScheduling: 0/2 nodes are available: 2 Insufficient memory.
  #
  # Two pods (orders and ui) could never be scheduled, and the nodes were already at 2.5x
  # their memory in limits. The 89% of requests is the number that blocks scheduling, but the
  # 257% of limits is the more serious figure: with limits that far above capacity, the first
  # memory spike triggers node-level OOM eviction of whichever pods happen to be largest.
  #
  # m7i-flex.large is 2 vCPU and 8 GiB, so roughly 6.9 GiB allocatable per node and about
  # 13.8 GiB across the group. That covers the roughly 3.4 GiB of requests for the
  # application and its dependencies with room for the observability stack (Prometheus alone
  # requests 512Mi and limits at 2Gi).
  #
  # Why both entries are the same type: EKS picks a type from the list per node. Listing a
  # smaller type first would place undersized nodes and reproduce the failure above. The list
  # exists only so a capacity shortage on one type does not fail the apply.
  #
  # Why not t4g (ARM): the application images are single-architecture x86. See node_ami_type.
  #
  # Cost consequence, stated because it is real: t3.small is about $0.021/hour each, while
  # m7i-flex.large is about $0.102/hour each. Two nodes therefore cost roughly $0.20/hour
  # instead of $0.042/hour. With the control plane at roughly $0.10/hour the cluster runs at
  # about $0.30/hour. That is the honest price of running this workload set on EKS.
  default = ["m7i-flex.large"]
}

variable "node_ami_type" {
  description = "AMI type for the node group. AL2_x86_64 for Intel, AL2_ARM_64 for Graviton."
  type        = string
  # Why x86 and not ARM: the application images were built on an x86 build server and
  # pushed as single-architecture images. An ARM node group would fail to pull them with
  # "no matching manifest". Switching to t4g requires first pushing multi-arch images.
  default = "AL2_x86_64"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  # Why 2: this gives the scheduler two failure domains to place pods across and enough
  # total memory for the application, its databases and a trimmed observability stack.
  # One node would leave some pods Pending on memory; three would raise the hourly cost by
  # half for no functional gain at this scale.
  default = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  # Why 2 and not 1: a minimum of 1 lets the cluster scale down to a single node, which
  # cannot hold the workload set. The floor is set where the workload actually fits.
  default = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  # Why 3: a ceiling that the cluster could reach on a busy day without an unbounded cost
  # surprise. Cluster Autoscaler is not installed, so this is a guard rail rather than an
  # active limit.
  default = 3
}

variable "node_disk_size_gb" {
  description = "Root volume size for each worker node, in GiB."
  type        = number
  # Why 30 and not the default 20: container images for this application total roughly
  # 4.7 GB of layers, and each node may hold several. 20 GiB fills up and produces
  # DiskPressure evictions, which look like unrelated pod failures.
  default = 30
}

variable "enable_cluster_logging" {
  description = "Enable EKS control plane logging to CloudWatch."
  type        = bool
  # Why the API server audit log specifically: it is the record of who changed what in the
  # cluster, which is the first thing to consult when something changes unexpectedly.
  default = true
}

variable "log_retention_days" {
  description = "CloudWatch retention for control plane logs."
  type        = number
  # Why 3 days: control plane logs are charged per GB ingested and stored. Three days is
  # enough to investigate a change made during this deployment's lifetime, and it keeps the
  # cost proportional to a cluster that exists for days.
  default = 3
}

variable "endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the Kubernetes API endpoint."
  type        = list(string)
  # Why the current public address is not hardcoded here: the operator's address changes,
  # and a stale value locks everyone out of the cluster with no way back in except the AWS
  # console. See the README for how to narrow this once the cluster is up.
  default = ["0.0.0.0/0"]
}
