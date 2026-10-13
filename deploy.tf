// Delivers stack/ (and the units that run it) to the host on every apply that changes them. The instance ignores
// changes to user_data, so the bootstrap only runs on first boot; this SSM document runs the same script again
// through the SSM agent, and the association makes Systems Manager run it on the instance right after the apply.
locals {
  // gzip keeps the document well under its 64 KB limit
  stack_files = { for f in fileset("${path.module}/stack", "{docker-compose.yml,*.sh,*.yaml}") : f => base64gzip(file("${path.module}/stack/${f}")) }

  bootstrap = templatefile("${path.module}/bootstrap.sh", {
    files      = local.stack_files
    ssm_prefix = var.ssm_prefix
  })
}

resource "aws_ssm_document" "deploy_stack" {
  name            = "${local.name_prefix}-deploy-stack"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install the stack/ folder of ${local.name_prefix} and restart the stack"
    parameters = {
      // Not used by the script: its value changes with the files, so updating the association runs the document.
      ContentHash = { type = "String", default = "" }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deployStack"
      inputs = {
        timeoutSeconds = "600"
        runCommand     = split("\n", "#!/bin/bash\nset -euo pipefail\n${local.bootstrap}")
      }
    }]
  })

  tags = merge(local.tags, { Name = "${local.name_prefix}-deploy-stack" })
}

resource "aws_ssm_association" "deploy_stack" {
  name             = aws_ssm_document.deploy_stack.name
  association_name = "${local.name_prefix}-deploy-stack"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.observability.id]
  }

  parameters = { ContentHash = sha256(local.bootstrap) }

  // Fail the apply (and so the CD run) if the deployment fails on the host.
  wait_for_success_timeout_seconds = 300
}
