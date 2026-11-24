data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.ecr_public
}

locals {
  vpc_cidr = "10.0.0.0/16"

  # Three AZs: g6 capacity is not in every us-east-1 zone, so Karpenter gets a choice.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Created by infra/billing (applied first, kept after this stack is destroyed). Built from the
  # name, not looked up, so `terraform plan` works before infra/billing is applied.
  weights_read_policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.name}-weights-read"

  tags = {
    owner      = var.owner
    project    = var.project
    managed-by = "terraform"
  }
}

################################################################################
# Network: private subnets for nodes, public for load balancers, intra for the
# control plane ENIs. One NAT gateway, not one per AZ, to keep a short run cheap.
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.8"

  name = var.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.name
  }

  tags = local.tags
}

# Free gateway endpoint: weights come from S3 without passing through the NAT gateway,
# which charges per GB processed.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}

################################################################################
# EKS: a small managed node group for system pods; GPU nodes come from Karpenter.
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.30"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  eks_managed_node_groups = {
    system = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = [var.system_instance_type]

      min_size     = 1
      max_size     = 2
      desired_size = 2

      labels = {
        "karpenter.sh/controller" = "true"
      }
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.name
  }

  # Also passed explicitly (not only via default_tags) so the system nodes' launch template
  # tags the instances and volumes it starts; the project budget counts costs by this tag.
  tags = local.tags
}

################################################################################
# Karpenter: IAM, interruption queue and the controller. The GPU NodePool and
# EC2NodeClass are Kubernetes objects in platform/eks/karpenter-gpu.yaml.
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.30"

  cluster_name = module.eks.cluster_name

  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = "${var.name}-karpenter-node"
  create_pod_identity_association = true

  # The weights bucket is read by the vLLM pod via Pod Identity (pod-identity.tf), not the node role.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

resource "helm_release" "karpenter" {
  namespace           = "kube-system"
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = var.karpenter_version
  wait                = false

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: 'true'
    dnsPolicy: Default
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    webhook:
      enabled: false
    EOT
  ]
}
