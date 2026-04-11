data "aws_iam_policy_document" "parquet_etl_scheduler_assume_role" {
  statement {
    sid     = "AllowSchedulerServiceToAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "parquet_etl_scheduler" {
  name               = local.parquet_etl_schedule_role
  assume_role_policy = data.aws_iam_policy_document.parquet_etl_scheduler_assume_role.json
  description        = "Role for EventBridge Scheduler to invoke the Parquet ETL Lambda."
}

data "aws_iam_policy_document" "parquet_etl_scheduler_invoke" {
  statement {
    sid    = "AllowInvokeParquetEtlLambda"
    effect = "Allow"
    actions = [
      "lambda:InvokeFunction"
    ]
    resources = [aws_lambda_function.parquet_etl_runner.arn]
  }
}

resource "aws_iam_role_policy" "parquet_etl_scheduler_invoke" {
  name   = "${local.name_prefix}-parquet-etl-scheduler-invoke"
  role   = aws_iam_role.parquet_etl_scheduler.id
  policy = data.aws_iam_policy_document.parquet_etl_scheduler_invoke.json
}

resource "aws_scheduler_schedule" "parquet_etl_daily" {
  name                         = local.parquet_etl_schedule_name
  description                  = "Daily scheduler for Athena-based Parquet ETL catch-up execution."
  schedule_expression          = local.parquet_etl_schedule_cron
  schedule_expression_timezone = local.parquet_etl_schedule_tz
  state                        = local.parquet_etl_schedule_state

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.parquet_etl_runner.arn
    role_arn = aws_iam_role.parquet_etl_scheduler.arn
    input = jsonencode({
      mode = "daily"
    })
  }
}

