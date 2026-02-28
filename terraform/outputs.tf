output "project" {
  description = "Project identifier."
  value       = var.project
}

output "environment" {
  description = "Deployment environment."
  value       = var.environment
}

output "aws_region" {
  description = "AWS region in use."
  value       = var.aws_region
}

output "name_prefix" {
  description = "Common name prefix for AWS resources."
  value       = local.name_prefix
}

output "common_tags" {
  description = "Merged common tags applied via provider default_tags."
  value       = local.common_tags
}

output "log_bucket_name" {
  description = "Generated S3 bucket name for firewall logs."
  value       = local.log_bucket_name
}
