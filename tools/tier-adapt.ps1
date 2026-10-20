#Requires -Version 5
<#
  tier-adapt.ps1 — analyze tier outcomes and adjust classification thresholds.

  Reads agent-tier-outcomes.jsonl, computes success rates per tier, and
  adjusts agent-tier-thresholds.json (maxQuickLength, quickKeywords).
  Conservative: only tightens quick tier if its success rate is low.
#>
$ErrorActionPreference = 'Stop'
$OutcomePath  = Join-Path $PSScriptRoot 'agent-tier-outcomes.jsonl'
$ThresholdPath = Join-Path $PSScriptRoot 'agent-tier-thresholds.json'

# Default thresholds
$defaults = @{
    maxQuickLength = 180
    quickSuccessRate = 1.0
    sampleCount = 0
}

$thresholds = $defaults
if (Test-Path -LiteralPath $ThresholdPath) {
    try { $thresholds = Get-Content -LiteralPath $ThresholdPath -Raw | ConvertFrom-Json } catch { $thresholds = $defaults }
}

if (-not (Test-Path -LiteralPath $OutcomePath)) {
    $thresholds | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ThresholdPath -Encoding UTF8
    Write-Output 'no outcome data yet'
    exit 0
}

# Analyze outcomes
$records = @()
foreach ($line in Get-Content -LiteralPath $OutcomePath) {
    if (-not $line.Trim()) { continue }
    try { $records += ($line | ConvertFrom-Json) } catch {}
}

if ($records.Count -lt 10) {
    Write-Output ("only {0} samples, need 10+" -f $records.Count)
    exit 0
}

$byTier = @{}
foreach ($r in $records) {
    if (-not $byTier.ContainsKey($r.tier)) { $byTier[$r.tier] = @{ success = 0; total = 0 } }
    $byTier[$r.tier].total++
    if ($r.exitCode -eq 0) { $byTier[$r.tier].success++ }
}

$quickRate = if ($byTier.ContainsKey('quick') -and $byTier['quick'].total -gt 0) {
    [double]$byTier['quick'].success / [double]$byTier['quick'].total
} else { 1.0 }

# If quick tier success rate < 70%, tighten (reduce max length by 20)
$changed = $false
if ($quickRate -lt 0.7 -and $byTier['quick'].total -ge 5) {
    $newMax = [Math]::Max(80, $thresholds.maxQuickLength - 20)
    if ($newMax -ne $thresholds.maxQuickLength) {
        $thresholds.maxQuickLength = $newMax
        $changed = $true
    }
}

# If quick tier success rate > 90% with enough samples, could loosen (but be conservative)
if ($quickRate -gt 0.9 -and $byTier['quick'].total -ge 20 -and $thresholds.maxQuickLength -lt 250) {
    $newMax = [Math]::Min(250, $thresholds.maxQuickLength + 10)
    if ($newMax -ne $thresholds.maxQuickLength) {
        $thresholds.maxQuickLength = $newMax
        $changed = $true
    }
}

$thresholds.quickSuccessRate = [Math]::Round($quickRate, 3)
$thresholds.sampleCount = $records.Count
$thresholds | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ThresholdPath -Encoding UTF8

$quickTotal = if ($byTier.ContainsKey('quick')) { $byTier['quick'].total } else { 0 }
$quickPct   = if ($quickTotal -gt 0) { '{0:P0}' -f $quickRate } else { 'n/a' }
Write-Output ("tier-adapt: quick success={0} ({1} samples), maxQuickLength={2}, changed={3}" -f $quickPct, $quickTotal, $thresholds.maxQuickLength, $changed)