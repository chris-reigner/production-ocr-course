output "region" {
  description = "AWS region."
  value       = var.region
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group (attached to nodes)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN (for IRSA — e.g. the AWS LB Controller role)."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN to annotate onto the kube-system:aws-load-balancer-controller ServiceAccount (§6.1)."
  value       = aws_iam_role.lb_controller.arn
}

output "vpc_id" {
  description = "Cluster VPC ID."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (node groups, EFS mount targets, VPC Link)."
  value       = aws_subnet.private[*].id
}

output "efs_id" {
  description = "EFS filesystem ID — substitute into k8s/eks/infra/efs-storageclass.yaml."
  value       = aws_efs_file_system.weights.id
}

output "ecr_registry" {
  description = "ECR registry host for docker login / image tags."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  description = "Full ECR repository URLs."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "update_kubeconfig_command" {
  description = "Run this to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name}"
}

output "apply_storageclass_command" {
  description = "Inject the EFS ID into the StorageClass and apply it (post-apply manual step)."
  value       = "sed 's|<EFS_FILE_SYSTEM_ID>|${aws_efs_file_system.weights.id}|' k8s/eks/infra/efs-storageclass.yaml | kubectl apply -f -"
}
