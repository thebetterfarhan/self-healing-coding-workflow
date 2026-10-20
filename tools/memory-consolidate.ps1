#Requires -Version 5
<#
  memory-consolidate.ps1 — merge new ad_hoc note learnings into MEMORY.md.

  Deterministic (no model calls): extracts learning bullets from notes that have
  not yet been consolidated, dedupes against the existing MEMORY.md content by a
  normalized substring key, and appends the novel bullets grouped by topic under a
  dated section. Tracks consolidated notes in .consolidated (filename:hash).
#>
$ErrorActionPreference = 'Stop'
$NotesDir   = Join-Path $env:USERPROFILE '.codex\memories\extensions\ad_hoc\notes'
$MemoryFile = Join-Path $env:USERPROFILE '.codex\memories\MEMORY.md'
$IndexFile  = Join-Path $NotesDir '.consolidated'

if (-not (Test-Path -LiteralPath $MemoryFile)) { Write-Output 'no MEMORY.md'; exit 0 }
if (-not (Test-Path -LiteralPath $NotesDir))   { Write-Output 'no notes dir'; exit 0 }

$done = @{}
if (Test-Path -LiteralPath $IndexFile) { foreach ($l in Get-Content -LiteralPath $IndexFile) { $done[$l.Trim()] = $true } }

$mem = Get-Content -LiteralPath $MemoryFile -Raw
$populated = Get-ChildItem -LiteralPath $NotesDir -Filter *.md | Where-Object {
    (Get-Content $_.FullName -Raw) -match 'Learnings to consider adding:'
}

$groups = @{}
$toMark = @()
foreach ($n in $populated) {
    $key = $n.Name + ':' + (Get-FileHash -LiteralPath $n.FullName -Algorithm MD5).Hash
    if ($done.ContainsKey($key)) { continue }

    $c = Get-Content -LiteralPath $n.FullName -Raw
    $title = ''
    if ($c -match 'title: (.+)') { $title = $Matches[1].Trim() -replace '\)$', '' }
    if (-not $title) { $title = $n.BaseName }

    $novel = @()
    if ($c -match '(?s)Learnings to consider adding:\r?\n(.*?)(?:\r?\nReferences:|\z)') {
        foreach ($l in ($Matches[1] -split "`r?`n")) {
            $t = $l.Trim()
            if (-not $t -or -not $t.StartsWith('-')) { continue }
            $norm = ($t -replace '^- ' -replace '[^a-zA-Z0-9 ]', '')
            $norm = $norm.Substring(0, [Math]::Min(40, $norm.Length)).Trim()
            if ($norm.Length -lt 12) { continue }
            if ($mem -match [regex]::Escape($norm)) { continue }
            $novel += $t
        }
    }
    if ($novel.Count -gt 0) {
        if (-not $groups.ContainsKey($title)) { $groups[$title] = @() }
        $groups[$title] += $novel
    }
    $toMark += $key
}

if ($groups.Count -eq 0) {
    foreach ($k in $toMark) { Add-Content -LiteralPath $IndexFile -Value $k -Encoding UTF8 }
    Write-Output 'consolidated 0 novel learning(s)'
    exit 0
}

# Backup MEMORY.md before appending
$backupDir = Join-Path $env:USERPROFILE '.codex\memories\backups'
if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
$backupName = 'MEMORY.md.' + (Get-Date -Format 'yyyyMMddHHmmss') + '.bak'
Copy-Item -LiteralPath $MemoryFile -Destination (Join-Path $backupDir $backupName) -Force

$stamp = Get-Date -Format 'yyyy-MM-dd'
$lines = @()
$lines += ''
$lines += ('# Consolidated learnings (auto, {0})' -f $stamp)
$lines += ''
foreach ($title in ($groups.Keys | Sort-Object)) {
    $lines += ('## {0}' -f $title)
    $lines += ''
    foreach ($b in $groups[$title]) { $lines += $b }
    $lines += ''
}
$lines | Add-Content -LiteralPath $MemoryFile -Encoding UTF8

foreach ($k in $toMark) { Add-Content -LiteralPath $IndexFile -Value $k -Encoding UTF8 }

$totalNovel = ($groups.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
Write-Output ("consolidated {0} novel learning(s) across {1} topic(s)" -f $totalNovel, $groups.Count)