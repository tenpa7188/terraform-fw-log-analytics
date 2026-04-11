[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [datetime]$StartDate,

  [Parameter(Mandatory = $true)]
  [datetime]$EndDate,

  [string]$FunctionName,

  [string]$TerraformDir,

  [string]$Region,

  [string]$Profile,

  [int]$CliReadTimeoutSeconds = 900,

  [int]$CliConnectTimeoutSeconds = 60,

  [switch]$IncludeQualitySummary,

  [switch]$DryRun
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

function Resolve-TerraformDir {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RequestedPath
  )

  return (Resolve-Path $RequestedPath).Path
}

function Resolve-FunctionName {
  param(
    [string]$ExplicitFunctionName,

    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitFunctionName)) {
    return $ExplicitFunctionName.Trim()
  }

  Assert-CommandAvailable -CommandName "terraform"

  Push-Location $WorkingDirectory
  try {
    $resolvedName = & terraform output -raw parquet_etl_lambda_function_name
    if ($LASTEXITCODE -ne 0) {
      throw "terraform output -raw parquet_etl_lambda_function_name failed."
    }

    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
      throw "Terraform output 'parquet_etl_lambda_function_name' was empty."
    }

    return $resolvedName.Trim()
  }
  finally {
    Pop-Location
  }
}

function Get-DateRangeInclusive {
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$RangeStart,

    [Parameter(Mandatory = $true)]
    [datetime]$RangeEnd
  )

  $current = $RangeStart.Date
  $end = $RangeEnd.Date

  while ($current -le $end) {
    $current
    $current = $current.AddDays(1)
  }
}

function New-BackfillPayloadJson {
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$TargetDate,

    [switch]$IncludeQualitySummary
  )

  $payload = [ordered]@{
    mode        = "backfill"
    target_date = $TargetDate.ToString("yyyy-MM-dd")
  }

  if ($IncludeQualitySummary) {
    $payload.include_quality_summary = $true
  }

  return ($payload | ConvertTo-Json -Compress)
}

function Invoke-BackfillForDate {
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$TargetDate,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedFunctionName,

    [string]$AwsRegion,

    [string]$AwsProfile,

    [int]$ReadTimeoutSeconds,

    [int]$ConnectTimeoutSeconds,

    [switch]$IncludeQualitySummary,

    [switch]$IsDryRun
  )

  $targetDateText = $TargetDate.ToString("yyyy-MM-dd")
  $payloadJson = New-BackfillPayloadJson -TargetDate $TargetDate -IncludeQualitySummary:$IncludeQualitySummary

  Write-Host ""
  Write-Host "==> Backfill target date: $targetDateText"
  Write-Host "Lambda function : $ResolvedFunctionName"
  Write-Host "Payload         : $payloadJson"

  if ($IsDryRun) {
    Write-Host "Dry-run enabled. Lambda invoke was skipped."
    return [pscustomobject]@{
      TargetDate = $targetDateText
      Status     = "DRY_RUN"
      Message    = "Invoke skipped by -DryRun."
    }
  }

  $tempFileName = "parquet-etl-backfill-{0}-{1}.json" -f $targetDateText, ([guid]::NewGuid().ToString("N"))
  $tempDirectory = [System.IO.Path]::GetTempPath()
  $tempOutputPath = Join-Path -Path $tempDirectory -ChildPath $tempFileName
  $tempPayloadPath = Join-Path -Path $tempDirectory -ChildPath ("payload-" + $tempFileName)

  try {
    [System.IO.File]::WriteAllText($tempPayloadPath, $payloadJson, (New-Object System.Text.UTF8Encoding($false)))

    $cliArgs = @(
      "lambda",
      "invoke",
      "--function-name",
      $ResolvedFunctionName,
      "--cli-binary-format",
      "raw-in-base64-out",
      "--payload",
      ("fileb://" + $tempPayloadPath),
      "--output",
      "json",
      "--cli-read-timeout",
      $ReadTimeoutSeconds.ToString(),
      "--cli-connect-timeout",
      $ConnectTimeoutSeconds.ToString()
    )

    if (-not [string]::IsNullOrWhiteSpace($AwsRegion)) {
      $cliArgs += @("--region", $AwsRegion)
    }

    if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) {
      $cliArgs += @("--profile", $AwsProfile)
    }

    $invokeMetadataJson = & aws @cliArgs $tempOutputPath

    if ($LASTEXITCODE -ne 0) {
      throw "aws lambda invoke failed for target_date '$targetDateText'."
    }

    $invokeMetadata = $null
    if (-not [string]::IsNullOrWhiteSpace($invokeMetadataJson)) {
      $invokeMetadata = $invokeMetadataJson | ConvertFrom-Json
    }

    $responseBody = ""
    if (Test-Path $tempOutputPath) {
      $responseBody = Get-Content -LiteralPath $tempOutputPath -Raw
    }

    if ($invokeMetadata) {
      Write-Host "Invoke status   : $($invokeMetadata.StatusCode)"
      if ($invokeMetadata.PSObject.Properties["FunctionError"]) {
        Write-Host "Function error  : $($invokeMetadata.FunctionError)" -ForegroundColor Red
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
      Write-Host "Response body   : $responseBody"
    }

    if ($invokeMetadata -and $invokeMetadata.PSObject.Properties["FunctionError"]) {
      throw "Lambda returned FunctionError for target_date '$targetDateText'."
    }

    $statusCode = $null
    if ($invokeMetadata) {
      $statusCode = $invokeMetadata.StatusCode
    }

    return [pscustomobject]@{
      TargetDate   = $targetDateText
      Status       = "SUCCEEDED"
      StatusCode   = $statusCode
      ResponseBody = $responseBody
    }
  }
  finally {
    if (Test-Path $tempOutputPath) {
      Remove-Item -LiteralPath $tempOutputPath -Force
    }
  }
}

Assert-CommandAvailable -CommandName "aws"

$start = $StartDate.Date
$end = $EndDate.Date

if ($start -gt $end) {
  throw "StartDate must be earlier than or equal to EndDate."
}

$requestedTerraformDir = $TerraformDir
if ([string]::IsNullOrWhiteSpace($requestedTerraformDir)) {
  $requestedTerraformDir = Join-Path (Split-Path -Parent $PSCommandPath) "..\terraform"
}
$resolvedTerraformDir = Resolve-TerraformDir -RequestedPath $requestedTerraformDir
$resolvedFunctionName = Resolve-FunctionName -ExplicitFunctionName $FunctionName -WorkingDirectory $resolvedTerraformDir
$targetDates = @(Get-DateRangeInclusive -RangeStart $start -RangeEnd $end)

Write-Host "Backfill date range : $($start.ToString('yyyy-MM-dd')) -> $($end.ToString('yyyy-MM-dd'))"
Write-Host "Target day count    : $($targetDates.Count)"
Write-Host "Lambda function     : $resolvedFunctionName"

if ($DryRun) {
  Write-Host "Execution mode      : DRY_RUN"
}
else {
  Write-Host "Execution mode      : APPLY"
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($targetDate in $targetDates) {
  $result = Invoke-BackfillForDate `
    -TargetDate $targetDate `
    -ResolvedFunctionName $resolvedFunctionName `
    -AwsRegion $Region `
    -AwsProfile $Profile `
    -ReadTimeoutSeconds $CliReadTimeoutSeconds `
    -ConnectTimeoutSeconds $CliConnectTimeoutSeconds `
    -IncludeQualitySummary:$IncludeQualitySummary `
    -IsDryRun:$DryRun

  $results.Add($result)
}

Write-Host ""
Write-Host "Backfill finished."
Write-Host "Processed count : $($results.Count)"

if ($DryRun) {
  Write-Host "Dry-run only. No Lambda execution was performed."
}