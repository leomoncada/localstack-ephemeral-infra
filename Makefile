SHELL := /usr/bin/env bash
TF     := terraform -chdir=infra
VENV   := .venv

export AWS_ENDPOINT_URL      ?= http://localhost:4566
export AWS_ACCESS_KEY_ID     ?= test
export AWS_SECRET_ACCESS_KEY ?= test
export AWS_REGION            ?= us-east-1

# Terraform does NOT honor the AWS_ENDPOINT_URL env var: with the env var
# alone and no provider-level endpoint config, `terraform apply` hung for
# minutes and the request never reached LocalStack (see PARITY-NOTES.md,
# "Endpoint targeting"). LocalStack is targeted by this variable instead.
# Defined once so the apply/destroy call sites cannot drift apart. Not used
# for fmt/validate/init: those do not accept -var; init takes its LocalStack
# config through -backend-config.
TF_LOCALSTACK_VAR := -var aws_endpoint_url=$(AWS_ENDPOINT_URL)

# The exports above are LocalStack's. `env -u` removes them for the real-AWS
# targets so terraform and pytest fall through to the ambient AWS credential
# chain -- unsetting rather than blanking, because botocore treats an empty
# AWS_ACCESS_KEY_ID as a credential rather than as an absent one. AWS_REGION
# stays: it is a plain region name, not a LocalStack artefact.
REAL_AWS := env -u AWS_ENDPOINT_URL -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY

.PHONY: up down init apply destroy test lint clean init-aws apply-aws test-aws destroy-aws

up: ## Start LocalStack and wait until the Terraform state backend exists
	# `--wait` blocks on the compose healthcheck, which polls for the tfstate
	# bucket rather than for /_localstack/health. Readiness is defined in one
	# place (docker-compose.yml) so this target and the container cannot
	# disagree about what "ready" means.
	docker compose up -d --wait
	@echo "localstack ready"

down: ## Stop LocalStack and discard all state
	docker compose down -v

init: ## Initialise Terraform against the local backend
	$(TF) init -reconfigure -backend-config=env/local.backend.hcl

apply: init ## Provision the stack against LocalStack
	$(TF) apply $(TF_LOCALSTACK_VAR) -auto-approve

destroy: ## Tear the stack down in LocalStack
	$(TF) destroy $(TF_LOCALSTACK_VAR) -auto-approve

# --- real AWS ------------------------------------------------------------
# The other half of the thesis. Same modules, same suite, no -var: leaving
# aws_endpoint_url at its default "" is what selects real AWS. The only other
# difference is the backend config file.
#
# Terraform keeps one initialised working directory, so init and init-aws are
# mutually exclusive -- switching targets means re-running the other one.
#
# NOTHING BELOW HAS EVER BEEN RUN against a real account. It is here because
# the alternative is a thesis with no invocation, not because it is verified.

init-aws: ## Initialise Terraform against the real-AWS backend
	$(REAL_AWS) $(TF) init -reconfigure -backend-config=env/aws.backend.hcl

apply-aws: init-aws ## Provision the stack against real AWS
	$(REAL_AWS) $(TF) apply -auto-approve

test-aws: $(VENV) ## Run the same suite against real AWS
	$(REAL_AWS) $(VENV)/bin/pytest tests -v

destroy-aws: ## Tear the stack down in real AWS
	$(REAL_AWS) $(TF) destroy -auto-approve
# -------------------------------------------------------------------------

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
	# --init installs the AWS ruleset declared in .tflint.hcl; without it
	# tflint runs with only its bundled terraform ruleset and no aws_* rule
	# ever fires. --recursive is what makes it descend into infra/modules/*,
	# where every AWS resource in this stack lives, and TFLINT_CONFIG_FILE is
	# what carries the ruleset down with it.
	TFLINT_CONFIG_FILE=$(CURDIR)/.tflint.hcl tflint --chdir=infra --recursive --init
	TFLINT_CONFIG_FILE=$(CURDIR)/.tflint.hcl tflint --chdir=infra --recursive
	checkov -d infra --quiet --compact

clean: down ## Remove all local artefacts
	# infra/.terraform.lock.hcl is deliberately NOT removed: it is committed,
	# so that every run resolves the same provider builds.
	rm -rf $(VENV) infra/.terraform infra/modules/processor-lambda/.build
