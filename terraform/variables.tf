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
