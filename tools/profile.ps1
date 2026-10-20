# profile.ps1 — canonical PowerShell profile (Windows PowerShell 5.1)
# Sourced by $PROFILE (see ./Microsoft.PowerShell_profile.ps1 loader) so there is
# exactly one copy to edit. Applied/installed by ./dev-setup.ps1.
# Every block is guarded: a missing tool or older PSReadLine never breaks the shell.

# ---- Helpers ---------------------------------------------------------------
function Test-Cmd { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
function reload { . $PROFILE }
function agent-task { & (Join-Path $PSScriptRoot 'agent-task.ps1') @args }
function work { agent-task @args }
function worktree { & (Join-Path $PSScriptRoot 'new-worktree.ps1') @args }
Set-Alias -Name wt -Value worktree -Force -Option AllScope
function workflow-status { & (Join-Path $PSScriptRoot 'status.ps1') @args }
Set-Alias -Name wf-status -Value workflow-status -Force -Option AllScope
function codex-fast { codex --profile fast @args }
function codex-review { codex --profile review @args }
function opencode-review { opencode --agent review @args }
function command-code-plan { command-code --plan @args }
function mkcd {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Set-Location $Path
}
function touch {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Path)
    foreach ($p in $Path) {
        if (Test-Path $p) { (Get-Item $p).LastWriteTime = Get-Date }
        else { New-Item -ItemType File -Path $p -Force | Out-Null }
    }
}
function which { param([Parameter(Mandatory)][string]$Name) (Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source) }
function cd.. { Set-Location .. }
function .. { Set-Location .. }
function ... { Set-Location ../.. }

# ---- Console encoding (fix garbled UTF-8 from git/tools) -------------------
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---- PSReadLine: history search + menu completion --------------------------
Import-Module PSReadLine -ErrorAction SilentlyContinue
try { Set-PSReadLineOption -BellStyle None } catch {}
try { Set-PSReadLineOption -HistorySearchCursorMovesToEnd } catch {}
try { Set-PSReadLineOption -MaximumHistoryCount 32767 } catch {}
try {
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
    Set-PSReadLineKeyHandler -Key Ctrl+d    -Function DeleteCharOrExit
} catch {}
# Predictive IntelliSense — needs PSReadLine 2.1+; silently ignored on 2.0.
try { Set-PSReadLineOption -PredictionSource History -ErrorAction Stop } catch {}
try { Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction Stop } catch {}

# ---- Modern CLI tool wiring (only if the binary exists) --------------------
$blindPilotNpm = Join-Path $env:LOCALAPPDATA 'BlindPilot\npm'
$haveShim = (Test-Path (Join-Path $blindPilotNpm 'command-code.cmd')) -or (Test-Path (Join-Path $blindPilotNpm 'codex.cmd'))
if ($haveShim) {
    $env:Path = (($env:Path -split ';' | Where-Object { $_ -and ($_ -ine $blindPilotNpm) }) -join ';')
    $env:Path = "$blindPilotNpm;$env:Path"
}
if (Test-Cmd rg)  { Set-Alias -Name grep -Value rg -Force -Option AllScope }
if (Test-Cmd bat) { $env:BAT_THEME = 'ansi' }
if (Test-Cmd fzf) { $env:FZF_DEFAULT_OPTS = '--height 40% --layout=reverse --border' }
if (Test-Cmd zoxide) {
    try { Invoke-Expression (& { (zoxide init powershell | Out-String) }) } catch {}
}
if (Test-Cmd delta) { $env:GIT_PAGER = 'delta' }

# ---- Git-aware prompt (disable with: $GitPromptEnabled = $false) -----------
$GitPromptEnabled = $true
function prompt {
    $loc = $ExecutionContext.SessionState.Path.CurrentLocation
    Write-Host ($loc.Path) -NoNewline -ForegroundColor Cyan
    if ($GitPromptEnabled -and (Test-Cmd git)) {
        $branch = git rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $branch) {
            Write-Host (" [" + $branch + "]") -NoNewline -ForegroundColor Yellow
        }
    }
    if ($global:LASTEXITCODE -ne 0) { Write-Host (" (" + $global:LASTEXITCODE + ")") -NoNewline -ForegroundColor Red }
    Write-Host ''
    return '> '
}

# ---- Taste projection: Command Code taste -> every agent's file (daily) ----
function taste-sync { & (Join-Path $PSScriptRoot 'sync-taste.ps1') @args }
try {
    $stamp = Join-Path $HOME '.commandcode\.taste-sync-stamp'
    $due = $true
    if (Test-Path $stamp) { if (((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalHours -lt 24) { $due = $false } }
    if ($due) {
        Set-Content -Path $stamp -Value (Get-Date -Format o) -Force
        $ts = Join-Path $PSScriptRoot 'sync-taste.ps1'
        if (Test-Path $ts) { & $ts | Out-Null }
    }
} catch {}
