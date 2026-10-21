#Requires -Version 5
<#
  leak-scan.ps1  -  find the things that must never leave this machine.

  One scanner, two callers: the packer refuses to build a bundle that trips
  it, and the CI workflow fails the build when a tracked file does.

  What it looks for:
    1. Key material - private keys, cloud keys, tokens, JWTs.
    2. A machine path - a Windows user profile directory - which names the
       person who built it.
    3. A generated taste block - the learned preferences, fenced by the
       TASTE:BEGIN and TASTE:END markers. A script that merely mentions the
       markers is not one.
    4. Your own patterns, from tools/leak-patterns.local.json. That file is
       git-ignored and never packaged, so a personal address can be blocked
       without being written into a bundle anyone downloads.

  -SecretsOnly leaves out the machine path. A private document is allowed to
  name this machine - the tools handover does exactly that - and it is the
  published repository and the bundle that must carry nothing of it.

  .EXAMPLE
  # Scan a folder of files - what the packer does.
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/leak-scan.ps1 -Path <folder>

  .EXAMPLE
  # Scan the tracked files of a repository - what CI does.
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/leak-scan.ps1 -Repo .
#>
[CmdletBinding()]
param(
  [string]$Path,
  [string]$Repo,
  [switch]$Quiet,
  [switch]$SecretsOnly
)

$ErrorActionPreference = 'Stop'

function Get-LeakPatterns {
  <#  The built-in patterns, plus the personal ones from the local file. #>
  $patterns = @(
    @{ Name = 'private key';   Pattern = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
    @{ Name = 'aws key';       Pattern = '\bAKIA[0-9A-Z]{16}\b' },
    @{ Name = 'github token';  Pattern = '\bgh[pousr]_[A-Za-z0-9]{20,}\b' },
    @{ Name = 'github pat';    Pattern = '\bgithub_pat_[A-Za-z0-9_]{20,}\b' },
    @{ Name = 'slack token';   Pattern = '\bxox[baprs]-[A-Za-z0-9-]{10,}\b' },
    @{ Name = 'google api key'; Pattern = '\bAIza[0-9A-Za-z_-]{35}\b' },
    @{ Name = 'jwt';           Pattern = '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{8,}' },
    @{ Name = 'machine path';  Pattern = '[A-Za-z]:\\Users\\' }
  )
  $local = Join-Path $PSScriptRoot 'leak-patterns.local.json'
  if (Test-Path -LiteralPath $local) {
    try {
      $doc = Get-Content -LiteralPath $local -Raw | ConvertFrom-Json
      foreach ($p in @($doc.patterns)) {
        if ($p -and $p.pattern) { $patterns += @{ Name = $p.name; Pattern = $p.pattern } }
      }
    } catch {
      Write-Warning "could not read $local - personal leak patterns were not applied"
    }
  }
  return $patterns
}

function Get-StagedLeaks {
  <#  Returns one string per leak found under $StageRoot. #>
  param(
    [Parameter(Mandatory)][string]$StageRoot,
    $Patterns
  )
  if (-not $Patterns) { $Patterns = Get-LeakPatterns }
  $leaks = @()
  $text = @('.md', '.ps1', '.py', '.mjs', '.js', '.json', '.toml', '.txt', '.html', '.yml', '.yaml')
  foreach ($file in Get-ChildItem -LiteralPath $StageRoot -Recurse -File) {
    if ($file.Extension -notin $text) { continue }
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    $rel = $file.FullName.Substring($StageRoot.Length).TrimStart('\', '/')
    # A real taste block: the BEGIN/END markers with taste bullets between
    # them. A script that merely mentions the markers is not one.
    $a = $content.IndexOf('<!-- TASTE:BEGIN'); $b = $content.IndexOf('<!-- TASTE:END -->')
    if ($a -ge 0 -and $b -gt $a) {
      $body = $content.Substring($a, $b - $a)
      if ($body -match '(?m)^-\s+.*Confidence:\s*0\.') { $leaks += "$rel : a generated taste block" }
    }
    foreach ($p in $Patterns) {
      if ($content -match $p.Pattern) { $leaks += ("{0} : {1}" -f $rel, $p.Name) }
    }
  }
  return $leaks
}

function Get-RepoLeaks {
  <#  Scans the tracked files of a repository, working-tree copies. #>
  param(
    [Parameter(Mandatory)][string]$RepoPath,
    $Patterns
  )
  if (-not $Patterns) { $Patterns = Get-LeakPatterns }
  $leaks = @()
  $text = @('.md', '.ps1', '.py', '.mjs', '.js', '.json', '.toml', '.txt', '.html', '.yml', '.yaml')
  $files = @(git -C $RepoPath ls-files 2>$null)
  foreach ($rel in $files) {
    $full = Join-Path $RepoPath $rel
    if (-not (Test-Path -LiteralPath $full)) { continue }
    if ([System.IO.Path]::GetExtension($full) -notin $text) { continue }
    $content = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    $a = $content.IndexOf('<!-- TASTE:BEGIN'); $b = $content.IndexOf('<!-- TASTE:END -->')
    if ($a -ge 0 -and $b -gt $a) {
      $body = $content.Substring($a, $b - $a)
      if ($body -match '(?m)^-\s+.*Confidence:\s*0\.') { $leaks += "$rel : a generated taste block" }
    }
    foreach ($p in $Patterns) {
      if ($content -match $p.Pattern) { $leaks += ("{0} : {1}" -f $rel, $p.Name) }
    }
  }
  return $leaks
}

# --- run as a script ------------------------------------------------------
if ($Path -or $Repo) {
    $patterns = @(Get-LeakPatterns)
    if ($SecretsOnly) { $patterns = @($patterns | Where-Object { $_.Name -ne 'machine path' }) }
    $leaks = if ($Path) { @(Get-StagedLeaks -StageRoot $Path -Patterns $patterns) } else { @(Get-RepoLeaks -RepoPath $Repo -Patterns $patterns) }
  if ($leaks.Count -gt 0) {
    if (-not $Quiet) {
      Write-Host 'LEAK FOUND - these must not be published:' -ForegroundColor Red
      $leaks | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    exit 1
  }
  if (-not $Quiet) { Write-Host 'leak scan: clean' -ForegroundColor Green }
  exit 0
}
