# Example: powershell -ExecutionPolicy Bypass -File .\scripts\run-athena-performance-tests.ps1 -DryRun
# Execute: powershell -ExecutionPolicy Bypass -File .\scripts\run-athena-performance-tests.ps1 -RepeatCount 3

[CmdletBinding()]
param(
  [string]$TerraformDir,

  [string]$TemplateDir,

  [string]$OutputDir,

  [string]$WorkgroupName,

  [string]$DatabaseName,

  [string]$Region,

  [string]$Profile,

  [int]$RepeatCount = 3,

  [int]$PollIntervalSeconds = 3,

  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-CommandAvailable {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CommandName
  )

  if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
    throw "Required command '$CommandName' was not found."
  }
}

function Resolve-ExistingPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RequestedPath
  )

  return (Resolve-Path $RequestedPath).Path
}

function Get-TerraformOutputValue {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,

    [Parameter(Mandatory = $true)]
    [string]$OutputName
  )

  Push-Location $WorkingDirectory
  try {
    $value = & terraform output -raw $OutputName
    if ($LASTEXITCODE -ne 0) {
      throw "terraform output -raw $OutputName failed."
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
      throw "Terraform output '$OutputName' was empty."
    }

    return $value.Trim()
  }
  finally {
    Pop-Location
  }
}

function Resolve-TemplateDir {
  param(
    [string]$RequestedPath
  )

  if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
    return (Resolve-ExistingPath -RequestedPath (Join-Path $PWD 'sql\performance'))
  }

  return (Resolve-ExistingPath -RequestedPath $RequestedPath)
}

function Resolve-OutputDir {
  param(
    [string]$RequestedPath
  )

  if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
    $requested = Join-Path $PWD 'artifacts\athena-performance'
  }
  else {
    $requested = $RequestedPath
  }

  if (-not (Test-Path $requested)) {
    New-Item -ItemType Directory -Path $requested -Force | Out-Null
  }

  return (Resolve-Path $requested).Path
}

function Resolve-WorkgroupName {
  param(
    [string]$ExplicitWorkgroupName,
    [Parameter(Mandatory = $true)]
    [string]$ResolvedTerraformDir
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitWorkgroupName)) {
    return $ExplicitWorkgroupName.Trim()
  }

  return Get-TerraformOutputValue -WorkingDirectory $ResolvedTerraformDir -OutputName 'athena_workgroup_name'
}

function Resolve-DatabaseName {
  param(
    [string]$ExplicitDatabaseName,
    [Parameter(Mandatory = $true)]
    [string]$ResolvedTerraformDir
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitDatabaseName)) {
    return $ExplicitDatabaseName.Trim()
  }

  return Get-TerraformOutputValue -WorkingDirectory $ResolvedTerraformDir -OutputName 'glue_database_name'
}

function Get-TemplateFiles {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResolvedTemplateDir
  )

  $files = Get-ChildItem -LiteralPath $ResolvedTemplateDir -Filter *.sql | Sort-Object Name
  if ($files.Count -eq 0) {
    throw "No SQL files were found under '$ResolvedTemplateDir'."
  }

  return $files
}

function Expand-SqlTemplate {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TemplatePath,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedTableName
  )

  $template = Get-Content -LiteralPath $TemplatePath -Raw
  return $template.Replace('__TABLE_NAME__', $ResolvedTableName)
}

function Invoke-AwsCliJson {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $response = & aws @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "aws command failed: aws $($Arguments -join ' ')"
  }

  if ([string]::IsNullOrWhiteSpace($response)) {
    return $null
  }

  return ($response | ConvertFrom-Json)
}

function Start-AthenaQuery {
  param(
    [Parameter(Mandatory = $true)]
    [string]$QueryText,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedWorkgroupName,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedDatabaseName,

    [string]$AwsRegion,

    [string]$AwsProfile
  )

  $arguments = @(
    'athena',
    'start-query-execution',
    '--query-string',
    $QueryText,
    '--work-group',
    $ResolvedWorkgroupName,
    '--query-execution-context',
    ('Database=' + $ResolvedDatabaseName),
    '--output',
    'json'
  )

  if (-not [string]::IsNullOrWhiteSpace($AwsRegion)) {
    $arguments += @('--region', $AwsRegion)
  }

  if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) {
    $arguments += @('--profile', $AwsProfile)
  }

  $response = Invoke-AwsCliJson -Arguments $arguments
  return $response.QueryExecutionId
}

function Wait-AthenaQuery {
  param(
    [Parameter(Mandatory = $true)]
    [string]$QueryExecutionId,

    [int]$PollSeconds,

    [string]$AwsRegion,

    [string]$AwsProfile
  )

  while ($true) {
    $arguments = @(
      'athena',
      'get-query-execution',
      '--query-execution-id',
      $QueryExecutionId,
      '--output',
      'json'
    )

    if (-not [string]::IsNullOrWhiteSpace($AwsRegion)) {
      $arguments += @('--region', $AwsRegion)
    }

    if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) {
      $arguments += @('--profile', $AwsProfile)
    }

    $response = Invoke-AwsCliJson -Arguments $arguments
    $execution = $response.QueryExecution
    $status = $execution.Status.State

    if ($status -eq 'SUCCEEDED') {
      return $execution
    }

    if ($status -in @('FAILED', 'CANCELLED')) {
      $reason = $execution.Status.StateChangeReason
      throw "Athena query $QueryExecutionId ended with $status. $reason"
    }

    Start-Sleep -Seconds $PollSeconds
  }
}

function Get-AthenaScalarValue {
  param(
    [Parameter(Mandatory = $true)]
    [string]$QueryExecutionId,

    [string]$AwsRegion,

    [string]$AwsProfile
  )

  $arguments = @(
    'athena',
    'get-query-results',
    '--query-execution-id',
    $QueryExecutionId,
    '--max-items',
    '10',
    '--output',
    'json'
  )

  if (-not [string]::IsNullOrWhiteSpace($AwsRegion)) {
    $arguments += @('--region', $AwsRegion)
  }

  if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) {
    $arguments += @('--profile', $AwsProfile)
  }

  $response = Invoke-AwsCliJson -Arguments $arguments
  $rows = @($response.ResultSet.Rows)
  if ($rows.Count -lt 2) {
    return $null
  }

  $data = @($rows[1].Data)
  if ($data.Count -eq 0) {
    return $null
  }

  return $data[0].VarCharValue
}

function Get-Median {
  param(
    [Parameter(Mandatory = $true)]
    [double[]]$Values
  )

  if ($Values.Count -eq 0) {
    return $null
  }

  $sorted = @($Values | Sort-Object)
  $count = $sorted.Count
  $middle = [int]($count / 2)

  if (($count % 2) -eq 1) {
    return [double]$sorted[$middle]
  }

  return [math]::Round((([double]$sorted[$middle - 1]) + ([double]$sorted[$middle])) / 2, 2)
}

Assert-CommandAvailable -CommandName 'aws'
Assert-CommandAvailable -CommandName 'terraform'

$requestedTerraformDir = $TerraformDir
if ([string]::IsNullOrWhiteSpace($requestedTerraformDir)) {
  $requestedTerraformDir = Join-Path (Split-Path -Parent $PSCommandPath) '..\terraform'
}

$resolvedTerraformDir = Resolve-ExistingPath -RequestedPath $requestedTerraformDir
$resolvedTemplateDir = Resolve-TemplateDir -RequestedPath $TemplateDir
$resolvedOutputDir = Resolve-OutputDir -RequestedPath $OutputDir
$resolvedWorkgroupName = Resolve-WorkgroupName -ExplicitWorkgroupName $WorkgroupName -ResolvedTerraformDir $resolvedTerraformDir
$resolvedDatabaseName = Resolve-DatabaseName -ExplicitDatabaseName $DatabaseName -ResolvedTerraformDir $resolvedTerraformDir
$templateFiles = @(Get-TemplateFiles -ResolvedTemplateDir $resolvedTemplateDir)

$tableTargets = @(
  [pscustomobject]@{ Label = 'raw'; TableName = "$resolvedDatabaseName.fortigate_logs" },
  [pscustomobject]@{ Label = 'parquet'; TableName = "$resolvedDatabaseName.fortigate_logs_parquet" }
)

Write-Host "Template dir   : $resolvedTemplateDir"
Write-Host "Output dir     : $resolvedOutputDir"
Write-Host "Workgroup      : $resolvedWorkgroupName"
Write-Host "Database       : $resolvedDatabaseName"
Write-Host "Repeat count   : $RepeatCount"
if ($DryRun) {
  Write-Host 'Execution mode : DRY_RUN'
}
else {
  Write-Host 'Execution mode : APPLY'
}

$expandedRoot = Join-Path $resolvedOutputDir 'expanded-sql'
if (-not (Test-Path $expandedRoot)) {
  New-Item -ItemType Directory -Path $expandedRoot -Force | Out-Null
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($tableTarget in $tableTargets) {
  $tableOutputDir = Join-Path $expandedRoot $tableTarget.Label
  if (-not (Test-Path $tableOutputDir)) {
    New-Item -ItemType Directory -Path $tableOutputDir -Force | Out-Null
  }

  foreach ($templateFile in $templateFiles) {
    $expandedSql = Expand-SqlTemplate -TemplatePath $templateFile.FullName -ResolvedTableName $tableTarget.TableName
    $expandedSqlPath = Join-Path $tableOutputDir $templateFile.Name
    [System.IO.File]::WriteAllText($expandedSqlPath, $expandedSql, (New-Object System.Text.UTF8Encoding($false)))

    for ($repeatIndex = 1; $repeatIndex -le $RepeatCount; $repeatIndex++) {
      Write-Host ''
      Write-Host ("==> {0} | {1} | run {2}/{3}" -f $tableTarget.Label, $templateFile.BaseName, $repeatIndex, $RepeatCount)
      Write-Host ("Expanded SQL : {0}" -f $expandedSqlPath)

      if ($DryRun) {
        $results.Add([pscustomobject]@{
          TemplateName           = $templateFile.BaseName
          TableLabel             = $tableTarget.Label
          TableName              = $tableTarget.TableName
          RepeatIndex            = $repeatIndex
          QueryExecutionId       = $null
          QueryStatus            = 'DRY_RUN'
          CountValue             = $null
          DataScannedBytes       = $null
          EngineExecutionMs      = $null
          TotalExecutionMs       = $null
          QueryQueueMs           = $null
          ServicePreProcessingMs = $null
          ServiceProcessingMs    = $null
          ResultOutputLocation   = $null
          ErrorMessage           = $null
        })
        continue
      }

      $queryExecutionId = $null

      try {
        $queryExecutionId = Start-AthenaQuery `
          -QueryText $expandedSql `
          -ResolvedWorkgroupName $resolvedWorkgroupName `
          -ResolvedDatabaseName $resolvedDatabaseName `
          -AwsRegion $Region `
          -AwsProfile $Profile

        $execution = Wait-AthenaQuery `
          -QueryExecutionId $queryExecutionId `
          -PollSeconds $PollIntervalSeconds `
          -AwsRegion $Region `
          -AwsProfile $Profile

        $countValue = Get-AthenaScalarValue `
          -QueryExecutionId $queryExecutionId `
          -AwsRegion $Region `
          -AwsProfile $Profile

        $statistics = $execution.Statistics
        $status = $execution.Status

        $results.Add([pscustomobject]@{
          TemplateName           = $templateFile.BaseName
          TableLabel             = $tableTarget.Label
          TableName              = $tableTarget.TableName
          RepeatIndex            = $repeatIndex
          QueryExecutionId       = $queryExecutionId
          QueryStatus            = $status.State
          CountValue             = $countValue
          DataScannedBytes       = [double]$statistics.DataScannedInBytes
          EngineExecutionMs      = [double]$statistics.EngineExecutionTimeInMillis
          TotalExecutionMs       = [double]$statistics.TotalExecutionTimeInMillis
          QueryQueueMs           = [double]$statistics.QueryQueueTimeInMillis
          ServicePreProcessingMs = [double]$statistics.ServicePreProcessingTimeInMillis
          ServiceProcessingMs    = [double]$statistics.ServiceProcessingTimeInMillis
          ResultOutputLocation   = $execution.ResultConfiguration.OutputLocation
          ErrorMessage           = $null
        })

        Write-Host ("QueryExecutionId : {0}" -f $queryExecutionId)
        Write-Host ("Matched count    : {0}" -f $countValue)
        Write-Host ("Scanned bytes    : {0}" -f $statistics.DataScannedInBytes)
        Write-Host ("Total exec ms    : {0}" -f $statistics.TotalExecutionTimeInMillis)
        Write-Host ("Engine exec ms   : {0}" -f $statistics.EngineExecutionTimeInMillis)
      }
      catch {
        $results.Add([pscustomobject]@{
          TemplateName           = $templateFile.BaseName
          TableLabel             = $tableTarget.Label
          TableName              = $tableTarget.TableName
          RepeatIndex            = $repeatIndex
          QueryExecutionId       = $queryExecutionId
          QueryStatus            = 'FAILED'
          CountValue             = $null
          DataScannedBytes       = $null
          EngineExecutionMs      = $null
          TotalExecutionMs       = $null
          QueryQueueMs           = $null
          ServicePreProcessingMs = $null
          ServiceProcessingMs    = $null
          ResultOutputLocation   = $null
          ErrorMessage           = $_.Exception.Message
        })

        Write-Host ("Query failed     : {0}" -f $_.Exception.Message) -ForegroundColor Red
      }
    }
  }
}

$rawResultsPath = Join-Path $resolvedOutputDir 'performance-results.csv'
$summaryPath = Join-Path $resolvedOutputDir 'performance-summary.csv'
$comparisonPath = Join-Path $resolvedOutputDir 'performance-comparison.csv'

$results | Export-Csv -LiteralPath $rawResultsPath -NoTypeInformation -Encoding UTF8

$summaryRows = foreach ($tableTarget in $tableTargets) {
  foreach ($templateFile in $templateFiles) {
    $groupRows = @($results | Where-Object {
      $_.TableLabel -eq $tableTarget.Label -and $_.TemplateName -eq $templateFile.BaseName -and $_.QueryStatus -eq 'SUCCEEDED'
    })

    if ($groupRows.Count -eq 0) {
      continue
    }

    [pscustomobject]@{
      TemplateName             = $templateFile.BaseName
      TableLabel               = $tableTarget.Label
      TableName                = $tableTarget.TableName
      RepeatCount              = $groupRows.Count
      MatchedCount             = ($groupRows | Select-Object -ExpandProperty CountValue -First 1)
      MedianDataScannedBytes   = (Get-Median -Values @($groupRows | Select-Object -ExpandProperty DataScannedBytes))
      MedianEngineExecutionMs  = (Get-Median -Values @($groupRows | Select-Object -ExpandProperty EngineExecutionMs))
      MedianTotalExecutionMs   = (Get-Median -Values @($groupRows | Select-Object -ExpandProperty TotalExecutionMs))
      MedianQueryQueueMs       = (Get-Median -Values @($groupRows | Select-Object -ExpandProperty QueryQueueMs))
    }
  }
}

$summaryRows | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8

$comparisonRows = foreach ($templateFile in $templateFiles) {
  $rawSummary = $summaryRows | Where-Object { $_.TemplateName -eq $templateFile.BaseName -and $_.TableLabel -eq 'raw' } | Select-Object -First 1
  $parquetSummary = $summaryRows | Where-Object { $_.TemplateName -eq $templateFile.BaseName -and $_.TableLabel -eq 'parquet' } | Select-Object -First 1

  if (($null -eq $rawSummary) -or ($null -eq $parquetSummary)) {
    continue
  }

  $rawTime = [double]$rawSummary.MedianTotalExecutionMs
  $parquetTime = [double]$parquetSummary.MedianTotalExecutionMs
  $rawScan = [double]$rawSummary.MedianDataScannedBytes
  $parquetScan = [double]$parquetSummary.MedianDataScannedBytes

  $timeImprovementPercent = $null
  if ($rawTime -gt 0) {
    $timeImprovementPercent = [math]::Round((($rawTime - $parquetTime) / $rawTime) * 100, 2)
  }

  $scanImprovementPercent = $null
  if ($rawScan -gt 0) {
    $scanImprovementPercent = [math]::Round((($rawScan - $parquetScan) / $rawScan) * 100, 2)
  }

  [pscustomobject]@{
    TemplateName             = $templateFile.BaseName
    RawMatchedCount          = $rawSummary.MatchedCount
    ParquetMatchedCount      = $parquetSummary.MatchedCount
    RawMedianTotalExecutionMs = $rawTime
    ParquetMedianTotalExecutionMs = $parquetTime
    RawMedianDataScannedBytes = $rawScan
    ParquetMedianDataScannedBytes = $parquetScan
    TimeImprovementPercent   = $timeImprovementPercent
    ScanImprovementPercent   = $scanImprovementPercent
  }
}

$comparisonRows | Export-Csv -LiteralPath $comparisonPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host 'Performance test finished.'
Write-Host ("Detailed results : {0}" -f $rawResultsPath)
Write-Host ("Median summary   : {0}" -f $summaryPath)
Write-Host ("Comparison       : {0}" -f $comparisonPath)

if (-not $DryRun -and $comparisonRows.Count -gt 0) {
  Write-Host ''
  $comparisonRows |
    Select-Object TemplateName, RawMedianTotalExecutionMs, ParquetMedianTotalExecutionMs, RawMedianDataScannedBytes, ParquetMedianDataScannedBytes, TimeImprovementPercent, ScanImprovementPercent |
    Format-Table -AutoSize
}
