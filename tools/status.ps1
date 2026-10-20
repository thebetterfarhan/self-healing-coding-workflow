#Requires -Version 5.1
<#
.SYNOPSIS
  One-screen health check for the workflow.

.DESCRIPTION
  Answers "is this workflow healthy?" without reading anything.

  Shows: what is installed and whether the layers agree, the nightly repair
  task and its last result, drift in each synced layer, backend health, and
  the most recent failure if there was one.

  Read-only. Never writes. Exits 0 when everything is healthy, 1 when
  something needs attention.

.EXAMPLE
  ./status.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$Tools   = $PSScriptRoot
$Home_   = $env:USERPROFILE
$Root    = Split-Path $Tools -Parent
$problems = @()

function Line($label, $value, $state) {
    $color = 'Gray'
    if ($state -eq 'ok') { $color = 'Green' }
    elseif ($state -eq 'bad') { $color = 'Red' }
    elseif ($state -eq 'warn') { $color = 'Yellow' }
    Write-Host ('  {0,-24}' -f $label) -NoNewline
    Write-Host $value -ForegroundColor $color
}

Write-Host ''
Write-Host 'Workflow status' -ForegroundColor White
Write-Host ''

# --- install ---------------------------------------------------------------
Write-Host 'Install' -ForegroundColor Cyan
$policyPaths = @(
    (Join-Path $Home_ '.codex\AGENTS.md'),
    (Join-Path $Home_ '.config\opencode\AGENTS.md'),
    (Join-Path $Home_ '.commandcode\AGENTS.md')
)
$present = @($policyPaths | Where-Object { Test-Path $_ })
if ($present.Count -eq 3) {
    $hashes = @($present | ForEach-Object { (Get-FileHash $_ -Algorithm MD5).Hash })
    if (($hashes | Select-Object -Unique).Count -eq 1) {
        Line 'policy' ("in sync across 3 CLIs ({0})" -f $hashes[0].Substring(0, 8)) 'ok'
    } else {
        Line 'policy' 'DRIFTED across CLIs - run sync-agent-instructions.ps1' 'bad'
        $problems += 'policy drift'
    }
} else {
    Line 'policy' ("only {0}/3 installed - run setup.ps1" -f $present.Count) 'bad'
    $problems += 'policy missing'
}

$skillRoots = @(
    (Join-Path $Home_ '.agents\skills'),
    (Join-Path $Home_ '.codex\skills'),
    (Join-Path $Home_ '.config\opencode\skills'),
    (Join-Path $Home_ '.commandcode\skills')
)
# .system is Codex's own private helper folder and is never synced, so it is
# not counted - otherwise the codex total always looks one ahead.
$skillCounts = @($skillRoots | ForEach-Object {
    if (Test-Path $_) {
        @(Get-ChildItem $_ -Directory | Where-Object { $_.Name -ne '.system' }).Count
    } else { 0 }
})
if ($skillCounts[0] -eq 0) {
    Line 'skills' 'no canonical skill set - run setup.ps1' 'bad'
    $problems += 'no canonical skills'
} elseif ($skillCounts[1] -eq $skillCounts[0] -and $skillCounts[2] -eq $skillCounts[0] -and $skillCounts[3] -eq $skillCounts[0]) {
    Line 'skills' ("{0} canonical, rendered into all three CLIs" -f $skillCounts[0]) 'ok'
} else {
    Line 'skills' ("DRIFTED canonical={0} codex={1} opencode={2} commandcode={3}" -f $skillCounts) 'warn'
    $problems += 'skill drift'
}

$roster = Join-Path $Home_ '.codex\agents'
if (Test-Path $roster) {
    Line 'roster' ("{0} agents rendered" -f @(Get-ChildItem $roster -Filter '*.toml').Count) 'ok'
} else { Line 'roster' 'not rendered' 'warn'; $problems += 'roster missing' }

$taste = Join-Path $Home_ '.commandcode\taste\taste.md'
if (Test-Path $taste) {
    $entries = ([regex]::Matches([System.IO.File]::ReadAllText($taste), '(?m)^- ')).Count
    Line 'taste' ("$entries entries (edit to make them yours)") 'ok'
} else { Line 'taste' 'not seeded - run setup.ps1' 'warn'; $problems += 'no taste' }

$hooksPath = Join-Path $Home_ '.codex\hooks.json'
if (Test-Path $hooksPath) {
    $h = [System.IO.File]::ReadAllText($hooksPath)
    if ($h -match 'guard-hook\.ps1') { Line 'guard hook' 'wired (PreToolUse)' 'ok' }
    else { Line 'guard hook' 'NOT wired - run setup.ps1' 'warn'; $problems += 'guard hook missing' }
} else { Line 'guard hook' 'no hooks.json' 'warn'; $problems += 'hooks.json missing' }

# --- configuration repository ------------------------------------------------
Write-Host ''
Write-Host 'Configuration repo' -ForegroundColor Cyan
$repair = Join-Path $Tools 'repair-config.ps1'
if (-not (Test-Path (Join-Path $Root '.git'))) {
    # Not set up yet: the installer and the nightly job create it.
    Line 'files' 'no repository yet - run tools/repair-config.ps1' 'warn'
} elseif (Test-Path $repair) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repair -Check 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        $dirty = @(& git -C $Root status --porcelain 2>$null | Where-Object { $_ })
        if ($dirty.Count -gt 0) {
            # Uncommitted configuration edits are normal while the user works;
            # the nightly job records them. Not a health problem.
            Line 'files' ("{0} uncommitted change(s) - the nightly job records them" -f $dirty.Count) 'warn'
        } else {
            $head = (& git -C $Root log -1 --format='%h %s' 2>$null | Out-String).Trim()
            Line 'files' ("clean - {0}" -f $head) 'ok'
        }
    } else {
        Line 'files' 'BROKEN - run tools/repair-config.ps1' 'bad'
        $problems += 'configuration repo has a broken file'
    }
} else {
    Line 'files' 'no repair-config.ps1' 'warn'
}

# --- nightly repair --------------------------------------------------------
Write-Host ''
Write-Host 'Nightly repair' -ForegroundColor Cyan
$task = Get-ScheduledTask -TaskName 'CodexWorkflowSelfHeal' -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName 'CodexWorkflowSelfHeal' -ErrorAction SilentlyContinue
    Line 'task' ("{0} ({1})" -f $task.State, ($task.Triggers | ForEach-Object { $_.StartBoundary })) 'ok'
    if ($info) {
        $res = if ($info.LastTaskResult -eq 0) { 'ok' } else { 'bad' }
        Line 'last run' ("{0}   result {1}" -f $info.LastRunTime, $info.LastTaskResult) $res
        if ($info.LastTaskResult -ne 0) { $problems += "nightly task result $($info.LastTaskResult)" }
        Line 'next run' ("{0}" -f $info.NextRunTime) 'ok'
    }
} else {
    Line 'task' 'NOT registered - run setup.ps1' 'bad'
    $problems += 'nightly task missing'
}

$log = Join-Path $Tools 'self-repair.log'
if (Test-Path $log) {
    $summary = @(Get-Content $log | Where-Object { $_ -match 'run complete' } | Select-Object -Last 1)
    if ($summary) {
        $line = $summary[0]
        $tail = if ($line -match '(run complete.*)$') { $Matches[1] } else { $line.Trim() }
        $ok = if ($line -match 'failed=0') { 'ok' } else { 'bad' }
        Line 'last steps' $tail $ok
        if ($line -notmatch 'failed=0') { $problems += 'last repair run had failures' }
    }
    $failLog = Join-Path $Tools 'self-repair-failures.log'
    if ((Test-Path $failLog) -and (Get-Item $failLog).Length -gt 0) {
        $last = @(Get-Content $failLog | Where-Object { $_ -match '^====' } | Select-Object -Last 1)
        if ($last) { Line 'last failure' $last[0] 'warn' }
    } else {
        Line 'last failure' 'none recorded' 'ok'
    }
} else {
    Line 'last steps' 'no log yet - run self-repair.ps1 once' 'warn'
}

# --- drift -----------------------------------------------------------------
Write-Host ''
Write-Host 'Drift' -ForegroundColor Cyan
foreach ($s in @('sync-agents.ps1', 'sync-agent-instructions.ps1', 'sync-skills.ps1', 'sync-taste.ps1')) {
    $p = Join-Path $Tools $s
    if (-not (Test-Path $p)) { Line $s 'script missing' 'bad'; continue }
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Check 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -eq 0) { Line ($s -replace '\.ps1$','') 'in sync' 'ok' }
    elseif ($code -eq 2) { Line ($s -replace '\.ps1$','') 'DRIFT - run it' 'warn'; $problems += "$s drift" }
    else { Line ($s -replace '\.ps1$','') 'check failed' 'bad'; $problems += "$s check failed" }
}

# --- backends --------------------------------------------------------------
Write-Host ''
Write-Host 'Backends' -ForegroundColor Cyan
function Test-ActiveUntil($until) {
    try { return ([datetime]$until) -gt (Get-Date) } catch { return $false }
}
$healthPath = Join-Path $Tools 'agent-backend-health.json'
if (Test-Path $healthPath) {
    $bj = [System.IO.File]::ReadAllText($healthPath) | ConvertFrom-Json
    foreach ($b in @('codex', 'commandcode', 'opencode')) {
        $entry = if ($bj.PSObject.Properties[$b]) { $bj.$b } else { $null }
        if ($entry -and (Test-ActiveUntil $entry.unhealthyUntil)) {
            Line $b ("unhealthy until {0}: {1}" -f $entry.unhealthyUntil, $entry.reason) 'warn'
            $problems += "$b unhealthy"
        } else { Line $b 'healthy' 'ok' }
        if ($entry -and $entry.paidExhausted -and (Test-ActiveUntil $entry.paidExhaustedUntil)) {
            Line "$b paid" ("exhausted until {0}: {1}" -f $entry.paidExhaustedUntil, $entry.paidExhaustedReason) 'warn'
            $problems += "$b paid exhausted"
        }
    }
} else { Line 'health' 'no health file yet' 'warn' }

$usageScript = Join-Path $Tools 'agent-usage.ps1'
if (Test-Path $usageScript) {
    try {
        $u = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $usageScript -Json 2>$null | Out-String) | ConvertFrom-Json
        if ($u.commandCode.coolingDown) { Line 'commandcode' ("cooling down until {0}" -f $u.commandCode.cooldownUntil) 'warn' }
        if ($u.opencode.costs) {
            $c = $u.opencode.costs.last24h
            Line 'spend 24h' ("{0} requests, {1}" -f $c.requests, ('${0:N4}' -f [double]$c.cost)) 'ok'
        }
    } catch { Line 'spend' 'unavailable' 'warn' }
}

Write-Host ''
if ($problems.Count -eq 0) {
    Write-Host 'Healthy. Nothing needs attention.' -ForegroundColor Green
    exit 0
}
Write-Host ("{0} thing(s) need attention:" -f $problems.Count) -ForegroundColor Yellow
$problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
Write-Host ''
Write-Host 'Most fixes are one command:  tools/setup.ps1' -ForegroundColor Gray
exit 1
