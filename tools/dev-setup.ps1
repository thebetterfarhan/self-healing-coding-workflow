#requires -Version 5.1
<#
.SYNOPSIS
    Idempotent developer-environment setup for this Windows machine.

.DESCRIPTION
    One entry point that applies the global git config + aliases, installs the
    global gitignore, wires the canonical PowerShell profile, and installs the
    modern CLI tools via winget. Safe to re-run.

    Canonical profile lives at ./profile.ps1 (edit that, not $PROFILE).

.PARAMETER Check
    Report drift only; change nothing. Exits 2 if anything is missing.

.PARAMETER SkipTools
    Skip the winget tool installs.

.EXAMPLE
    ./dev-setup.ps1
    ./dev-setup.ps1 -Check
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$SkipTools
)

$ErrorActionPreference = 'Stop'
$ToolsDir   = $PSScriptRoot
$Canonical  = Join-Path $ToolsDir 'profile.ps1'
$GitIgnore  = Join-Path $HOME '.gitignore_global'
$Loader     = $PROFILE.CurrentUserCurrentHost
$drift      = $false

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    ok  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    !!  $m" -ForegroundColor Yellow; $script:drift = $true }

# ---------------------------------------------------------------------------
# 1. Git global config
# ---------------------------------------------------------------------------
$gitConfig = [ordered]@{
    'init.defaultBranch'   = 'main'
    'pull.rebase'          = 'false'
    'pull.ff'              = 'only'
    'push.autoSetupRemote' = 'true'
    'push.default'         = 'simple'
    'fetch.prune'          = 'true'
    'rerere.enabled'       = 'true'
    'rerere.autoupdate'    = 'true'
    'merge.conflictStyle'  = 'zdiff3'
    'diff.algorithm'       = 'histogram'
    'diff.colorMoved'      = 'zebra'
    'rebase.autosquash'    = 'true'
    'rebase.autostash'     = 'true'
    'rebase.updateRefs'    = 'true'
    'core.longpaths'       = 'true'
    'core.excludesfile'    = ($GitIgnore -replace '\\', '/')
    'color.ui'             = 'auto'
    'help.autocorrect'     = 'prompt'
    'branch.sort'          = '-committerdate'
    'log.date'             = 'iso'
    'column.ui'            = 'auto'
    'commit.verbose'       = 'true'
}
$gitAliases = [ordered]@{
    'st'      = 'status -sb'
    'co'      = 'checkout'
    'cob'     = 'checkout -b'
    'br'      = 'branch'
    'ci'      = 'commit'
    'cm'      = 'commit -m'
    'ca'      = 'commit --amend --no-edit'
    'unstage' = 'reset HEAD --'
    'undo'    = 'reset --soft HEAD~1'
    'last'    = 'log -1 HEAD --stat'
    'lg'      = "log --graph --abbrev-commit --decorate --date=relative --format='format:%C(auto)%h %C(dim)%ad%C(auto)%d %s'"
    'aliases' = 'config --get-regexp ^alias\.'
    'wip'     = '!git add -A && git commit -m wip'
    'who'     = 'shortlog -sn --no-merges'
}

Step 'Git global config'
foreach ($k in $gitConfig.Keys) {
    $cur = git config --global --get $k
    if ($cur -eq $gitConfig[$k]) { Ok "$k" }
    elseif ($Check) { Warn "$k (is '$cur', want '$($gitConfig[$k])')" }
    else { git config --global $k $gitConfig[$k]; Ok "set $k" }
}
foreach ($k in $gitAliases.Keys) {
    $cur = git config --global --get "alias.$k"
    if ($cur -eq $gitAliases[$k]) { Ok "alias.$k" }
    elseif ($Check) { Warn "alias.$k" }
    else { git config --global "alias.$k" $gitAliases[$k]; Ok "set alias.$k" }
}

# ---------------------------------------------------------------------------
# 2. Global gitignore
# ---------------------------------------------------------------------------
Step 'Global gitignore'
if (Test-Path $GitIgnore) { Ok "$GitIgnore" }
elseif ($Check) { Warn "missing $GitIgnore" }
else {
    @'
# Global gitignore — applied to every repo via core.excludesfile.
.DS_Store
Thumbs.db
desktop.ini
$RECYCLE.BIN/
.vscode/
.idea/
*.swp
*.swo
*~
.env
.env.*
!.env.example
*.local
*.pem
*.key
*.log
*.tmp
*.bak
*.orig
*.rej
node_modules/
__pycache__/
*.py[cod]
.pytest_cache/
.mypy_cache/
.ruff_cache/
.venv/
venv/
dist/
build/
*.egg-info/
target/
.cargo/
'@ | Set-Content -Path $GitIgnore -Encoding UTF8
    Ok "wrote $GitIgnore"
}

# ---------------------------------------------------------------------------
# 3. PowerShell profile (loader -> canonical profile.ps1)
# ---------------------------------------------------------------------------
Step 'PowerShell profile'
if (-not (Test-Path $Canonical)) { Warn "canonical profile missing: $Canonical" }
else { Ok "canonical $Canonical" }

$loaderBody = @"
# `$PROFILE loader — do not put config here.
# Canonical profile: $Canonical (one copy, edit that).
`$canonical = '$Canonical'
if (Test-Path `$canonical) { . `$canonical }
"@
$loaderWired = (Test-Path $Loader) -and ((Get-Content -Raw $Loader) -match [regex]::Escape($Canonical))
if ($loaderWired) { Ok "loader wired" }
elseif ($Check) { Warn "loader not wired: $Loader" }
else {
    $dir = Split-Path $Loader
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Loader, $loaderBody, (New-Object System.Text.UTF8Encoding($false)))
    Ok "wrote loader $Loader"
}

# ---------------------------------------------------------------------------
# 4. Modern CLI tools (winget)
# ---------------------------------------------------------------------------
$tools = @(
    @{ id = 'BurntSushi.ripgrep.MSVC'; cmd = 'rg' },
    @{ id = 'sharkdp.fd';             cmd = 'fd' },
    @{ id = 'sharkdp.bat';            cmd = 'bat' },
    @{ id = 'junegunn.fzf';           cmd = 'fzf' },
    @{ id = 'ajeetdsouza.zoxide';     cmd = 'zoxide' },
    @{ id = 'dandavison.delta';       cmd = 'delta' },
    @{ id = 'Casey.Just';             cmd = 'just' }
)
Step 'Modern CLI tools'
foreach ($t in $tools) {
    if (Get-Command $t.cmd -ErrorAction SilentlyContinue) { Ok "$($t.cmd)" }
    elseif ($Check) { Warn "missing $($t.cmd) ($($t.id))" }
    elseif ($SkipTools) { Warn "skipped $($t.cmd)" }
    else {
        Write-Host "    installing $($t.id) ..." -ForegroundColor DarkGray
        winget install --id $t.id -e --accept-source-agreements --accept-package-agreements --disable-interactivity --silent | Out-Null
        if (Get-Command $t.cmd -ErrorAction SilentlyContinue) { Ok "$($t.cmd)" } else { Warn "$($t.cmd) install needs a new shell or manual step" }
    }
}

# ---------------------------------------------------------------------------
# 5. delta as git pager (only if delta is present)
# ---------------------------------------------------------------------------
Step 'git pager (delta)'
if (Get-Command delta -ErrorAction SilentlyContinue) {
    $deltaCfg = [ordered]@{
        'core.pager'            = 'delta'
        'interactive.diffFilter'= 'delta --color-only'
        'delta.navigate'        = 'true'
        'delta.line-numbers'    = 'true'
        'delta.side-by-side'    = 'false'
        'delta.dark'            = 'true'
        'delta.syntax-theme'    = 'ansi'
    }
    foreach ($k in $deltaCfg.Keys) {
        if ((git config --global --get $k) -eq $deltaCfg[$k]) { Ok $k }
        elseif ($Check) { Warn $k }
        else { git config --global $k $deltaCfg[$k]; Ok "set $k" }
    }
} else { Warn 'delta not installed; skipped' }

# ---------------------------------------------------------------------------
Write-Host ''
if ($Check) {
    if ($drift) { Write-Host 'DRIFT detected (exit 2).' -ForegroundColor Yellow; exit 2 }
    else { Write-Host 'All good.' -ForegroundColor Green; exit 0 }
}
Write-Host 'Done. Open a new shell (or run: reload).' -ForegroundColor Green
