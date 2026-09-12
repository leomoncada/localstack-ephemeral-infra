# LocalStack Parity Notes

Divergences found while building this repository, against LocalStack Community.
Format: expected / observed / worked around.

Anticipated risks that did **not** materialise are recorded here too, in the
same format with "no workaround needed". A register that only lists the
failures overstates them.

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

## `AWS_ENDPOINT_URL` injection into the Lambda container

**Expected:** the Lambda handler would need the endpoint passed to it
explicitly — a Terraform-set `AWS_ENDPOINT_URL` environment variable on the
function, conditional on the target — because a `boto3` client built inside
the function has no way to know it is running in LocalStack. That would have
meant target-specific configuration reaching into application code, which is
the one thing the repository's thesis claims is unnecessary.

**Observed:** LocalStack injects `AWS_ENDPOINT_URL` into the Lambda execution
container itself, pointing at its own container IP. Verified by inspecting
the live container's environment rather than inferred from behaviour:

```
$ docker inspect localstack-ephemeral-infra-lambda-ephemeral-infra-processor-... \
    --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'AWS_ENDPOINT_URL|RECEIPTS_TABLE'
AWS_REGION=us-east-1
AWS_ENDPOINT_URL=http://172.20.0.2:4566
RECEIPTS_TABLE=ephemeral-infra-receipts
```

Terraform sets only `RECEIPTS_TABLE` — confirmed by
`awslocal lambda get-function-configuration --query 'Environment'`, which
returns that single variable. The `AWS_ENDPOINT_URL` entry is LocalStack's,
not ours.

**Workaround:** none needed, and the planned fallback (threading an
`aws_endpoint_url` variable through to `environment.variables`) was not taken.
The handler's `os.environ.get("AWS_ENDPOINT_URL") or None` idiom therefore
works unmodified on both targets: LocalStack supplies the value, real AWS
leaves it unset and `boto3` resolves the public endpoints. This is the
mechanism that lets the same handler source run against either target without
a build-time switch.

## DynamoDB `describe_continuous_backups`

**Expected:** a risk flagged before implementation — that
`describe_continuous_backups` might be unimplemented on Community tier, which
would have made the point-in-time-recovery contract test unassertable and
forced a weaker fallback (asserting the Terraform attribute instead of the
deployed state).

**Observed:** it is implemented on `localstack/localstack:4`, and returns a
real value rather than a stub default. Checked directly against the container,
not only through the passing test:

```
$ docker compose exec -T localstack awslocal dynamodb describe-continuous-backups \
    --table-name ephemeral-infra-receipts
{
    "ContinuousBackupsDescription": {
        "ContinuousBackupsStatus": "ENABLED",
        "PointInTimeRecoveryDescription": {
            "PointInTimeRecoveryStatus": "ENABLED"
        }
    }
}
```

**Workaround:** none needed. `test_receipts_table_has_point_in_time_recovery`
asserts against the live API response, as originally intended.

## Asynchronous dead-letter routing latency

**Expected:** a Lambda invocation that fails at the infrastructure level
(an uncaught exception) would route to the configured SQS dead-letter queue
quickly enough for a test to wait on it.

**Observed:** routing took roughly **four minutes**. A receipt that was valid
JSON with all required fields but an unusable value (`total_cents: "abc"`)
crashed the handler; LocalStack retried it twice at roughly 60-second
intervals — three invocations in total — before the message appeared on the
queue:

```
$ docker compose logs localstack | grep invocations
... POST /_localstack_lambda/.../invocations/7308eb98-.../error => 202   15:58:44
... POST /_localstack_lambda/.../invocations/7308eb98-.../error => 202   15:59:45

$ awslocal sqs get-queue-attributes --queue-url .../ephemeral-infra-processor-dlq \
    --attribute-names ApproximateNumberOfMessages
messages=1
```

That interval matches Lambda's documented asynchronous retry behaviour, so
this reads as emulated semantics rather than slowness — but the wall-clock
cost is real for a test loop that targets four minutes end to end.

**Workaround:** no test waits for dead-lettering. The suite's malformed-input
test asserts the DLQ stays *empty* and, in the same test, that the handler
logged a rejection for each bad object — the log assertion is what closes the
four-minute window, since a queue read taken moments after an upload cannot on
its own distinguish "rejected cleanly" from "crashed, not routed yet". The
positive path (a message does arrive on genuine failure) is therefore observed
but **not asserted by any test**. Adding
`aws_lambda_function_event_invoke_config` with `maximum_retry_attempts = 0`
would collapse the window; it was considered and deliberately not added, since
the log-based assertion achieves the same soundness without new
infrastructure.

## Docker-in-Docker Lambda execution on GitHub-hosted runners

**Expected:** `LAMBDA_RUNTIME_EXECUTOR: docker` requires LocalStack to spawn
sibling containers through the mounted Docker socket. This is the component
most likely to behave differently on a CI runner than on a laptop, and a
fallback executor mode was held in reserve.

**Observed:** it worked unmodified on `ubuntu-latest`. The same
`docker-compose.yml`, with the same socket mount, provisioned and invoked the
function on the first CI run, and the `make test` step — which includes two
tests that depend on a real Lambda invocation — measured 15.0 s on run
`34705348618`. GitHub-hosted runners expose a genuine, non-sandboxed Docker
daemon, unlike some sandboxed development environments.

**Workaround:** none needed. No CI-specific executor configuration exists in
this repository.

## SQS queue deletion time

**Expected:** `terraform destroy` time to be dominated by the Lambda function
and its supporting IAM and log resources.

**Observed:** `aws_sqs_queue.dlq` was the single longest operation in teardown,
at roughly 42 s locally — the dominant term in a `make destroy` that measures
65.0 s in CI. It completes correctly; it is only slow.

**Workaround:** none needed, and none taken. Recorded because it explains the
destroy figure in the README's comparison table, and because a stack that adds
several queues would feel it.
