#
# Purpose:
#   Validate IAM responsibility boundaries for ingest / analyst / parquet_etl /
#   parquet_etl_scheduler / terraform
#   by using aws iam simulate-principal-policy against the Terraform-managed
#   roles and resource names from the current state.
#
# Usage:
#   Run this script from the terraform directory:
#   powershell -ExecutionPolicy Bypass -File .\tests\iam-policy-simulator.ps1
#   powershell -ExecutionPolicy Bypass -File .\tests\iam-policy-simulator.ps1 -Role analyst
#
[CmdletBinding()]
param(
  [ValidateSet("ingest", "analyst", "parquet_etl", "parquet_etl_scheduler", "terraform")]
  [string[]]$Role = @("ingest", "analyst", "parquet_etl", "parquet_etl_scheduler", "terraform"),

  [string]$TerraformDir = (Resolve-Path (Join-Path $Get-Location "..")).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-CommandAvailable {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CommandName
  )

  if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
    throw "Required command '$CommandName' was not found."
  }
}

function Get-TerraformOutputs {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory
  )

  Push-Location $WorkingDirectory
  try {
    $json = & terraform output -json
    if ($LASTEXITCODE -ne 0) {
      throw "terraform output -json failed in '$WorkingDirectory'."
    }

    if ([string]::IsNullOrWhiteSpace($json)) {
      throw "terraform output -json returned empty output."
    }

    return $json | ConvertFrom-Json
  }
  finally {
    Pop-Location
  }
}

function Get-OutputValue {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Outputs,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $property = $Outputs.PSObject.Properties[$Name]
  if (-not $property) {
    throw "Terraform output '$Name' was not found."
  }

  return $property.Value.value
}

function New-ContextEntry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string[]]$Values,

    [string]$Type = "string"
  )

  return "ContextKeyName=$Name,ContextKeyType=$Type,ContextKeyValues=$([string]::Join(',', $Values))"
}

function Invoke-SimulationCase {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Case
  )

  $cliArgs = @(
    "iam",
    "simulate-principal-policy",
    "--policy-source-arn",
    $Case.PolicySourceArn,
    "--action-names",
    $Case.ActionName,
    "--output",
    "json"
  )

  if ($Case.ContainsKey("ResourceArns") -and $Case.ResourceArns.Count -gt 0) {
    $cliArgs += "--resource-arns"
    $cliArgs += $Case.ResourceArns
  }

  if ($Case.ContainsKey("ContextEntries") -and $Case.ContextEntries.Count -gt 0) {
    $cliArgs += "--context-entries"
    $cliArgs += $Case.ContextEntries
  }

  $json = & aws @cliArgs
  if ($LASTEXITCODE -ne 0) {
    throw "aws iam simulate-principal-policy failed for '$($Case.Name)'."
  }

  $response = $json | ConvertFrom-Json
  $evaluation = $response.EvaluationResults[0]
  $actual = $evaluation.EvalDecision

  return [pscustomobject]@{
    Role      = $Case.Role
    Category  = $Case.Category
    Name      = $Case.Name
    Expected  = $Case.Expected
    Actual    = $actual
    Passed    = ($actual -eq $Case.Expected)
    Action    = $Case.ActionName
    Principal = $Case.PolicySourceArn
    Resource  = if ($Case.ContainsKey("ResourceArns") -and $Case.ResourceArns.Count -gt 0) { $Case.ResourceArns -join ", " } else { "*" }
  }
}

Assert-CommandAvailable -CommandName "terraform"
Assert-CommandAvailable -CommandName "aws"

$resolvedTerraformDir = (Resolve-Path $TerraformDir).Path
$outputs = Get-TerraformOutputs -WorkingDirectory $resolvedTerraformDir

$bucketName = Get-OutputValue -Outputs $outputs -Name "log_bucket_name"
$region = Get-OutputValue -Outputs $outputs -Name "aws_region"
$glueDatabaseName = Get-OutputValue -Outputs $outputs -Name "glue_database_name"
$glueTableName = Get-OutputValue -Outputs $outputs -Name "glue_table_name"
$glueParquetTableName = Get-OutputValue -Outputs $outputs -Name "glue_parquet_table_name"
$athenaWorkgroupName = Get-OutputValue -Outputs $outputs -Name "athena_workgroup_name"
$athenaWorkgroupArn = Get-OutputValue -Outputs $outputs -Name "athena_workgroup_arn"
$athenaEtlWorkgroupName = Get-OutputValue -Outputs $outputs -Name "athena_etl_workgroup_name"
$athenaEtlWorkgroupArn = Get-OutputValue -Outputs $outputs -Name "athena_etl_workgroup_arn"
$ingestRoleArn = Get-OutputValue -Outputs $outputs -Name "iam_ingest_role_arn"
$analystRoleArn = Get-OutputValue -Outputs $outputs -Name "iam_analyst_role_arn"
$parquetEtlRoleArn = Get-OutputValue -Outputs $outputs -Name "iam_parquet_etl_role_arn"
$parquetEtlSchedulerRoleArn = Get-OutputValue -Outputs $outputs -Name "iam_parquet_etl_scheduler_role_arn"
$parquetEtlLambdaArn = Get-OutputValue -Outputs $outputs -Name "parquet_etl_lambda_function_arn"
$terraformRoleArn = Get-OutputValue -Outputs $outputs -Name "iam_terraform_role_arn"

if ($terraformRoleArn -notmatch "^arn:(?<partition>[^:]+):iam::(?<account_id>\d{12}):role/.+$") {
  throw "Failed to parse partition/account ID from terraform role ARN '$terraformRoleArn'."
}

$partition = $Matches.partition
$accountId = $Matches.account_id
$bucketArn = "arn:${partition}:s3:::${bucketName}"
$fortigateObjectArn = "$bucketArn/fortigate/year=2026/month=03/day=07/test.log"
$fortigateParquetObjectArn = "$bucketArn/fortigate-parquet/year=2026/month=03/day=07/part-00000.snappy.parquet"
$athenaResultObjectArn = "$bucketArn/athena-results/query-result.csv"
$athenaEtlResultObjectArn = "$bucketArn/athena-results/etl/query-result.csv"
$unrelatedBucketArn = "arn:${partition}:s3:::terraform-fw-log-analytics-unrelated-bucket"
$glueCatalogArn = "arn:${partition}:glue:${region}:${accountId}:catalog"
$glueDatabaseArn = "arn:${partition}:glue:${region}:${accountId}:database/${glueDatabaseName}"
$glueTableArn = "arn:${partition}:glue:${region}:${accountId}:table/${glueDatabaseName}/${glueTableName}"
$glueParquetTableArn = "arn:${partition}:glue:${region}:${accountId}:table/${glueDatabaseName}/${glueParquetTableName}"
$unrelatedLambdaArn = "arn:${partition}:lambda:${region}:${accountId}:function:unrelated-test-function"
$unrelatedRoleArn = "arn:${partition}:iam::${accountId}:role/unrelated-test-role"

$cases = @()

$cases += @(
  @{
    Role            = "ingest"
    Category        = "permissions"
    Name            = "ingest role can list fortigate prefix"
    PolicySourceArn = $ingestRoleArn
    ActionName      = "s3:ListBucket"
    ResourceArns    = @($bucketArn)
    ContextEntries  = @(New-ContextEntry -Name "s3:prefix" -Values @("fortigate/"))
    Expected        = "allowed"
  },
  @{
    Role            = "ingest"
    Category        = "permissions"
    Name            = "ingest role can put fortigate object"
    PolicySourceArn = $ingestRoleArn
    ActionName      = "s3:PutObject"
    ResourceArns    = @($fortigateObjectArn)
    Expected        = "allowed"
  },
  @{
    Role            = "ingest"
    Category        = "permissions"
    Name            = "ingest role can read Glue table metadata"
    PolicySourceArn = $ingestRoleArn
    ActionName      = "glue:GetTable"
    ResourceArns    = @($glueTableArn)
    Expected        = "allowed"
  },
  @{
    Role            = "ingest"
    Category        = "permissions"
    Name            = "ingest role can create Glue partition"
    PolicySourceArn = $ingestRoleArn
    ActionName      = "glue:BatchCreatePartition"
    ResourceArns    = @($glueCatalogArn, $glueDatabaseArn, $glueTableArn)
    Expected        = "allowed"
  },
  @{
    Role            = "ingest"
    Category        = "permissions"
    Name            = "ingest role cannot read fortigate object"
    PolicySourceArn = $ingestRoleArn
    ActionName      = "s3:GetObject"
    ResourceArns    = @($fortigateObjectArn)
    Expected        = "implicitDeny"
  },
  @{
    Role            = "ingest"
    Category        = "permissions"
    Name            = "ingest role cannot put athena results"
    PolicySourceArn = $ingestRoleArn
    ActionName      = "s3:PutObject"
    ResourceArns    = @($athenaResultObjectArn)
    Expected        = "implicitDeny"
  },
  @{
    Role            = "ingest"
    Category        = "permissions"
    Name            = "ingest role cannot use Athena workgroup"
    PolicySourceArn = $ingestRoleArn
    ActionName      = "athena:GetWorkGroup"
    ResourceArns    = @($athenaWorkgroupArn)
    Expected        = "implicitDeny"
  },
  @{
    Role            = "analyst"
    Category        = "permissions"
    Name            = "analyst role can start query in project workgroup"
    PolicySourceArn = $analystRoleArn
    ActionName      = "athena:StartQueryExecution"
    ResourceArns    = @($athenaWorkgroupArn)
    ContextEntries  = @(New-ContextEntry -Name "athena:WorkGroup" -Values @($athenaWorkgroupName))
    Expected        = "allowed"
  },
  @{
    Role            = "analyst"
    Category        = "permissions"
    Name            = "analyst role cannot start query in default workgroup"
    PolicySourceArn = $analystRoleArn
    ActionName      = "athena:StartQueryExecution"
    ResourceArns    = @($athenaWorkgroupArn)
    ContextEntries  = @(New-ContextEntry -Name "athena:WorkGroup" -Values @("primary"))
    Expected        = "implicitDeny"
  },
  @{
    Role            = "analyst"
    Category        = "permissions"
    Name            = "analyst role can read Glue database metadata"
    PolicySourceArn = $analystRoleArn
    ActionName      = "glue:GetDatabase"
    ResourceArns    = @($glueDatabaseArn)
    Expected        = "allowed"
  },
  @{
    Role            = "analyst"
    Category        = "permissions"
    Name            = "analyst role can read Glue table metadata"
    PolicySourceArn = $analystRoleArn
    ActionName      = "glue:GetTable"
    ResourceArns    = @($glueTableArn)
    Expected        = "allowed"
  },
  @{
    Role            = "analyst"
    Category        = "permissions"
    Name            = "analyst role can read fortigate object"
    PolicySourceArn = $analystRoleArn
    ActionName      = "s3:GetObject"
    ResourceArns    = @($fortigateObjectArn)
    Expected        = "allowed"
  },
  @{
    Role            = "analyst"
    Category        = "permissions"
    Name            = "analyst role can write athena results"
    PolicySourceArn = $analystRoleArn
    ActionName      = "s3:PutObject"
    ResourceArns    = @($athenaResultObjectArn)
    Expected        = "allowed"
  },
  @{
    Role            = "analyst"
    Category        = "permissions"
    Name            = "analyst role cannot write fortigate object"
    PolicySourceArn = $analystRoleArn
    ActionName      = "s3:PutObject"
    ResourceArns    = @($fortigateObjectArn)
    Expected        = "implicitDeny"
  },
  @{
    Role            = "parquet_etl"
    Category        = "permissions"
    Name            = "parquet etl role can start query in ETL workgroup"
    PolicySourceArn = $parquetEtlRoleArn
    ActionName      = "athena:StartQueryExecution"
    ResourceArns    = @($athenaEtlWorkgroupArn)
    ContextEntries  = @(New-ContextEntry -Name "athena:WorkGroup" -Values @($athenaEtlWorkgroupName))
    Expected        = "allowed"
  },
  @{
    Role            = "parquet_etl"
    Category        = "permissions"
    Name            = "parquet etl role cannot start query in standard workgroup"
    PolicySourceArn = $parquetEtlRoleArn
    ActionName      = "athena:StartQueryExecution"
    ResourceArns    = @($athenaWorkgroupArn)
    ContextEntries  = @(New-ContextEntry -Name "athena:WorkGroup" -Values @($athenaWorkgroupName))
    Expected        = "implicitDeny"
  },
  @{
    Role            = "parquet_etl"
    Category        = "permissions"
    Name            = "parquet etl role can read ETL workgroup"
    PolicySourceArn = $parquetEtlRoleArn
    ActionName      = "athena:GetWorkGroup"
    ResourceArns    = @($athenaEtlWorkgroupArn)
    Expected        = "allowed"
  },
  @{
    Role            = "parquet_etl"
    Category        = "permissions"
    Name            = "parquet etl role can read raw Glue table"
    PolicySourceArn = $parquetEtlRoleArn
    ActionName      = "glue:GetTable"
    ResourceArns    = @($glueTableArn)
    Expected        = "allowed"
  },
  @{
    Role            = "parquet_etl"
    Category        = "permissions"
    Name            = "parquet etl role can read parquet Glue table"
    PolicySourceArn = $parquetEtlRoleArn
    ActionName      = "glue:GetTable"
    ResourceArns    = @($glueParquetTableArn)
    Expected        = "allowed"
  },
  @{
    Role            = "parquet_etl"
    Category        = "permissions"
    Name            = "parquet etl role can read raw fortigate object"
    PolicySourceArn = $parquetEtlRoleArn
    ActionName      = "s3:GetObject"
    ResourceArns    = @($fortigateObjectArn)
    Expected        = "allowed"
  },
  @{
    Role            = "parquet_etl"
    Category        = "permissions"
    Name            = "parquet etl role can write parquet object"
    PolicySourceArn = $parquetEtlRoleArn
    ActionName      = "s3:PutObject"
    ResourceArns    = @($fortigateParquetObjectArn)
    Expected        = "allowed"
  },
  @{
    Role            = "parquet_etl"
    Category        = "permissions"
    Name            = "parquet etl role can delete parquet object"
    PolicySourceArn = $parquetEtlRoleArn
    ActionName      = "s3:DeleteObject"
    ResourceArns    = @($fortigateParquetObjectArn)
    Expected        = "allowed"
  },
  @{
    Role            = "parquet_etl"
    Category        = "permissions"
    Name            = "parquet etl role can write ETL athena results"
    PolicySourceArn = $parquetEtlRoleArn
    ActionName      = "s3:PutObject"
    ResourceArns    = @($athenaEtlResultObjectArn)
    Expected        = "allowed"
  },
  @{
    Role            = "parquet_etl"
    Category        = "permissions"
    Name            = "parquet etl role cannot write raw fortigate object"
    PolicySourceArn = $parquetEtlRoleArn
    ActionName      = "s3:PutObject"
    ResourceArns    = @($fortigateObjectArn)
    Expected        = "implicitDeny"
  },
  @{
    Role            = "parquet_etl"
    Category        = "permissions"
    Name            = "parquet etl role cannot write standard athena results"
    PolicySourceArn = $parquetEtlRoleArn
    ActionName      = "s3:PutObject"
    ResourceArns    = @($athenaResultObjectArn)
    Expected        = "implicitDeny"
  },
  @{
    Role            = "parquet_etl_scheduler"
    Category        = "permissions"
    Name            = "parquet etl scheduler role can invoke parquet etl lambda"
    PolicySourceArn = $parquetEtlSchedulerRoleArn
    ActionName      = "lambda:InvokeFunction"
    ResourceArns    = @($parquetEtlLambdaArn)
    Expected        = "allowed"
  },
  @{
    Role            = "parquet_etl_scheduler"
    Category        = "permissions"
    Name            = "parquet etl scheduler role cannot invoke unrelated lambda"
    PolicySourceArn = $parquetEtlSchedulerRoleArn
    ActionName      = "lambda:InvokeFunction"
    ResourceArns    = @($unrelatedLambdaArn)
    Expected        = "implicitDeny"
  },
  @{
    Role            = "terraform"
    Category        = "permissions"
    Name            = "terraform role can read project bucket versioning"
    PolicySourceArn = $terraformRoleArn
    ActionName      = "s3:GetBucketVersioning"
    ResourceArns    = @($bucketArn)
    Expected        = "allowed"
  },
  @{
    Role            = "terraform"
    Category        = "permissions"
    Name            = "terraform role can read project role definition"
    PolicySourceArn = $terraformRoleArn
    ActionName      = "iam:GetRole"
    ResourceArns    = @($ingestRoleArn)
    Expected        = "allowed"
  },
  @{
    Role            = "terraform"
    Category        = "permissions"
    Name            = "terraform role can use Athena API"
    PolicySourceArn = $terraformRoleArn
    ActionName      = "athena:GetWorkGroup"
    ResourceArns    = @($athenaWorkgroupArn)
    Expected        = "allowed"
  },
  @{
    Role            = "terraform"
    Category        = "permissions"
    Name            = "terraform role cannot read unrelated bucket versioning"
    PolicySourceArn = $terraformRoleArn
    ActionName      = "s3:GetBucketVersioning"
    ResourceArns    = @($unrelatedBucketArn)
    Expected        = "implicitDeny"
  },
  @{
    Role            = "terraform"
    Category        = "permissions"
    Name            = "terraform role cannot read unrelated role definition"
    PolicySourceArn = $terraformRoleArn
    ActionName      = "iam:GetRole"
    ResourceArns    = @($unrelatedRoleArn)
    Expected        = "implicitDeny"
  },
  @{
    Role            = "terraform"
    Category        = "permissions"
    Name            = "terraform role cannot list users"
    PolicySourceArn = $terraformRoleArn
    ActionName      = "iam:ListUsers"
    Expected        = "implicitDeny"
  }
)

$selectedCases = $cases | Where-Object { $Role -contains $_.Role }

if (-not $selectedCases -or $selectedCases.Count -eq 0) {
  throw "No test cases matched the requested roles."
}

$results = foreach ($case in $selectedCases) {
  Invoke-SimulationCase -Case $case
}

$results | Sort-Object Role, Category, Name | Format-Table Role, Category, Name, Expected, Actual, Passed -AutoSize

$failedResults = $results | Where-Object { -not $_.Passed }
if ($failedResults) {
  Write-Host ""
  Write-Host "Failed cases:" -ForegroundColor Red
  $failedResults | Sort-Object Role, Category, Name | Format-Table Role, Category, Name, Expected, Actual, Action, Resource -AutoSize
  exit 1
}

Write-Host ""
Write-Host "All IAM simulator tests passed." -ForegroundColor Green


