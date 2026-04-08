resource "aws_lambda_function" "parquet_etl_runner" {
  filename         = "${path.module}/artifacts/parquet_etl_runner.zip"
  function_name    = local.parquet_etl_lambda_name
  role             = aws_iam_role.parquet_etl.arn
  handler          = "app.handler"
  runtime          = local.parquet_etl_lambda_runtime
  memory_size      = local.parquet_etl_lambda_memory
  timeout          = local.parquet_etl_lambda_timeout
  source_code_hash = filebase64sha256("${path.module}/artifacts/parquet_etl_runner.zip")
  description      = "Lambda for Athena-based Parquet ETL orchestration."

  environment {
    variables = {
      ATHENA_ETL_WORKGROUP_NAME = aws_athena_workgroup.fw_log_analytics_etl.name
      ATHENA_RESULTS_PREFIX     = local.athena_etl_results_prefix
      GLUE_DATABASE_NAME        = aws_glue_catalog_database.fw_log_analytics.name
      LOG_BUCKET_NAME           = aws_s3_bucket.log_bucket.bucket
      LOOKBACK_DAYS             = tostring(local.parquet_etl_lookback_days)
      PARQUET_PREFIX_ROOT       = "fortigate-parquet"
      PARQUET_TABLE_NAME        = aws_glue_catalog_table.fortigate_logs_parquet.name
      RAW_PREFIX_ROOT           = "fortigate"
      RAW_TABLE_NAME            = aws_glue_catalog_table.fortigate_logs.name
    }
  }

  depends_on = [aws_iam_role_policy.parquet_etl_access]
}
