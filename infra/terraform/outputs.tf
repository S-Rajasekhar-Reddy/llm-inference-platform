output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "configure_kubectl" {
  description = "Run this after apply to point kubectl at the cluster."
  value       = "make cloud-kubeconfig  (writes ~/.kube/llm-inference-eks; the k3s kubeconfig is untouched)"
}

output "karpenter_node_role" {
  description = "IAM role for Karpenter-launched nodes (used by platform/eks/karpenter-gpu.yaml)."
  value       = module.karpenter.node_iam_role_name
}

output "weights_bucket" {
  description = "Created by infra/billing."
  value       = "${var.name}-weights-${data.aws_caller_identity.current.account_id}"
}
