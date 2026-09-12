#!/usr/bin/env bash
# Runs inside the LocalStack container once the runtime is ready.
# Creates the Terraform state backend so `terraform init` succeeds against a
# cold container with no manual bootstrap step.
#
# Verified against LocalStack Community: `use_lockfile = true` provides real
# mutual exclusion (a concurrent apply is rejected with 412 PreconditionFailed),
# so this backend needs only an S3 bucket. No DynamoDB lock table.
set -euo pipefail

# Idempotent: create-bucket answers BucketAlreadyOwnedByYou on a second run,
# which `set -e` would turn into a failed hook. The container's healthcheck
# polls for this bucket, so a hook that aborts here never reports ready.
if ! awslocal s3api head-bucket --bucket tfstate >/dev/null 2>&1; then
  awslocal s3api create-bucket --bucket tfstate
fi

awslocal s3api put-bucket-versioning \
  --bucket tfstate \
  --versioning-configuration Status=Enabled

echo "terraform state backend ready"
