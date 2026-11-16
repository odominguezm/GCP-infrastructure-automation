# ============================================================
# Operator entrypoints for the Always Free GCP lab.
#
# The free profile has no external IP, so a deployment is three steps:
#
#   make plan          # review it: no billed resource, no "must be replaced"
#   make egress-on
#   make deploy
#   make egress-off
#
# Everything else is convenience around those commands.
# ============================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

TF := terraform
ANSIBLE := ansible-playbook
PYTHON := python3

# Extra arguments for the Ansible run, e.g. `make deploy ARGS="--tags verify"`.
ARGS ?=

# The linters are optional tooling, not a deployment dependency. Prefer a local
# install; fall back to `uvx` (already used in CI and by the project notes) so
# `make lint` works on a machine that has uv but not pip.
YAMLLINT := $(shell command -v yamllint >/dev/null 2>&1 && echo yamllint || echo "uvx yamllint")
ANSIBLE_LINT := $(shell command -v ansible-lint >/dev/null 2>&1 && echo ansible-lint || echo "uvx ansible-lint")

.PHONY: help init fmt validate plan apply destroy egress-on egress-off deploy verify tunnel fmt-check lint test dashboard

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

init: ## Download providers (no backend)
	$(TF) init -backend=false -input=false

fmt: ## Format Terraform
	$(TF) fmt -recursive

plan: ## Plan the free profile
	$(TF) plan -out=tfplan

apply: ## Apply the plan produced by `make plan`
	$(TF) apply tfplan

destroy: ## Destroy every Terraform-managed resource
	@printf 'This destroys the instance and its boot disk. Type "destroy" to continue: '; \
	read -r answer; [[ "$$answer" == "destroy" ]] || { echo "Cancelled."; exit 1; }
	$(TF) destroy

egress-on: ## Attach an ephemeral IP so apt/docker can download (no inbound port)
	$(TF) apply -auto-approve -var='enable_egress=true'
	@echo "Egress window open. Run 'make deploy', then 'make egress-off'."

egress-off: ## Remove the ephemeral IP and return to the free profile
	$(TF) apply -auto-approve -var='enable_egress=false'
	@echo "Free profile restored: the instance has no external address."

deploy: ## Run the Ansible playbook through an IAP tunnel
	./scripts/deploy.sh $(ARGS)

verify: ## Re-run only the post-deployment checks
	./scripts/deploy.sh --tags verify

tunnel: ## Open an SSH tunnel on localhost:2222 and keep it in the foreground
	@instance="$$($(TF) output -raw instance_name)"; \
	zone="$$($(TF) output -raw zone)"; \
	project="$$(gcloud config get-value project)"; \
	echo "ssh -p 2222 -i ~/.ssh/id_deploy_gcp ubuntu@127.0.0.1"; \
	gcloud compute start-iap-tunnel "$$instance" 22 \
		--local-host-port=127.0.0.1:2222 \
		--project="$$project" --zone="$$zone"

fmt-check: ## Fail if Terraform is not formatted
	$(TF) fmt -check -recursive -diff

validate: ## Static validation: Terraform, Ansible and the compose files
	$(TF) init -backend=false -input=false
	$(TF) validate
	$(ANSIBLE) site.yml --syntax-check
	GF_SECURITY_ADMIN_USER=ci GF_SECURITY_ADMIN_PASSWORD=ci-only \
		sh -c 'for s in app proxy monitoring; do docker compose -f "$$s/docker-compose.yml" config --quiet; done'

dashboard: ## Regenerate the Grafana dashboard from its generator
	$(PYTHON) monitoring/grafana/dashboards/build_dashboard.py

lint: ## yamllint + ansible-lint (local install or uvx)
	$(YAMLLINT) .
	$(ANSIBLE_LINT) site.yml

test: validate fmt-check dashboard ## Everything CI checks locally
	@git diff --exit-code -- monitoring/grafana/dashboards/node-overview.json \
		|| { echo "Dashboard drift: regenerate and commit node-overview.json."; exit 1; }
	@git diff --check
	@echo "Local gates passed."
