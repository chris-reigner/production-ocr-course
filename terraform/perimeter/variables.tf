variable "region" {
  description = "AWS region — must match the terraform/eks deployment."
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Used to locate the cluster VPC/SG and to filter the LB-Controller-provisioned NLB by tag."
  type        = string
  default     = "eks-ocr-cluster"
}

# --- Runtime NLB lookup (created by the in-cluster AWS LB Controller, not TF) ---
variable "service_namespace" {
  description = "Namespace of the Kubernetes Service that fronts the Rust API. Half of the kubernetes.io/service-name tag the LB Controller stamps on the NLB."
  type        = string
  default     = "default"
}

variable "service_name" {
  description = "Name of the Kubernetes LoadBalancer Service (k8s/eks/networking/service.yml). Half of the kubernetes.io/service-name tag on the NLB."
  type        = string
  default     = "ocr-api-service"
}

variable "nlb_listener_port" {
  description = "Listener port the internal NLB exposes (the ocr-api-service targetPort maps to 80)."
  type        = number
  default     = 80
}

# --- API Gateway routing ---
variable "public_route_key" {
  description = "Public route clients call."
  type        = string
  default     = "POST /ocr/process"
}

variable "backend_path" {
  description = "Path the Rust API actually serves (client_rt_producer serves POST /process). Rewritten from public_route_key via an overwrite:path parameter mapping."
  type        = string
  default     = "/process"
}

variable "throttling_burst_limit" {
  description = "Stage-level burst throttle — caps request spikes so a flood can't trigger expensive KEDA scale-out on the GPU pools."
  type        = number
  default     = 10
}

variable "throttling_rate_limit" {
  description = "Stage-level steady-state throttle (requests/sec)."
  type        = number
  default     = 5
}

# --- Cognito (identity for the JWT authorizer) ---
variable "cognito_pool_name" {
  description = "Cognito user pool name backing the JWT authorizer."
  type        = string
  default     = "ocr-user-pool"
}

variable "cognito_client_name" {
  description = "Cognito app-client name; its ID is the JWT audience."
  type        = string
  default     = "ocr-api-client"
}

# --- WAF ---
# NOTE: AWS WAF (wafv2) cannot associate with an HTTP API (apigatewayv2). It only
# supports REST APIs, CloudFront, ALB, AppSync, App Runner, and Cognito user pools.
# So this module CREATES the regional Web ACL but only associates it if you give it
# a supported resource ARN (e.g. a CloudFront distribution you put in front of the
# API, or a REST API stage). Left empty, the ACL exists unattached — see README.
variable "enable_waf" {
  description = "Create the regional WAF Web ACL (OWASP managed rules + a rate-based rule)."
  type        = bool
  default     = true
}

variable "waf_rate_limit" {
  description = "Requests per 5-minute window per IP before the WAF rate-based rule blocks."
  type        = number
  default     = 2000
}

variable "waf_association_arn" {
  description = "ARN of a WAF-supported resource to attach the Web ACL to (CloudFront/REST-API-stage/ALB/Cognito). Empty = create the ACL but do not associate (HTTP APIs are not WAF-associable)."
  type        = string
  default     = ""
}
