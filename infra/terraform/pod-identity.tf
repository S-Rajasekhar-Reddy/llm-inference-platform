# The vLLM pod reads the weights bucket through EKS Pod Identity: only the "vllm" service account
# in the default namespace gets the read policy, instead of every pod on the GPU node (node role).
resource "aws_iam_role" "vllm_weights" {
  name = "${var.name}-vllm-weights"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "vllm_weights" {
  role       = aws_iam_role.vllm_weights.name
  policy_arn = local.weights_read_policy_arn
}

resource "aws_eks_pod_identity_association" "vllm_weights" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.vllm_namespace
  service_account = var.vllm_service_account
  role_arn        = aws_iam_role.vllm_weights.arn
}
