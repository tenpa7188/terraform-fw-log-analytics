resource "aws_athena_workgroup" "fw_log_analytics" {
  name          = local.athena_workgroup_name
  description   = "Standard Athena workgroup for firewall log analytics queries."
  state         = "ENABLED"
  force_destroy = false
  depends_on    = [aws_s3_bucket.log_bucket]

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff_per_query

    result_configuration {
      output_location = local.athena_results_location
    }
  }
}
