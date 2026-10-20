<#
  new-worktree.ps1

  Create one git worktree per task and make it immediately usable. A fresh
  worktree does not carry the repo's gitignored local files. This copies the
  files listed in the repo's .worktreeinclude (one gitignore-style pattern per
  line). With no such file it falls back to a built-in Android/env list
  (local.properties, keystore.properties, *.keystore / *.jks, .env). Without
  them a build fails before it starts.

  Usage:
    new-worktree.ps1 -Repo tv-launcher -Name fix-focus -Base master
    new-worktree.ps1 -Repo C:\path\to\repo -Name spike -Preview

  Convention: one worktree per task, cap 2-4 in flight (review capacity is the
  limit, not compute). Worktrees live under <workspace>\.worktrees\ so they are
  never untracked files inside the repo.
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Name,
    [string]$Base  = 'HEAD',
    [string]$Root  = (Split-Path $PSScriptRoot -Parent),
    [switch]$Preview
)
$ErrorActionPreference = 'Stop'

if ((Test-Path -LiteralPath $Repo -PathType Container)) {
    $repoPath = (Resolve-Path -LiteralPath $Repo).Path
} else {
    $repoPath = Join-Path $Root $Repo
}
if (-not (Test-Path -LiteralPath (Join-Path $repoPath '.git'))) {
    throw "not a git repo: $repoPath"
}
$repoName = Split-Path $repoPath -Leaf
$wtPath   = Join-Path (Join-Path $Root '.worktrees') "$repoName-$Name"

if (Test-Path -LiteralPath $wtPath) { throw "worktree path already exists: $wtPath" }

$branchExists = [bool](git -C $repoPath rev-parse --verify --quiet "refs/heads/$Name")
if ($branchExists) {
    $gitArgs = @('-C', $repoPath, 'worktree', 'add', $wtPath, $Name)
} else {
    $gitArgs = @('-C', $repoPath, 'worktree', 'add', '-b', $Name, $wtPath, $Base)
}

# Gitignored local files a fresh checkout needs to build/run. A repo declares
# its own set in .worktreeinclude; the built-in list is the fallback.
$defaults = @('local.properties', 'keystore.properties', '*.keystore', '*.jks', '.env', '.env.*')
$incFile  = Join-Path $repoPath '.worktreeinclude'
$patterns = if (Test-Path -LiteralPath $incFile) {
    Get-Content -LiteralPath $incFile | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } | ForEach-Object { $_.Trim() }
} else { $defaults }

# shortcut: plain paths and simple globs, gitignore-style. No `!` negation and
# no leading-`/` anchoring. Extend if a repo ever needs them.
$localFiles = @()
if ($patterns) {
    $tracked = Get-ChildItem -LiteralPath $repoPath -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
    foreach ($f in $tracked) {
        $rel  = $f.FullName.Substring($repoPath.Length + 1).Replace('\', '/')
        foreach ($pat in $patterns) {
            $p = $pat.TrimStart('/').Replace('\', '/')
            $hit = if ($p.Contains('/')) { $rel -like $p } else { $f.Name -like $p }
            if ($hit) { $localFiles += $f.FullName; break }
        }
    }
}
$localFiles = $localFiles | Sort-Object -Unique

$relFiles = $localFiles | ForEach-Object { $_.Substring($repoPath.Length + 1) }

if ($Preview) {
    Write-Host ("git " + ($gitArgs -join ' '))
    if ($relFiles) { Write-Host ("copy: " + ($relFiles -join ', ')) }
    else { Write-Host 'copy: (no local files found)' }
    Write-Host "worktree: $wtPath"
    exit 0
}

& git @gitArgs
if ($LASTEXITCODE -ne 0) { throw "git worktree add failed with exit $LASTEXITCODE" }

foreach ($rel in $relFiles) {
    $dest    = Join-Path $wtPath $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    Copy-Item -LiteralPath (Join-Path $repoPath $rel) -Destination $dest -Force
}

Write-Host "worktree ready: $wtPath"
Write-Host ("branch: {0}   base: {1}" -f $Name, $Base)
if ($relFiles) { Write-Host ("copied: " + ($relFiles -join ', ')) }
Write-Host "next: cd `"$wtPath`"  (give each worktree its own ports/DB before parallel runs)"
