# -----------------------------------------------------------------------------
# Managed node groups — eks_deployment.md §1.5. Five pools:
#   systemnp  (untainted) hosts cluster add-ons: EFS CSI, CoreDNS, KEDA,
#             kube-prometheus-stack, AWS LB Controller.
#   gpunpa100 L40S (g6e.4xlarge) for vLLM inference — GPU AMI + GPU taint.
#   gpunpt4   T4 (g4dn.4xlarge) for the layout worker — GPU AMI + GPU taint.
#   redisnp   r6i.xlarge Redis state store.
#   apinp     m6i.large Rust producer API.
#
# diskSize is immutable on a managed node group; the GPU pools use 100 GB so the
# multi-GB CUDA images unpack without triggering DiskPressure eviction.
# -----------------------------------------------------------------------------

locals {
  # g6e.4xlarge (L40S) capacity swings between AZs hour to hour: 1b was dry / 1a had
  # capacity on 2026-08-26, then reversed on 2026-08-27. Pinning a single AZ makes
  # node group creation retry-loop on InsufficientInstanceCapacity until timeout
  # whenever that one AZ is dry, so gpunpa100 spans both eks-ocr-cluster private
  # subnets (1a + 1b) like the other groups — the ASG places the node in whichever
  # AZ has capacity. Safe because model weights live on EFS (regional, multi-AZ),
  # not a single-AZ EBS PVC. If both AZs are chronically dry, add a fallback
  # instance type (e.g. g6e.2xlarge) rather than re-pinning an AZ.

  node_groups = {
    systemnp = {
      instance_types = ["m6i.large"]
      ami_type       = "AL2023_x86_64_STANDARD"
      disk_size      = 20
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      labels         = {}
      taints         = {}
    }

    gpunpa100 = {
      instance_types = ["g6e.4xlarge", "g6e.8xlarge", "g6e.16xlarge"]
      ami_type       = "AL2023_x86_64_NVIDIA"
      disk_size      = 100
      min_size       = 0
      max_size       = 2
      desired_size   = 1
      labels         = {}
      taints = {
        gpu = { key = "nvidia.com/gpu", value = "present", effect = "NO_SCHEDULE" }
      }
    }

    gpunpt4 = {
      instance_types = ["g4dn.4xlarge"]
      ami_type       = "AL2023_x86_64_NVIDIA"
      disk_size      = 100
      min_size       = 0
      max_size       = 4
      desired_size   = 1
      labels         = {}
      taints = {
        gpu = { key = "nvidia.com/gpu", value = "present", effect = "NO_SCHEDULE" }
      }
    }

    redisnp = {
      instance_types = ["r6i.xlarge"]
      ami_type       = "AL2023_x86_64_STANDARD"
      disk_size      = 20
      min_size       = 1
      max_size       = 3
      desired_size   = 1
      labels         = { app = "redis-store" }
      taints = {
        sku = { key = "sku", value = "redis", effect = "NO_SCHEDULE" }
      }
    }

    apinp = {
      instance_types = ["m6i.large"]
      ami_type       = "AL2023_x86_64_STANDARD"
      disk_size      = 20
      min_size       = 1
      max_size       = 5
      desired_size   = 1
      labels         = { app = "api-gateway" }
      taints = {
        sku = { key = "sku", value = "api", effect = "NO_SCHEDULE" }
      }
    }
  }
}

# Launch template per node group. metadata_options and encrypted root volumes
# can't be set directly on aws_eks_node_group, so they live here:
#   - IMDSv2 required + hop limit 1 → a compromised pod on the pod network can't
#     reach 169.254.169.254 to steal the node role's credentials. (The AWS LB
#     Controller already relies on this — eks_deployment.md §6 passes region/vpcId
#     explicitly because pods can't read IMDS.)
#   - root EBS encrypted at rest, independent of the account-level default.
# No image_id is set, so EKS still selects the correct AMI for each ami_type.
resource "aws_launch_template" "node" {
  for_each = local.node_groups

  name_prefix = "${var.cluster_name}-${each.key}-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda" # AL2023 EKS AMI root device
    ebs {
      volume_size = each.value.disk_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-${each.key}" }
  }
}

resource "aws_eks_node_group" "this" {
  for_each = local.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  # All groups span both private subnets so the ASG can place nodes in whichever
  # AZ has capacity (see the g6e.4xlarge capacity note on local.node_groups).
  subnet_ids     = aws_subnet.private[*].id
  instance_types = each.value.instance_types
  ami_type       = each.value.ami_type
  labels         = each.value.labels

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  scaling_config {
    min_size     = each.value.min_size
    max_size     = each.value.max_size
    desired_size = each.value.desired_size
  }

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  lifecycle {
    # KEDA / the scale-to-zero lifecycle drive desired_size at runtime; don't let
    # Terraform revert it on the next apply.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}
