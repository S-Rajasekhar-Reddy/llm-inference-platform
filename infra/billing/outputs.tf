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
  description = "Upload one snapshot folder (plain files; syncing the whole HF cache folder would upload every file twice via its symlinks)."
  value       = "aws s3 sync \"$(ls -d ~/.cache/huggingface/hub/models--Qwen--Qwen3-8B-FP8/snapshots/*/ | head -1)\" s3://${aws_s3_bucket.weights.bucket}/models/Qwen3-8B-FP8/"
}

output "account_backstop_budget" {
  value = one(aws_budgets_budget.account_backstop[*].name)
}
