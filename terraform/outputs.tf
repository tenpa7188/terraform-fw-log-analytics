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

output "log_bucket_arn" {
  description = "ARN of the firewall log S3 bucket."
  value       = aws_s3_bucket.log_bucket.arn
}

output "log_bucket_sse_algorithm" {
  description = "Default server-side encryption algorithm for the firewall log bucket."
  value       = local.log_bucket_sse_algorithm
}

output "log_bucket_kms_key_id" {
  description = "KMS key identifier used when the firewall log bucket defaults to SSE-KMS."
  value       = local.log_bucket_kms_key_id
}

output "log_bucket_versioning_status" {
  description = "Versioning status for the firewall log bucket."
  value       = aws_s3_bucket_versioning.log_bucket.versioning_configuration[0].status
}
