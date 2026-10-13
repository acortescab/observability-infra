variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Project tag value"
  type        = string
  default     = "observability"
}

variable "instance_name" {
  description = "Name tag for the observability EC2 instance"
  type        = string
  default     = "observability-instance"
}

variable "subnet_id" {
  description = "Private subnet that hosts the instance. It needs outbound internet (NAT) for apt and Docker images, and must be in the VPC of the clients that send telemetry (for example the private_subnet_id output of the game's infrastructure stack)"
  type        = string
}

variable "allowed_client_security_group_ids" {
  description = "Security groups (same VPC) whose members may send OTLP to the Collector, one per game host (for example the security_group_id output of each game's infrastructure stack)"
  type        = list(string)
  default     = []
}

variable "allowed_client_cidrs" {
  description = "CIDR blocks that may send OTLP to the Collector (for example a peered VPC). Prefer allowed_client_security_group_ids inside one VPC"
  type        = list(string)
  default     = []
}

variable "otlp_endpoint_parameters" {
  description = "SSM parameter names (String) that Terraform sets to the OTLP endpoint of this stack, so each game's deploy picks it up (for example [\"/coika/auth_service/app/OTEL_EXPORTER_OTLP_ENDPOINT\"]). Delete any parameter created by hand first"
  type        = list(string)
  default     = []
}

variable "ssm_prefix" {
  description = "SSM Parameter Store path prefix the instance reads its secrets from (GRAFANA_PASSWORD)"
  type        = string
  default     = "/observability"
}

variable "instance_type" {
  description = "EC2 instance type (Collector, Prometheus, Loki, Tempo and Grafana need about 1.5 GiB of memory together; grow it as games are added)"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB (OS and boot only: the telemetry lives on the data volume)"
  type        = number
  default     = 12

  validation {
    condition     = var.root_volume_size >= 8
    error_message = "root_volume_size must be at least 8 GiB (the Ubuntu AMI size)."
  }
}

variable "root_volume_type" {
  description = "Root EBS volume type"
  type        = string
  default     = "gp3"
}

variable "data_volume_size" {
  description = "Data EBS volume size in GiB (mounted on /var/lib/docker: Prometheus, Loki, Tempo and Grafana data). It can grow online but never shrink"
  type        = number
  default     = 30

  validation {
    condition     = var.data_volume_size >= 10
    error_message = "data_volume_size must be at least 10 GiB."
  }
}

variable "data_volume_type" {
  description = "Data EBS volume type"
  type        = string
  default     = "gp3"
}

variable "snapshot_retention_days" {
  description = "Number of daily EBS snapshots of the root and data disks to keep"
  type        = number
  default     = 7
}

variable "ami_architecture" {
  description = "Architecture for Ubuntu AMI lookup (x86_64 or arm64)"
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.ami_architecture)
    error_message = "ami_architecture must be x86_64 or arm64."
  }
}

variable "ubuntu_lts_version" {
  description = "Ubuntu LTS version for AMI lookup (for example: 24.04 or 22.04)"
  type        = string
  default     = "24.04"
}

variable "extra_tags" {
  description = "Additional tags to merge into all resources"
  type        = map(string)
  default     = {}
}
