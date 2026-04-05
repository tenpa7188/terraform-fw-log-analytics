data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_root_principal_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"

  ingest_iam_user_name = "${local.name_prefix}-ingest-user"

  ingest_trusted_principal_arns = length(concat(var.ingest_trusted_principal_arns, var.create_ingest_iam_user ? [aws_iam_user.ingest[0].arn] : [])) > 0 ? concat(var.ingest_trusted_principal_arns, var.create_ingest_iam_user ? [aws_iam_user.ingest[0].arn] : []) : [
    local.account_root_principal_arn
  ]
  analyst_trusted_principal_arns = length(var.analyst_trusted_principal_arns) > 0 ? var.analyst_trusted_principal_arns : [
    local.account_root_principal_arn
  ]
  terraform_trusted_principal_arns = length(var.terraform_trusted_principal_arns) > 0 ? var.terraform_trusted_principal_arns : [
    local.account_root_principal_arn
  ]

  ingest_role_name      = "${local.name_prefix}-ingest-role"
  analyst_role_name     = "${local.name_prefix}-analyst-role"
  parquet_etl_role_name = "${local.name_prefix}-parquet-etl-role"
  terraform_role_name   = "${local.name_prefix}-terraform-role"

  glue_catalog_arn       = "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog"
  glue_database_arn      = "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.fw_log_analytics.name}"
  glue_table_arn         = "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.fw_log_analytics.name}/${aws_glue_catalog_table.fortigate_logs.name}"
  glue_parquet_table_arn = "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.fw_log_analytics.name}/${aws_glue_catalog_table.fortigate_logs_parquet.name}"
}

data "aws_iam_policy_document" "ingest_assume_role" {
  statement {
    sid     = "AllowAssumeRoleForIngestTrustedPrincipals"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.ingest_trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "ingest" {
  name               = local.ingest_role_name
  assume_role_policy = data.aws_iam_policy_document.ingest_assume_role.json
  description        = "Role for uploading firewall logs to the fortigate/ prefix."
}

data "aws_iam_policy_document" "ingest_access" {
  statement {
    sid    = "AllowListFortigatePrefix"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]
    resources = [aws_s3_bucket.log_bucket.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["fortigate/*"]
    }
  }

  statement {
    sid    = "AllowPutFortigateObjects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.log_bucket.arn}/fortigate/*"]
  }

  statement {
    sid    = "AllowRegisterFortigatePartitionsInGlue"
    effect = "Allow"
    actions = [
      "glue:BatchCreatePartition",
      "glue:GetTable"
    ]
    resources = [
      local.glue_catalog_arn,
      local.glue_database_arn,
      local.glue_table_arn,
      local.glue_parquet_table_arn
    ]
  }
}

resource "aws_iam_role_policy" "ingest_access" {
  name   = "${local.name_prefix}-ingest-access"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest_access.json
}

data "aws_iam_policy_document" "analyst_assume_role" {
  statement {
    sid     = "AllowAssumeRoleForAnalystTrustedPrincipals"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.analyst_trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "analyst" {
  name               = local.analyst_role_name
  assume_role_policy = data.aws_iam_policy_document.analyst_assume_role.json
  description        = "Role for querying firewall logs with Athena and reading Glue metadata."
}

data "aws_iam_policy_document" "analyst_access" {
  statement {
    sid       = "AllowStartQueryInStandardWorkgroup"
    effect    = "Allow"
    actions   = ["athena:StartQueryExecution"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "athena:WorkGroup"
      values   = [local.athena_workgroup_name]
    }
  }

  statement {
    sid    = "AllowQueryReadAndControl"
    effect = "Allow"
    actions = [
      "athena:BatchGetQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:ListQueryExecutions",
      "athena:StopQueryExecution"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowReadConfiguredWorkgroup"
    effect = "Allow"
    actions = [
      "athena:GetWorkGroup"
    ]
    resources = [aws_athena_workgroup.fw_log_analytics.arn]
  }

  statement {
    sid    = "AllowReadGlueCatalogForFirewallLogs"
    effect = "Allow"
    actions = [
      "glue:BatchGetPartition",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTable",
      "glue:GetTables"
    ]
    resources = [
      local.glue_catalog_arn,
      local.glue_database_arn,
      local.glue_table_arn
    ]
  }

  statement {
    sid    = "AllowListQueryPrefixes"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]
    resources = [aws_s3_bucket.log_bucket.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "fortigate/*",
        "athena-results/*"
      ]
    }
  }

  statement {
    sid    = "AllowReadFortigateLogs"
    effect = "Allow"
    actions = [
      "s3:GetObject"
    ]
    resources = ["${aws_s3_bucket.log_bucket.arn}/fortigate/*"]
  }

  statement {
    sid    = "AllowReadWriteAthenaResults"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.log_bucket.arn}/${local.athena_results_prefix}*"]
  }
}

resource "aws_iam_role_policy" "analyst_access" {
  name   = "${local.name_prefix}-analyst-access"
  role   = aws_iam_role.analyst.id
  policy = data.aws_iam_policy_document.analyst_access.json
}

data "aws_iam_policy_document" "parquet_etl_assume_role" {
  statement {
    sid     = "AllowLambdaServiceToAssumeParquetEtlRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "parquet_etl" {
  name               = local.parquet_etl_role_name
  assume_role_policy = data.aws_iam_policy_document.parquet_etl_assume_role.json
  description        = "Role for running Athena-based Parquet ETL for firewall logs."
}

data "aws_iam_policy_document" "parquet_etl_access" {
  statement {
    sid       = "AllowStartQueryInEtlWorkgroup"
    effect    = "Allow"
    actions   = ["athena:StartQueryExecution"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "athena:WorkGroup"
      values   = [local.athena_etl_workgroup_name]
    }
  }

  statement {
    sid    = "AllowQueryReadAndControlForEtl"
    effect = "Allow"
    actions = [
      "athena:BatchGetQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowReadConfiguredEtlWorkgroup"
    effect = "Allow"
    actions = [
      "athena:GetWorkGroup"
    ]
    resources = [aws_athena_workgroup.fw_log_analytics_etl.arn]
  }

  statement {
    sid    = "AllowReadGlueCatalogForRawAndParquet"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTable",
      "glue:GetTables"
    ]
    resources = [
      local.glue_catalog_arn,
      local.glue_database_arn,
      local.glue_table_arn,
      local.glue_parquet_table_arn
    ]
  }

  statement {
    sid    = "AllowListRelevantPrefixes"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]
    resources = [aws_s3_bucket.log_bucket.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "fortigate/*",
        "fortigate-parquet/*",
        "${local.athena_etl_results_prefix}*"
      ]
    }
  }

  statement {
    sid    = "AllowReadRawFortigateLogs"
    effect = "Allow"
    actions = [
      "s3:GetObject"
    ]
    resources = ["${aws_s3_bucket.log_bucket.arn}/fortigate/*"]
  }

  statement {
    sid    = "AllowManageParquetObjects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.log_bucket.arn}/fortigate-parquet/*"]
  }

  statement {
    sid    = "AllowReadWriteEtlAthenaResults"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.log_bucket.arn}/${local.athena_etl_results_prefix}*"]
  }

  statement {
    sid    = "AllowLambdaLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowWriteLambdaLogStreams"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.parquet_etl_lambda_name}:*"]
  }
}

resource "aws_iam_role_policy" "parquet_etl_access" {
  name   = "${local.name_prefix}-parquet-etl-access"
  role   = aws_iam_role.parquet_etl.id
  policy = data.aws_iam_policy_document.parquet_etl_access.json
}

data "aws_iam_policy_document" "terraform_assume_role" {
  statement {
    sid     = "AllowAssumeRoleForTerraformTrustedPrincipals"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.terraform_trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "terraform" {
  name               = local.terraform_role_name
  assume_role_policy = data.aws_iam_policy_document.terraform_assume_role.json
  description        = "Role for provisioning this project infrastructure with Terraform."
}

data "aws_iam_policy_document" "terraform_access" {
  statement {
    sid       = "AllowListAllBuckets"
    effect    = "Allow"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowManageProjectBucket"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketLocation",
      "s3:GetBucketOwnershipControls",
      "s3:GetBucketPolicy",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketTagging",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:ListBucket",
      "s3:PutBucketOwnershipControls",
      "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketTagging",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration"
    ]
    resources = [aws_s3_bucket.log_bucket.arn]
  }

  statement {
    sid    = "AllowManageProjectBucketObjects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.log_bucket.arn}/*"]
  }

  statement {
    sid    = "AllowManageGlueResourcesForProject"
    effect = "Allow"
    actions = [
      "glue:*"
    ]
    resources = [
      local.glue_catalog_arn,
      local.glue_database_arn,
      local.glue_table_arn
    ]
  }

  statement {
    sid       = "AllowManageAthenaResourcesForProject"
    effect    = "Allow"
    actions   = ["athena:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowManageProjectRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:PassRole",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-*"]
  }

  statement {
    sid    = "AllowManageProjectUsers"
    effect = "Allow"
    actions = [
      "iam:CreateAccessKey",
      "iam:CreateUser",
      "iam:DeleteAccessKey",
      "iam:DeleteUser",
      "iam:DeleteUserPolicy",
      "iam:GetUser",
      "iam:GetUserPolicy",
      "iam:ListAccessKeys",
      "iam:ListUserPolicies",
      "iam:PutUserPolicy",
      "iam:TagUser",
      "iam:UntagUser",
      "iam:UpdateUser"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:user/${local.name_prefix}-*"]
  }

  statement {
    sid       = "AllowListRoles"
    effect    = "Allow"
    actions   = ["iam:ListRoles"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "terraform_access" {
  name   = "${local.name_prefix}-terraform-access"
  role   = aws_iam_role.terraform.id
  policy = data.aws_iam_policy_document.terraform_access.json
}
