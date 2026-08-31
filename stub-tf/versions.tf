terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # No backend block on purpose.
  #
  # docs/release-process.md section 7 specifies an S3 backend with DynamoDB
  # locking, but the bucket, the table and the account are all site-specific.
  # Committing a half-real backend here would make `terraform init` fail in a
  # way that looks like a bug in this module rather than a missing decision.
  #
  # Supply one at init time:
  #   terraform init \
  #     -backend-config="bucket=<state-bucket>" \
  #     -backend-config="key=awuca/<env>/terraform.tfstate" \
  #     -backend-config="region=<region>" \
  #     -backend-config="dynamodb_table=<lock-table>"
  #
  # ...after adding `backend "s3" {}` to this block.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# CloudFront-adjacent resources (ACM certificates for the distribution) are
# only available in us-east-1, regardless of where everything else lives.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.tags
  }
}
