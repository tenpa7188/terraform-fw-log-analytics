locals {
  name_prefix = "${var.project}-${var.environment}"

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
