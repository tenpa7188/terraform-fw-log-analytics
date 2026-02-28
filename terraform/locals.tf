locals {
  name_prefix = "${var.project}-${var.environment}"
  log_bucket_name = "${local.name_prefix}-${random_id.bucket_suffix.hex}"

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
