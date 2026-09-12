# Ephemeral AWS Infrastructure Testing with LocalStack — Design

**Date:** 2026-09-12
**Status:** Approved, ready for implementation planning
**Budget:** 4-6 hours
**Constraint:** LocalStack Community tier only

---

## 1. Context

This is the first of four flagship projects in a personal portfolio aimed at
DevOps / Platform Engineering / MLOps roles. It is scheduled first because of an
upcoming interview with LocalStack for an internal DevOps / Platform Engineer
position.

The audience is therefore unusual and worth stating plainly: the reviewer builds
the tool being used. A tutorial-grade demonstration of "I can point Terraform at
`http://localhost:4566`" has negative value with that audience. What has value is
evidence of using the tool to solve the problem the tool exists to solve, plus an
honest account of where it has rough edges.

## 2. Thesis

The entire repository exists to make one claim verifiable by cloning it:

> The same Terraform code and the same tests run against LocalStack or against
> real AWS. Against AWS: minutes, plus cloud credentials in CI. Against
> LocalStack: seconds, with no credentials at all. It runs on every pull request.

Every decision below is subordinate to that claim. Anything that does not serve
it is out of scope.

## 3. Goals

- A single Terraform codebase that targets LocalStack or real AWS through one
  variable, with no conditional resource logic and no duplicated directories.
- An integration test suite that asserts real behaviour, not just that
  `terraform apply` exited zero.
- A CI pipeline that provisions, tests, and destroys the whole stack on every
  pull request, in roughly two minutes, with no AWS secrets in the repository.
- A measured, honestly-labelled comparison of the local feedback loop against
  the real-AWS one.
- A short, non-defensive account of LocalStack parity gaps encountered while
  building.

## 4. Non-goals

- Multi-environment promotion (dev/staging/prod). One root module, two tfvars
  files. Anything more is scope that does not serve the thesis.
- Demonstrating breadth of AWS services. A small, realistic stack beats a wide,
  shallow one.
- LocalStack Pro features (IAM enforcement, Cloud Pods, Chaos API, ECS/RDS
  emulation). Community tier only.
- Production-grade application code. The Lambda handler is deliberately small.

## 5. Architecture

A receipt-ingestion pipeline — small, but shaped like production.

```
S3 (uploads/)  --ObjectCreated-->  Lambda (processor)  -->  DynamoDB (receipts)
                                          |
                                          +-->  CloudWatch Logs
                                          +-->  SQS DLQ           [stretch]
```

**Core scope (must work):**

- S3 bucket with versioning and public access blocked, plus an ObjectCreated
  notification.
- Python Lambda that parses the uploaded receipt and writes an item to DynamoDB.
- DynamoDB table with point-in-time recovery enabled.
- IAM role and policy scoped to the specific bucket and table ARNs. No
  `Resource: "*"` anywhere.
- CloudWatch log group with an explicit retention period.

**Stretch scope (only if time remains):**

- Lambda asynchronous `on_failure` destination routing to an SQS dead-letter
  queue.
- An EventBridge rule as a second trigger path.

The DLQ is deliberately cut from the core. Asynchronous Lambda destinations are
the highest-friction surface in LocalStack Community, and a stretch goal must
never be able to sink the deliverable the night before an interview.

## 6. Key design decisions

### 6.1 One codebase, two targets, via a single variable

```hcl
variable "aws_endpoint_url" {
  type        = string
  default     = ""   # "" => real AWS; "http://localhost:4566" => LocalStack
  description = "When set, all AWS service calls are redirected to this endpoint."
}

provider "aws" {
  region = var.region

  endpoints {
    s3       = var.aws_endpoint_url
    lambda   = var.aws_endpoint_url
    dynamodb = var.aws_endpoint_url
    iam      = var.aws_endpoint_url
    sts      = var.aws_endpoint_url
    logs     = var.aws_endpoint_url
    sqs      = var.aws_endpoint_url
  }

  s3_use_path_style           = var.aws_endpoint_url != ""
  skip_credentials_validation = var.aws_endpoint_url != ""
  skip_metadata_api_check     = var.aws_endpoint_url != ""
  skip_requesting_account_id  = var.aws_endpoint_url != ""
}
```

Two variable files, `env/local.tfvars` and `env/aws.tfvars`, are the only
difference between the two worlds. No `count` guards, no `local/` directory, no
provider aliases in the happy path.

This relies on the AWS provider treating an empty endpoint string as "use the
default endpoint". **This is the single highest-risk assumption in the design
and must be validated in the first 20 minutes of implementation**, before any
other work. See section 10 for the fallback.

### 6.2 Not using `tflocal` on the primary path

LocalStack ships `tflocal`, a wrapper that injects endpoints automatically. It is
simpler. It is not used here, for four reasons:

1. It relocates the portability from the code into the toolchain, which
   contradicts the thesis in section 2.
2. It generates `localstack_providers_override.tf` inside the working directory,
   shadowing the provider configuration. A stale override file can silently
   redirect a run intended for real AWS.
3. It does not survive realistic CI. Terraform frequently runs inside Atlantis,
   Spacelift, a TFC agent, or a fixed image where injecting a Python wrapper is
   not an option. Endpoint configuration through variables works everywhere.
4. Understanding what `tflocal` does and being able to work without it is a
   stronger signal than installing it.

`tflocal` is documented in the README as the zero-config alternative, with this
reasoning stated. The goal is to demonstrate knowledge of both and a deliberate
choice between them — not ignorance of the recommended path.

### 6.3 Terraform state backend inside LocalStack

The S3 bucket and DynamoDB lock table backing Terraform state are created by a
LocalStack init hook at `/etc/localstack/init/ready.d/`, so that
`terraform init` succeeds against a cold container with no manual bootstrap step.

This is a polish detail, not a headline. Nobody runs production state in
LocalStack; the value is that `make up && make apply` works from a clean clone.

DynamoDB-based locking is used rather than S3 native locking (`use_lockfile`)
because it is the more universally supported path. Native locking is noted as a
parity item to test if time allows.

### 6.4 Test strategy

`pytest` with `boto3`, reading `AWS_ENDPOINT_URL` from the environment. The same
suite runs against either target. Two families:

**Infrastructure contract tests** — fast, no data flow:

- the bucket has versioning enabled and public access blocked;
- the Lambda execution role policy contains no `Resource: "*"`;
- the DynamoDB table has point-in-time recovery enabled;
- the log group has a finite retention period.

These are executable policy, not a linter pass. They assert the deployed state of
the world, which is a different and stronger claim than static analysis.

**End-to-end flow tests** — the actual behaviour:

- uploading a valid receipt results in a correctly-shaped DynamoDB item, using
  bounded polling with an explicit timeout;
- a malformed payload does not crash the consumer or corrupt the table;
- (stretch) a failing invocation lands in the DLQ.

## 7. Repository layout

```
localstack-ephemeral-infra/
├── README.md                  # thesis, quickstart, the comparison table
├── PARITY-NOTES.md            # honest LocalStack divergences found
├── Makefile                   # up, apply, test, destroy, clean
├── docker-compose.yml         # LocalStack Community
├── localstack/
│   └── init/ready.d/
│       └── 01-tf-backend.sh   # creates state bucket + lock table
├── infra/
│   ├── providers.tf variables.tf main.tf outputs.tf backend.tf
│   ├── env/
│   │   ├── local.tfvars
│   │   └── aws.tfvars
│   └── modules/
│       ├── ingest-bucket/
│       ├── processor-lambda/
│       └── receipts-table/
├── src/handler/app.py
├── tests/
│   ├── conftest.py            # client factory driven by AWS_ENDPOINT_URL
│   ├── test_infra_contract.py
│   └── test_ingest_flow.py
└── .github/workflows/ci.yml
```

## 8. CI

GitHub Actions, on every pull request:

```
terraform fmt -check  →  terraform validate  →  tflint  →  checkov
   →  start LocalStack  →  terraform apply  →  pytest  →  terraform destroy
```

Target: green in roughly two minutes, with zero AWS secrets configured on the
repository.

`checkov` is included because it costs about ten minutes of setup and adds
DevSecOps signal. `terraform destroy` runs in an `always()` step so that a failed
test still tears down.

## 9. Measurement and honesty

The README closes with a comparison table. The discipline that matters:

- LocalStack numbers are **measured** and pasted from real runs.
- Real-AWS numbers are **explicitly labelled as typical estimates** unless a real
  apply is actually performed.

An invented number costs all credibility with this particular audience and saves
nothing. The label costs nothing.

`PARITY-NOTES.md` records three to four real divergences encountered during
implementation, each in the form "expected X, observed Y, worked around it by Z".
Tone is that of a user reporting from the field, not a critic. Pointing at the
edges of the interviewer's own product, usefully and without complaint, is the
strongest credibility signal available in this repository.

## 10. Risks and fallbacks

| Risk | Likelihood | Fallback |
|---|---|---|
| Empty-string endpoint does not fall back to the default AWS endpoint | Medium | Two provider configurations selected by alias, or a `dynamic "endpoints"` block. Still no `tflocal`. Validate in the first 20 minutes. |
| `backend.tf` endpoint syntax varies across Terraform versions | Medium | Pin the Terraform version in CI and in the README; use `-backend-config` flags instead of a static block if needed. |
| Lambda asynchronous destinations unreliable on Community tier | Medium | Already mitigated: the DLQ is stretch scope, not core. |
| S3 ObjectCreated notification to Lambda is flaky | Low | Fall back to an explicit invoke in the test, and record the gap in `PARITY-NOTES.md`. |
| Time overrun against the 4-6h budget | Medium | Ship core scope only. The core alone satisfies the thesis; every stretch item is severable. |

## 11. Definition of done

1. `git clone && make up && make apply && make test` succeeds from a clean
   machine with Docker and Terraform installed, and nothing else.
2. The CI workflow is green on a pull request, with no repository secrets.
3. The README states the thesis, the quickstart, the comparison table with
   correctly-labelled numbers, and the `tflocal` rationale.
4. `PARITY-NOTES.md` contains at least three real, verified entries.
5. Commit history is incremental and written in English.

## 12. Identity and repository conventions

This is a personal project. Git identity is configured **locally** to the
repository, never globally:

```
user.name  = Leomar Moncada
user.email = 22892546+leomoncada@users.noreply.github.com
```

Commit messages are written in English. No cryptographic commit signing. No
co-author trailers. The repository is created private and flipped to public once
presentable.

## 13. Follow-on work

This is project one of four. The remaining flagships, each getting its own
design and plan cycle:

- **P2** — Internal Developer Platform, golden path (Platform Engineering).
- **P3** — GitOps Kubernetes with progressive delivery and SLOs (SRE).
- **P4** — LLMOps: RAG in production with evaluations as a CI quality gate.

Supply-chain security is folded into P2 and P3 rather than standing alone.
