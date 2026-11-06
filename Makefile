# Cold-Chain Logistics Monitoring — Makefile
# All targets run against AWS SSO profile `training` in eu-central-1.
# Ensure a live session first:  aws sso login --profile training

export AWS_PROFILE ?= training
TF_DIR := terraform

.PHONY: help init plan apply deploy destroy fmt validate lint

help:
	@echo "Targets:"
	@echo "  init      terraform init (partial backend via backend.hcl)"
	@echo "  plan      terraform plan"
	@echo "  apply     terraform apply (alias: deploy)"
	@echo "  destroy   terraform destroy"
	@echo "  fmt       terraform fmt -recursive"
	@echo "  validate  terraform validate"
	@echo "  lint      ruff check on Python (devices + lambda)"

init:
	cd $(TF_DIR) && terraform init -backend-config=backend.hcl

plan: init
	cd $(TF_DIR) && terraform plan

apply deploy: init flink-package
	cd $(TF_DIR) && terraform apply

destroy:
	cd $(TF_DIR) && terraform destroy

fmt:
	cd $(TF_DIR) && terraform fmt -recursive

validate: init
	cd $(TF_DIR) && terraform validate

# Fetch the version-pinned, checksum-verified Flink Kinesis connector JAR into
# flink/lib/ (gitignored). Required before the Flink app zip is built.
.PHONY: flink-package
flink-package:
	bash scripts/fetch-flink-deps.sh

lint:
	ruff check devices lambda 2>/dev/null || echo "(no Python yet)"

# --- Managed Flink cost control ------------------------------------------
# The Flink app bills per KPU WHILE RUNNING (~EUR 0.11/hr). It is created
# stopped; start it only to demo, and STOP it when done.
.PHONY: flink-start flink-stop flink-status
FLINK_APP := $(shell cd $(TF_DIR) && terraform output -raw flink_application_name 2>/dev/null)

flink-start:
	@echo "Starting Flink app $(FLINK_APP) — this BILLS until you run 'make flink-stop'."
	aws kinesisanalyticsv2 start-application --application-name $(FLINK_APP)

flink-stop:
	aws kinesisanalyticsv2 stop-application --application-name $(FLINK_APP)
	@echo "Stopped $(FLINK_APP). No further KPU charges."

flink-status:
	@aws kinesisanalyticsv2 describe-application --application-name $(FLINK_APP) \
		--query 'ApplicationDetail.ApplicationStatus' --output text

# --- Simulated fleet (ECS Fargate, one task == one truck) ----------------
# `make fleet-build` once to push the image; `make fleet SIZE=20` to run 20
# trucks; `make fleet-stop` to scale to 0 (stops all cost). Each task self-
# registers as a truck-<hash> thing on start and deregisters on stop.
.PHONY: fleet-build fleet fleet-stop fleet-status
REGION      := eu-central-1
FLEET_ECR     = $(shell cd $(TF_DIR) && terraform output -raw fleet_ecr_repository_url 2>/dev/null)
FLEET_CLUSTER = $(shell cd $(TF_DIR) && terraform output -raw fleet_ecs_cluster 2>/dev/null)
FLEET_SERVICE = $(shell cd $(TF_DIR) && terraform output -raw fleet_ecs_service 2>/dev/null)
SIZE ?= 20

fleet-build:
	@echo "Building + pushing simulator image to $(FLEET_ECR)"
	aws ecr get-login-password --region $(REGION) \
		| docker login --username AWS --password-stdin $(firstword $(subst /, ,$(FLEET_ECR)))
	docker build -t $(FLEET_ECR):latest devices/simulator
	docker push $(FLEET_ECR):latest

fleet:
	@echo "Scaling the fleet to $(SIZE) trucks — this BILLS Fargate until 'make fleet-stop'."
	aws ecs update-service --cluster $(FLEET_CLUSTER) --service $(FLEET_SERVICE) \
		--desired-count $(SIZE) --no-cli-pager >/dev/null
	@echo "Requested $(SIZE) tasks. Watch them register:  make fleet-status"

fleet-stop:
	aws ecs update-service --cluster $(FLEET_CLUSTER) --service $(FLEET_SERVICE) \
		--desired-count 0 --no-cli-pager >/dev/null
	@echo "Scaled the fleet to 0. Tasks deregister their things on stop."

fleet-status:
	@aws ecs describe-services --cluster $(FLEET_CLUSTER) --services $(FLEET_SERVICE) \
		--query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}' \
		--output table
