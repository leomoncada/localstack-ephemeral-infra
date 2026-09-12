# LocalStack Parity Notes

Divergences found while building this repository, against LocalStack Community.
Format: expected / observed / worked around.

## Endpoint targeting

**Chosen mechanism:** variant B — the spec's empty-string endpoint pattern
(`endpoints { s3 = var.aws_endpoint_url ... }` with `s3_use_path_style`,
`skip_credentials_validation`, `skip_metadata_api_check`, and
`skip_requesting_account_id` all gated on `var.aws_endpoint_url != ""`).
Variant A (pure `AWS_ENDPOINT_URL` env var, no provider-level endpoint
configuration) was tried first per the spike's priority order but failed.

**Expected:** variant A — setting `AWS_ENDPOINT_URL=http://localhost:4566`
plus dummy credentials, with zero endpoint configuration in the provider
block — would let `terraform apply` transparently target LocalStack.

**Observed:** `terraform init` and `terraform plan` succeeded, but
`terraform apply` hung indefinitely on `aws_s3_bucket.probe: Still
creating...` past 4 minutes with no error and no bucket ever appearing in
LocalStack (`awslocal s3api list-buckets` stayed empty the whole time). The
global `AWS_ENDPOINT_URL` env var was not honored by the AWS provider
v6.64.0 for the S3 create-bucket call in this setup, so the request went to
real AWS instead, where it stalled rather than failing fast on the fake
`test`/`test` credentials. The process was killed manually after the
timebox made it clear this was not going to resolve.

**Workaround:** switched to variant B — explicit `endpoints { s3 = ...
sts = ... iam = ... }` in the provider block, gated by an
`aws_endpoint_url` variable defaulting to `""`. With
`-var aws_endpoint_url=http://localhost:4566`, `terraform apply` completed
in 0s and the bucket was confirmed to exist *inside the LocalStack
container* via `docker compose exec -T localstack awslocal s3api
list-buckets`. The fallback direction was also verified: `terraform plan`
with the default empty-string endpoint failed with
`Error: Retrieving AWS account details: ... GetCallerIdentity ... 403
InvalidClientTokenId: The security token included in the request is
invalid` — a genuine credentials error against real AWS's STS endpoint, not
an endpoint-parsing error. This confirms the empty-string fallback correctly
routes to real AWS when no LocalStack endpoint is supplied.

**Later tasks must use:** the variant B provider block, with a variable
(e.g. `aws_endpoint_url`, default `""`) feeding `endpoints { s3 = ...
sts = ... iam = ... lambda = ... dynamodb = ... }`, and
`s3_use_path_style` / `skip_credentials_validation` /
`skip_metadata_api_check` / `skip_requesting_account_id` all set to
`var.aws_endpoint_url != ""`. LocalStack is selected by passing
`-var aws_endpoint_url=http://localhost:4566` (or a `.tfvars` file); real
AWS is selected by leaving the variable at its default `""`. No
`AWS_ENDPOINT_URL` env var is required or relied upon.

## Terraform state locking

**Expected:** `use_lockfile = true` (Terraform 1.14 deprecates
`dynamodb_table`).

**Observed:** `use_lockfile = true` works against LocalStack Community.
After creating the `tfstate-probe` bucket via `awslocal s3api
create-bucket`, configuring the S3 backend with `use_lockfile = true` plus
LocalStack-pointing `endpoints = { s3 = "http://localhost:4566" }`,
`access_key`/`secret_key` = `test`, and the standard `skip_*`/
`use_path_style` flags, `terraform init -reconfigure -backend-config=
backend.hcl` and `terraform apply` both succeeded and wrote
`probe/terraform.tfstate` into the bucket. To confirm the lock is real
(not a no-op), two `terraform apply` runs were launched concurrently
against the same state: the second one failed immediately with
`operation error S3: PutObject ... StatusCode: 412 ... PreconditionFailed:
At least one of the pre-conditions you specified did not hold`, along with
a printed `Lock Info` block (lock ID, path, operation, holder, timestamp).
This is exactly S3's conditional-write locking mechanism rejecting a
second writer, proving `use_lockfile` provides working mutual exclusion
against LocalStack Community. No DynamoDB lock table was needed.

**Workaround:** none needed. `use_lockfile = true` in the S3 backend block
is sufficient; the backend block must additionally carry the LocalStack
`endpoints`, dummy `access_key`/`secret_key`, and the `skip_*` /
`use_path_style` flags (mirroring the provider block) since the backend's
AWS client configuration is independent of the provider's.

**Later tasks must use in the backend config:**
```hcl
bucket                      = "<state-bucket>"
key                         = "<state-key>"
region                      = "us-east-1"
use_lockfile                = true
access_key                  = "test"      # LocalStack only; real AWS uses normal credential chain
secret_key                  = "test"      # LocalStack only
skip_credentials_validation = true        # LocalStack only
skip_metadata_api_check     = true        # LocalStack only
skip_requesting_account_id  = true        # LocalStack only
use_path_style              = true        # LocalStack only
endpoints = {
  s3 = "http://localhost:4566"            # LocalStack only
}
```
These LocalStack-only lines must be conditional/omitted for real-AWS runs,
the same way the provider block gates its `endpoints` on
`aws_endpoint_url != ""`.
