variable "region" {
  description = "AWS region. us-east-1 is where the G/VT vCPU quota was requested."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name for the cluster, VPC and related resources."
  type        = string
  default     = "llm-inference"
}

variable "owner" {
  description = "Value of the owner tag on every resource (who pays and who tears down)."
  type        = string
}

variable "project" {
  description = "Value of the project tag on every resource."
  type        = string
  default     = "llm-inference-platform"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. `make cloud-preflight` fails if it is in extended support (control plane $0.60/hr instead of $0.10)."
  type        = string
  default     = "1.34"
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Set to your own IP (x.x.x.x/32)."
  type        = list(string)
}

variable "system_instance_type" {
  description = "Instance type for the small managed node group that runs Karpenter, KEDA, CoreDNS and monitoring."
  type        = string
  default     = "t3.large"
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version (OCI, public.ecr.aws/karpenter)."
  type        = string
  default     = "1.15.2"
}

variable "vllm_namespace" {
  description = "Namespace of the vLLM release (Pod Identity association for the weights bucket)."
  type        = string
  default     = "default"
}

variable "vllm_service_account" {
  description = "Service account of the vLLM pod; must match serviceAccount.name in charts/vllm/values-cloud.yaml."
  type        = string
  default     = "vllm"
}
