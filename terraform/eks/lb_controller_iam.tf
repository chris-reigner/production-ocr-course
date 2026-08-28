# -----------------------------------------------------------------------------
# AWS Load Balancer Controller IAM — eks_deployment.md §6.1.
#
# This codifies the manual "create policy + IRSA role" steps so Terraform users
# skip them. Same IRSA pattern as the EFS CSI role in iam.tf. What is NOT here:
#   - the controller itself (Helm chart) — installed post-apply like the other
#     add-ons (KEDA, Prometheus, NVIDIA plugin), per repo convention.
#   - the annotated ServiceAccount — created at Helm-install time (the chart is
#     installed with serviceAccount.create=false), annotated with the role ARN
#     from the lb_controller_role_arn output.
# The controller then reconciles the internal NLB from the ocr-api-service
# annotations; that NLB is a Kubernetes-owned object, not a Terraform resource.
# -----------------------------------------------------------------------------

variable "lb_controller_policy_version" {
  description = "aws-load-balancer-controller release tag whose iam_policy.json to attach. Keep in sync with the Helm chart version you install."
  type        = string
  default     = "v3.5.0"
}

# Pull the official policy for the pinned version — single source of truth with
# the manual curl in the doc, so no stale vendored copy drifts out of date.
data "http" "lb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${var.lb_controller_policy_version}/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lb_controller" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  policy = data.http.lb_controller_policy.response_body
}

# IRSA role assumed by the kube-system:aws-load-balancer-controller service account.
data "aws_iam_policy_document" "lb_controller_assume" {
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
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "AmazonEKSLoadBalancerControllerRole-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume.json
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}
