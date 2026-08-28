# -----------------------------------------------------------------------------
# Cognito — identity provider the JWT authorizer trusts (eks_deployment.md §6.3).
# The test user + permanent password from the doc is a CREDENTIAL and stays a
# manual post-apply step (see README) — it is deliberately not in Terraform.
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool" "this" {
  name = var.cognito_pool_name
}

resource "aws_cognito_user_pool_client" "this" {
  name         = var.cognito_client_name
  user_pool_id = aws_cognito_user_pool.this.id

  # ALLOW_USER_PASSWORD_AUTH lets `cognito-idp initiate-auth` mint a token from a
  # username/password for testing. Drop it for production and front the pool with
  # a proper OAuth flow.
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}

locals {
  jwt_issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
  jwt_audience = aws_cognito_user_pool_client.this.id
}
