// IAM roles that GitHub Actions assumes through OIDC: one read-only to plan pull requests (ci.yml) and one to apply
// after the approval of the `production` environment (cd.yml). Same convention as the other stacks of the account.
//
// Chicken and egg: these roles are applied by hand the first time, from a workstation, because the pipeline needs
// them to exist. Afterwards the apply role can change everything in this stack except these roles and the boundary
// (see the IAM statements below).
locals {
  ci_name          = "observability-ci"
  ci_boundary_name = "${local.ci_name}-boundary"
  // Built from the name, not from the policy resource: the boundary document denies editing itself.
  ci_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${local.ci_boundary_name}"

  account_id = data.aws_caller_identity.current.account_id

  tfstate_bucket_arn = "arn:aws:s3:::${var.tfstate_bucket}"
  // Both the state and its lock file (.tflock) live under this key prefix.
  tfstate_objects_arn = "${local.tfstate_bucket_arn}/observability/*"

  // Built from the name, not from the bucket resource, so the roles do not depend on the bucket.
  telemetry_bucket_arn = "arn:aws:s3:::${local.telemetry_bucket}"

  // The only parameters Terraform manages. The CI roles never touch the others under the prefix (GRAFANA_PASSWORD).
  ci_ssm_parameter_arns = concat(
    ["arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_prefix}/TELEMETRY_BUCKET"],
    [for name in var.otlp_endpoint_parameters : "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${name}"],
  )

  ci_ssm_document_arn    = "arn:aws:ssm:${var.aws_region}:${local.account_id}:document/${local.name_prefix}-deploy-stack"
  ci_ssm_association_arn = "arn:aws:ssm:${var.aws_region}:${local.account_id}:association/*"

  // Roles and instance profile of the host. The CI roles are not in this list, so they cannot change themselves.
  host_role_arns = [
    "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*",
    "arn:aws:iam::${local.account_id}:instance-profile/${local.name_prefix}-*",
  ]
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "ci_assume_role" {
  // plan: the PR plan of ci.yml (environment `plan`) and the plan job of cd.yml (push to main, no environment, so its
  // subject is the branch ref). apply: only the apply job of cd.yml, after the approval of `production`. The apply role
  // never trusts the branch ref: that would give it to any workflow run on main without the approval.
  for_each = {
    plan = {
      subjects = [
        "${var.github_oidc_subject}:environment:plan",
        "${var.github_oidc_subject}:ref:refs/heads/main",
      ]
      pin_workflow = false
    }
    apply = {
      subjects     = ["${var.github_oidc_subject}:environment:production"]
      pin_workflow = true
    }
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value.subjects
    }

    // The subject of an environment job carries no branch: without these two, the workflow of any branch that targets
    // `production` would get the apply role once a reviewer approves it.
    dynamic "condition" {
      for_each = each.value.pin_workflow ? {
        ref              = "refs/heads/main"
        job_workflow_ref = "${var.github_repository}/.github/workflows/cd.yml@refs/heads/main"
      } : {}

      content {
        test     = "StringEquals"
        variable = "token.actions.githubusercontent.com:${condition.key}"
        values   = [condition.value]
      }
    }
  }
}

// What the apply role may do. The boundary below starts from this same document, so the role can never be granted
// more than its own policy plus what the host roles need at runtime.
data "aws_iam_policy_document" "ci_apply" {
  statement {
    sid       = "TerraformState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.tfstate_objects_arn]
  }

  statement {
    sid       = "TerraformStateList"
    actions   = ["s3:ListBucket"]
    resources = [local.tfstate_bucket_arn]
  }

  statement {
    sid = "Ec2"
    actions = [
      "ec2:Describe*",
      "ec2:*Instance*",
      "ec2:*Volume*",
      "ec2:*SecurityGroup*",
      "ec2:*Tags",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid       = "IamHostRolesAndProfile"
    actions   = ["iam:*Role*", "iam:*InstanceProfile*"]
    resources = local.host_role_arns
  }

  statement {
    sid       = "IamRead"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  statement {
    sid       = "TelemetryBucket"
    actions   = ["s3:*"]
    resources = [local.telemetry_bucket_arn, "${local.telemetry_bucket_arn}/*"]
  }

  statement {
    sid       = "SsmManagedParameters"
    actions   = ["ssm:*Parameter*", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource"]
    resources = local.ci_ssm_parameter_arns
  }

  statement {
    sid       = "SsmDescribeParameters"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  // The document and association that deliver stack/ to the host (deploy.tf).
  statement {
    sid = "SsmDeployDocument"
    actions = [
      "ssm:CreateDocument",
      "ssm:UpdateDocument",
      "ssm:UpdateDocumentDefaultVersion",
      "ssm:DeleteDocument",
      "ssm:DescribeDocument",
      "ssm:DescribeDocumentPermission",
      "ssm:GetDocument",
      "ssm:ListDocumentVersions",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:ListTagsForResource",
    ]
    resources = [local.ci_ssm_document_arn]
  }

  statement {
    sid       = "SsmDeployAssociation"
    actions   = ["ssm:CreateAssociation", "ssm:UpdateAssociation", "ssm:DeleteAssociation"]
    resources = [local.ci_ssm_document_arn, local.ci_ssm_association_arn, "arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*"]
  }

  // The provider reads and writes the tags of the association (the document has its own statement above).
  statement {
    sid       = "SsmAssociationTags"
    actions   = ["ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource"]
    resources = [local.ci_ssm_association_arn]
  }

  statement {
    sid = "SsmAssociationRead"
    actions = [
      "ssm:DescribeAssociation",
      "ssm:DescribeAssociationExecutions",
      "ssm:DescribeInstanceAssociationsStatus",
      "ssm:DescribeInstanceInformation",
      "ssm:ListAssociations",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "Dlm"
    actions   = ["dlm:*"]
    resources = ["*"]
  }

  statement {
    sid = "CloudWatchAlarms"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "cloudwatch:ListTagsForResource",
    ]
    resources = ["arn:aws:cloudwatch:${var.aws_region}:${local.account_id}:alarm:${local.name_prefix}-*"]
  }

  statement {
    sid       = "CloudWatchDescribeAlarms"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = ["*"]
  }
}

// The ceiling for the CI roles and the host roles. It adds what the host roles need at runtime (Session Manager,
// reading its parameters, the DLM snapshots) and the guards that keep the ceiling in place.
data "aws_iam_policy_document" "ci_boundary" {
  source_policy_documents = [data.aws_iam_policy_document.ci_apply.json]

  statement {
    sid = "HostSessionManager"
    actions = [
      "ssm:DescribeAssociation",
      "ssm:DescribeDocument",
      "ssm:GetDeployablePatchSnapshotForInstance",
      "ssm:GetDocument",
      "ssm:GetManifest",
      "ssm:ListAssociations",
      "ssm:ListInstanceAssociations",
      "ssm:PutComplianceItems",
      "ssm:PutConfigurePackageResult",
      "ssm:PutInventory",
      "ssm:UpdateAssociationStatus",
      "ssm:UpdateInstanceAssociationStatus",
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }

  // The host reads its own parameters (GRAFANA_PASSWORD, TELEMETRY_BUCKET). The CI roles are not granted this.
  statement {
    sid       = "HostReadParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [local.ssm_arn_base, "${local.ssm_arn_base}/*"]
  }

  // Decrypting the SecureString parameters with the AWS managed key, only through Systems Manager.
  statement {
    sid       = "HostDecryptParameters"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }

  // The Data Lifecycle Manager role takes and prunes the daily snapshots.
  statement {
    sid       = "DlmSnapshots"
    actions   = ["ec2:*Snapshot*", "ec2:*Tags", "ec2:Describe*"]
    resources = ["*"]
  }

  statement {
    sid       = "DenyRoleWithoutBoundary"
    effect    = "Deny"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.ci_boundary_arn]
    }
  }

  statement {
    sid       = "DenyRemoveBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyEditBoundary"
    effect = "Deny"
    actions = [
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = [local.ci_boundary_arn]
  }
}

resource "aws_iam_policy" "ci_boundary" {
  name        = local.ci_boundary_name
  description = "Permissions boundary of the CI roles and the host roles of ${local.name_prefix}"
  policy      = data.aws_iam_policy_document.ci_boundary.json

  tags = merge(local.tags, { Name = local.ci_boundary_name })
}

// Plan role: read only. It sees the infrastructure and the state, never the Grafana password, and it cannot write
// the state. It can only write the lock file, because the plan job of cd.yml takes the lock (the PR plan of ci.yml
// runs with -lock=false).
data "aws_iam_policy_document" "ci_plan" {
  statement {
    sid       = "TerraformStateRead"
    actions   = ["s3:GetObject"]
    resources = [local.tfstate_objects_arn]
  }

  statement {
    sid       = "TerraformStateLock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.tfstate_bucket_arn}/observability/*.tflock"]
  }

  statement {
    sid       = "TerraformStateList"
    actions   = ["s3:ListBucket"]
    resources = [local.tfstate_bucket_arn]
  }

  statement {
    sid       = "Ec2Read"
    actions   = ["ec2:Describe*"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid       = "IamRead"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  statement {
    sid       = "TelemetryBucketRead"
    actions   = ["s3:Get*", "s3:List*"]
    resources = [local.telemetry_bucket_arn]
  }

  statement {
    sid       = "SsmManagedParametersRead"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:ListTagsForResource"]
    resources = local.ci_ssm_parameter_arns
  }

  statement {
    sid       = "SsmDescribeParameters"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    sid       = "SsmDeployRead"
    actions   = ["ssm:DescribeDocument", "ssm:DescribeDocumentPermission", "ssm:GetDocument", "ssm:ListDocumentVersions", "ssm:ListTagsForResource"]
    resources = [local.ci_ssm_document_arn]
  }

  statement {
    sid = "SsmAssociationRead"
    actions = [
      "ssm:DescribeAssociation",
      "ssm:DescribeAssociationExecutions",
      "ssm:DescribeInstanceAssociationsStatus",
      "ssm:DescribeInstanceInformation",
      "ssm:ListAssociations",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "SsmAssociationTagsRead"
    actions   = ["ssm:ListTagsForResource"]
    resources = [local.ci_ssm_association_arn]
  }

  statement {
    sid       = "DlmRead"
    actions   = ["dlm:Get*", "dlm:List*"]
    resources = ["*"]
  }

  statement {
    sid       = "CloudWatchAlarmsRead"
    actions   = ["cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "ci_plan" {
  name                 = "${local.ci_name}_plan-role"
  assume_role_policy   = data.aws_iam_policy_document.ci_assume_role["plan"].json
  permissions_boundary = aws_iam_policy.ci_boundary.arn
  max_session_duration = 3600

  tags = merge(local.tags, { Name = "${local.ci_name}_plan-role" })
}

resource "aws_iam_role_policy" "ci_plan" {
  name   = "terraform-plan"
  role   = aws_iam_role.ci_plan.id
  policy = data.aws_iam_policy_document.ci_plan.json
}

resource "aws_iam_role" "ci_apply" {
  name                 = "${local.ci_name}_apply-role"
  assume_role_policy   = data.aws_iam_policy_document.ci_assume_role["apply"].json
  permissions_boundary = aws_iam_policy.ci_boundary.arn
  max_session_duration = 3600

  tags = merge(local.tags, { Name = "${local.ci_name}_apply-role" })
}

resource "aws_iam_role_policy" "ci_apply" {
  name   = "terraform-apply"
  role   = aws_iam_role.ci_apply.id
  policy = data.aws_iam_policy_document.ci_apply.json
}
