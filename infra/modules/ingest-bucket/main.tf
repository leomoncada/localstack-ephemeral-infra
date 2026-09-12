resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_18:Access logging needs a second, separate log-delivery bucket with its own lifecycle and access policy. This module's scope is a single ingest bucket; adding a log target would double the stack's S3 footprint to record accesses that, for an ephemeral stack whose entire backing store is discarded by `make down`, nothing would ever read.
  #checkov:skip=CKV_AWS_144:Cross-region replication protects durable data against the loss of a region. This bucket holds inbound receipts only until the processor has written them to DynamoDB; it is a staging area, not a system of record, and its objects are reproducible by re-upload. Replicating it would need a second bucket, a second region and a replication role to guard data the stack is not the custodian of.
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
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    # One data key per bucket rather than one KMS call per object. The ingest
    # path is many small objects, so this is the difference between a KMS
    # request per upload and effectively none.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    # Required by the real S3 API: a lifecycle rule must carry exactly one of
    # `filter` or `prefix`. An empty filter means "every object", which is the
    # intent here. LocalStack accepts the rule without it; real AWS answers
    # MalformedXML. A no-op locally, load-bearing on the other target.
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
