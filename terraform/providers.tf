provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.name_prefix
      ManagedBy = "terraform"
      Env       = var.environment
    }
  }
}

# awscc provider shares the same region/profile via the standard AWS credential chain.
# Used for IoT resources that are only exposed on the Cloud Control provider.
provider "awscc" {
  region  = var.region
  profile = var.aws_profile
}
