terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
  }

  # Separate local state from infra/terraform on purpose: this stack outlives the cluster.
}
