environment = "prod"
aws_region  = "ap-northeast-1"
owner       = "infra"

additional_tags = {
  service             = "fw-log-analytics"
  data_classification = "internal"
}

fortigate_retention_days                 = 365
fortigate_noncurrent_retention_days      = 30
athena_results_retention_days            = 30
athena_results_noncurrent_retention_days = 7
athena_bytes_scanned_cutoff_per_query    = 107374182400
create_ingest_iam_user                   = false
create_ingest_iam_access_key             = false
