# Model weights for the cloud run (design decision D9): synced to the GPU node's disk
# so cold start measures loading, not a Hugging Face download. In this stack so the weights
# can be uploaded before the run, and so a tagged resource shows up in billing early enough
# to activate the project cost allocation tag.
resource "aws_s3_bucket" "weights" {
  bucket        = "${var.name}-weights-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # the bucket only holds re-downloadable public weights
}

resource "aws_s3_bucket_public_access_block" "weights" {
  bucket                  = aws_s3_bucket.weights.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "weights" {
  bucket = aws_s3_bucket.weights.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_iam_policy" "weights_read" {
  name        = "${var.name}-weights-read"
  description = "Read-only access to the model weights bucket"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.weights.arn, "${aws_s3_bucket.weights.arn}/*"]
      }
    ]
  })
}
