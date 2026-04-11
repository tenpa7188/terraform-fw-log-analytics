locals {
  name_prefix                 = "${var.project}-${var.environment}"
  log_bucket_name             = "${local.name_prefix}-${random_id.bucket_suffix.hex}"
  log_bucket_sse_algorithm    = var.environment == "prod" ? "aws:kms" : "AES256"
  log_bucket_kms_key_id       = var.environment == "prod" ? "alias/aws/s3" : null
  athena_results_prefix       = "athena-results/"
  athena_results_location     = "s3://${local.log_bucket_name}/${local.athena_results_prefix}"
  athena_workgroup_name       = "fw-log-analytics-wg"
  athena_etl_results_prefix   = "athena-results/etl/"
  athena_etl_results_location = "s3://${local.log_bucket_name}/${local.athena_etl_results_prefix}"
  athena_etl_workgroup_name   = "fw-log-analytics-etl-wg"
  parquet_etl_lambda_name     = "${local.name_prefix}-parquet-etl-runner"
  parquet_etl_lambda_runtime  = "python3.12"
  parquet_etl_lambda_memory   = 256
  parquet_etl_lambda_timeout  = 600
  parquet_etl_lookback_days   = 7
  parquet_etl_schedule_name   = "${local.name_prefix}-parquet-etl-daily"
  parquet_etl_schedule_role   = "${local.name_prefix}-parquet-etl-scheduler-role"
  parquet_etl_schedule_cron   = "cron(0 8 * * ? *)"
  parquet_etl_schedule_tz     = "Asia/Tokyo"
  parquet_etl_schedule_state  = "DISABLED"

  common_tags = merge(
    {
      project     = var.project
      environment = var.environment
      owner       = var.owner
      managed_by  = "terraform"
      repository  = "terraform-fw-log-analytics"
    },
    var.additional_tags
  )
}
