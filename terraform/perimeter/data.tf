# -----------------------------------------------------------------------------
# Decoupling layer — eks_deployment.md §6.
#
# This module holds NO reference to terraform/eks's state. Everything it needs is
# resolved live from AWS by cluster name and by the tags the cluster + the AWS LB
# Controller stamp on their resources. The two Terraform roots are linked only by
# "these tagged resources exist", never by a shared backend.
#
# Ordering this implies (see README): terraform/eks apply  →  kubectl apply the
# Service (LB Controller provisions the NLB)  →  terraform apply HERE. Destroy in
# reverse: this module first, while the NLB still exists (a destroy plan re-reads
# these data sources, so a missing NLB would error).
# -----------------------------------------------------------------------------

# Cluster VPC + the EKS-managed cluster security group. Canonical, state-free
# lookup by name — gives us the VPC and an SG that already self-permits traffic
# to the node/pod targets, which is what the VPC Link ENIs need.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

# Private subnets for the VPC Link — filtered by the internal-elb role tag the
# eks module puts on them (terraform/eks/vpc.tf), scoped to the cluster VPC.
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_eks_cluster.this.vpc_config[0].vpc_id]
  }

  tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# The internal NLB — NOT created by any Terraform. The in-cluster AWS LB
# Controller provisions it from k8s/eks/networking/service.yml and tags it with
# the Service identity + cluster. We match on both so we never grab a stray LB.
# The Service-identity tag is `service.k8s.aws/stack` (what the LB Controller
# stamps) — NOT `kubernetes.io/service-name` (the legacy in-tree cloud provider).
data "aws_lb" "ocr" {
  tags = {
    "service.k8s.aws/stack" = "${var.service_namespace}/${var.service_name}"
    "elbv2.k8s.aws/cluster" = var.cluster_name
  }
}

# The NLB listener whose ARN becomes the API Gateway integration URI.
data "aws_lb_listener" "ocr" {
  load_balancer_arn = data.aws_lb.ocr.arn
  port              = var.nlb_listener_port
}
