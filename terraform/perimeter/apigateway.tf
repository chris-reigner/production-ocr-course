# -----------------------------------------------------------------------------
# Amazon API Gateway (HTTP API / apigatewayv2) + private VPC Link
# — eks_deployment.md §6.3. Public edge → VPC Link → internal NLB listener → pods.
# -----------------------------------------------------------------------------

# VPC Link (AWS PrivateLink) into the cluster's private subnets. Reuses the EKS
# cluster SG, which self-permits traffic to the node/pod targets behind the NLB.
resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "ocr-vpc-link"
  subnet_ids         = data.aws_subnets.private.ids
  security_group_ids = [data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
}

resource "aws_apigatewayv2_api" "this" {
  name          = "ocr-http-api"
  protocol_type = "HTTP"
}

# HTTP_PROXY integration to the NLB listener over the VPC Link.
# overwrite:path rewrites the public /ocr/process down to the backend /process
# (the Rust API only serves POST /process — client_rt_producer/src/main.rs).
resource "aws_apigatewayv2_integration" "this" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "POST"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  integration_uri        = data.aws_lb_listener.ocr.arn
  payload_format_version = "1.0"

  request_parameters = {
    "overwrite:path" = var.backend_path
  }
}

# JWT authorizer — validates Cognito Bearer tokens before the VPC Link is reached.
resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.this.id
  name             = "ocr-jwt-authorizer"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = local.jwt_issuer
    audience = [local.jwt_audience]
  }
}

resource "aws_apigatewayv2_route" "this" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = var.public_route_key
  target             = "integrations/${aws_apigatewayv2_integration.this.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

# Auto-deploying $default stage (no path segment in the invoke URL) with
# stage-level throttling — HTTP APIs rate-limit here, not via usage plans.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.throttling_burst_limit
    throttling_rate_limit  = var.throttling_rate_limit
  }
}
