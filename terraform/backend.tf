# =====================================================================
# STATE BACKEND — S3 remote state with native locking
# ---------------------------------------------------------------------
# This file is PUBLISH-SAFE: it contains no bucket name and no account id.
# The sensitive value (the state bucket name) is supplied at init time via
# a gitignored `backend.hcl` — Terraform's "partial backend config" pattern.
#
# Why partial config? The `backend "s3"` block is read BEFORE variables are
# initialized, so `var.*` cannot be used inside it. Partial config is the
# idiomatic way to keep environment-specific / private values out of VCS.
#
# Locking: `use_lockfile = true` uses S3-native conditional-write locking
# (Terraform >= 1.11). No DynamoDB lock table is required.
#
# FIRST-TIME SETUP:
#   1. Create (or reuse) an S3 bucket for Terraform state.
#   2. cp backend.hcl.example backend.hcl  and fill in that bucket name.
#   3. terraform init -backend-config=backend.hcl
# =====================================================================

terraform {
  backend "s3" {
    # bucket  -> supplied via backend.hcl (gitignored)
    key          = "iot-cold-chain-monitoring/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
