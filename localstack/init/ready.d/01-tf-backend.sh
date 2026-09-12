#!/usr/bin/env bash
# Runs inside the LocalStack container once the runtime is ready.
# Creates the Terraform state backend so `terraform init` succeeds against a
# cold container with no manual bootstrap step.
#
# Task 1 proved `use_lockfile = true` works against LocalStack Community
# (concurrent apply produced a 412 PreconditionFailed), so this backend needs
# only an S3 bucket. No DynamoDB lock table.
set -euo pipefail

awslocal s3api create-bucket --bucket tfstate
awslocal s3api put-bucket-versioning \
  --bucket tfstate \
  --versioning-configuration Status=Enabled

echo "terraform state backend ready"
