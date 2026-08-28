provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "production-ocr-course"
      Cluster   = var.cluster_name
      ManagedBy = "terraform"
      Layer     = "perimeter"
    }
  }
}

data "aws_caller_identity" "current" {}
