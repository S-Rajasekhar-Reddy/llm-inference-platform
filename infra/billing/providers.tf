provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  tags = {
    owner      = var.owner
    project    = var.project
    managed-by = "terraform"
  }
}
