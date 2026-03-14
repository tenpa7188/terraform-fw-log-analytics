resource "aws_iam_user" "ingest" {
  count = var.create_ingest_iam_user ? 1 : 0

  name = local.ingest_iam_user_name

  tags = {
    purpose = "fortigate-log-ingest"
  }
}

data "aws_iam_policy_document" "ingest_user_assume_role" {
  count = var.create_ingest_iam_user ? 1 : 0

  statement {
    sid     = "AllowAssumeIngestRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    resources = [aws_iam_role.ingest.arn]
  }
}

resource "aws_iam_user_policy" "ingest_user_assume_role" {
  count = var.create_ingest_iam_user ? 1 : 0

  name   = "${local.name_prefix}-ingest-assume-role"
  user   = aws_iam_user.ingest[0].name
  policy = data.aws_iam_policy_document.ingest_user_assume_role[0].json
}

resource "aws_iam_access_key" "ingest" {
  count = var.create_ingest_iam_user && var.create_ingest_iam_access_key ? 1 : 0

  user = aws_iam_user.ingest[0].name
}
