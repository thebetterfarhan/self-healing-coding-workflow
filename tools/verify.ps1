#Requires -Version 5
<#
  verify.ps1 — smoke checks for the workflow tooling.
  Returns exit 0 on success, 1 on any failure.
#>
$ErrorActionPreference = 'Stop'
$tools = $PSScriptRoot
$fail = 0

# 1. Parse all PowerShell scripts in the tools directory.
Get-ChildItem -LiteralPath $tools -Filter *.ps1 | ForEach-Object {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
    if ($errs) {
        $fail++
        Write-Output ("PARSE FAIL: " + $_.Name)
        $errs | ForEach-Object { Write-Output ("   " + $_.Message) }
    }
}

# 2. Load the router and exercise selection.
try {
    . (Join-Path $tools 'agent-route.ps1')
    $p = Get-RoutePenalties
    $r = Select-CheapModel -Tier quick
    if (-not $r -or -not $r.Id) { throw 'Select-CheapModel returned no model' }
    Write-Output ("route smoke OK: quick=" + $r.Id)
    $ranking = Get-BackendRanking
    Write-Output ("backend ranking: " + ($ranking -join ' > '))
} catch {
    $fail++
    Write-Output ("ROUTE SMOKE FAIL: " + $_.Exception.Message)
}

# 3. npm codex copies must agree (drift guard: agent-task uses the npm copy;
#    a stale prefix copy is what bare `codex` may resolve to).
$codexNpm = Join-Path $env:LOCALAPPDATA 'BlindPilot\npm\codex.cmd'
$codexPrefix = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'BlindPilot\runtimes\node') -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'codex.cmd' } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
try {
    if (-not (Test-Path -LiteralPath $codexNpm)) {
        if ($codexPrefix) {
            Write-Output 'codex shim: npm copy absent, prefix copy present - skipped'
        } else {
            # The Codex CLI is not installed here. There is nothing to keep in
            # agreement, so this is not a failure - it used to be, which made
            # the gate fail on any machine without Codex.
            Write-Output 'codex shim: the Codex CLI is not installed here - skipped'
        }
    } else {
        $v1 = (& $codexNpm --version 2>$null | Select-Object -First 1)
        if (-not $v1) { throw 'npm codex --version returned nothing' }
        if ($codexPrefix) {
            $v2 = (& $codexPrefix --version 2>$null | Select-Object -First 1)
            if ($v1 -ne $v2) { throw "codex version drift: npm=$v1 prefix=$v2" }
            Write-Output "codex shim OK: $v1 (prefix copy matches)"
        } else {
            Write-Output "codex shim OK: $v1 (prefix copy absent)"
        }
    }
} catch {
    $fail++
    Write-Output ("CODEX SHIM FAIL: " + $_.Exception.Message)
}

# 4. The distributable template must match the live canonical AGENTS.md, and
#    no script may hardcode a user path (the workflow has to be portable).
$liveAgents = Join-Path $env:USERPROFILE '.codex\AGENTS.md'
$template   = Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow\AGENTS.template.md'
if ((Test-Path $liveAgents) -and (Test-Path $template)) {
    $live = [System.IO.File]::ReadAllText($liveAgents)
    $a = $live.IndexOf('<!-- TASTE:BEGIN'); $b = $live.IndexOf('<!-- TASTE:END -->')
    if ($a -ge 0 -and $b -gt $a) { $live = $live.Substring(0, $a).TrimEnd() }
    $tpl = [System.IO.File]::ReadAllText($template)
    $t = $tpl.IndexOf('-->')
    if ($t -ge 0) { $tpl = $tpl.Substring($t + 3).Trim() }
    if ($live -eq $tpl) { Write-Output 'template in sync with the live AGENTS.md' }
    else { Write-Output 'TEMPLATE STALE: run tools/setup.ps1 -RefreshTemplate before sharing' }
} else {
    Write-Output 'template check skipped (template or live AGENTS.md not found)'
}

$scriptFiles = @(Get-ChildItem -LiteralPath $tools -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.ps1', '.mjs', '.js' -and $_.FullName -notmatch 'node_modules|workflow-config-editor|self-repair-backups' })
$hardcoded = @($scriptFiles | ForEach-Object {
    $ln = 0
    foreach ($line in [System.IO.File]::ReadAllLines($_.FullName)) {
        $ln++
        if ($line -match '[A-Za-z]:\\Users\\') { "{0}:{1}" -f $_.Name, $ln }
    }
})
if ($hardcoded.Count -gt 0) {
    $fail++
    Write-Output 'HARDCODED USER PATHS:'
    $hardcoded | ForEach-Object { Write-Output "   $_" }
} else {
    Write-Output 'no hardcoded user paths'
}

# 5. A provider credit/limit error must fail the run even when the CLI exits 0
#    (Command Code v1.84.0 exits 0 after "Insufficient credits for Command
#    Code."). A transcript that only mentions credits in passing must not trip
#    the check.
$creditLog = Join-Path $env:TEMP ('credit-check-' + [guid]::NewGuid().ToString('n') + '.log')
try {
    . (Join-Path $tools 'agent-route.ps1')
    Set-Content -LiteralPath $creditLog -Encoding UTF8 -Value @(
        '# Command Code v1.84.0',
        '? Insufficient credits for Command Code.',
        '  Buy extra usage (pay-as-you-go at API cost, zero markup) or upgrade:'
    )
    if (-not (Test-CreditFailure -OutFile $creditLog)) { throw 'credit error at the end of the output was not detected' }
    Set-Content -LiteralPath $creditLog -Encoding UTF8 -Value @(
        '# Command Code v1.84.0',
        '? Insufficient credits for Command Code.',
        ('x' * 4000)
    )
    if (Test-CreditFailure -OutFile $creditLog) { throw 'credit error mid-run was treated as a provider failure' }
    # Codex prints the limit with a typographic apostrophe (U+2019).
    Set-Content -LiteralPath $creditLog -Encoding UTF8 -Value @(
        "ERROR: You$([char]0x2019)ve hit your usage limit. Upgrade to Pro"
    )
    if (-not (Test-CreditFailure -OutFile $creditLog)) { throw 'codex usage-limit error was not detected' }
    # The guard itself: exit 0 plus a provider credit error is a failure.
    Set-Content -LiteralPath $creditLog -Encoding UTF8 -Value @(
        '# Command Code v1.84.0',
        '? Insufficient credits for Command Code.'
    )
    if ((Resolve-RunExit -ExitCode 0 -OutFile $creditLog) -ne 1) { throw 'a credit error with exit code 0 was not turned into a failure' }
    Set-Content -LiteralPath $creditLog -Encoding UTF8 -Value 'all good'
    if ((Resolve-RunExit -ExitCode 0 -OutFile $creditLog) -ne 0) { throw 'a clean run was turned into a failure' }
    if ((Resolve-RunExit -ExitCode 1 -OutFile $creditLog) -ne 1) { throw 'a real failure was swallowed' }
    Write-Output 'credit-failure detection OK'
} catch {
    $fail++
    Write-Output ("CREDIT CHECK FAIL: " + $_.Exception.Message)
} finally {
    Remove-Item -LiteralPath $creditLog -Force -ErrorAction SilentlyContinue
}

# 6. Set-PaidExhausted must work on a backend that already has a health entry
#    (the file round-trips through JSON, so the entry arrives as a fixed-shape
#    object). This is the path a credit failure takes after a backend was
#    already marked unhealthy.
$healthPath = Join-Path $tools 'agent-backend-health.json'
$healthCopy = Join-Path $env:TEMP ('health-' + [guid]::NewGuid().ToString('n') + '.json')
try {
    . (Join-Path $tools 'agent-route.ps1')
    Copy-Item -LiteralPath $healthPath -Destination $healthCopy -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $healthPath -Encoding UTF8 -Value '{"commandcode":{"unhealthyUntil":"2099-01-01T00:00:00","reason":"test","recordedAt":"2026-01-01T00:00:00"}}'
    Set-PaidExhausted -Backend 'commandcode' -Minutes 5 -Reason 'test'
    if (-not (Test-PaidExhausted -Backend 'commandcode')) { throw 'paidExhausted was not recorded' }
    # A free-model success clears the health flag but not the paid credits.
    Clear-BackendUnhealthy -Backend 'commandcode'
    if (-not (Test-PaidExhausted -Backend 'commandcode')) { throw 'paid-exhausted flags were lost when the health flag was cleared' }
    Clear-PaidExhausted -Backend 'commandcode'
    if (Test-PaidExhausted -Backend 'commandcode') { throw 'paidExhausted was not cleared' }
    Write-Output 'paid-exhausted bookkeeping OK'

    # 7. Full status must ignore expired flags and report active flags without writing health state.
    $statusScript = Join-Path $tools 'status.ps1'
    Set-Content -LiteralPath $healthPath -Encoding UTF8 -Value '{"commandcode":{"unhealthyUntil":"2000-01-01T00:00:00","reason":"expired test","paidExhausted":true,"paidExhaustedUntil":"2000-01-01T00:00:00","paidExhaustedReason":"expired test"}}'
    $before = (Get-FileHash -LiteralPath $healthPath -Algorithm SHA256).Hash
    $status = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $statusScript 2>&1 | Out-String
    # Only the expired flags are under test here. The status of the rest of
    # the machine is not: a clean install has no skill set, and the status
    # rightly reports that, so asserting the whole screen is healthy would
    # fail on exactly the machine this check is most useful on.
    if ($status -match '(?m)^\s+commandcode\s+unhealthy' -or $status -match '(?m)^\s+commandcode paid\s+exhausted') { throw 'status treated expired health flags as active' }
    if ((Get-FileHash -LiteralPath $healthPath -Algorithm SHA256).Hash -ne $before) { throw 'status changed expired health record' }

    Set-Content -LiteralPath $healthPath -Encoding UTF8 -Value '{"commandcode":{"unhealthyUntil":"2099-01-01T00:00:00","reason":"active test","paidExhausted":true,"paidExhaustedUntil":"2099-01-01T00:00:00","paidExhaustedReason":"active test"}}'
    $before = (Get-FileHash -LiteralPath $healthPath -Algorithm SHA256).Hash
    $status = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $statusScript 2>&1 | Out-String
    if ($LASTEXITCODE -ne 1 -or $status -notmatch '(?m)^\s+commandcode\s+unhealthy until 2099-01-01T00:00:00: active test\s*$' -or $status -notmatch '(?m)^\s+commandcode paid\s+exhausted until 2099-01-01T00:00:00: active test\s*$') { throw 'status did not report both active health flags' }
    if ((Get-FileHash -LiteralPath $healthPath -Algorithm SHA256).Hash -ne $before) { throw 'status changed active health record' }
    Write-Output 'status expired/active health checks OK'
} catch {
    $fail++
    Write-Output ("PAID EXHAUSTED FAIL: " + $_.Exception.Message)
} finally {
    if (Test-Path -LiteralPath $healthCopy) { Move-Item -LiteralPath $healthCopy -Destination $healthPath -Force }
    else { Remove-Item -LiteralPath $healthPath -Force -ErrorAction SilentlyContinue }
}

# 8. The one-task continuation runner must keep its stop conditions: a missing
#    marker, a missing session id, a changed session id, and a CLI failure all
#    stop the run instead of starting another turn.
if (Get-Command python -ErrorAction SilentlyContinue) {
    try {
        # unittest writes to stderr, which this script treats as fatal, so run
        # it through a wrapper that prints the report on stdout and sets the
        # exit code.
        $runner = "import sys,unittest; suite=unittest.defaultTestLoader.discover(r'{0}', pattern='test_auto_next.py'); result=unittest.TextTestRunner(stream=sys.stdout).run(suite); sys.exit(0 if result.wasSuccessful() else 1)" -f $tools
        $out = & python -c $runner 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw ('continuation runner tests failed: ' + $out.Trim()) }
        Write-Output 'continuation runner tests OK'
    } catch {
        $fail++
        Write-Output ("CONTINUATION TEST FAIL: " + $_.Exception.Message)
    }
} else {
    Write-Output 'continuation runner tests skipped (python not found)'
}

# 9. Every tracked file in the configuration repo must parse. A broken file is
#    restored from the last good commit by repair-config.ps1; the gate reports
#    it so the repair is not the first thing that notices.
$repair = Join-Path $tools 'repair-config.ps1'
$repoRoot = Split-Path $tools -Parent
if (-not (Test-Path (Join-Path $repoRoot '.git'))) {
    Write-Output 'configuration repository not created yet - run tools/repair-config.ps1'
} elseif (Test-Path -LiteralPath $repair) {
    try {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repair -Check 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = $saved
        if ($code -ne 0) { throw ('configuration repository: ' + $out.Trim()) }
        Write-Output 'configuration repository OK'
    } catch {
        $fail++
        Write-Output ("CONFIG REPO FAIL: " + $_.Exception.Message)
    }
} else {
    Write-Output 'configuration repository check skipped (repair-config.ps1 missing)'
}

if ($fail -gt 0) {
    Write-Output ("verify FAILED: " + $fail + " issue(s)")
    exit 1
}
Write-Output 'verify OK'
exit 0
