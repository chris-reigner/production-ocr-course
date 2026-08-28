variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster (matches eks_deployment.md)."
  type        = string
  default     = "eks-ocr-cluster"
}

variable "k8s_version" {
  description = "Kubernetes control-plane version."
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR block for the cluster VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across. 3 so the GPU node group can reach eu-central-1c, which has g6e.4xlarge (L40S) capacity when 1a/1b run dry."
  type        = number
  default     = 3
}

variable "ecr_repositories" {
  description = "ECR repositories to create (one per container image)."
  type        = list(string)
  default     = ["ocr-vlm-qwen", "ocr-api-rust", "ocr-worker-rt"]
}

variable "endpoint_public_access" {
  description = "Whether the EKS API server is reachable from the public internet (needed for kubectl from your laptop)."
  type        = bool
  default     = true
}
