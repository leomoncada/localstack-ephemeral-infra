# Ephemeral AWS Infrastructure Testing with LocalStack

![ci](https://github.com/leomoncada/localstack-ephemeral-infra/actions/workflows/ci.yml/badge.svg)

A receipt-ingestion stack — S3, Lambda, DynamoDB, IAM, CloudWatch Logs, SQS — provisioned,
integration-tested and destroyed on every pull request, with no AWS account and no credentials
anywhere in CI.

## The thesis

> The same Terraform code and the same tests run against LocalStack or against
> real AWS. Against AWS: minutes, plus cloud credentials in CI. Against
> LocalStack: seconds, with no credentials at all. It runs on every pull request.

Everything in this repository is subordinate to that claim, including the parts below where the
measurements are less flattering than the slogan.

## Quickstart

Requires Docker, Terraform (>= 1.11; CI pins 1.14.8), Python 3.12 and `make`. Nothing else — no AWS
account, no credentials, no `awscli` configuration. The floor is 1.11 because the S3 backend locks
with `use_lockfile`, which landed in 1.10 and is GA in 1.11.

```bash
make up       # start LocalStack
make apply    # provision the stack
make test     # run the suite
make destroy  # tear it down
```

`make lint` runs `terraform fmt -check`, `terraform validate`, `tflint` and `checkov` — the same
four commands CI runs, from the same target, so they cannot drift apart. `tflint` runs `--init`
first (it needs the AWS ruleset from `.tflint.hcl`; without it only the bundled Terraform ruleset
loads and no `aws_*` rule fires) and `--recursive`, so it reaches `infra/modules/*` where every AWS
resource actually lives.

## Architecture

```
S3 (uploads/)  --ObjectCreated-->  Lambda (processor)  -->  DynamoDB (receipts)
                                          |
                                          +-->  CloudWatch Logs
                                          +-->  SQS DLQ      (async failure routing --
                                                              see "What is tested" below)
```

Fifteen resources: eleven across three modules (`ingest-bucket`, `processor-lambda`,
`receipts-table`), plus the bucket notification and the Lambda permission that wire them together,
plus a KMS key and its alias. The bucket has versioning on and all public access blocked. The table
has point-in-time recovery enabled. The execution role carries five inline statements, each scoped
to a concrete ARN, and no attached managed policies. The log group has a finite, parameterised
retention.

One customer-managed KMS key encrypts the bucket, the table, the dead-letter queue and the log
group. That is not decoration: those four resources previously carried `checkov:skip` comments
claiming KMS was unavailable because it was absent from `docker-compose.yml`'s `SERVICES` — a
circular argument from a file this repository writes, and wrong about LocalStack, which has started
services lazily since 2.0. Enabling it deleted four suppressions. The one place it did not work is
recorded in [`PARITY-NOTES.md`](PARITY-NOTES.md).

Terraform state lives in an S3 backend with `use_lockfile = true` — inside LocalStack for the local
target, created by an init hook at container start so `terraform init` works against a cold
container with no bootstrap step.

## How targeting works

One variable selects the target:

```hcl
variable "aws_endpoint_url" {
  description = "When set, redirects all AWS service calls to this endpoint (LocalStack). Empty means real AWS."
  type        = string
  default     = ""
}
```

```hcl
provider "aws" {
  region = var.region

  # LocalStack is selected by setting var.aws_endpoint_url; an empty string
  # (the default) falls through to real AWS. Every service the stack will ever
  # touch is listed: an omitted service silently routes to real AWS.
  endpoints {
    s3       = var.aws_endpoint_url
    lambda   = var.aws_endpoint_url
    dynamodb = var.aws_endpoint_url
    iam      = var.aws_endpoint_url
    sts      = var.aws_endpoint_url
    logs     = var.aws_endpoint_url
    sqs      = var.aws_endpoint_url
    events   = var.aws_endpoint_url
    kms      = var.aws_endpoint_url
  }

  s3_use_path_style           = var.aws_endpoint_url != ""
  skip_credentials_validation = var.aws_endpoint_url != ""
  skip_metadata_api_check     = var.aws_endpoint_url != ""
  skip_requesting_account_id  = var.aws_endpoint_url != ""
}
```

LocalStack: `terraform apply -var aws_endpoint_url=http://localhost:4566` (what `make apply` does).
Real AWS: leave the variable at its default and point `init` at `infra/env/aws.backend.hcl` (what
`make apply-aws` does).

There are no `count` guards, no conditional resource logic, no `local/` directory and no provider
aliases. The same fifteen resources are planned for both targets; the only difference between the
two worlds is one string and one backend config file.

What the code does contain is provider-level endpoint configuration, and that is worth being precise
about rather than glossing: **this is the second-choice mechanism.** The first choice was to
configure nothing at all in the provider and let the `AWS_ENDPOINT_URL` environment variable do the
work. That was tried first and did not work — `terraform apply` hung indefinitely and LocalStack
never saw the request. What was and was not established about why is recorded in
[`PARITY-NOTES.md`](PARITY-NOTES.md); the honest summary is that the request did not arrive, and the
cause was not isolated. The `endpoints` block is the fallback, and it is dormant when the variable
is empty.

**No real-AWS apply has ever been run from this repository.** The real-AWS direction is verified
only this far: with the default empty endpoint, `terraform plan` reaches real AWS's STS endpoint and
fails with `403 InvalidClientTokenId`. That proves the empty-string fallback routes to AWS rather
than mis-parsing an endpoint. It does not prove the stack applies cleanly there, and nothing in this
repository does.

### Running against real AWS

The other half of the thesis has an invocation, so that it is a command someone can run rather than
a paragraph. Fill in a state bucket you own in `infra/env/aws.backend.hcl`, then:

```bash
make apply-aws    # init against env/aws.backend.hcl, then apply with no -var
make test-aws     # the same seven tests, unmodified
make destroy-aws
```

Those targets strip the LocalStack endpoint and the `test`/`test` credentials that the default
targets export (`env -u`, so the AWS credential chain sees them as absent rather than as empty
strings) and pass no `-var`, which leaves `aws_endpoint_url` at its default `""`. Terraform keeps
one initialised working directory, so `make apply` and `make apply-aws` are mutually exclusive:
switching targets re-runs `init -reconfigure`.

**None of these has ever been run against a real account,** and the paragraph above still stands.
Two things are expected to need attention on a first real run. Naming them is more useful than a
general disclaimer:

- **The ingest bucket's name is not globally unique.** It is `${var.project_name}-uploads`, and
  `project_name` defaults to `ephemeral-infra`. S3 bucket names live in one namespace shared by
  every AWS account on earth, so a project prefix buys no collision protection whatsoever:
  `ephemeral-infra-uploads` may already exist in a stranger's account, and the apply would fail with
  `BucketAlreadyExists`. A real run needs `-var project_name=<something-account-unique>`; a
  production version of this module would append the account ID or a random suffix rather than
  leaving the caller to remember.
- **LocalStack is the more permissive of the two targets.** The lifecycle rule in `ingest-bucket`
  now carries `filter {}` because the real S3 API requires every rule to specify exactly one of
  `filter` or `prefix`, while LocalStack accepts a rule with neither. That specific one is fixed —
  it was found by reading the S3 API contract, not by running against AWS — but it is the shape of
  the risk: a resource that applies cleanly here can still be rejected there.

`var.log_retention_days` is a third; it has its own section below.

## Why not `tflocal`

LocalStack ships [`tflocal`](https://github.com/localstack/terraform-local), a Terraform wrapper
that injects the endpoints automatically. It is simpler than the above. It is not used here, for
four reasons:

1. It relocates the portability from the code into the toolchain, which contradicts the thesis.
2. It generates `localstack_providers_override.tf` in the working directory, shadowing the provider
   configuration. A stale override file can silently redirect a run intended for real AWS.
3. It does not survive realistic CI. Terraform frequently runs inside Atlantis, Spacelift, a TFC
   agent, or a fixed image where injecting a Python wrapper is not an option. Endpoint
   configuration through variables works everywhere.
4. Understanding what `tflocal` does and being able to work without it is a stronger signal than
   installing it.

None of that makes `tflocal` the wrong tool. For someone who wants a local loop working in the next
five minutes, it is the right choice and this repository is the long way round. The point here is a
deliberate choice between the two, not ignorance of the recommended path.

## What the loop costs

LocalStack figures are **measured**, from GitHub Actions run
[`34705348618`](https://github.com/leomoncada/localstack-ephemeral-infra/actions/runs/34705348618)
(job step `started_at`/`completed_at`). Real-AWS figures were **not measured** — no apply against a
real account has been run — so every cell in that column is an estimate and is labelled as one in
the table itself.

| | LocalStack | Real AWS |
|---|---|---|
| `terraform apply` | **70.0 s** (includes `terraform init`) | ~1–2 min *(typical for a stack this size; estimated, not measured here)* |
| `terraform destroy` | **65.0 s** | ~1–2 min *(typical for a stack this size; estimated, not measured here)* |
| Test suite (7 tests) | **15.0 s** (includes venv build) | *(not measured here)* |
| Full CI run | **255.0 s (4 m 15 s)** | — |
| AWS credentials in CI | none | required |
| Cost per run | $0 | metered |

Full step breakdown of the same run, so the total is checkable rather than asserted:

| Step | Duration |
|---|---:|
| Install checkov | 19.0 s |
| Lint (fmt, validate, tflint, checkov) | 40.0 s |
| Start LocalStack | 38.0 s |
| Provision (`make apply`) | **70.0 s** |
| Test (`make test`) | **15.0 s** |
| Destroy (`make destroy`, `if: always()`) | **65.0 s** |
| **Total job** | **255.0 s** |

The steps sum to 247.0 s; the remaining ~8 s is checkout and tool setup.

Two things that table does not say, and should:

- **The 70.0 s provision is not a dramatic speed win over real AWS for a stack this small.** It
  includes `terraform init` (provider download) because `make apply` depends on `make init`. For
  thirteen resources, a real-AWS apply is in the same order of magnitude. The speed argument in the
  thesis gets stronger as a stack grows and as the loop repeats; it is not carried by this stack's
  apply time alone.
- **What is unambiguous is the rest of the row.** The full cycle — provision, integration-test
  against live resources, tear down — runs on every pull request with zero repository secrets, zero
  spend, zero shared-account contention, and a teardown that cannot leave anything billable behind,
  because `make down` discards the entire backing store.

## What is tested — and what is not

Seven tests, run against the live resources (not against the Terraform plan):

**Contract tests** — point-in-time recovery is enabled; bucket versioning is enabled; all public
access is blocked; the log group's retention is finite; the execution role has no attached managed
policies and no inline statement with `Resource: "*"`. These are executable policy, asserted against
the deployed state of the world, which is a stronger claim than a static-analysis pass.

**Flow tests** — a valid receipt uploaded to S3 arrives in DynamoDB with the right shape; a
malformed upload is rejected cleanly.

**The dead-letter queue, stated precisely.** An SQS DLQ is provisioned, wired as the Lambda's
`dead_letter_config` target, granted `sqs:SendMessage` on its own ARN and encrypted with SSE-KMS
under the stack's customer-managed key.
Its test coverage is **negative only**: the suite asserts that a malformed upload leaves the DLQ
*empty*, which proves the handler rejects bad input cleanly rather than crashing and routing. That a
message *does* arrive on a genuine infrastructure-level failure was observed manually during
development, but **no test asserts it**. Read the DLQ here as provisioned and negatively covered,
not as tested failure routing.

The reason no test asserts the positive path is in [`PARITY-NOTES.md`](PARITY-NOTES.md): against
LocalStack, dead-lettering took roughly four minutes (two retries about 60 s apart, then routing).
A test that waits that long would roughly double the 4 m 15 s CI run.

## A trade-off worth naming

`CKV_AWS_338` (retain CloudWatch logs for at least one year) is suppressed, and the justification
argues from this stack's ephemerality: `make down` runs `docker compose down -v` and discards the
whole backing store, so a one-year retention would outlive the thing it describes.

That justification is in tension with the repository's other central claim. If the same code really
does run against real AWS, then the 7-day default in `var.log_retention_days` would ship to a real
account as-is, where the ephemerality argument no longer applies. The retention is parameterised
precisely so a real-AWS run can raise it (`-var log_retention_days=...`), but nothing in this
repository does that, because no real-AWS run has happened. Recording the tension rather than
leaving it to sit quietly inside a `#checkov:skip` comment.

## Parity notes

[`PARITY-NOTES.md`](PARITY-NOTES.md) is the field register: expected / observed / workaround, for
each divergence and each anticipated-risk-that-did-not-materialise found while building this. It
covers endpoint targeting, S3 native state locking, `describe_continuous_backups`,
`AWS_ENDPOINT_URL` injection into the Lambda container, customer-managed KMS keys, dead-letter
latency, SQS teardown time, and the Docker-in-Docker Lambda executor on GitHub-hosted runners. Notes, not grievances — several entries record things that
worked.
