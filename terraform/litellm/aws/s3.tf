# General-purpose S3 bucket for the proxy. LiteLLM uses S3 for:
#   - Cache backend (cache_params.s3_bucket_name in proxy_config)
#   - Request log archival (S3_REQUEST_LOGS_BUCKET_NAME)
#   - /v1/files endpoint passthrough storage
#
# The bucket name + region are exposed to gateway + backend as S3_BUCKET_NAME
# / S3_REGION_NAME so proxy_config can reference them via
# `os.environ/S3_BUCKET_NAME`. The task role is scoped to this bucket only.

resource "random_id" "s3_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "this" {
  bucket = "${var.name}-${random_id.s3_suffix.hex}"

  # Allow terraform destroy to clear remaining objects. Set to false for
  # production environments where you want a tripwire against accidental
  # data loss.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Task role gains object-level read/write on this bucket. Bucket-level perms
# (list/location) are also scoped to this bucket only.
data "aws_iam_policy_document" "s3_access" {
  statement {
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }
}

resource "aws_iam_policy" "s3_access" {
  name   = "${var.name}-s3-access"
  policy = data.aws_iam_policy_document.s3_access.json
}

resource "aws_iam_role_policy_attachment" "task_s3_access" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.s3_access.arn
}
