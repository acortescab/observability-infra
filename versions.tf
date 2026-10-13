terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0, < 6.65.0"
    }
  }

  // Remote state in S3. Same bucket as the other stacks, its own key. Override the bucket at init if needed:
  //   terraform init -backend-config="bucket=<bucket>"
  backend "s3" {
    bucket  = "coika-auth-tfstate-s3-290294660813-eu-west-1-an"
    key     = "observability/terraform.tfstate"
    region  = "eu-west-1"
    encrypt = true

    // Native S3 state locking (a .tflock object next to the state). Needs Terraform >= 1.10.
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}
