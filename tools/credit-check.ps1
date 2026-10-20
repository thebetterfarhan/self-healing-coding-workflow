#Requires -Version 5
<#
  credit-check.ps1 — probe credit availability across all backends and update
  backend health / paid-exhausted flags automatically.

  - Codex: no headless subscription check — health comes from real run
    results (agent-task.ps1 sets/clears the flag on success/infra failure).
  - Command Code: probes with a tiny paid-model request; detects
    "insufficient credits" in output.
  - OpenCode: reads recent cost from its local SQLite DB (if sqlite3 available).

  Updates agent-backend-health.json so the router auto-skips dead backends
  and auto-uses free models when paid credits are exhausted.
#>
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'agent-route.ps1')

$probeTask = 'Reply with exactly: OK'
$probeTimeout = 90

# --- Codex: left alone; agent-task.ps1 marks/clears health per real run ---
Write-Output "Codex: health tracked by run results (no headless subscription check)"

# --- Command Code: probe with a tiny paid-model request ---
$ccStatus = 'unknown'
$probeOut = Join-Path $env:TEMP 'credit-probe-cc-out.log'
$probeErr = Join-Path $env:TEMP 'credit-probe-cc-err.log'
$cli = Join-Path $env:LOCALAPPDATA 'BlindPilot\npm\node_modules\command-code\dist\index.mjs'
if (Test-Path -LiteralPath $cli) {
    if (Test-CommandCodeCoolingDown) {
        $ccStatus = 'cooldown active - probe skipped'
        Write-Output 'Command Code: cooldown active -> probe skipped'
    } else {
    # Clean up old probe files
    Remove-Item $probeOut, $probeErr -Force -ErrorAction SilentlyContinue
    try {
        $node = (Get-Command node.exe -ErrorAction Stop).Source
        $proc = Start-Process -FilePath $node -ArgumentList @($cli, '--model', 'deepseek/deepseek-v4-pro', '--skip-onboarding', '-p', $probeTask) `
            -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr -PassThru -WindowStyle Hidden
        $finished = $proc.WaitForExit($probeTimeout * 1000)
        if (-not $finished) {
            $proc.Kill()
            Write-Output "Command Code: probe timed out"
            $ccStatus = 'probe timeout'
        } else {
            $outText = ''
            if (Test-Path $probeOut) { $outText += Get-Content $probeOut -Raw -ErrorAction SilentlyContinue }
            if (Test-Path $probeErr) { $outText += Get-Content $probeErr -Raw -ErrorAction SilentlyContinue }
            if ($outText -match '(?i)insufficient credits') {
                Set-PaidExhausted -Backend commandcode -Minutes 120 -Reason 'probe: insufficient credits'
                $ccStatus = 'paid-exhausted'
                Write-Output "Command Code: paid credits exhausted -> free models only"
            } elseif ($proc.ExitCode -eq 0) {
                Clear-PaidExhausted -Backend commandcode
                $ccStatus = 'paid available'
                Write-Output "Command Code: paid credits available"
            } else {
                Write-Output ("Command Code: probe exited {0} (not a credits issue)" -f $proc.ExitCode)
                $ccStatus = "exit $($proc.ExitCode)"
            }
        }
    } catch {
        Write-Output ("Command Code: probe failed ({0})" -f $_.Exception.Message)
        $ccStatus = "probe error: $($_.Exception.Message)"
    }
    }
} else {
    Write-Output "Command Code: CLI not found"
}

# --- OpenCode: read recent cost from SQLite ---
$ocStatus = 'unknown'
$ocDb = Join-Path $HOME '.local\share\opencode\opencode.db'
if (Test-Path -LiteralPath $ocDb) {
    if (Get-Command sqlite3 -ErrorAction SilentlyContinue) {
        try {
            $row = (sqlite3 -readonly $ocDb "SELECT COUNT(*), ROUND(COALESCE(SUM(json_extract(data,'$.cost')),0),4) FROM message WHERE json_extract(data,'$.role')='assistant' AND time_created >= ((strftime('%s','now') - 86400) * 1000);" 2>&1 | Out-String).Trim()
            $parts = $row -split '\|'
            if ($parts.Count -ge 2) {
                $ocStatus = "{0} requests, `${1} in 24h" -f $parts[0], $parts[1]
            } else {
                $ocStatus = $row
            }
            Write-Output ("OpenCode: {0}" -f $ocStatus)
        } catch {
            Write-Output ("OpenCode: DB read failed ({0})" -f $_.Exception.Message)
        }
    } else {
        Write-Output "OpenCode: sqlite3 not found (skipping cost check)"
    }
} else {
    Write-Output "OpenCode: no DB found"
}

# Summary
Write-Output ""
Write-Output "=== Credit Check Summary ==="
Write-Output "Codex:        tracked by run results"
Write-Output ("Command Code: {0}" -f $ccStatus)
Write-Output ("OpenCode:     {0}" -f $ocStatus)
Write-Output ("Backend health file: {0}" -f $BackendHealthPath)