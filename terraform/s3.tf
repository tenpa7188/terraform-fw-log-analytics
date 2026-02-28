resource "aws_s3_bucket" "log_bucket" {
  bucket        = local.log_bucket_name
  force_destroy = false
}
