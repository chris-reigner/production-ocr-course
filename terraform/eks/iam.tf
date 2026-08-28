# -----------------------------------------------------------------------------
# IAM — eks_deployment.md §1.1 (cluster + node roles) and §2.1 (EFS CSI IRSA).
# -----------------------------------------------------------------------------

# 1. Cluster role — assumed by the EKS control plane.
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "eksOcrClusterRole"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# 2. Node role — assumed by all managed node groups.
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "eksOcrNodeRole"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# efs-utils falls back to elasticfilesystem:DescribeMountTargets when the regional
# DNS name can't be resolved (see eks_deployment.md §1.1). That is the ONLY EFS
# permission the node role needs — the AWS-managed AmazonElasticFileSystemClientReadWriteAccess
# policy also grants ClientMount/ClientWrite/ClientRootAccess to every node, which
# is broader than required. Actual mount I/O is authorized by the EFS CSI driver's
# IRSA role, not the node role.
data "aws_iam_policy_document" "node_efs_describe" {
  statement {
    effect    = "Allow"
    actions   = ["elasticfilesystem:DescribeMountTargets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "node_efs_describe" {
  name   = "efs-describe-mount-targets"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node_efs_describe.json
}

# 3. EFS CSI driver IRSA role — assumed by the efs-csi-controller-sa service
#    account via the cluster OIDC provider (eks_deployment.md §2.1). Distinct
#    from the cluster role: a pod cannot assume the service-trusted role.
locals {
  oidc_provider = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}

data "aws_iam_policy_document" "efs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:efs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "efs_csi" {
  name               = "eksOcrEfsCsiRole"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}
