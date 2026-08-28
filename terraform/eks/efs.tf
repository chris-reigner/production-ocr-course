# -----------------------------------------------------------------------------
# EFS (RWX model-weights volume) + CSI driver addon — eks_deployment.md §2.1.
# EBS is RWO-only; the ingest Job, vLLM server, and layout worker mount the
# weights simultaneously, so the shared volume must be EFS (ReadWriteMany).
# -----------------------------------------------------------------------------

# NFS ingress must come FROM the EKS-managed cluster security group, which is
# what managed nodes actually attach — not the node role or a custom SG. Using
# the wrong source lets DNS resolve but the mount times out (DeadlineExceeded).
resource "aws_security_group" "efs" {
  name_prefix = "${var.cluster_name}-efs-"
  description = "Allow NFS (2049) from EKS nodes to the model-weights EFS"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "NFS from the EKS cluster security group"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-efs" }
}

resource "aws_efs_file_system" "weights" {
  creation_token   = "${var.cluster_name}-model-weights"
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"
  encrypted        = true

  tags = { Name = "eks-ocr-model-weights" }
}

# File-system policy: require TLS (encryption in transit) for all access.
# `encrypted = true` above only covers data at rest; without this policy a client
# could mount over plaintext NFS. The efs-sc StorageClass sets `mountOptions: [tls]`
# so the CSI-provisioned mounts satisfy the SecureTransport condition.
data "aws_iam_policy_document" "efs_weights" {
  statement {
    sid    = "AllowMountOverTLS"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
      "elasticfilesystem:ClientRootAccess",
    ]
    resources = [aws_efs_file_system.weights.arn]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["true"]
    }
  }

  statement {
    sid    = "DenyNonTLS"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["*"]
    resources = [aws_efs_file_system.weights.arn]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_efs_file_system_policy" "weights" {
  file_system_id = aws_efs_file_system.weights.id
  policy         = data.aws_iam_policy_document.efs_weights.json
}

# A mount target per AZ — a pod on a node in an AZ with no mount target fails to
# start ("No matching mount target in the az ..."). Covers every AZ the node
# groups can land in.
resource "aws_efs_mount_target" "this" {
  count = var.az_count

  file_system_id  = aws_efs_file_system.weights.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

# EFS CSI driver as an EKS-managed addon, bound to the IRSA role from iam.tf.
# depends_on the node groups: the controller has no tolerations and needs the
# untainted systemnp pool to schedule on.
resource "aws_eks_addon" "efs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-efs-csi-driver"
  service_account_role_arn    = aws_iam_role.efs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.efs_csi,
  ]
}
