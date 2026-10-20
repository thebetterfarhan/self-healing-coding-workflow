#Requires -Version 5
<#
.SYNOPSIS
  Regenerate tools/free-models.json - the free-model fallback catalog the
  router uses when a paid model is unavailable.

.DESCRIPTION
  Reads each backend's own catalog (never a hand-typed list, so it tracks
  price and availability changes):

    - CommandCode: the installed CLI's live `--list-models` output (models
                   tagged FREE), falling back to tools/model-prices.json
                   entries with free = true when the CLI is unavailable.
    - OpenCode:    %USERPROFILE%\.cache\opencode\models.json, provider
                   "opencode", models whose cost input and output are 0 and
                   that are not deprecated.

  Output is ordered newest-first per backend so the fallback tries the most
  recent free model first. Upstreams that may train on your prompts are
  excluded.

.EXAMPLE
  .\refresh-free-models.ps1
#>
param(
  [string]$OutFile = (Join-Path $PSScriptRoot 'free-models.json')
)

$ErrorActionPreference = 'Stop'

# Upstreams that may train on your prompts - never auto-selected. Matched as a
# substring so a provider prefix (stealth/glyph-cluster:free) still excludes.
$TrainingModels = @('glyph-cluster:free')

function Test-TrainingModel {
  param([string]$Id)
  foreach ($t in $TrainingModels) { if ($Id -like "*$t*") { return $true } }
  return $false
}

function Get-CommandCodeLiveModels {
  <#  Live free list from the installed CLI, so a retired model is never offered. #>
  $cli = Join-Path $env:LOCALAPPDATA 'BlindPilot\npm\node_modules\command-code\dist\index.mjs'
  if (-not (Test-Path -LiteralPath $cli)) { return @() }
  $node = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $node) { return @() }
  try { $out = & $node.Source $cli --list-models 2>$null } catch { return @() }
  if (-not $out) { return @() }
  $ids = @()
  foreach ($line in $out) {
    # The CLI marks a free model with an uppercase FREE tag; match case-sensitively
    # so prose ("everything else free") is not mistaken for a model.
    if ($line -cmatch '\bFREE\b' -and $line -match '([A-Za-z0-9_.:-]+/[A-Za-z0-9_.:-]+)') {
      $ids += $matches[1]
    }
  }
  return $ids
}

function Get-CommandCodeFreeModels {
  # Prefer the live catalog; the bundled price file lags availability changes.
  $live = Get-CommandCodeLiveModels
  if ($live.Count -gt 0) { return @($live | Where-Object { -not (Test-TrainingModel $_) }) }
  $path = Join-Path $PSScriptRoot 'model-prices.json'
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  $catalog = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).models
  $ids = @()
  foreach ($p in $catalog.PSObject.Properties) {
    if ($p.Value.free -and -not (Test-TrainingModel $p.Name)) { $ids += $p.Name }
  }
  return $ids
}

function Get-OpenCodeFreeModels {
  $path = Join-Path $env:USERPROFILE '.cache\opencode\models.json'
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  $catalog = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  $provider = $catalog.opencode
  if (-not $provider) { return @() }
  $free = $provider.models.PSObject.Properties | Where-Object {
    $_.Value.cost.input -eq 0 -and $_.Value.cost.output -eq 0 -and $_.Value.status -ne 'deprecated'
  }
  $free = $free | Sort-Object { $_.Value.release_date } -Descending
  return @($free | ForEach-Object { 'opencode/' + $_.Name })
}

$doc = [ordered]@{
  generatedAt  = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
  note         = 'Regenerate with refresh-free-models.ps1. Order: newest free model first per backend.'
  commandcode  = @(Get-CommandCodeFreeModels)
  opencode     = @(Get-OpenCodeFreeModels)
}

$doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8
"wrote $OutFile : commandcode=$($doc.commandcode.Count) opencode=$($doc.opencode.Count)"
