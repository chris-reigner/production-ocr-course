# -----------------------------------------------------------------------------
# EKS control plane + OIDC provider — eks_deployment.md §1.3 and §1.4.
# -----------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.k8s_version

  vpc_config {
    # The control-plane AZ set is IMMUTABLE after creation — EKS rejects adding a
    # subnet in a new AZ (UpdateClusterConfig InvalidParameterException). The cluster
    # was created across the first 2 AZs, so pin its subnets to those (indices 0-1).
    # Node groups (nodegroups.tf) are NOT bound to this set — they use all private
    # subnets incl. the 1c subnet added via az_count=3 to chase g6e.4xlarge capacity.
    subnet_ids = concat(
      slice(aws_subnet.private[*].id, 0, 2),
      slice(aws_subnet.public[*].id, 0, 2),
    )
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = true
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
    # Grants the applying IAM principal cluster-admin so `kubectl` works after apply.
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Ensure the policy is attached before the control plane is created.
  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# OIDC provider — enables IRSA (used by the EFS CSI role above and, later, the
# manually-installed AWS Load Balancer Controller).
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}
