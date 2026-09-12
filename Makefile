SHELL := /usr/bin/env bash
TF     := terraform -chdir=infra
VENV   := .venv

export AWS_ENDPOINT_URL      ?= http://localhost:4566
export AWS_ACCESS_KEY_ID     ?= test
export AWS_SECRET_ACCESS_KEY ?= test
export AWS_REGION            ?= us-east-1

# Terraform does NOT honor the AWS_ENDPOINT_URL env var (Task 1 spike: with
# the env var alone and no provider-level endpoint config, `terraform apply`
# hung for minutes and never reached LocalStack). It is targeted by this
# variable instead. Defined once so the apply/destroy call sites cannot
# drift apart. Not used for fmt/validate/init: those do not accept -var;
# init takes its LocalStack config through -backend-config.
TF_LOCALSTACK_VAR := -var aws_endpoint_url=$(AWS_ENDPOINT_URL)

.PHONY: up down init apply destroy test lint clean

up: ## Start LocalStack and wait for it to be healthy
	docker compose up -d
	@deadline=$$((SECONDS + 120)); \
	until curl -sf $(AWS_ENDPOINT_URL)/_localstack/health >/dev/null; do \
		if [ $$SECONDS -ge $$deadline ]; then echo "timed out waiting for localstack" >&2; exit 1; fi; \
		sleep 2; \
	done
	@echo "localstack ready"

down: ## Stop LocalStack and discard all state
	docker compose down -v

init: ## Initialise Terraform against the local backend
	$(TF) init -reconfigure -backend-config=env/local.backend.hcl

apply: init ## Provision the stack against LocalStack
	$(TF) apply $(TF_LOCALSTACK_VAR) -auto-approve

destroy: ## Tear the stack down in LocalStack
	$(TF) destroy $(TF_LOCALSTACK_VAR) -auto-approve

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
