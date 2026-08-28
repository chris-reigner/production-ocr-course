provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "production-ocr-course"
      Cluster   = var.cluster_name
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}
