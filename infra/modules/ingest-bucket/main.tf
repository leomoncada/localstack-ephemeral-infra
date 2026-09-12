resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_18:Access logging needs a separate log-delivery bucket, which is outside this task's interface (an ingest bucket with versioning and public-access-block only); no log-target bucket exists in this repo.
  #checkov:skip=CKV2_AWS_62:Event notifications need a subscriber (SQS/SNS/Lambda) for uploaded objects, which no task has introduced yet; nothing in this repo consumes ingest-bucket events.
  #checkov:skip=CKV_AWS_144:Cross-region replication needs a second bucket in another region; this is a single-region ephemeral LocalStack stack with no replica region configured.
  #checkov:skip=CKV_AWS_145:KMS is out of scope for this repo (not in docker-compose's SERVICES or the provider's endpoints block); the aws_s3_bucket_server_side_encryption_configuration below still applies AES256/SSE-S3 encryption at rest without a customer-managed CMK.
  bucket = "${var.project_name}-uploads"

  # Tests write objects into this bucket; destroy must not be blocked by them.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
