output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "configure_kubectl" {
  description = "Run this after apply to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "karpenter_node_role" {
  description = "IAM role for Karpenter-launched nodes (used by platform/eks/karpenter-gpu.yaml)."
  value       = module.karpenter.node_iam_role_name
}

output "weights_bucket" {
  value = aws_s3_bucket.weights.bucket
}
