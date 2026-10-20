<#
  refresh-model-prices.ps1

  Regenerates tools/model-prices.json from the installed Command Code CLI's own
  bundled model catalog (a generated doc the CLI ships, matching the pricing page
  at https://commandcode.ai/docs/resources/pricing-limits). Using the shipped
  file keeps the prices aligned with the installed CLI and avoids scraping.

  Run it after upgrading Command Code, or when the pricing page changes.

  Fields written per model:
    id, name, context, efforts, input, output, cacheRead, minPlan
    peak { input, output }   deepseek only: Mon-Fri 01-04 & 06-10 UTC rates
    free                     true when input/output are $0
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Source,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

if (-not $Source) {
    $Source = Join-Path $env:LOCALAPPDATA 'BlindPilot\npm\node_modules\command-code\dist\bundled\command-code-knowledge\reference\models.md'
}
if (-not $OutFile) {
    $OutFile = Join-Path $PSScriptRoot 'model-prices.json'
}
if (-not (Test-Path -LiteralPath $Source)) { throw "model catalog not found: $Source" }

# DeepSeek V4 models bill peak rates Mon-Fri 01-04 & 06-10 UTC; the catalog lists
# the off-peak number, so record the peak pair here.
$Peak = @{
    'deepseek/deepseek-v4-pro'             = @{ input = 1.32; output = 3.96 }
    'deepseek/deepseek-v4-flash'           = @{ input = 0.30; output = 1.20 }
    'deepseek/deepseek-v4-flash-vision-exp'= @{ input = 0.30; output = 1.20 }
    'deepseek/deepseek-v4.1-flash'         = @{ input = 0.30; output = 1.20 }
    'deepseek/deepseek-v4.1-flash-fast'    = @{ input = 0.32; output = 1.16 }
}

$models = [ordered]@{}
foreach ($line in Get-Content -LiteralPath $Source) {
    if ($line -notmatch '^\s*\|') { continue }
    $cells = $line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
    if ($cells.Count -lt 7) { continue }

    $idMatch = [regex]::Match($cells[0], '`([^`]+)`')
    if (-not $idMatch.Success) { continue }
    $id = $idMatch.Groups[1].Value
    if ($id -eq 'Id (use EXACTLY this)') { continue }

    $price = [regex]::Match($cells[4], '\$([\d.]+)/\$([\d.]+)(?:\s*·\s*cache\s*\$([\d.]+))?')
    if (-not $price.Success) { continue }

    $input  = [double]$price.Groups[1].Value
    $output = [double]$price.Groups[2].Value
    $cache  = if ($price.Groups[3].Success) { [double]$price.Groups[3].Value } else { 0.0 }
    $plan   = $cells[5]
    $context = if ($cells[2] -eq '—') { $null } else { $cells[2] }
    $efforts = if ($cells[3] -eq '—') { $null } else { $cells[3] }

    $entry = [ordered]@{
        display   = $id
        name      = $cells[1]
        context   = $context
        efforts   = $efforts
        input     = $input
        output    = $output
        cacheRead = $cache
        minPlan   = $plan
        free      = [bool]($input -eq 0 -and $output -eq 0)
    }
    if ($Peak.ContainsKey($id.ToLower())) { $entry['peak'] = $Peak[$id.ToLower()] }
    # Key on the lowercase id: the CLI prints and accepts ids lowercased.
    $models[$id.ToLower()] = $entry
}

if ($models.Count -lt 20) { throw "parsed only $($models.Count) models from $Source - format changed?" }

$doc = [ordered]@{
    generatedFrom = 'command-code reference models.md'
    generatedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    currency      = 'USD per 1M tokens'
    note          = 'Regenerate with tools/refresh-model-prices.ps1. Rates are off-peak/base; see peak for DeepSeek.'
    models        = $models
}

$doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Host "Wrote $($models.Count) models to $OutFile"
