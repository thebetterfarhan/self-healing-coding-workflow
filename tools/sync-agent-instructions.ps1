#Requires -Version 5
<#
.SYNOPSIS
  Keep every agent global AGENTS.md identical from one canonical source.

.DESCRIPTION
  Codex, OpenCode, and CommandCode each read their own AGENTS.md and do not
  share one file, so copies drift. Edit only the canonical file
  (~\.codex\AGENTS.md) and run this to propagate it.

.EXAMPLE
  .\sync-agent-instructions.ps1          # push canonical -> the others
  .\sync-agent-instructions.ps1 -Check   # report drift, change nothing
#>
param(
  [string]$Canonical = (Join-Path $env:USERPROFILE '.codex\AGENTS.md'),
  [switch]$Check
)

$targets = @(
  (Join-Path $env:USERPROFILE '.config\opencode\AGENTS.md'),
  (Join-Path $env:USERPROFILE '.commandcode\AGENTS.md')
)

if (-not (Test-Path $Canonical)) { Write-Error "Canonical missing: $Canonical"; exit 1 }
$srcHash = (Get-FileHash $Canonical -Algorithm MD5).Hash

if ($Check) {
  '{0}  canonical  {1}' -f $srcHash, $Canonical
  $drift = $false
  foreach ($t in $targets) {
    if (-not (Test-Path $t)) { 'MISSING     ' + $t; $drift = $true; continue }
    $h = (Get-FileHash $t -Algorithm MD5).Hash
    if ($h -eq $srcHash) { '{0}  in sync   {1}' -f $h, $t }
    else { '{0}  DRIFTED   {1}' -f $h, $t; $drift = $true }
  }
  if ($drift) { exit 2 } else { exit 0 }
}

$text = [System.IO.File]::ReadAllText($Canonical)
foreach ($t in $targets) {
  $dir = Split-Path $t -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (Test-Path $t) {
    if ((Get-FileHash $t -Algorithm MD5).Hash -eq $srcHash) {
      'already in sync: ' + $t
    } else {
      $ts = Get-Date -Format yyyyMMdd-HHmmss
      Copy-Item $t "$t.bak-$ts" -Force
      [System.IO.File]::WriteAllText($t, $text, (New-Object System.Text.UTF8Encoding($false)))
      'synced: ' + $t
    }
  } else {
    [System.IO.File]::WriteAllText($t, $text, (New-Object System.Text.UTF8Encoding($false)))
    'created: ' + $t
  }
  # Keep the five latest verified backups per config; prune older copies only
  # after confirming those five are intact.
  $backups = @(Get-ChildItem -LiteralPath $dir -Filter 'AGENTS.md.bak-*' -File -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending)
  if ($backups.Count -gt 5) {
    $intact = @($backups | Select-Object -First 5 | Where-Object { $_.Length -eq 0 }).Count -eq 0
    if ($intact) {
      foreach ($old in ($backups | Select-Object -Skip 5)) { Remove-Item -LiteralPath $old.FullName -Force }
      'pruned {0} old backup(s) in {1}' -f ($backups.Count - 5), $dir
    } else {
      'prune skipped: newest backups not intact in ' + $dir
    }
  }
}
'canonical hash: ' + $srcHash
