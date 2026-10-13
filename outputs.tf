output "instance_id" {
  description = "ID of the observability instance (target of the SSM sessions for Grafana)"
  value       = aws_instance.observability.id
}

output "private_ip" {
  description = "Private IP of the observability instance"
  value       = aws_instance.observability.private_ip
}

output "otlp_endpoint" {
  description = "OTLP gRPC endpoint the games send telemetry to (OTEL_EXPORTER_OTLP_ENDPOINT)"
  value       = "http://${aws_instance.observability.private_ip}:4317"
}

output "telemetry_bucket" {
  description = "S3 bucket of Loki (prefix loki/) and Tempo (prefix tempo/)"
  value       = aws_s3_bucket.telemetry.id
}

output "security_group_id" {
  description = "Security group of the observability instance"
  value       = aws_security_group.observability.id
}
