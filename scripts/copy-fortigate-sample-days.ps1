# Example: powershell -ExecutionPolicy Bypass -File .\scripts\copy-fortigate-sample-days.ps1 -BucketName <log-bucket-name> -SourceKey "fortigate/year=2026/month=03/day=16/traffic-1000000.log.gz" -StartDate 2026-03-16 -TotalDays 365 -Execute
# Dry-run : powershell -ExecutionPolicy Bypass -File .\scripts\copy-fortigate-sample-days.ps1 -BucketName <log-bucket-name> -SourceKey "fortigate/year=2026/month=03/day=16/traffic-1000000.log.gz" -StartDate 2026-03-16 -TotalDays 365
param(
  [Parameter(Mandatory = $true)]
  [string]$BucketName,

  [string]$SourceKey = "fortigate/year=2026/month=03/day=16/traffic-1000000.log.gz",

  [datetime]$StartDate = [datetime]"2026-03-16",

  [int]$TotalDays = 365,

  [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($TotalDays -lt 1) {
  throw "TotalDays must be 1 or greater."
}

$sourceUri = "s3://$BucketName/$SourceKey"
$fileName = Split-Path -Path $SourceKey -Leaf
$additionalCopies = [Math]::Max($TotalDays - 1, 0)

Write-Host "Source object : $sourceUri"
Write-Host "Start date    : $($StartDate.ToString('yyyy-MM-dd'))"
Write-Host "Total days    : $TotalDays"
Write-Host "Copies to make: $additionalCopies"

if (-not $Execute) {
  Write-Host "Mode          : dry-run"
} else {
  Write-Host "Mode          : execute"
  aws s3api head-object --bucket $BucketName --key $SourceKey | Out-Null
}

for ($offset = 1; $offset -lt $TotalDays; $offset++) {
  $targetDate = $StartDate.AddDays($offset)
  $targetKey = "fortigate/year={0}/month={1}/day={2}/{3}" -f `
    $targetDate.ToString("yyyy"), `
    $targetDate.ToString("MM"), `
    $targetDate.ToString("dd"), `
    $fileName

  $targetUri = "s3://$BucketName/$targetKey"

  if (-not $Execute) {
    Write-Host "DRYRUN  aws s3 cp $sourceUri $targetUri --only-show-errors"
    continue
  }

  Write-Host "COPY    $targetUri"
  aws s3 cp $sourceUri $targetUri --only-show-errors
}

if (-not $Execute) {
  Write-Host "Dry-run completed. Add -Execute to run the copies."
} else {
  Write-Host "Copy completed."
}
