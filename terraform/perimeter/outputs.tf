output "api_id" {
  description = "HTTP API ID."
  value       = aws_apigatewayv2_api.this.id
}

output "invoke_url" {
  description = "Public invoke URL for the OCR route (append the route path, e.g. /ocr/process)."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "vpc_link_id" {
  description = "API Gateway VPC Link ID."
  value       = aws_apigatewayv2_vpc_link.this.id
}

output "nlb_listener_arn" {
  description = "Internal NLB listener the API integrates with (resolved by tag, not managed here)."
  value       = data.aws_lb_listener.ocr.arn
}

output "user_pool_id" {
  description = "Cognito user pool ID."
  value       = aws_cognito_user_pool.this.id
}

output "app_client_id" {
  description = "Cognito app-client ID (the JWT audience)."
  value       = aws_cognito_user_pool_client.this.id
}

output "jwt_issuer" {
  description = "JWT issuer URL configured on the authorizer."
  value       = local.jwt_issuer
}

output "jwt_audience" {
  description = "JWT audience (app-client ID) configured on the authorizer."
  value       = local.jwt_audience
}

output "web_acl_arn" {
  description = "Regional WAF Web ACL ARN (null when enable_waf=false). Attach it to a CloudFront/REST/ALB resource via waf_association_arn — HTTP APIs are not WAF-associable."
  value       = try(aws_wafv2_web_acl.this[0].arn, null)
}

# Post-apply reminder: the Cognito test user is a credential, so it's created by
# hand, not by Terraform. Run these once against the outputs above:
#   aws cognito-idp admin-create-user --user-pool-id <user_pool_id> --username api-user --message-action SUPPRESS
#   aws cognito-idp admin-set-user-password --user-pool-id <user_pool_id> --username api-user --password '<pw>' --permanent
