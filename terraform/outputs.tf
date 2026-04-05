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

output "athena_results_prefix" {
  description = "Prefix used for Athena query result objects."
  value       = local.athena_results_prefix
}

output "athena_results_location" {
  description = "S3 location used for Athena query results."
  value       = local.athena_results_location
}

output "athena_etl_results_prefix" {
  description = "Prefix used for Athena ETL query result objects."
  value       = local.athena_etl_results_prefix
}

output "athena_etl_results_location" {
  description = "S3 location used for Athena ETL query results."
  value       = local.athena_etl_results_location
}

output "athena_workgroup_name" {
  description = "Standard Athena workgroup name for this project."
  value       = aws_athena_workgroup.fw_log_analytics.name
}

output "athena_workgroup_arn" {
  description = "ARN of the standard Athena workgroup."
  value       = aws_athena_workgroup.fw_log_analytics.arn
}

output "athena_workgroup_state" {
  description = "Current state of the standard Athena workgroup."
  value       = aws_athena_workgroup.fw_log_analytics.state
}

output "athena_etl_workgroup_name" {
  description = "Dedicated Athena workgroup name for Parquet ETL queries."
  value       = aws_athena_workgroup.fw_log_analytics_etl.name
}

output "athena_etl_workgroup_arn" {
  description = "ARN of the dedicated Athena ETL workgroup."
  value       = aws_athena_workgroup.fw_log_analytics_etl.arn
}

output "athena_etl_workgroup_state" {
  description = "Current state of the dedicated Athena ETL workgroup."
  value       = aws_athena_workgroup.fw_log_analytics_etl.state
}

output "athena_bytes_scanned_cutoff_per_query" {
  description = "Configured bytes scanned cutoff per Athena query."
  value       = var.athena_bytes_scanned_cutoff_per_query
}

output "glue_database_name" {
  description = "Glue Data Catalog database name for Athena queries."
  value       = aws_glue_catalog_database.fw_log_analytics.name
}

output "glue_table_name" {
  description = "Glue Data Catalog table name for firewall logs."
  value       = aws_glue_catalog_table.fortigate_logs.name
}

output "glue_table_location" {
  description = "S3 location referenced by the Glue firewall log table."
  value       = "s3://${aws_s3_bucket.log_bucket.bucket}/fortigate/"
}

output "glue_parquet_table_name" {
  description = "Glue Data Catalog table name for Parquet-optimized firewall logs."
  value       = aws_glue_catalog_table.fortigate_logs_parquet.name
}

output "glue_parquet_table_location" {
  description = "S3 location referenced by the Glue Parquet firewall log table."
  value       = "s3://${aws_s3_bucket.log_bucket.bucket}/fortigate-parquet/"
}

output "iam_ingest_role_name" {
  description = "IAM role name for log ingestion operations."
  value       = aws_iam_role.ingest.name
}

output "iam_ingest_role_arn" {
  description = "IAM role ARN for log ingestion operations."
  value       = aws_iam_role.ingest.arn
}

output "iam_ingest_user_name" {
  description = "Dedicated IAM user name for assuming the ingest role."
  value       = try(aws_iam_user.ingest[0].name, null)
}

output "iam_ingest_user_arn" {
  description = "Dedicated IAM user ARN for assuming the ingest role."
  value       = try(aws_iam_user.ingest[0].arn, null)
}

output "iam_ingest_user_access_key_id" {
  description = "Access key ID for the dedicated ingest IAM user when access key creation is enabled."
  value       = try(aws_iam_access_key.ingest[0].id, null)
}

output "iam_ingest_user_secret_access_key" {
  description = "Secret access key for the dedicated ingest IAM user when access key creation is enabled."
  value       = try(aws_iam_access_key.ingest[0].secret, null)
  sensitive   = true
}

output "iam_analyst_role_name" {
  description = "IAM role name for Athena analyst operations."
  value       = aws_iam_role.analyst.name
}

output "iam_analyst_role_arn" {
  description = "IAM role ARN for Athena analyst operations."
  value       = aws_iam_role.analyst.arn
}

output "iam_parquet_etl_role_name" {
  description = "IAM role name for Athena-based Parquet ETL operations."
  value       = aws_iam_role.parquet_etl.name
}

output "iam_parquet_etl_role_arn" {
  description = "IAM role ARN for Athena-based Parquet ETL operations."
  value       = aws_iam_role.parquet_etl.arn
}

output "iam_parquet_etl_scheduler_role_arn" {
  description = "IAM role ARN for EventBridge Scheduler to invoke the Parquet ETL Lambda."
  value       = aws_iam_role.parquet_etl_scheduler.arn
}

output "iam_terraform_role_name" {
  description = "IAM role name for Terraform infrastructure operations."
  value       = aws_iam_role.terraform.name
}

output "iam_terraform_role_arn" {
  description = "IAM role ARN for Terraform infrastructure operations."
  value       = aws_iam_role.terraform.arn
}

output "parquet_etl_lambda_function_name" {
  description = "Lambda function name for Athena-based Parquet ETL orchestration."
  value       = aws_lambda_function.parquet_etl_runner.function_name
}

output "parquet_etl_lambda_function_arn" {
  description = "Lambda function ARN for Athena-based Parquet ETL orchestration."
  value       = aws_lambda_function.parquet_etl_runner.arn
}

output "parquet_etl_schedule_name" {
  description = "EventBridge Scheduler name for daily Parquet ETL execution."
  value       = aws_scheduler_schedule.parquet_etl_daily.name
}
