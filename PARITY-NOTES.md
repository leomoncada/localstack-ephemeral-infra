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
creating...` past 4 minutes with no error. The process was killed manually
after the timebox made it clear this was not going to resolve. The decisive
check was negative: `awslocal s3api list-buckets` inside the container
stayed empty for the whole 4 minutes, so the bucket was never created in
LocalStack. That is the only thing confirmed — the request did not reach
LocalStack. Where it actually went, and why it hung rather than erroring,
is **undetermined**. Two explanations are consistent with the symptom and
neither was ruled out:
  - the global `AWS_ENDPOINT_URL` env var was not honored by the AWS
    provider v6.64.0 for this S3 call, so the request went to real AWS and
    stalled there instead of failing fast; or
  - the request never left the host at all — network egress being blocked
    or silently dropped (sandboxed shell, firewall dropping SYNs) produces
    an identical indefinite hang with LocalStack never seeing anything.

  The first explanation cannot be asserted with confidence: the variant-B
  fallback test below shows real AWS rejecting the same `test`/`test`
  credentials **fast**, with a non-retryable `403 InvalidClientTokenId` — if
  bad credentials fail fast there, they cannot also explain a 4-minute
  hang here. No packet capture or egress test was run to distinguish the
  two, so the cause is left open rather than asserted.

**Workaround:** the request not reaching LocalStack, for whatever reason,
means variant A cannot be relied on. Switched to variant B — explicit
`endpoints { s3 = ...
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

Captured output from the second (blocked) apply, verbatim:

```
Error: Error acquiring the state lock

Error message: operation error S3: PutObject, https response error
StatusCode: 412, RequestID: b15bbf21-f236-429d-8a14-044222969b12, HostID:
s9lzHYrFp76ZVxRcpX9+5cjAnEH2ROuNkd2BHfIa6UkFVdtjf5mKR3/eTPFvsiP/XV/VLi31234=,
api error PreconditionFailed: At least one of the pre-conditions you
specified did not hold
Lock Info:
  ID:        8a1b8378-d2d9-3261-4873-e24d88b4bc6d
  Path:      tfstate-probe/probe/terraform.tfstate
  Operation: OperationTypeApply
  Who:       <redacted>@<redacted-host>
  Version:   1.14.8
  Created:   2026-09-12 14:45:40.633526 +0000 UTC
  Info:

Terraform acquires a state lock to protect the state from being written
by multiple users at the same time. Please resolve the issue above and try
again. For most commands, you can disable locking with the "-lock=false"
flag, but this is not recommended.
```

The `Who` field's user and host identifiers were redacted above; nothing
else in the block was altered. The `RequestID` differs between independent
runs (it is per-request), but the `HostID` was checked against an earlier,
separate test run and is byte-for-byte identical there too — confirming it
is a static value LocalStack's S3 mock returns, not a hand-typed string.

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
