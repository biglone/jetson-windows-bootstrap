Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $scriptDir "bootstrap-jetson.ps1"

if (-not (Test-Path -LiteralPath $target)) {
    throw "bootstrap-jetson.ps1 not found in $scriptDir"
}

& $target @args
