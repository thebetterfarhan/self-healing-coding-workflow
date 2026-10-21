#Requires -Version 5.1
<#
.SYNOPSIS
  Install or update the self-healing workflow on this machine.

.DESCRIPTION
  One command that turns a clean Windows machine into a working workflow.

  What it installs:
    1. PowerShell profile loader   -> tools/profile.ps1 (gives you `work` and `wt`)
    2. Global AGENTS.md            -> from workflow/AGENTS.template.md
    3. Instruction propagation     -> OpenCode + Command Code copies
    4. Starter taste               -> ~/.commandcode/taste/taste.md (if absent)
    5. Agent roster                -> rendered into all three CLIs
    6. Skill set                   -> rendered into all three CLIs
    7. Guard hook                  -> ~/.codex/hooks.json, PreToolUse only
    8. Command Code permissions    -> from workflow/commandcode-settings.template.json
    9. Model catalogs              -> free-model and price catalogs
   10. Nightly repair task         -> CodexWorkflowSelfHeal at 03:00
   11. Configuration repository    -> the workspace becomes a git repo
   12. Smoke checks                -> tools/verify.ps1

  What it deliberately does NOT install:
    - Audio feedback (Claudio) hooks. A hook pointing at a missing binary fails
      on every lifecycle event, so audio stays an opt-in add-on.
    - Anything that needs administrator rights, a license, or credentials.
    - The vendor agent tooling. The workflow is self-contained.

  Safe to re-run: every step is idempotent and only writes what is missing or
  out of date. Existing user files are never silently overwritten - a changed
  file is backed up first.

.PARAMETER Check
  Report what would change. Writes nothing. Exits 2 if anything is missing.

.PARAMETER Force
  Overwrite the global AGENTS.md even when one already exists (it is backed up
  first).

.PARAMETER RefreshTemplate
  Refresh workflow/AGENTS.template.md from the live canonical AGENTS.md, then
  exit. Use this on the machine that maintains the workflow before sharing it.

.PARAMETER SkipTask
  Do not register the nightly scheduled task.

.PARAMETER SkipProfile
  Do not write the PowerShell profile loader.

  The loader must go to $PROFILE.CurrentUserCurrentHost, which PowerShell
  derives from the real Documents folder - not from $env:USERPROFILE. So a
  test install that fakes USERPROFILE would otherwise overwrite the real
  profile. Use this switch whenever you are testing.

.EXAMPLE
  ./setup.ps1
  ./setup.ps1 -Check
  ./setup.ps1 -RefreshTemplate
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Force,
    [switch]$RefreshTemplate,
    [switch]$SkipTask,
    [switch]$SkipProfile
)

$ErrorActionPreference = 'Stop'
$Tools    = $PSScriptRoot
$Root     = Split-Path $Tools -Parent
$Payload  = Join-Path $Root 'workflow'
$Home_    = $env:USERPROFILE
$Codex    = Join-Path $Home_ '.codex'
$OpenCode = Join-Path $Home_ '.config\opencode'
$CmdCode  = Join-Path $Home_ '.commandcode'
$Agents   = Join-Path $Home_ '.agents\skills'
$Utf8     = New-Object System.Text.UTF8Encoding($false)

$script:drift = $false
function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    ok   $m" -ForegroundColor Green }
function Note($m) { Write-Host "    note $m" -ForegroundColor Gray }
function Warn($m) { Write-Host "    !!   $m" -ForegroundColor Yellow; $script:drift = $true }
function Die($m)  { Write-Host "    XX   $m" -ForegroundColor Red; $script:drift = $true }

# ---------------------------------------------------------------------------
# RefreshTemplate: copy the live canonical AGENTS.md into the payload.
# ---------------------------------------------------------------------------
if ($RefreshTemplate) {
    $live = Join-Path $Codex 'AGENTS.md'
    $out = Join-Path $Payload 'AGENTS.template.md'
    . (Join-Path $PSScriptRoot 'policy_template.ps1')
    [System.IO.File]::WriteAllText($out, (Get-PolicyTemplateText -LivePath $live), $Utf8)
    Write-Host "refreshed $out ($((Get-Item $out).Length) bytes)" -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host 'Self-healing workflow setup' -ForegroundColor White
Write-Host "  source: $Root" -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
# 1. PowerShell profile
# ---------------------------------------------------------------------------
Step 'PowerShell profile'
$loader = $PROFILE.CurrentUserCurrentHost
if ($SkipProfile) { Note "skipped (-SkipProfile) - the loader at $loader was not touched" }
else {
$loaderBody = @"
# `$PROFILE loader - do not put config here.
# Canonical profile: $Tools\profile.ps1 (one copy, edit that).
`$canonical = '$Tools\profile.ps1'
if (Test-Path `$canonical) { . `$canonical }
"@
$wired = (Test-Path $loader) -and ((Get-Content $loader -Raw) -match [regex]::Escape($Tools + '\profile.ps1'))
if ($wired) { Ok "loader wired: $loader" }
elseif ($Check) { Warn "loader not wired: $loader" }
else {
    $dir = Split-Path $loader -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($loader, $loaderBody, $Utf8)
    Ok "wrote loader $loader"
}
}

# ---------------------------------------------------------------------------
# 2. Global AGENTS.md
# ---------------------------------------------------------------------------
Step 'Global AGENTS.md'
$tplPath = Join-Path $Payload 'AGENTS.template.md'
$livePath = Join-Path $Codex 'AGENTS.md'
if (-not (Test-Path $tplPath)) { Die "template missing: $tplPath" }
elseif (Test-Path $livePath) {
    $same = (Get-FileHash $livePath -Algorithm MD5).Hash -eq (Get-FileHash $tplPath -Algorithm MD5).Hash
    if ($same) { Ok "already installed: $livePath" }
    elseif ($Force) {
        if ($Check) { Warn "would overwrite $livePath (use -Force)" }
        else {
            $bak = "$livePath.bak-setup-$(Get-Date -Format yyyyMMdd-HHmmss)"
            Copy-Item $livePath $bak -Force
            Copy-Item $tplPath $livePath -Force
            Ok "overwrote $livePath (backup: $(Split-Path $bak -Leaf))"
        }
    } else { Note "kept your existing $livePath (use -Force to replace)" }
} elseif ($Check) { Warn "would install $livePath" }
else {
    if (-not (Test-Path $Codex)) { New-Item -ItemType Directory -Force -Path $Codex | Out-Null }
    Copy-Item $tplPath $livePath -Force
    Ok "installed $livePath"
}

# ---------------------------------------------------------------------------
# 3. Starter taste
# ---------------------------------------------------------------------------
Step 'Starter taste'
$tastePath = Join-Path $CmdCode 'taste\taste.md'
$tasteSrc  = Join-Path $Payload 'taste-starter\taste.md'
if (-not (Test-Path $tasteSrc)) { Die "starter taste missing: $tasteSrc" }
elseif (Test-Path $tastePath) { Ok "taste already present (kept yours): $tastePath" }
elseif ($Check) { Warn "would seed $tastePath" }
else {
    $dir = Split-Path $tastePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item $tasteSrc $tastePath -Force
    Ok "seeded $tastePath with the baseline - edit it to make it yours"
}

# ---------------------------------------------------------------------------
# 4. Canonical skill set, then render the roster and skills into every CLI
# ---------------------------------------------------------------------------
Step 'Canonical skill set'
$skillsSrc = Join-Path $Payload 'skills'
$skillsDst = Join-Path $Home_ '.agents\skills'
if (Test-Path $skillsDst) { Ok "canonical skills already present (kept yours): $skillsDst" }
elseif (-not (Test-Path $skillsSrc)) { Note "no canonical skill set here and none bundled - run from a workflow-kit folder" }
elseif ($Check) { Warn "would install the canonical skill set into $skillsDst" }
else {
    New-Item -ItemType Directory -Force -Path $skillsDst | Out-Null
    Get-ChildItem -LiteralPath $skillsSrc -Directory | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $skillsDst $_.Name) -Recurse -Force
    }
    Ok "installed $((Get-ChildItem $skillsDst -Directory).Count) canonical skills into $skillsDst"
}

Step 'Agent roster and skill set'
foreach ($s in @('sync-agents.ps1', 'sync-skills.ps1')) {
    $p = Join-Path $Tools $s
    if (-not (Test-Path $p)) { Die "missing $s"; continue }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $p)
    if ($Check) { $args += '-Check' }
    # A native command that writes to stderr is an error under
    # ErrorActionPreference=Stop, and these scripts report a problem that way.
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe @args 2>&1 | Out-String
    $ErrorActionPreference = 'Stop'
    $code = $LASTEXITCODE
    $last = ($out.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($code -eq 0) { Ok "$s -> $last" }
    elseif ($Check -and $code -eq 2) { Warn "$s reports drift" }
    else { Die "$s failed: $last" }
}

# ---------------------------------------------------------------------------
# 5. Instruction propagation + taste injection
# ---------------------------------------------------------------------------
Step 'Instructions and taste'
foreach ($s in @('sync-agent-instructions.ps1', 'sync-taste.ps1')) {
    $p = Join-Path $Tools $s
    if (-not (Test-Path $p)) { Die "missing $s"; continue }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $p)
    if ($Check) { $args += '-Check' }
    # A native command that writes to stderr is an error under
    # ErrorActionPreference=Stop, and these scripts report a problem that way.
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe @args 2>&1 | Out-String
    $ErrorActionPreference = 'Stop'
    $code = $LASTEXITCODE
    $last = ($out.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($code -eq 0) { Ok "$s -> $last" }
    elseif ($Check -and $code -eq 2) { Warn "$s reports drift" }
    else { Die "$s failed: $last" }
}

# ---------------------------------------------------------------------------
# 6. Guard hook (PreToolUse only - no audio hooks, they need a binary)
# ---------------------------------------------------------------------------
Step 'Guard hook'
$hooksPath = Join-Path $Codex 'hooks.json'
$guard = Join-Path $Tools 'guard-hook.ps1'
$guardCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File '$guard'"
$guardWin = "powershell -NoProfile -ExecutionPolicy Bypass -File '$guard'"
$hooks = $null
if (Test-Path $hooksPath) {
    try { $hooks = [System.IO.File]::ReadAllText($hooksPath) | ConvertFrom-Json } catch { $hooks = $null }
}
if ($null -eq $hooks) { $hooks = [pscustomobject]@{ hooks = [pscustomobject]@{} } }
if (-not $hooks.hooks) { $hooks | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }

# Drop any existing guard-hook entry (avoid duplicates), keep everything else.
$pre = @()
if ($hooks.hooks.PSObject.Properties['PreToolUse']) { $pre = @($hooks.hooks.PreToolUse) }
$kept = @($pre | Where-Object {
    $c = ($_.hooks | ForEach-Object { $_.command }) -join ' '
    ($c -notmatch 'guard-hook\.ps1')
})
$kept += [pscustomobject]@{
    matcher = '*'
    hooks   = @([pscustomobject]@{ type = 'command'; command = $guardCmd; commandWindows = $guardWin; timeout = 30 })
}
$hooks.hooks | Add-Member -NotePropertyName PreToolUse -NotePropertyValue $kept -Force

if ($Check) {
    Ok "would ensure the guard hook in $hooksPath"
} else {
    $bak = "$hooksPath.bak-setup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    if (Test-Path $hooksPath) { Copy-Item $hooksPath $bak -Force }
    $json = $hooks | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($hooksPath, $json, $Utf8)
    Ok "guard hook wired into $hooksPath"
}

# ---------------------------------------------------------------------------
# 7. Command Code permissions (no audio hooks)
# ---------------------------------------------------------------------------
Step 'Command Code permissions'
$ccTpl  = Join-Path $Payload 'commandcode-settings.template.json'
$ccPath = Join-Path $CmdCode 'settings.json'
$ccHookSrc = Join-Path $Payload 'commandcode-hooks\superpowers-bootstrap.mjs'
$ccHookDst = Join-Path $CmdCode 'hooks\superpowers-bootstrap.mjs'

if (-not (Test-Path $ccTpl)) { Die "Command Code template missing: $ccTpl" }
elseif (Test-Path $ccPath) {
    $cur = $null
    try { $cur = [System.IO.File]::ReadAllText($ccPath) | ConvertFrom-Json } catch {}
    $hasRules = $cur -and $cur.permissions -and $cur.permissions.deny -and @($cur.permissions.deny).Count -gt 0
    if ($hasRules) { Ok "permissions already present (kept yours): $ccPath" }
    elseif ($Check) { Warn "would install permission rules into $ccPath" }
    else {
        $bak = "$ccPath.bak-setup-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item $ccPath $bak -Force
        [System.IO.File]::WriteAllText($ccPath, ([System.IO.File]::ReadAllText($ccTpl) -replace '__WORKSPACE__', ($Root -replace '\\','/')), $Utf8)
        Ok "installed permission rules (backup: $(Split-Path $bak -Leaf))"
    }
} elseif ($Check) { Warn "would install $ccPath" }
else {
    if (-not (Test-Path $CmdCode)) { New-Item -ItemType Directory -Force -Path $CmdCode | Out-Null }
    [System.IO.File]::WriteAllText($ccPath, ([System.IO.File]::ReadAllText($ccTpl) -replace '__WORKSPACE__', ($Root -replace '\\','/')), $Utf8)
    Ok "installed $ccPath"
}

# The superpowers bootstrap hook, with a path derived from this install.
if (Test-Path $ccHookSrc) {
    if ($Check) { Ok "would install the superpowers bootstrap hook" }
    else {
        $dir = Split-Path $ccHookDst -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Copy-Item $ccHookSrc $ccHookDst -Force
        Ok "installed the superpowers bootstrap hook"
    }
}

# ---------------------------------------------------------------------------
# 8. Model catalogs
# ---------------------------------------------------------------------------
Step 'Model catalogs'
if ($Check) {
    Note 'skipped in -Check mode (these scripts write; run without -Check to refresh)'
} else {
    foreach ($s in @('refresh-free-models.ps1', 'refresh-model-prices.ps1')) {
        $p = Join-Path $Tools $s
        if (-not (Test-Path $p)) { Note "skipped $s (not present)"; continue }
        # A native command that writes to stderr is an error under
        # ErrorActionPreference=Stop, and these scripts report a missing CLI
        # that way. The catalogs are a convenience, not a requirement.
        $ErrorActionPreference = 'Continue'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p 2>&1 | Out-String
        $ErrorActionPreference = 'Stop'
        $last = ($out.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if ($LASTEXITCODE -eq 0) { Ok "$s -> $last" } else { Note "$s failed (needs the CLI installed): $last" }
    }
}

# ---------------------------------------------------------------------------
# 9. Nightly repair task
# ---------------------------------------------------------------------------
Step 'Nightly repair task'
$taskName = 'CodexWorkflowSelfHeal'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) { Ok "task already registered: $taskName" }
elseif ($Check) { Warn "would register the task $taskName at 03:00" }
elseif ($SkipTask) { Note "skipped ($SkipTask)" }
else {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Tools\self-repair.ps1`""
    $trigger = New-ScheduledTaskTrigger -Daily -At 3am
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
        -Description 'Daily unattended repair pass over the workflow configuration.' -Force | Out-Null
    Ok "registered $taskName (daily 03:00)"
}

# ---------------------------------------------------------------------------
# 11. Configuration repository
# ---------------------------------------------------------------------------
Step 'Configuration repository'
# The workspace becomes a git repository holding the configuration only. The
# nightly job keeps it healthy: a broken file is restored from the last good
# commit. It is created here so a fresh install is protected from the start.
$repair = Join-Path $Tools 'repair-config.ps1'
if (-not (Test-Path $repair)) { Note 'repair-config.ps1 not present' }
elseif (Test-Path (Join-Path $Root '.git')) { Ok "configuration repository present: $Root" }
elseif ($Check) { Warn "would create the configuration repository in $Root" }
else {
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repair 2>&1 | Out-String
    $ErrorActionPreference = 'Stop'
    $last = ($out.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($LASTEXITCODE -eq 0) { Ok "configuration repository -> $last" } else { Die "configuration repository failed: $last" }
}

# ---------------------------------------------------------------------------
# 12. Smoke checks
# ---------------------------------------------------------------------------
Step 'Smoke checks'
$verify = Join-Path $Tools 'verify.ps1'
if (-not (Test-Path $verify)) { Note 'verify.ps1 not present' }
elseif ($Check) { Note 'would run the smoke checks (tools/verify.ps1) - run them separately' }
else {
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verify 2>&1 | Out-String
    $ErrorActionPreference = 'Stop'
    $last = ($out.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($LASTEXITCODE -eq 0) { Ok "verify -> $last" } else { Die "verify failed: $last" }
}

# ---------------------------------------------------------------------------
# 13. Workspace files
# ---------------------------------------------------------------------------
Step 'Workspace files'
$wsAgents = Join-Path $Root 'AGENTS.md'
if (Test-Path $wsAgents) { Ok 'workspace AGENTS.md present' }
elseif ($Check) { Warn "would create $wsAgents" }
else {
    $ws = @'
# Documents\Codex workspace

The authoritative policy is the global `~/.codex/AGENTS.md`; this workspace follows it. Add only workspace-specific instructions here - specialize, do not duplicate, the global policy.

Read `AGENTS-compat.md` (this directory) before compatibility work or a broad review.

## Documentation

`START-HERE.md` is the entry point for anyone new to this workspace.

Published as HTML in `html/` (open `html/index.html`). Generated from the Markdown sources in this directory by `tools/docgen/convert-docs.mjs`; run `node tools/docgen/verify-html.mjs` to check the output. Edit the `.md` file, then regenerate - never edit the HTML.

The complete guide to the self-healing workflow is `SELF-HEALING-WORKFLOW.md` (also `html/self-healing-workflow.html`).

`tools/setup.ps1` installs this workflow on a new machine in one command; `-Check` reports what it would do without writing anything.
'@
    [System.IO.File]::WriteAllText($wsAgents, $ws, $Utf8)
    Ok "created $wsAgents"
}

$handover = Join-Path $Tools 'HANDOVER.md'
if (Test-Path $handover) { Ok 'handover present' }
elseif ($Check) { Warn "would create $handover" }
else {
    $h = @"
# Tools handover - $(Get-Date -Format 'yyyy-MM-dd')

Freshly installed. No repair run yet.

## Next action

Run the nightly repair once by hand to confirm the install:

    ~/Documents/Codex/tools/self-repair.ps1

Then read `../START-HERE.md`.
"@
    [System.IO.File]::WriteAllText($handover, $h, $Utf8)
    Ok "created $handover"
}

Write-Host ''
if ($Check) {
    if ($script:drift) { Write-Host 'DRIFT detected (exit 2).' -ForegroundColor Yellow; exit 2 }
    else { Write-Host 'All good.' -ForegroundColor Green; exit 0 }
}
if ($script:drift) {
    Write-Host 'Setup finished with problems - see the !! lines above.' -ForegroundColor Yellow
    exit 1
}
Write-Host 'Setup complete.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next:' -ForegroundColor White
Write-Host '  1. Open a new PowerShell window (or run: reload)'
Write-Host '  2. work ''Find the setting that controls focus return'' -Preview'
Write-Host '  3. Read START-HERE.md for what to try first.'
Write-Host ''
exit 0
