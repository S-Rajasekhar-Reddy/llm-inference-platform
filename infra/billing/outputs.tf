output "weights_bucket" {
  value = aws_s3_bucket.weights.bucket
}

output "weights_read_policy_arn" {
  value = aws_iam_policy.weights_read.arn
}

output "budget_name" {
  value = aws_budgets_budget.run.name
}

output "upload_weights" {
  description = "Upload the model from the local Hugging Face cache before the run (S3 upload is free; storage is cents)."
  value       = "aws s3 sync ~/.cache/huggingface/hub/models--Qwen--Qwen3-8B-FP8 s3://${aws_s3_bucket.weights.bucket}/hub/models--Qwen--Qwen3-8B-FP8"
}
