<#
  agent-task.ps1 — route one task to one CLI, with free-model and cross-agent
  fallback.

  The short name is `work` (see the PowerShell profile). Model choice per task
  tier lives in agent-route.ps1; edit that table, not this file. Backends:
  codex, commandcode, opencode.

  Fallback, in order: if the primary agent fails with an infrastructure
  signature (usage limit, plan restriction, auth, unreachable, missing binary),
  the same backend is retried once on a free model (disable with
  -NoFreeFallback), then the same task is re-run once with another CLI
  (disable with -NoFallback).
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Task,

    [string]$WorkDir = (Get-Location).Path,

    [ValidateSet('auto', 'quick', 'standard', 'deep')]
    [string]$Complexity = 'auto',

    [ValidateSet('auto', 'codex', 'commandcode', 'opencode')]
    [string]$Agent = 'auto',

    [string]$Model,

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string]$Effort,

    [switch]$ReadOnly,

    [switch]$Headless,   # bridge use: run edit-capable Command Code without a TTY

    [switch]$Static,      # use the hand-picked model table, not the price picker

    [switch]$NoFree,      # price picker excludes free models

    [switch]$NoFreeFallback,  # do not retry on a free model when paid is unavailable

    [switch]$NoFallback,

    [ValidateRange(1, 4)]
    [int]$N = 1,          # Best-of-N: run N attempts in parallel wt-style sandboxes

    [switch]$Preview
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agent-route.ps1')

$resolvedDir   = (Resolve-Path -LiteralPath $WorkDir).Path
$infraPatterns = '(?i)(usage limit|rate.?limit|quota|insufficient credits|too many requests|\b429\b|\b401\b|\b403\b|MODEL_NOT_IN_PLAN|no longer available|is not available|model.{0,20}not.{0,10}available|no longer supported|not signed in|unauthor|forbidden|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|unexpected server error|not recognized as an internal|cannot find the file|is not recognized|requires a TTY|TTY terminal|interactive mode|npm codex shim missing|helper_unknown_error|setup refresh had errors)'

if ($Complexity -eq 'auto') { $Complexity = Get-TaskTier -Task $Task }
if ($Complexity -eq 'quick' -and $Task -match $AgentLookupRequest) { $ReadOnly = $true }

if ($Agent -eq 'auto') {
    $Agent = Get-AutoBackend -ReadOnly:$ReadOnly -Complexity $Complexity
    # Interactive Command Code edits need a TTY unless the bridge requests headless mode.
    $hasTty = -not [Console]::IsOutputRedirected
    if (-not $Headless -and -not $hasTty -and -not $ReadOnly -and $Complexity -ne 'quick' -and $Agent -eq 'commandcode') {
        if (Test-BackendHealthy -Backend 'opencode') {
            Write-Host "  (no TTY for Command Code interactive -> using OpenCode)"
            $Agent = 'opencode'
        } elseif (Test-BackendHealthy -Backend 'codex') {
            Write-Host "  (no TTY for Command Code interactive -> using Codex)"
            $Agent = 'codex'
        }
    }
}

function Resolve-Route {
    param([string]$Backend, [switch]$ApplyOverrides)
    $route = Get-AgentRoute -Task $Task -Complexity $Complexity -Backend $Backend -Static:$Static -NoFree:$NoFree
    [pscustomobject]@{
        Tier   = $route.Tier
        Model  = if ($ApplyOverrides -and $Model) { $Model } else { $route.Model }
        Effort = if ($ApplyOverrides -and $Effort) { $Effort } else { $route.Effort }
        Cost   = $route.Cost
        Priced = $route.Priced
    }
}

function Invoke-Backend {
    param([string]$Backend, [string]$ModelId, [string]$EffortLevel, [string]$OutFile)
    # Native CLIs write progress/notices to stderr (e.g. Command Code's "Reasoning
    # effort set to ..." note). Under the script-wide 'Stop' those records would
    # terminate the pipeline, so relax it for this call only (function-local).
    $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $resolvedDir
    try {
        if ($Backend -eq 'codex') {
            # desktop codex 0.162.x ships the broken Windows sandbox helper
            # (openai/codex#51634, os error 32); only the npm shim is usable.
            $npmCodex = Join-Path $env:LOCALAPPDATA 'BlindPilot\npm\codex.cmd'
            if (Test-Path -LiteralPath $npmCodex) {
                $codex = $npmCodex
            } else {
                throw "npm codex shim missing: $npmCodex (desktop codex.exe sandbox helper is broken, openai/codex#51634). Reinstall: npm install -g --prefix `"$env:LOCALAPPDATA\BlindPilot\npm`" @openai/codex@0.163.0"
            }
            $a = @('exec')
            if ($ModelId)     { $a += @('--model', $ModelId) }
            if ($EffortLevel) { $a += @('--config', "model_reasoning_effort=$EffortLevel") }
            if ($ReadOnly)    { $a += @('--sandbox', 'read-only') }
            elseif ($Headless) { $a += @('--sandbox', 'workspace-write') }
            $ancestor = Get-Item -LiteralPath $resolvedDir
            while ($ancestor -and -not (Test-Path -LiteralPath (Join-Path $ancestor.FullName '.git'))) {
                $ancestor = $ancestor.Parent
            }
            if (-not $ancestor) { $a += '--skip-git-repo-check' }
            & $codex @a $Task 2>&1 | Tee-Object -FilePath $OutFile | Out-Host
        } elseif ($Backend -eq 'opencode') {
            $op = (Get-Command opencode.cmd -ErrorAction Stop).Source
            $a = @('run')
            if ($ModelId)     { $a += @('--model', $ModelId) }
            if ($EffortLevel) { $a += @('--variant', $EffortLevel) }
            if ($ReadOnly)    { $a += @('--agent', $(if ($Headless) { 'interop_read' } else { 'plan' })) }
            elseif ($Headless) { $a += @('--agent', 'interop_edit', '--auto') }
            else              { $a += '--auto' }
            & $op @a $Task 2>&1 | Tee-Object -FilePath $OutFile | Out-Host
        } else {
            $node = (Get-Command node.exe -ErrorAction Stop).Source
            $cli  = Join-Path $env:LOCALAPPDATA 'BlindPilot\npm\node_modules\command-code\dist\index.mjs'
            if (-not (Test-Path -LiteralPath $cli)) { throw "Command Code CLI missing: $cli" }
            $a = @($cli)
            if ($ModelId)     { $a += @('--model', $ModelId) }
            if ($EffortLevel) { $a += @('--effort', $EffortLevel) }
            $a += '--skip-onboarding'
            if ($ReadOnly)      { $a += @('--plan', '-p', $Task) }
            elseif ($Headless)  { $a += @('--accept-edits', '-p', $Task) }
            else                { $a += $Task }
            # Capture output to variable first (preserves full output including
            # messages that may not flush to Tee-Object), then write to file.
            $output = & $node @a 2>&1
            $exitCode = $LASTEXITCODE
            # Convert ErrorRecords to strings for proper file capture
            $output | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
            } | Out-Host
            $output | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
            } | Set-Content -LiteralPath $OutFile -Encoding UTF8
            return [int]$exitCode
        }
        return [int]$LASTEXITCODE
    } finally {
        Pop-Location
    }
}

function Test-InfraFailure {
    param([string]$OutFile)
    if (-not (Test-Path -LiteralPath $OutFile)) { return $true }
    $text = Get-Content -LiteralPath $OutFile -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return $true }
    return [bool]($text -match $infraPatterns)
}

function Get-LimitCooldownMinutes {
    <#  Parse a usage-limit message for the reset window, in minutes. #>
    param([string]$OutFile)
    if (-not (Test-Path -LiteralPath $OutFile)) { return $null }
    $text = Get-Content -LiteralPath $OutFile -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return $null }
    if ($text -notmatch '(?i)(usage limit|rate.?limit)') { return $null }
    if ($text -match '(?i)resets? in\s+(?:(\d+)\s*h(?:our)?s?\s*)?(?:(\d+)\s*m(?:in)?)?') {
        $h = if ($matches[1]) { [int]$matches[1] } else { 0 }
        $m = if ($matches[2]) { [int]$matches[2] } else { 0 }
        $total = $h * 60 + $m
        if ($total -gt 0) { return $total }
    }
    if ($text -match '(?i)(?:try again|resets?)\D{0,24}(\d{1,2}):(\d{2})\s*(am|pm)') {
        $hh = [int]$matches[1] % 12; $mm = [int]$matches[2]
        if ($matches[3] -eq 'pm') { $hh += 12 }
        $target = (Get-Date).Date.AddHours($hh).AddMinutes($mm)
        if ($target -le (Get-Date)) { $target = $target.AddDays(1) }
        return [int][Math]::Ceiling(($target - (Get-Date)).TotalMinutes)
    }
    return 300   # a 5-hour window; assume the full window when unparseable
}

function Invoke-WithRecovery {
    param([string]$Backend, [string]$ModelId, [string]$EffortLevel, [string]$OutFile)
    try {
        return Invoke-Backend -Backend $Backend -ModelId $ModelId -EffortLevel $EffortLevel -OutFile $OutFile
    } catch {
        Write-Host "  ! $Backend could not start: $($_.Exception.Message)"
        Add-Content -LiteralPath $OutFile -Value "could not start $Backend : $($_.Exception.Message)" -ErrorAction SilentlyContinue
        return 1
    }
}

function Invoke-Run {
    <#  One attempt. A provider credit/limit error aborts some CLIs with exit
        code 0 (Command Code v1.84.0 exits 0 after "Insufficient credits for
        Command Code."), so the exit code alone would report a success that
        never ran the task and the chain would stop there. Treat it as failed. #>
    param([string]$Backend, [string]$ModelId, [string]$EffortLevel, [string]$OutFile)
    $rc0 = Invoke-WithRecovery -Backend $Backend -ModelId $ModelId -EffortLevel $EffortLevel -OutFile $OutFile
    $rc = Resolve-RunExit -ExitCode $rc0 -OutFile $OutFile
    if ($rc0 -eq 0 -and $rc -ne 0) {
        Write-Host "  ! $Backend reported a provider credit/limit error but exited 0 -> treating it as failed."
    }
    return $rc
}

# Adaptive tier tracking: log the classified tier and outcome.
$tierOutcomePath = Join-Path $PSScriptRoot 'agent-tier-outcomes.jsonl'
$tierOutcomeRecord = [ordered]@{
    time         = (Get-Date).ToString('s')
    taskHash     = ($Task.GetHashCode()).ToString()
    tier         = $Complexity
    exitCode     = $null
    infraFailure = $false
}

$primary   = Resolve-Route -Backend $Agent -ApplyOverrides
$alternate = if ($Agent -in @('codex', 'commandcode', 'opencode')) {
    # Pick the next healthy backend in preference order
    $prefOrder = @('codex', 'commandcode', 'opencode')
    $idx = $prefOrder.IndexOf($Agent)
    $found = $null
    for ($i = 1; $i -lt $prefOrder.Count; $i++) {
        $candidate = $prefOrder[($idx + $i) % $prefOrder.Count]
        if ($candidate -ne $Agent -and (Test-BackendHealthy -Backend $candidate)) { $found = $candidate; break }
    }
    $found
} else { $null }
$altRoute  = if ($alternate) { Resolve-Route -Backend $alternate } else { $null }

# Usage-aware reroute: if Command Code is cooling down (5-hour limit) and no free
# model fits this tier, the picker returns no model - so do not run a paid model.
if ($Agent -eq 'commandcode' -and -not $primary.Model -and -not $Static -and -not $NoFallback) {
    if (Test-BackendHealthy -Backend 'codex') {
        Write-Host '  ! Command Code is over its usage limit and no free model fits this tier -> using Codex.'
        $Agent     = 'codex'
        $primary   = Resolve-Route -Backend $Agent -ApplyOverrides
        $alternate = 'commandcode'
        $altRoute  = Resolve-Route -Backend $alternate
    } elseif (Test-BackendHealthy -Backend 'opencode') {
        Write-Host '  ! Command Code is over its usage limit and no free model fits this tier -> using OpenCode.'
        $Agent     = 'opencode'
        $primary   = Resolve-Route -Backend $Agent -ApplyOverrides
        $alternate = $null
        $altRoute  = $null
    }
}

$tierOutcomeRecord.backend = $Agent
$tierOutcomeRecord.model   = if ($primary.Model) { $primary.Model } else { 'default' }
$finalOut = $null

$agentLabel = if ($Agent -eq 'commandcode') { 'Command Code' } elseif ($Agent -eq 'opencode') { 'OpenCode' } else { 'Codex' }
$altLabel   = if ($alternate -eq 'commandcode') { 'Command Code' } elseif ($alternate -eq 'opencode') { 'OpenCode' } else { 'Codex' }
$modeLabel  = if ($ReadOnly) { 'read-only' } elseif ($Agent -eq 'commandcode') { if ($Headless) { 'headless accept-edits' } else { 'interactive' } } else { 'automatic' }
$primaryModelLabel = if ($primary.Model) { $primary.Model } else { 'default model' }
$altModelLabel     = if ($altRoute.Model) { $altRoute.Model } else { 'default model' }

if ($Preview) {
    [pscustomobject]@{
        Agent    = $Agent
        Tier     = $primary.Tier
        Model    = $primaryModelLabel
        Effort   = if ($primary.Effort) { $primary.Effort } else { '(none)' }
        EstCost  = if ($primary.Priced) { ('${0:N6}/request (typical profile)' -f $primary.Cost) }
                   elseif ($Agent -eq 'codex') { 'n/a (subscription)' }
                   else { 'n/a (static table)' }
        WorkDir  = $resolvedDir
        ReadOnly = [bool]$ReadOnly
        Mode     = $modeLabel
        Fallback = if ($alternate -and -not $NoFallback) { "$alternate ($altModelLabel)" } else { '(none)' }
    } | Format-List | Out-String | Write-Host
    return
}

Write-Host "Starting: $agentLabel, $primaryModelLabel, $(if ($primary.Effort) { $primary.Effort } else { 'default' }) effort, $modeLabel."

$logDir = Join-Path $env:TEMP 'agent-task'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$uniq    = '{0:x8}-{1}' -f $PID, (Get-Random -Maximum 0x10000)
$outFile = Join-Path $logDir ("{0}-{1}-{2}.log" -f $Agent, (Get-Date -Format 'yyyyMMdd-HHmmss'), $uniq)
Write-Host "(log: $outFile)"
$finalOut = $outFile
$attemptLogs = @($outFile)   # every log this run produced, in order

# Best-of-N: same task, N parallel attempts, each in its own fresh wt worktree,
# so the attempts can never touch each other's files. You pick the report.
if ($N -gt 1) {
    $root  = Split-Path $PSScriptRoot -Parent
    $repo  = Split-Path $resolvedDir -Leaf
    $stamp = Get-Date -Format 'HHmmss'
    $created = @()
    try {
        $attempts = for ($i = 1; $i -le $N; $i++) {
            $name   = "bestof-$stamp-a$i"
            $wtPath = Join-Path (Join-Path $root '.worktrees') "$repo-$name"
            & (Join-Path $PSScriptRoot 'new-worktree.ps1') -Repo $resolvedDir -Name $name | Out-Null
            if (-not (Test-Path -LiteralPath $wtPath)) { throw "best-of-N: worktree for attempt $i failed to create" }
            $created += $wtPath
            [pscustomobject]@{ Index = $i; Path = $wtPath }
        }
    } catch {
        foreach ($w in $created) { git worktree remove --force $w 2>$null }
        throw
    }
    Write-Host "Best-of-$N in parallel worktrees: $($attempts.Path -join ' | ')"

    $jobs = foreach ($a in $attempts) {
        if ($a.Index -gt 1) { Start-Sleep -Seconds 8 }
        Start-Job -Name "bestof-a$($a.Index)" -ScriptBlock {
            param($s, $d, $t, $ag, $m, $e, $ro, $st, $nf, $nfb, $nofb)
            $p = @{ Task = $t; WorkDir = $d; Agent = $ag; N = 1 }
            if ($m)  { $p.Model  = $m }
            if ($e)  { $p.Effort = $e }
            if ($ro) { $p.ReadOnly = $true }
            if ($st) { $p.Static = $true }
            if ($nf) { $p.NoFree = $true }
            if ($nfb) { $p.NoFreeFallback = $true }
            if ($nofb) { $p.NoFallback = $true }
            & $s @p
        } -ArgumentList $PSCommandPath, $a.Path, $Task, $Agent, $primary.Model, $primary.Effort,
            [bool]$ReadOnly, [bool]$Static, [bool]$NoFree, [bool]$NoFreeFallback, [bool]$NoFallback
    }
    $jobs | Wait-Job | Out-Null

    foreach ($a in $attempts) {
        $job = Get-Job -Name "bestof-a$($a.Index)"
        Write-Host ('=' * 70)
        Write-Host "attempt $($a.Index): $($a.Path)"
        try { $job | Receive-Job } catch { Write-Host "  attempt $($a.Index) failed: $($_.Exception.Message)" }
        $stat = git -C $a.Path diff HEAD --stat 2>$null
        $st   = @(git -C $a.Path status --porcelain 2>$null)
        Write-Host ("changed: {0} file(s)`n{1}" -f $st.Count, ($stat | Out-String))
    }
    $jobs | Remove-Job -Force
    return
}

$code = Invoke-Run -Backend $Agent -ModelId $primary.Model -EffortLevel $primary.Effort -OutFile $outFile
# Route learning: record this attempt so repeated infra failures on a model
# demote it in future runs (agent-route.ps1 Get-RoutePenalties).
Add-RouteOutcome -Backend $Agent -Model $(if ($primary.Model) { $primary.Model } else { 'default' }) `
    -Tier $primary.Tier -ExitCode $code `
    -InfraFailure $(if ($code -ne 0 -and (Test-InfraFailure -OutFile $outFile)) { 'yes' } else { '' })
# Backend health: mark dead backends so the next run skips them automatically.
if ($code -eq 0) { Clear-BackendUnhealthy -Backend $Agent } `
elseif (Test-InfraFailure -OutFile $outFile) { Set-BackendUnhealthy -Backend $Agent -Reason 'infra failure' }
# Paid-exhausted detection: if a paid model failed due to insufficient credits,
# mark paid models as exhausted on this backend (free models still work).
if ($code -ne 0 -and $primary.Model -and $primary.Model -notmatch ':free|free$' -and (Test-Path -LiteralPath $outFile)) {
    $outText = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
    if ($outText -match '(?i)insufficient credits') {
        Set-PaidExhausted -Backend $Agent -Reason 'insufficient credits'
    }
}

# Usage-aware: record a limit so the next run withholds paid models for this backend.
if ($code -ne 0) {
    $mins = Get-LimitCooldownMinutes -OutFile $outFile
    if ($mins) {
        if ($Agent -eq 'commandcode') {
            Set-CommandCodeCooldown -Minutes $mins -Reason '5-hour usage limit'
            Write-Host "  ! Command Code usage limit recorded; paid models withheld for ~$mins min (clear with agent-usage.ps1 -ClearCooldown)."
        } elseif ($Agent -eq 'opencode') {
            Set-OpenCodeCooldown -Minutes $mins -Reason 'usage limit'
            Write-Host "  ! OpenCode usage limit recorded; paid models withheld for ~$mins min (clear with agent-usage.ps1 -ClearCooldown)."
        } else {
            # Codex has no separate cooldown store: hold the backend unhealthy
            # so the router skips it instead of burning a failed run on every
            # task. The reset time it prints is not reliable (on 2026-10-20 it
            # said "try again at 5:11 AM" and the backend worked 35 minutes
            # later), so the hold is capped at an hour.
            $hold = [Math]::Min($mins, 60)
            Set-BackendUnhealthy -Backend $Agent -Minutes $hold -Reason 'usage limit'
            Write-Host "  ! $Agent usage limit recorded; backend held for ~$hold min."
        }
    }
}

# Free-model fallback: paid model unavailable (plan-restricted, limit, auth) ->
# retry the same backend once on a free model before changing backends.
if ($code -ne 0 -and -not $NoFree -and -not $NoFreeFallback -and (Test-InfraFailure -OutFile $outFile)) {
    $freeModel = Select-FreeModel -Backend $Agent -Exclude @($primary.Model)
    if ($freeModel) {
        Write-Host "  -> $agentLabel paid model unavailable; retrying on free model $freeModel..."
        $freeOut = Join-Path $logDir ("{0}-free-{1}-{2}.log" -f $Agent, (Get-Date -Format 'yyyyMMdd-HHmmss'), $uniq)
        $code = Invoke-Run -Backend $Agent -ModelId $freeModel -EffortLevel $null -OutFile $freeOut
        $finalOut = $freeOut
        $attemptLogs += $freeOut
        $tierOutcomeRecord.model = $freeModel
        Add-RouteOutcome -Backend $Agent -Model $freeModel -Tier $primary.Tier -ExitCode $code `
            -InfraFailure $(if ($code -ne 0 -and (Test-InfraFailure -OutFile $freeOut)) { 'yes' } else { '' })
        if ($code -eq 0) { Clear-BackendUnhealthy -Backend $Agent } `
        elseif (Test-InfraFailure -OutFile $freeOut) { Set-BackendUnhealthy -Backend $Agent -Reason 'free model failed' }
        if ($code -eq 0) { Write-Host "Done via free $agentLabel model ($freeModel)." }
    }
}

# Cross-backend fallback: try every remaining backend, in health-aware order.
# A backend that fails with an infra signature is retried once on a free model
# before the chain moves on. That is the self-healing step: out of credits ->
# free model -> next backend -> (only then) give up.
if ($code -ne 0 -and -not $NoFallback -and (Test-InfraFailure -OutFile $finalOut)) {
    $paidFirst = -not ($ReadOnly -or $Complexity -eq 'quick')
    $candidates = @(Get-BackendRanking -PaidFirst:$paidFirst) | Where-Object { $_ -ne $Agent }
    $healthyCandidates = @($candidates | Where-Object { Test-BackendHealthy -Backend $_ })
    if ($healthyCandidates.Count -gt 0) { $candidates = $healthyCandidates }
    foreach ($cand in $candidates) {
        if ($code -eq 0) { break }
        $candRoute  = Resolve-Route -Backend $cand
        $candLabel  = if ($cand -eq 'commandcode') { 'Command Code' } elseif ($cand -eq 'opencode') { 'OpenCode' } else { 'Codex' }
        $candModelLabel = if ($candRoute.Model) { $candRoute.Model } else { 'default model' }
        $candOut = Join-Path $logDir ("{0}-{1}-{2}.log" -f $cand, (Get-Date -Format 'yyyyMMdd-HHmmss'), $uniq)
        Write-Host "  -> falling back to $candLabel, $candModelLabel..."
        $code = Invoke-Run -Backend $cand -ModelId $candRoute.Model -EffortLevel $candRoute.Effort -OutFile $candOut
        $finalOut = $candOut
        $attemptLogs += $candOut
        $tierOutcomeRecord.backend = $cand
        $tierOutcomeRecord.model   = if ($candRoute.Model) { $candRoute.Model } else { 'default' }
        Add-RouteOutcome -Backend $cand -Model $(if ($candRoute.Model) { $candRoute.Model } else { 'default' }) `
            -Tier $candRoute.Tier -ExitCode $code `
            -InfraFailure $(if ($code -ne 0 -and (Test-InfraFailure -OutFile $candOut)) { 'yes' } else { '' })
        if ($code -eq 0) { Clear-BackendUnhealthy -Backend $cand } `
        elseif (Test-InfraFailure -OutFile $candOut) { Set-BackendUnhealthy -Backend $cand -Reason 'fallback failed' }
        # Paid-exhausted detection for the fallback backend.
        if ($code -ne 0 -and $candRoute.Model -and $candRoute.Model -notmatch ':free|free$' -and (Test-Path -LiteralPath $candOut)) {
            $candText = Get-Content -LiteralPath $candOut -Raw -ErrorAction SilentlyContinue
            if ($candText -match '(?i)insufficient credits') {
                Set-PaidExhausted -Backend $cand -Reason 'insufficient credits'
            }
        }
        # Same backend, free model: the paid credit wall is the usual reason the
        # first attempt died.
        if ($code -ne 0 -and -not $NoFreeFallback -and (Test-InfraFailure -OutFile $candOut)) {
            $candFree = Select-FreeModel -Backend $cand -Exclude @($candRoute.Model)
            if ($candFree) {
                Write-Host "  -> $candLabel model unavailable; retrying on free model $candFree..."
                $candFreeOut = Join-Path $logDir ("{0}-free-{1}-{2}.log" -f $cand, (Get-Date -Format 'yyyyMMdd-HHmmss'), $uniq)
                $code = Invoke-Run -Backend $cand -ModelId $candFree -EffortLevel $null -OutFile $candFreeOut
                $finalOut = $candFreeOut
                $attemptLogs += $candFreeOut
                $tierOutcomeRecord.model = $candFree
                Add-RouteOutcome -Backend $cand -Model $candFree -Tier $candRoute.Tier -ExitCode $code `
                    -InfraFailure $(if ($code -ne 0 -and (Test-InfraFailure -OutFile $candFreeOut)) { 'yes' } else { '' })
                if ($code -eq 0) { Clear-BackendUnhealthy -Backend $cand } `
                elseif (Test-InfraFailure -OutFile $candFreeOut) { Set-BackendUnhealthy -Backend $cand -Reason 'free model failed' }
                if ($code -eq 0) { Write-Host "Done via free $candLabel model ($candFree)." }
            }
        }
        if ($code -eq 0) { Write-Host "Done via fallback ($candLabel)." }
    }
}
if ($code -ne 0) {
    $finalError = if ($attemptLogs.Count -gt 1) {
        "Every backend failed for this task. Logs: $($attemptLogs -join ' ; ')"
    } else {
        "$Agent exited with code $code (log: $outFile)."
    }
}

# Log final tier outcome (after all fallbacks), then surface any failure.
$tierOutcomeRecord.exitCode = $code
$tierOutcomeRecord.infraFailure = ($code -ne 0 -and (Test-InfraFailure -OutFile $finalOut))
$tierOutcomeRecord | ConvertTo-Json -Compress | Add-Content -LiteralPath $tierOutcomePath -Encoding UTF8
if ($finalError) { throw $finalError }
