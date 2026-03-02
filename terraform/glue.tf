resource "aws_glue_catalog_database" "fw_log_analytics" {
  name        = "fw_log_analytics"
  description = "Glue Data Catalog database for firewall log analytics."
}
