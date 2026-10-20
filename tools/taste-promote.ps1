#Requires -Version 5
<#
  taste-promote.ps1 — scan ad_hoc notes for repeated patterns and propose
  taste entries. Writes candidates to taste-candidates.md for review.
  Does NOT modify taste files directly (those are managed by the learning system).
#>
$ErrorActionPreference = 'Stop'
$NotesDir = Join-Path $env:USERPROFILE '.codex\memories\extensions\ad_hoc\notes'
$OutFile  = Join-Path $PSScriptRoot 'taste-candidates.md'

if (-not (Test-Path -LiteralPath $NotesDir)) { Write-Output 'no notes dir'; exit 0 }

# Collect all learning bullets
$bullets = @()
$populated = Get-ChildItem -LiteralPath $NotesDir -Filter *.md | Where-Object {
    (Get-Content $_.FullName -Raw) -match 'Learnings to consider adding:'
}
foreach ($n in $populated) {
    $c = Get-Content $n.FullName -Raw
    if ($c -match '(?s)Learnings to consider adding:\r?\n(.*?)(?:\r?\nReferences:|\z)') {
        foreach ($l in ($Matches[1] -split "`r?`n")) {
            $t = $l.Trim()
            if ($t -and $t.StartsWith('-')) { $bullets += $t }
        }
    }
}

if ($bullets.Count -eq 0) { Write-Output 'no learnings found'; exit 0 }

# Look for preference-like patterns: "always", "prefer", "never", "use X instead of"
$preferencePatterns = @('always', 'prefer', 'never', 'instead of', 'use .* over', 'do not', 'must ')
$candidates = @()
foreach ($b in $bullets) {
    foreach ($pat in $preferencePatterns) {
        if ($b -match $pat) {
            $candidates += $b
            break
        }
    }
}

# Dedupe by normalized first 60 chars
$seen = @{}
$unique = @()
foreach ($c in $candidates) {
    $key = ($c -replace '[^a-zA-Z0-9 ]', '').Substring(0, [Math]::Min(60, ($c -replace '[^a-zA-Z0-9 ]', '').Length)).ToLower().Trim()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $unique += $c
}

# Only propose if a pattern appears 2+ times (repeated preference).
# Count on the raw pre-dedupe candidates so the same learning recorded in
# multiple note files still counts as a repeat.
$patternCounts = @{}
foreach ($c in $candidates) {
    # Extract a short keyword phrase (first 5 words after the dash)
    $words = ($c -replace '^- ' -split '\s+' | Select-Object -First 5) -join ' '
    $patternCounts[$words] = ($patternCounts[$words] + 1)
}
$repeated = @($unique | Where-Object {
    $words = ($_ -replace '^- ' -split '\s+' | Select-Object -First 5) -join ' '
    $patternCounts[$words] -ge 2
})

# Write candidates file
$lines = @()
$lines += "# Taste candidates (auto-generated $(Get-Date -Format 'yyyy-MM-dd'))"
$lines += ""
$lines += "Review these and apply via the ``taste`` tool if appropriate."
$lines += "Total learning bullets scanned: $($bullets.Count)"
$lines += "Preference-like candidates: $($unique.Count)"
$lines += "Repeated 2+ times (proposed below): $($repeated.Count)"
$lines += ""
foreach ($c in $repeated) {
    $lines += $c
}
$lines | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Output ("wrote {0} repeated taste candidate(s) to {1}" -f $repeated.Count, $OutFile)