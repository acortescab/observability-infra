// Built-in Terraform rules: unused variables and outputs, missing types and descriptions, unpinned modules...
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

// AWS rules: invalid instance types, AMI and parameter values that `terraform validate` accepts and AWS rejects.
// Keep the version in step with the tflint version in .github/workflows/ci.yml.
plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
