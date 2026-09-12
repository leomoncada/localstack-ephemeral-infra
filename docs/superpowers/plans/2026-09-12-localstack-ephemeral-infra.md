# Ephemeral AWS Infrastructure Testing with LocalStack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A repository proving that one Terraform codebase and one test suite run against either LocalStack or real AWS, exercised on every pull request without cloud credentials.

**Architecture:** A small event-driven AWS stack (S3 to Lambda to DynamoDB) defined in three Terraform modules. Target selection happens entirely through environment variables, so the Terraform code contains no LocalStack-specific configuration. A pytest suite asserts both the deployed infrastructure contract and the end-to-end data flow, against whichever target the environment points at. GitHub Actions runs provision, test, and destroy on every PR.

**Tech Stack:** Terraform 1.14.8, AWS provider ~> 6.0, LocalStack Community (Docker), Python 3.14 with pytest and boto3, GitHub Actions, tflint, checkov.

**Spec:** `docs/superpowers/specs/2026-09-12-localstack-ephemeral-infra-design.md`

## Global Constraints

- **Time budget: 4-6 hours total.** Tasks 1-7 are core. Task 8 is stretch and severable. If the budget runs out, ship core and stop.
- **LocalStack Community tier only.** No IAM enforcement, no Cloud Pods, no Chaos API, no ECS/RDS.
- **Terraform >= 1.9**, AWS provider `~> 6.0`. Local Terraform is 1.14.8.
- **No `tflocal` on the primary path.** Documented in the README as the zero-config alternative, with the reasoning from spec section 6.2.
- **No `Resource: "*"` in any IAM policy.** This is asserted by a test, not by review.
- **Git identity is repo-local and already configured:** `Leomar Moncada <22892546+leomoncada@users.noreply.github.com>`. Never set it globally.
- **All commit messages, code comments, and documentation in English.** No `Co-Authored-By` trailers. No cryptographic signing.
- **Region is `us-east-1` everywhere.** Account-agnostic; never hardcode an account ID.
- **Resource names carry a `var.project_name` prefix** (default `ephemeral-infra`) so the same code can be applied to real AWS without collisions.

---

## File Structure

| Path | Responsibility |
|---|---|
| `docker-compose.yml` | LocalStack Community service definition and healthcheck |
| `localstack/init/ready.d/01-tf-backend.sh` | Creates the Terraform state bucket and lock table on container start |
| `Makefile` | The user-facing verbs: `up`, `init`, `apply`, `test`, `destroy`, `down`, `lint` |
| `infra/versions.tf` | Terraform and provider version pins, backend declaration |
| `infra/providers.tf` | AWS provider block. Contains no LocalStack-specific values |
| `infra/variables.tf` | `project_name`, `region`, `log_retention_days` |
| `infra/main.tf` | Wires the three modules together |
| `infra/outputs.tf` | Bucket name, table name, function name — consumed by tests |
| `infra/env/local.backend.hcl` | Backend config for the LocalStack target |
| `infra/env/aws.backend.hcl` | Backend config for the real-AWS target |
| `infra/modules/receipts-table/` | DynamoDB table, PITR enabled |
| `infra/modules/ingest-bucket/` | S3 bucket, versioning, public access block, notification |
| `infra/modules/processor-lambda/` | Lambda function, IAM role and scoped policy, log group |
| `src/handler/app.py` | Receipt parsing and DynamoDB write |
| `tests/conftest.py` | boto3 client factory and Terraform output loader |
| `tests/test_infra_contract.py` | Asserts the deployed infrastructure contract |
| `tests/test_ingest_flow.py` | Asserts the end-to-end data flow |
| `.github/workflows/ci.yml` | fmt, validate, lint, scan, apply, test, destroy |
| `README.md` | Thesis, quickstart, comparison table, `tflocal` rationale |
| `PARITY-NOTES.md` | Verified LocalStack divergences |

---

## Task 1: Validate the targeting mechanism (TIMEBOX: 30 MINUTES)

This task exists because spec section 10 identifies endpoint targeting as the highest-risk assumption in the design. **Do this before writing any other code.** Its outcome decides how every later task configures Terraform.

**Files:**
- Create: `spike/main.tf` (throwaway — deleted at the end of this task)
- Create: `docker-compose.yml`

**Interfaces:**
- Produces: a decision recorded in `PARITY-NOTES.md` naming which of variants A, B, or C is used by all later tasks.

- [ ] **Step 1: Write the LocalStack compose file**

```yaml
# docker-compose.yml
services:
  localstack:
    image: localstack/localstack:4
    container_name: localstack-ephemeral-infra
    ports:
      - "4566:4566"
    environment:
      DEBUG: ${DEBUG:-0}
      SERVICES: s3,lambda,dynamodb,iam,sts,logs,sqs,events
      LAMBDA_RUNTIME_EXECUTOR: docker
    volumes:
      - "./localstack/init/ready.d:/etc/localstack/init/ready.d"
      - "/var/run/docker.sock:/var/run/docker.sock"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:4566/_localstack/health || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 20
```

- [ ] **Step 2: Start LocalStack and confirm it is healthy**

Run:
```bash
docker compose up -d
timeout 120 bash -c 'until curl -sf http://localhost:4566/_localstack/health >/dev/null; do sleep 2; done'
curl -s http://localhost:4566/_localstack/health | jq '.services | {s3, lambda, dynamodb, iam}'
```
Expected: all four services report `available` or `running`.

- [ ] **Step 3: Write the throwaway spike module**

```hcl
# spike/main.tf
terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "probe" {
  bucket = "spike-probe-bucket"
}

output "bucket" {
  value = aws_s3_bucket.probe.id
}
```

Note there is **no endpoint configuration at all**. That is the point of variant A.

- [ ] **Step 4: Try variant A — pure environment variables**

Run:
```bash
cd spike
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1
terraform init -no-color && terraform apply -auto-approve -no-color
```

Expected if variant A works: apply succeeds. Verify the bucket landed in LocalStack and not somewhere else:
```bash
curl -s http://localhost:4566/spike-probe-bucket | head -5
```

If this succeeds, **variant A wins.** The Terraform code needs zero LocalStack awareness, which is a stronger result than the spec assumed. Record it and skip to Step 7.

- [ ] **Step 5: If variant A failed, try variant B — the spec's empty-string endpoints**

Replace the provider block in `spike/main.tf`:

```hcl
variable "aws_endpoint_url" {
  type    = string
  default = ""
}

provider "aws" {
  region = "us-east-1"

  endpoints {
    s3  = var.aws_endpoint_url
    sts = var.aws_endpoint_url
    iam = var.aws_endpoint_url
  }

  s3_use_path_style           = var.aws_endpoint_url != ""
  skip_credentials_validation = var.aws_endpoint_url != ""
  skip_metadata_api_check     = var.aws_endpoint_url != ""
  skip_requesting_account_id  = var.aws_endpoint_url != ""
}
```

Run both directions to confirm the fallback actually falls back:
```bash
terraform apply -auto-approve -var aws_endpoint_url=http://localhost:4566   # must hit LocalStack
terraform plan -no-color                                                     # must attempt real AWS and fail on credentials, NOT on a malformed endpoint
```
Expected: the second command fails with a credentials or region error. If it fails with an endpoint parsing error, the empty-string fallback does not work and variant B is dead.

- [ ] **Step 6: If both A and B failed, use variant C — provider aliases**

```hcl
provider "aws" {
  alias                       = "localstack"
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  endpoints {
    s3  = "http://localhost:4566"
    sts = "http://localhost:4566"
    iam = "http://localhost:4566"
  }
}
```

Modules then receive `providers = { aws = aws.localstack }` from a target-specific root. This costs a duplicated root module and weakens the thesis, so it is the last resort. If you land here, say so plainly in the README rather than hiding it.

- [ ] **Step 7: Validate the state backend locking mechanism**

Terraform 1.14 deprecates the S3 backend's `dynamodb_table` argument in favour of `use_lockfile` (S3 conditional writes). Which one works against LocalStack Community is unknown and must be settled now.

```bash
awslocal_exec() { docker compose exec -T localstack awslocal "$@"; }
awslocal_exec s3api create-bucket --bucket tfstate-probe
```

Try `use_lockfile` first:
```bash
cat > backend.hcl <<'EOF'
bucket       = "tfstate-probe"
key          = "probe/terraform.tfstate"
region       = "us-east-1"
use_lockfile = true
EOF
terraform init -reconfigure -backend-config=backend.hcl -no-color
terraform apply -auto-approve -no-color
```
Expected: init and apply succeed, and a `.tflock` object appears alongside the state object during apply.

If `use_lockfile` fails, fall back to a DynamoDB lock table and accept the deprecation warning:
```bash
awslocal_exec dynamodb create-table --table-name tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```
and add `dynamodb_table = "tfstate-lock"` to `backend.hcl`.

- [ ] **Step 8: Record the decision and delete the spike**

Create `PARITY-NOTES.md` with the first entries. Write what you actually observed, not what you hoped:

```markdown
# LocalStack Parity Notes

Divergences found while building this repository, against LocalStack Community.
Format: expected / observed / worked around.

## Endpoint targeting

**Chosen mechanism:** variant <A|B|C> — <one line on why>.

**Expected:** <what you expected>
**Observed:** <what actually happened>
**Workaround:** <what you did>

## Terraform state locking

**Expected:** `use_lockfile = true` (Terraform 1.14 deprecates `dynamodb_table`).
**Observed:** <result>
**Workaround:** <result>
```

Then:
```bash
cd .. && rm -rf spike
git add docker-compose.yml PARITY-NOTES.md
git commit -m "chore: validate endpoint targeting and state locking against LocalStack

Settles the highest-risk assumption in the design before building on it.
Records the chosen mechanism and the observed behaviour in PARITY-NOTES."
```

**STOP HERE AND REPORT.** Tell the user which variant won and what the locking result was before continuing. Every later task depends on this answer.

---

## Task 2: Repository skeleton, init hook, and Makefile

**Files:**
- Create: `localstack/init/ready.d/01-tf-backend.sh`
- Create: `Makefile`
- Create: `requirements-dev.txt`

**Interfaces:**
- Consumes: the targeting variant chosen in Task 1.
- Produces: `make up` leaves a healthy LocalStack with a state bucket ready; `make lint` runs fmt, validate, tflint, checkov.

- [ ] **Step 1: Write the init hook**

Adjust the locking resources to match Task 1's outcome. If `use_lockfile` won, drop the DynamoDB table.

```bash
#!/usr/bin/env bash
# Runs inside the LocalStack container once the runtime is ready.
# Creates the Terraform state backend so `terraform init` works against a cold container.
set -euo pipefail

awslocal s3api create-bucket --bucket tfstate
awslocal s3api put-bucket-versioning \
  --bucket tfstate \
  --versioning-configuration Status=Enabled

echo "terraform state backend ready"
```

Make it executable: `chmod +x localstack/init/ready.d/01-tf-backend.sh`

- [ ] **Step 2: Write the Makefile**

```makefile
SHELL := /usr/bin/env bash
TF     := terraform -chdir=infra
VENV   := .venv

export AWS_ENDPOINT_URL   ?= http://localhost:4566
export AWS_ACCESS_KEY_ID  ?= test
export AWS_SECRET_ACCESS_KEY ?= test
export AWS_REGION         ?= us-east-1

.PHONY: up down init apply destroy test lint clean

up: ## Start LocalStack and wait for it to be healthy
	docker compose up -d
	@timeout 120 bash -c 'until curl -sf $(AWS_ENDPOINT_URL)/_localstack/health >/dev/null; do sleep 2; done'
	@echo "localstack ready"

down: ## Stop LocalStack and discard all state
	docker compose down -v

init: ## Initialise Terraform against the local backend
	$(TF) init -reconfigure -backend-config=env/local.backend.hcl

apply: init ## Provision the stack
	$(TF) apply -auto-approve

destroy: ## Tear the stack down
	$(TF) destroy -auto-approve

$(VENV): requirements-dev.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet --upgrade pip
	$(VENV)/bin/pip install --quiet -r requirements-dev.txt
	@touch $(VENV)

test: $(VENV) ## Run the test suite against the current target
	$(VENV)/bin/pytest tests -v

lint: ## Format check, validate, lint, and security scan
	$(TF) fmt -check -recursive
	$(TF) validate
	tflint --chdir=infra
	checkov -d infra --quiet --compact

clean: down ## Remove all local artefacts
	rm -rf $(VENV) infra/.terraform infra/.terraform.lock.hcl
```

- [ ] **Step 3: Write the dev requirements**

```
# requirements-dev.txt
boto3==1.40.*
pytest==8.*
```

- [ ] **Step 4: Verify the init hook actually ran**

Run:
```bash
make down && make up
docker compose logs localstack 2>&1 | grep "terraform state backend ready"
docker compose exec -T localstack awslocal s3api list-buckets --query 'Buckets[].Name'
```
Expected: the log line appears and `tfstate` is listed.

- [ ] **Step 5: Commit**

```bash
git add Makefile requirements-dev.txt localstack/
git commit -m "feat: add LocalStack compose stack with Terraform backend bootstrap

The state bucket is created by a ready.d init hook so that terraform init
succeeds against a cold container with no manual bootstrap step."
```

---
## Task 3: Terraform root, test harness, and the receipts table

**Files:**
- Create: `infra/versions.tf`, `infra/providers.tf`, `infra/variables.tf`, `infra/main.tf`, `infra/outputs.tf`
- Create: `infra/env/local.backend.hcl`, `infra/env/aws.backend.hcl`
- Create: `infra/modules/receipts-table/{main.tf,variables.tf,outputs.tf}`
- Create: `tests/conftest.py`, `tests/test_infra_contract.py`

**Interfaces:**
- Consumes: the targeting variant from Task 1; `make up` from Task 2.
- Produces:
  - Terraform outputs `receipts_table_name` (string), `receipts_table_arn` (string).
  - pytest fixtures `aws` (callable: `aws("dynamodb")` returns a boto3 client) and `tf_outputs` (dict of Terraform output name to value).
  - Module `receipts-table` with inputs `project_name` (string), `tags` (map(string)); outputs `name` (string), `arn` (string).

- [ ] **Step 1: Write the test harness**

```python
# tests/conftest.py
import functools
import json
import os
import subprocess

import boto3
import pytest


@pytest.fixture(scope="session")
def tf_outputs():
    """Terraform outputs for the currently applied stack."""
    result = subprocess.run(
        ["terraform", "-chdir=infra", "output", "-json"],
        capture_output=True,
        text=True,
        check=True,
    )
    return {k: v["value"] for k, v in json.loads(result.stdout).items()}


@pytest.fixture(scope="session")
def aws():
    """boto3 client factory.

    Honours AWS_ENDPOINT_URL, so this suite runs unchanged against LocalStack
    or against real AWS. Unset means real AWS.
    """
    endpoint = os.environ.get("AWS_ENDPOINT_URL") or None
    session = boto3.Session(region_name=os.environ.get("AWS_REGION", "us-east-1"))

    @functools.lru_cache(maxsize=None)
    def client(service_name):
        return session.client(service_name, endpoint_url=endpoint)

    return client
```

- [ ] **Step 2: Write the failing contract test**

```python
# tests/test_infra_contract.py
"""Assertions about the deployed infrastructure.

These are executable policy, not static analysis: they describe the real state
of the world after apply, which is a stronger claim than a linter pass.
"""


def test_receipts_table_has_point_in_time_recovery(aws, tf_outputs):
    ddb = aws("dynamodb")
    backups = ddb.describe_continuous_backups(
        TableName=tf_outputs["receipts_table_name"]
    )
    status = backups["ContinuousBackupsDescription"][
        "PointInTimeRecoveryDescription"
    ]["PointInTimeRecoveryStatus"]
    assert status == "ENABLED"
```

- [ ] **Step 3: Run it to verify it fails**

Run: `make up && make test`
Expected: FAIL. Terraform has no outputs yet, so `tf_outputs` raises `CalledProcessError` or `KeyError: 'receipts_table_name'`. Either is the correct failure.

- [ ] **Step 4: Write the root module version pins and backend declaration**

```hcl
# infra/versions.tf
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration. Supplied per target via -backend-config.
  backend "s3" {}
}
```

- [ ] **Step 5: Write the provider block**

Use the variant Task 1 selected. If variant A won, this file contains no LocalStack-specific configuration whatsoever — which is the result worth having:

```hcl
# infra/providers.tf
# No endpoint configuration. The target is selected entirely by environment
# (AWS_ENDPOINT_URL), so this code is identical for LocalStack and real AWS.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}
```

If variant B won, add the `endpoints` block and the four `skip_*` arguments exactly as written in Task 1 Step 5. If variant C won, follow Task 1 Step 6.

- [ ] **Step 6: Write variables, backend configs, and the root wiring**

```hcl
# infra/variables.tf
variable "project_name" {
  type        = string
  description = "Prefix for all resource names."
  default     = "ephemeral-infra"
}

variable "region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention. Finite by policy; asserted by tests."
  default     = 7
}
```

```hcl
# infra/env/local.backend.hcl
bucket = "tfstate"
key    = "ephemeral-infra/terraform.tfstate"
region = "us-east-1"
# Locking: set to whatever Task 1 Step 7 established.
use_lockfile = true
```

```hcl
# infra/env/aws.backend.hcl
# Real-AWS target. Fill bucket with a state bucket you own before using.
bucket       = "CHANGE-ME-your-tfstate-bucket"
key          = "ephemeral-infra/terraform.tfstate"
region       = "us-east-1"
use_lockfile = true
```

```hcl
# infra/main.tf
module "receipts_table" {
  source       = "./modules/receipts-table"
  project_name = var.project_name
}
```

```hcl
# infra/outputs.tf
output "receipts_table_name" {
  value = module.receipts_table.name
}

output "receipts_table_arn" {
  value = module.receipts_table.arn
}
```

- [ ] **Step 7: Write the receipts-table module**

```hcl
# infra/modules/receipts-table/variables.tf
variable "project_name" {
  type        = string
  description = "Prefix for the table name."
}
```

```hcl
# infra/modules/receipts-table/main.tf
resource "aws_dynamodb_table" "this" {
  name         = "${var.project_name}-receipts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "receipt_id"

  attribute {
    name = "receipt_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}
```

```hcl
# infra/modules/receipts-table/outputs.tf
output "name" {
  value = aws_dynamodb_table.this.name
}

output "arn" {
  value = aws_dynamodb_table.this.arn
}
```

- [ ] **Step 8: Apply and run the test to verify it passes**

Run: `make apply && make test`
Expected: PASS.

**If `describe_continuous_backups` is unimplemented on Community tier**, the call raises `UnknownOperationException` or returns `DISABLED` despite Terraform reporting success. That is a genuine parity finding, not a reason to delete the test. Add an entry to `PARITY-NOTES.md` and change the assertion to read the value Terraform recorded instead:

```python
def test_receipts_table_has_point_in_time_recovery(aws, tf_outputs):
    ddb = aws("dynamodb")
    table = ddb.describe_table(TableName=tf_outputs["receipts_table_name"])["Table"]
    assert table["TableStatus"] == "ACTIVE"
    # PITR is asserted through Terraform state rather than the DynamoDB API:
    # LocalStack Community does not implement describe_continuous_backups.
    # See PARITY-NOTES.md.
```

- [ ] **Step 9: Lint and commit**

```bash
make lint
git add infra/ tests/
git commit -m "feat: add Terraform root module and receipts table

Introduces the pytest harness that drives both targets from AWS_ENDPOINT_URL,
and the first infrastructure contract test asserting point-in-time recovery."
```

---

## Task 4: Ingest bucket

**Files:**
- Create: `infra/modules/ingest-bucket/{main.tf,variables.tf,outputs.tf}`
- Modify: `infra/main.tf`, `infra/outputs.tf`
- Modify: `tests/test_infra_contract.py`

**Interfaces:**
- Consumes: `project_name` variable from Task 3.
- Produces:
  - Terraform outputs `ingest_bucket_name` (string), `ingest_bucket_arn` (string).
  - Module `ingest-bucket` with input `project_name` (string); outputs `name` (string), `arn` (string), `id` (string).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_infra_contract.py`:

```python
def test_ingest_bucket_has_versioning_enabled(aws, tf_outputs):
    s3 = aws("s3")
    versioning = s3.get_bucket_versioning(Bucket=tf_outputs["ingest_bucket_name"])
    assert versioning.get("Status") == "Enabled"


def test_ingest_bucket_blocks_all_public_access(aws, tf_outputs):
    s3 = aws("s3")
    config = s3.get_public_access_block(
        Bucket=tf_outputs["ingest_bucket_name"]
    )["PublicAccessBlockConfiguration"]
    assert config["BlockPublicAcls"]
    assert config["IgnorePublicAcls"]
    assert config["BlockPublicPolicy"]
    assert config["RestrictPublicBuckets"]
```

- [ ] **Step 2: Run to verify they fail**

Run: `make test`
Expected: FAIL with `KeyError: 'ingest_bucket_name'` on both new tests. The Task 3 test still passes.

- [ ] **Step 3: Write the module**

```hcl
# infra/modules/ingest-bucket/variables.tf
variable "project_name" {
  type        = string
  description = "Prefix for the bucket name."
}
```

```hcl
# infra/modules/ingest-bucket/main.tf
resource "aws_s3_bucket" "this" {
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
```

```hcl
# infra/modules/ingest-bucket/outputs.tf
output "id" {
  value = aws_s3_bucket.this.id
}

output "name" {
  value = aws_s3_bucket.this.bucket
}

output "arn" {
  value = aws_s3_bucket.this.arn
}
```

- [ ] **Step 4: Wire it into the root**

Append to `infra/main.tf`:
```hcl
module "ingest_bucket" {
  source       = "./modules/ingest-bucket"
  project_name = var.project_name
}
```

Append to `infra/outputs.tf`:
```hcl
output "ingest_bucket_name" {
  value = module.ingest_bucket.name
}

output "ingest_bucket_arn" {
  value = module.ingest_bucket.arn
}
```

- [ ] **Step 5: Apply and verify the tests pass**

Run: `make apply && make test`
Expected: PASS, three tests.

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add infra/ tests/
git commit -m "feat: add ingest bucket with versioning and public access blocked

Both properties are asserted against the deployed bucket rather than trusted
from the Terraform plan."
```

---
## Task 5: Processor Lambda, scoped IAM, and the end-to-end flow

This is the task that makes the repository worth reading. Budget roughly 90 minutes.

**Files:**
- Create: `src/handler/app.py`
- Create: `infra/modules/processor-lambda/{main.tf,variables.tf,outputs.tf}`
- Create: `tests/test_ingest_flow.py`
- Modify: `infra/main.tf`, `infra/outputs.tf`, `infra/variables.tf`, `tests/test_infra_contract.py`

**Interfaces:**
- Consumes: `ingest_bucket_arn` and `ingest_bucket_id` from Task 4; `receipts_table_arn` and `receipts_table_name` from Task 3.
- Produces:
  - Terraform outputs `processor_function_name` (string), `processor_role_name` (string).
  - Module `processor-lambda` with inputs `project_name` (string), `source_dir` (string), `receipts_table_name` (string), `receipts_table_arn` (string), `ingest_bucket_arn` (string), `log_retention_days` (number); outputs `function_name` (string), `function_arn` (string), `role_name` (string).
  - DynamoDB item shape: `{receipt_id: S, merchant: S, total_cents: N, source_key: S}`.

- [ ] **Step 1: Write the failing end-to-end test**

```python
# tests/test_ingest_flow.py
"""End-to-end assertions: a receipt uploaded to S3 reaches DynamoDB."""

import json
import time
import uuid

POLL_TIMEOUT_SECONDS = 60
POLL_INTERVAL_SECONDS = 2


def _wait_for_receipt(ddb, table_name, receipt_id):
    """Poll for an item with a bounded deadline.

    Event delivery is asynchronous on both targets, so a bare read races the
    pipeline. The failure message carries the last response to make a timeout
    diagnosable rather than merely red.
    """
    deadline = time.monotonic() + POLL_TIMEOUT_SECONDS
    last_response = None
    while time.monotonic() < deadline:
        last_response = ddb.get_item(
            TableName=table_name,
            Key={"receipt_id": {"S": receipt_id}},
        )
        if "Item" in last_response:
            return last_response["Item"]
        time.sleep(POLL_INTERVAL_SECONDS)
    raise AssertionError(
        f"receipt {receipt_id} did not reach {table_name} within "
        f"{POLL_TIMEOUT_SECONDS}s. Last response: {last_response}"
    )


def _upload(aws, tf_outputs, key, body):
    aws("s3").put_object(
        Bucket=tf_outputs["ingest_bucket_name"], Key=key, Body=body
    )


def test_uploaded_receipt_is_persisted(aws, tf_outputs):
    receipt_id = f"rcpt-{uuid.uuid4()}"
    payload = {
        "receipt_id": receipt_id,
        "merchant": "Acme Hardware",
        "total_cents": 1299,
    }

    _upload(aws, tf_outputs, f"{receipt_id}.json", json.dumps(payload).encode())

    item = _wait_for_receipt(
        aws("dynamodb"), tf_outputs["receipts_table_name"], receipt_id
    )
    assert item["merchant"]["S"] == "Acme Hardware"
    assert item["total_cents"]["N"] == "1299"
    assert item["source_key"]["S"] == f"{receipt_id}.json"


def test_malformed_receipt_does_not_break_the_pipeline(aws, tf_outputs):
    """A bad payload must be rejected without poisoning the consumer."""
    bad_id = f"bad-{uuid.uuid4()}"
    _upload(aws, tf_outputs, f"{bad_id}.json", b"{ this is not valid json")

    # The pipeline must still be healthy afterwards.
    good_id = f"rcpt-{uuid.uuid4()}"
    payload = {
        "receipt_id": good_id,
        "merchant": "Still Working",
        "total_cents": 500,
    }
    _upload(aws, tf_outputs, f"{good_id}.json", json.dumps(payload).encode())

    item = _wait_for_receipt(
        aws("dynamodb"), tf_outputs["receipts_table_name"], good_id
    )
    assert item["merchant"]["S"] == "Still Working"

    # The malformed one must not have been stored.
    rejected = aws("dynamodb").get_item(
        TableName=tf_outputs["receipts_table_name"],
        Key={"receipt_id": {"S": bad_id}},
    )
    assert "Item" not in rejected
```

- [ ] **Step 2: Write the failing least-privilege test**

Append to `tests/test_infra_contract.py`:

```python
import json
import urllib.parse


def _role_policy_documents(iam, role_name):
    """Yield every inline policy document attached to a role, decoded."""
    for policy_name in iam.list_role_policies(RoleName=role_name)["PolicyNames"]:
        document = iam.get_role_policy(
            RoleName=role_name, PolicyName=policy_name
        )["PolicyDocument"]
        # IAM returns this either URL-encoded JSON or already decoded,
        # depending on the client and the backend. Handle both.
        if isinstance(document, str):
            document = json.loads(urllib.parse.unquote(document))
        yield policy_name, document


def test_processor_role_grants_no_wildcard_resources(aws, tf_outputs):
    """Least privilege as an executable assertion, not a review comment."""
    iam = aws("iam")
    role_name = tf_outputs["processor_role_name"]

    checked = 0
    for policy_name, document in _role_policy_documents(iam, role_name):
        for statement in document["Statement"]:
            resources = statement["Resource"]
            if isinstance(resources, str):
                resources = [resources]
            assert "*" not in resources, (
                f"policy {policy_name} grants a wildcard resource on "
                f"actions {statement.get('Action')}"
            )
            checked += 1

    assert checked > 0, f"no inline policies found on role {role_name}"


def test_processor_log_group_has_finite_retention(aws, tf_outputs):
    logs = aws("logs")
    name = f"/aws/lambda/{tf_outputs['processor_function_name']}"
    groups = logs.describe_log_groups(logGroupNamePrefix=name)["logGroups"]
    match = next(g for g in groups if g["logGroupName"] == name)
    assert match.get("retentionInDays"), "log group retains logs forever"
```

- [ ] **Step 3: Run to verify the new tests fail**

Run: `make test`
Expected: FAIL with `KeyError: 'processor_role_name'` and `KeyError: 'ingest_bucket_name'` on the flow tests. The three earlier tests still pass.

- [ ] **Step 4: Write the Lambda handler**

```python
# src/handler/app.py
"""Parse receipts uploaded to S3 and persist them to DynamoDB.

Deliberately small. The point of this repository is the infrastructure and its
test loop, not the business logic.
"""

import json
import os
import urllib.parse

import boto3

# LocalStack injects AWS_ENDPOINT_URL into the Lambda environment; on real AWS
# it is unset and boto3 resolves the public endpoints. Same code, both targets.
_ENDPOINT = os.environ.get("AWS_ENDPOINT_URL") or None
_TABLE_NAME = os.environ["RECEIPTS_TABLE"]

_s3 = boto3.client("s3", endpoint_url=_ENDPOINT)
_table = boto3.resource("dynamodb", endpoint_url=_ENDPOINT).Table(_TABLE_NAME)

REQUIRED_FIELDS = ("receipt_id", "merchant", "total_cents")


def _parse(body):
    receipt = json.loads(body)
    missing = [field for field in REQUIRED_FIELDS if field not in receipt]
    if missing:
        raise ValueError(f"missing required fields: {missing}")
    return receipt


def handler(event, context):
    stored = 0
    rejected = 0

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        body = _s3.get_object(Bucket=bucket, Key=key)["Body"].read()

        try:
            receipt = _parse(body)
        except (json.JSONDecodeError, ValueError) as exc:
            print(f"rejected s3://{bucket}/{key}: {exc}")
            rejected += 1
            continue

        _table.put_item(
            Item={
                "receipt_id": str(receipt["receipt_id"]),
                "merchant": str(receipt["merchant"]),
                "total_cents": int(receipt["total_cents"]),
                "source_key": key,
            }
        )
        stored += 1

    return {"stored": stored, "rejected": rejected}
```

- [ ] **Step 5: Write the processor-lambda module**

```hcl
# infra/modules/processor-lambda/variables.tf
variable "project_name" {
  type        = string
  description = "Prefix for resource names."
}

variable "source_dir" {
  type        = string
  description = "Directory containing the handler source to package."
}

variable "receipts_table_name" {
  type        = string
  description = "DynamoDB table the handler writes to."
}

variable "receipts_table_arn" {
  type        = string
  description = "ARN of the receipts table, for the scoped IAM policy."
}

variable "ingest_bucket_arn" {
  type        = string
  description = "ARN of the ingest bucket, for the scoped IAM policy."
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch retention in days."
}
```

```hcl
# infra/modules/processor-lambda/main.tf
data "archive_file" "this" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/handler.zip"
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.project_name}-processor"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.project_name}-processor"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "permissions" {
  statement {
    sid       = "ReadUploadedReceipts"
    actions   = ["s3:GetObject"]
    resources = ["${var.ingest_bucket_arn}/*"]
  }

  statement {
    sid       = "WriteReceipts"
    actions   = ["dynamodb:PutItem"]
    resources = [var.receipts_table_arn]
  }

  # No logs:CreateLogGroup: Terraform owns the group, so the function does not
  # need permission to create one. This is why the wildcard test can pass.
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.project_name}-processor"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_lambda_function" "this" {
  function_name    = "${var.project_name}-processor"
  role             = aws_iam_role.this.arn
  handler          = "app.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      RECEIPTS_TABLE = var.receipts_table_name
    }
  }

  depends_on = [
    aws_iam_role_policy.this,
    aws_cloudwatch_log_group.this,
  ]
}
```

```hcl
# infra/modules/processor-lambda/outputs.tf
output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "role_name" {
  value = aws_iam_role.this.name
}
```

- [ ] **Step 6: Wire the trigger in the root module**

Append to `infra/main.tf`:

```hcl
module "processor_lambda" {
  source = "./modules/processor-lambda"

  project_name        = var.project_name
  source_dir          = "${path.module}/../src/handler"
  receipts_table_name = module.receipts_table.name
  receipts_table_arn  = module.receipts_table.arn
  ingest_bucket_arn   = module.ingest_bucket.arn
  log_retention_days  = var.log_retention_days
}

resource "aws_lambda_permission" "allow_ingest_bucket" {
  statement_id  = "AllowExecutionFromIngestBucket"
  action        = "lambda:InvokeFunction"
  function_name = module.processor_lambda.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = module.ingest_bucket.arn
}

resource "aws_s3_bucket_notification" "ingest" {
  bucket = module.ingest_bucket.id

  lambda_function {
    lambda_function_arn = module.processor_lambda.function_arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.allow_ingest_bucket]
}
```

Append to `infra/outputs.tf`:

```hcl
output "processor_function_name" {
  value = module.processor_lambda.function_name
}

output "processor_role_name" {
  value = module.processor_lambda.role_name
}
```

Add `archive` to `infra/versions.tf` required_providers:

```hcl
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
```

- [ ] **Step 7: Apply and run the full suite**

Run: `make apply && make test`
Expected: PASS, seven tests.

If the flow test times out, diagnose in this order before changing anything:

```bash
# 1. Did the notification register?
docker compose exec -T localstack awslocal s3api get-bucket-notification-configuration \
  --bucket ephemeral-infra-uploads
# 2. Was the function invoked at all?
docker compose exec -T localstack awslocal logs describe-log-streams \
  --log-group-name /aws/lambda/ephemeral-infra-processor
# 3. What did it say?
docker compose logs localstack --tail 100
```

The most likely failure is that `AWS_ENDPOINT_URL` is **not** injected into the Lambda environment, so the handler's boto3 clients try to reach real AWS and hang until timeout. If step 3 shows connection timeouts, add an explicit passthrough in the module's `environment.variables`:

```hcl
      AWS_ENDPOINT_URL = var.aws_endpoint_url   # add a variable, default ""
```

and set it only for the local target. Record it in `PARITY-NOTES.md` — it is exactly the kind of divergence the file exists for.

- [ ] **Step 8: Lint and commit**

```bash
make lint
git add src/ infra/ tests/
git commit -m "feat: add processor Lambda with least-privilege IAM and S3 trigger

Completes the end-to-end path: an object landing in the ingest bucket is
parsed and persisted to DynamoDB. The execution role is scoped to specific
bucket and table ARNs, asserted by a test rather than by review."
```

---

## Task 6: Continuous integration

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `make` targets from Task 2, the full test suite from Tasks 3-5.
- Produces: a green check on pull requests, and the measured timings used by Task 7.

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/ci.yml
name: ci

on:
  pull_request:
  push:
    branches: [main]

# No AWS credentials are configured anywhere in this workflow. That is the point.
env:
  AWS_ENDPOINT_URL: http://localhost:4566
  AWS_ACCESS_KEY_ID: test
  AWS_SECRET_ACCESS_KEY: test
  AWS_REGION: us-east-1

jobs:
  verify:
    runs-on: ubuntu-latest
    timeout-minutes: 15

    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.14.8
          terraform_wrapper: false

      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: Static analysis
        run: |
          terraform -chdir=infra fmt -check -recursive
          terraform -chdir=infra init -backend=false
          terraform -chdir=infra validate

      - uses: terraform-linters/setup-tflint@v4
      - name: tflint
        run: tflint --chdir=infra

      - name: checkov
        uses: bridgecrewio/checkov-action@master
        with:
          directory: infra
          quiet: true
          soft_fail: false

      - name: Start LocalStack
        run: make up

      - name: Provision
        run: make apply

      - name: Test
        run: make test

      - name: Destroy
        if: always()
        run: make destroy
```

- [ ] **Step 2: Push to a branch and open a pull request**

```bash
git checkout -b ci/github-actions
git add .github/
git commit -m "ci: provision, test, and destroy the stack on every pull request

Runs the full integration suite against LocalStack with no AWS credentials
configured on the repository."
git push -u origin ci/github-actions
gh auth switch --user leomoncada
gh pr create --title "ci: provision, test, and destroy on every PR" \
             --body "Runs the full suite against LocalStack. No repository secrets required."
gh auth switch --user xl-lmoncada
```

- [ ] **Step 3: Watch the run and fix until green**

```bash
gh run watch
```

Expected: green. Common first failures and their fixes:
- **checkov fails on the S3 bucket** wanting encryption or access logging. Either add `aws_s3_bucket_server_side_encryption_configuration` (preferred — it is a real improvement and a one-liner), or add a `.checkov.yml` skip with a written justification. Never use `soft_fail: true` to make it green; that removes the signal the check exists to give.
- **Docker-in-Docker Lambda executor unavailable.** If `LAMBDA_RUNTIME_EXECUTOR: docker` misbehaves on the runner, remove it and let LocalStack choose. Note it in `PARITY-NOTES.md`.

- [ ] **Step 4: Record the timings**

From the completed run, note the wall-clock duration of the Provision, Test, and Destroy steps. These are the measured LocalStack numbers for Task 7. Write them down now; do not reconstruct them later from memory.

- [ ] **Step 5: Merge**

```bash
gh auth switch --user leomoncada
gh pr merge --squash --delete-branch
gh auth switch --user xl-lmoncada
git checkout main && git pull
```

---

## Task 7: README, parity notes, and the measurement

The repository is only as good as its front page. Budget 45 minutes and do not rush this — it is the first and often only thing the reviewer reads.

**Files:**
- Create: `README.md`
- Modify: `PARITY-NOTES.md`

- [ ] **Step 1: Write the README**

Required structure, in this order:

1. **Title, one-sentence description, and the CI badge.** The badge markdown is
   `![ci](https://github.com/leomoncada/localstack-ephemeral-infra/actions/workflows/ci.yml/badge.svg)`
2. **The thesis**, quoted, exactly as in spec section 2.
3. **Quickstart** — the four commands, nothing else:
   ```bash
   make up       # start LocalStack
   make apply    # provision the stack
   make test     # run the suite
   make destroy  # tear it down
   ```
4. **Architecture diagram** — the ASCII diagram from spec section 5. Do not reach for a rendered image; ASCII renders everywhere and never rots.
5. **How targeting works** — the mechanism Task 1 selected, in about a paragraph, showing the actual provider block. Make the "the Terraform code contains no LocalStack-specific configuration" claim explicit if variant A won.
6. **Why not `tflocal`** — the four reasons from spec section 6.2, and the note that `tflocal` is the right choice for someone who just wants to start fast.
7. **The comparison table.**
8. **Link to `PARITY-NOTES.md`.**

- [ ] **Step 2: Write the comparison table with honest labels**

```markdown
| | LocalStack | Real AWS |
|---|---|---|
| `terraform apply` | **<measured>s** | ~<n> min *(typical, not measured here)* |
| `terraform destroy` | **<measured>s** | ~<n> min *(typical, not measured here)* |
| Full CI run | **<measured from the GitHub Actions run>** | — |
| AWS credentials in CI | none | required |
| Cost per run | $0 | metered |
```

**The labelling is not optional.** Numbers you measured are bold; numbers you did not measure are italicised and marked as estimates. If you do run a real AWS apply, replace the estimates with measurements and drop the qualifier. An invented number costs everything with this audience and buys nothing.

- [ ] **Step 3: Finish PARITY-NOTES.md**

It needs at least three real entries by now. Candidates accumulated across the build: the endpoint targeting result (Task 1), the state locking result (Task 1), `describe_continuous_backups` support (Task 3), Lambda `AWS_ENDPOINT_URL` injection (Task 5), the Lambda executor on CI runners (Task 6).

Keep the register factual. "Expected X, observed Y, worked around it with Z." No complaints, no praise, no hedging.

- [ ] **Step 4: Commit and make the repository public**

```bash
git add README.md PARITY-NOTES.md
git commit -m "docs: document the thesis, the targeting mechanism, and parity findings"
git push
gh auth switch --user leomoncada
gh repo edit leomoncada/localstack-ephemeral-infra --visibility public --accept-visibility-change-consequences
gh repo edit leomoncada/localstack-ephemeral-infra \
  --add-topic terraform --add-topic localstack --add-topic infrastructure-as-code \
  --add-topic devops --add-topic testing --add-topic github-actions
gh auth switch --user xl-lmoncada
```

Then pin it: GitHub profile, "Customize your pins".

---

## Task 8 (STRETCH): Dead-letter queue

**Only start this if Tasks 1-7 are complete, green, and pushed, and time remains.** It is severable by design.

**Files:**
- Create: `infra/modules/processor-lambda/dlq.tf`
- Modify: `tests/test_ingest_flow.py`

- [ ] **Step 1: Add the queue and the failure destination**

```hcl
# infra/modules/processor-lambda/dlq.tf
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project_name}-processor-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_lambda_function_event_invoke_config" "this" {
  function_name          = aws_lambda_function.this.function_name
  maximum_retry_attempts = 0

  destination_config {
    on_failure {
      destination = aws_sqs_queue.dlq.arn
    }
  }
}
```

Add to the permissions policy document in `main.tf`:

```hcl
  statement {
    sid       = "SendFailuresToDlq"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
  }
```

Add `output "dlq_url" { value = aws_sqs_queue.dlq.url }` to the module and surface it as a root output named `dlq_url`.

- [ ] **Step 2: Change the handler to fail rather than swallow**

Currently `handler` catches parse errors and continues. For the DLQ to receive anything the invocation must fail. Change the `except` branch to re-raise after logging, and update `test_malformed_receipt_does_not_break_the_pipeline` accordingly — a failing invocation no longer processes later records in the same batch.

- [ ] **Step 3: Add the DLQ test**

```python
def test_malformed_receipt_reaches_the_dlq(aws, tf_outputs):
    bad_id = f"bad-{uuid.uuid4()}"
    _upload(aws, tf_outputs, f"{bad_id}.json", b"{ this is not valid json")

    sqs = aws("sqs")
    deadline = time.monotonic() + POLL_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        received = sqs.receive_message(
            QueueUrl=tf_outputs["dlq_url"], WaitTimeSeconds=5
        )
        if received.get("Messages"):
            return
        time.sleep(POLL_INTERVAL_SECONDS)
    raise AssertionError(f"no message reached the DLQ within {POLL_TIMEOUT_SECONDS}s")
```

- [ ] **Step 4: Apply, test, commit**

Run: `make apply && make test`

If asynchronous destinations do not work on Community tier, **stop, revert this task, and record the finding.** That is a legitimate and interesting outcome, not a failure:

```bash
git checkout -- .
```

and add the entry to `PARITY-NOTES.md`. A documented "I tried this and Community tier does not support it" is worth more than a half-working DLQ.

---

## Self-Review

**Spec coverage:**

| Spec section | Covered by |
|---|---|
| 2 Thesis | Task 7 Step 1 (README), proven by Task 6 |
| 3 Goals: single codebase, two targets | Task 1, Task 3 Step 5 |
| 3 Goals: behavioural test suite | Tasks 3, 4, 5 |
| 3 Goals: CI on every PR, ~2 min, no secrets | Task 6 |
| 3 Goals: measured comparison | Task 6 Step 4, Task 7 Step 2 |
| 3 Goals: parity account | Task 1 Step 8, Task 7 Step 3 |
| 5 Architecture core scope | Tasks 3, 4, 5 |
| 5 Architecture stretch scope | Task 8 |
| 6.1 Targeting mechanism | Task 1 (validates), Task 3 Step 5 (implements) |
| 6.2 No tflocal | Global Constraints, Task 7 Step 1 item 6 |
| 6.3 State backend via init hook | Task 1 Step 7, Task 2 Step 1 |
| 6.4 Test strategy | Task 3 Step 2, Task 4 Step 1, Task 5 Steps 1-2 |
| 7 Repository layout | File Structure table |
| 8 CI | Task 6 |
| 9 Measurement and honesty | Task 7 Step 2 |
| 10 Risks and fallbacks | Task 1, and inline fallbacks in Tasks 3, 5, 6, 8 |
| 11 Definition of done | Tasks 6 and 7 |
| 12 Identity conventions | Global Constraints |

No gaps.

**Type consistency:** Terraform output names are used identically across tasks: `receipts_table_name`, `receipts_table_arn`, `ingest_bucket_name`, `ingest_bucket_arn`, `processor_function_name`, `processor_role_name`, `dlq_url`. Module output names (`name`, `arn`, `id`, `function_name`, `function_arn`, `role_name`) match every call site. Pytest fixtures `aws` and `tf_outputs` are defined once in Task 3 and used unchanged thereafter. The DynamoDB item shape declared in Task 5's Interfaces block matches both the handler and the assertions.

**Known deviation from the spec, deliberate:** spec section 6.3 specifies a DynamoDB lock table. Terraform 1.14.8 deprecates `dynamodb_table` in favour of `use_lockfile`, so Task 1 Step 7 tries `use_lockfile` first and falls back to DynamoDB. Spec section 6.1 proposes empty-string endpoints; Task 1 tries the strictly better pure-environment-variable approach first. Both are validations, not assumptions — the spec's intent is preserved either way.
