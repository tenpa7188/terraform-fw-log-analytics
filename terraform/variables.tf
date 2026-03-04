variable "project" {
  description = "Project identifier used for names and tags."
  type        = string
  default     = "fw-log-analytics"
}

variable "environment" {
  description = "Deployment environment name (for example: dev, stg, prod)."
  type        = string
}

variable "aws_region" {
  description = "AWS region where resources are created."
  type        = string
}

variable "owner" {
  description = "Owner/team label used in tags."
  type        = string
  default     = "infra"
}

variable "additional_tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

variable "fortigate_retention_days" {
  description = "Retention period in days for fortigate/ objects."
  type        = number
  default     = 365
}

variable "fortigate_noncurrent_retention_days" {
  description = "Retention period in days for noncurrent versions under fortigate/."
  type        = number
  default     = 30
}

variable "athena_results_retention_days" {
  description = "Retention period in days for athena-results/ objects."
  type        = number
  default     = 30
}

variable "athena_results_noncurrent_retention_days" {
  description = "Retention period in days for noncurrent versions under athena-results/."
  type        = number
  default     = 7
}

variable "athena_bytes_scanned_cutoff_per_query" {
  description = "Maximum bytes scanned per Athena query in the standard workgroup."
  type        = number
  default     = 10737418240
}
