provider "aws" {
  region = var.region

  # Every taggable resource carries owner and project, so the cost of the run can be
  # found (and charged back) by tag, and nothing is left behind unnoticed.
  default_tags {
    tags = local.tags
  }
}

# Karpenter's chart lives in ECR Public, which only issues tokens in us-east-1.
provider "aws" {
  alias  = "ecr_public"
  region = "us-east-1"
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
