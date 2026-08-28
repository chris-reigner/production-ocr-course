# -----------------------------------------------------------------------------
# AWS WAF (wafv2) — eks_deployment.md §6 defense-in-depth.
#
# ⚠️ HTTP APIs (apigatewayv2) CANNOT be associated with a WAF Web ACL. WAFv2
# only supports CloudFront, ALB, REST APIs (apigateway v1), AppSync, App Runner,
# and Cognito user pools. This module therefore CREATES the regional Web ACL
# (reusable, no-op until attached) and only associates it when you pass
# var.waf_association_arn a supported resource — e.g. a CloudFront distribution
# fronting this HTTP API, or a REST API stage. See README for the two options.
# -----------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0

  name  = "ocr-web-acl"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # OWASP Top-10 baseline (SQLi, XSS, bad inputs, etc.).
  rule {
    name     = "aws-common-rule-set"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ocr-common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  # Per-IP rate limit — a second brake (alongside stage throttling) against
  # bursts that would drive KEDA scale-out on the GPU pools.
  rule {
    name     = "ip-rate-limit"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ocr-ip-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "ocr-web-acl"
    sampled_requests_enabled   = true
  }
}

# Only attach when given a WAF-supported resource ARN (NOT the HTTP API).
resource "aws_wafv2_web_acl_association" "this" {
  count = var.enable_waf && var.waf_association_arn != "" ? 1 : 0

  resource_arn = var.waf_association_arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}
