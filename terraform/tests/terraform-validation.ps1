[CmdletBinding()]
param(
  [string]$TerraformDir = "./",

  [string]$VarFile = "envs/dev.tfvars",

  [switch]$RunPlan
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

  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
    return (Resolve-Path $RequestedPath).Path
  }

  $currentDir = (Resolve-Path (Get-Location)).Path
  $parentDir = Split-Path $currentDir -Parent

  if (Test-Path (Join-Path $currentDir "main.tf")) {
    return $currentDir
  }

  if ($parentDir -and (Test-Path (Join-Path $parentDir "main.tf"))) {
    return (Resolve-Path $parentDir).Path
  }

  throw "Could not locate terraform directory. Run this script from 'terraform/' or specify -TerraformDir."
}

function Invoke-TerraformStep {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StepName,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  Write-Host ""
  Write-Host "==> $StepName"
  Write-Host ("terraform " + ($Arguments -join " "))

  & terraform @Arguments

  if ($LASTEXITCODE -ne 0) {
    throw "Terraform step failed: $StepName"
  }
}

Assert-CommandAvailable -CommandName "terraform"

$resolvedTerraformDir = Resolve-TerraformDir -RequestedPath $TerraformDir

Push-Location $resolvedTerraformDir
try {
  Invoke-TerraformStep -StepName "Initialize without backend" -Arguments @("init", "-backend=false")
  Invoke-TerraformStep -StepName "Check formatting" -Arguments @("fmt", "-check", "-recursive")
  Invoke-TerraformStep -StepName "Validate configuration" -Arguments @("validate")

  if ($RunPlan) {
    Invoke-TerraformStep -StepName "Plan with var-file" -Arguments @("plan", "-var-file=$VarFile")
  }
  else {
    Write-Host ""
    Write-Host "Skipping plan. Use -RunPlan to include 'terraform plan -var-file=$VarFile'."
  }
}
finally {
  Pop-Location
}
