#Requires -Version 5
<#
  self-repair.ps1 — daily, unattended repair pass over the workflow config.

  Runs, each independently guarded so one failure cannot stop the rest:
     1. repair-config           validate the configuration repo, restore what is
                               broken from the last good commit, record the
                               validated state
     2. sync-taste             heal taste drift in AGENTS/CLAUDE/GEMINI
     3. sync-agents            re-render agent configs from agents.toml
     4. sync-agent-instructions re-propagate the canonical AGENTS.md copies
     5. sync-skills            re-render the canonical skill set into every CLI
     6. refresh-free-models    regenerate the free-model fallback catalog
     7. memory-curate          distill new rollout summaries into ad_hoc notes
     8. memory-consolidate      merge novel note learnings into MEMORY.md
     9. tier-adapt             adjust tier classification thresholds
    10. taste-promote          scan notes for repeated taste candidates
    11. credit-check           probe credit availability per backend
    12. verify                parse + smoke checks

  Rollback: before each step, every file or directory the step writes is
  snapshotted under self-repair-backups\<run>\<step>\. A failed step restores
  that snapshot, including deleting files the step created. Timestamped
  AGENTS.md.bak-* safety backups remain. The 5 latest runs are kept.

  Exit code: 0 when every step passed, 1 when any step failed or rolled back.

  Logs: tools\self-repair.log (one line per step, trimmed to 500 lines) and
  tools\self-repair-failures.log (full output of failed steps, trimmed to 250).
  Scheduled as task 'CodexWorkflowSelfHeal'. Disable with:
    Unregister-ScheduledTask CodexWorkflowSelfHeal -Confirm:$false
#>
$ErrorActionPreference = 'Continue'
$logFile = Join-Path $PSScriptRoot 'self-repair.log'
$failureLog = Join-Path $PSScriptRoot 'self-repair-failures.log'
$backupRoot = Join-Path $PSScriptRoot 'self-repair-backups'
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Write-Step {
    param([string]$Name, [string]$Result)
    Add-Content -LiteralPath $logFile -Value ("{0} {1,-28} {2}" -f
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Name, $Result) -Encoding UTF8
}

function Trim-Log {
    param([string]$Path, [int]$Keep, [int]$Max)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -gt $Max) {
        $lines | Select-Object -Last $Keep | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

Trim-Log -Path $logFile -Keep 400 -Max 500
Trim-Log -Path $failureLog -Keep 200 -Max 250

# Backup/restore helpers
function Get-SnapshotHash {
    param([string]$Path)
    $root = Get-Item -LiteralPath $Path -ErrorAction Stop
    $items = @($root)
    if ($root.PSIsContainer) {
        $items += @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)
    }
    $records = foreach ($item in $items | Sort-Object FullName) {
        $hash = if ($item.PSIsContainer) { '' } else {
            (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        [pscustomobject]@{
            Path = $item.FullName.Substring($Path.Length)
            Directory = $item.PSIsContainer
            Hash = $hash
        }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToBase64String($sha.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($records) -Compress))))
    } finally {
        $sha.Dispose()
    }
}

function Backup-Files {
    param([string[]]$Files, [string]$Step)
    $dir = Join-Path $backupRoot (Join-Path $runStamp $Step)
    New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
    $manifest = @()
    $i = 0
    foreach ($f in $Files) {
        $i++
        $entry = Join-Path $dir ('{0:D2}' -f $i)
        New-Item -ItemType Directory -Force -Path $entry -ErrorAction Stop | Out-Null
        $exists = Test-Path -LiteralPath $f
        if ($exists) {
            $sourceHash = Get-SnapshotHash -Path $f
            Copy-Item -LiteralPath $f -Destination $entry -Recurse -Force -ErrorAction Stop
            $snapshot = Join-Path $entry (Split-Path -Leaf $f)
            $snapshotHash = Get-SnapshotHash -Path $snapshot
            if ($snapshotHash -cne $sourceHash) { throw "snapshot incomplete for: $f" }
            Set-Content -LiteralPath "$entry.sha256" -Value $snapshotHash -ErrorAction Stop
        }
        $manifest += ("{0}`t{1}`t{2}" -f $entry, $exists, $f)
    }
    $manifestPath = Join-Path $dir 'manifest.txt'
    Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding UTF8 -ErrorAction Stop
    Set-Content -LiteralPath (Join-Path $dir 'manifest.sha256') -Value (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256 -ErrorAction Stop).Hash -ErrorAction Stop
    return $dir
}

function Restore-Files {
    param([string]$BackupDir)
    $manifestPath = Join-Path $BackupDir 'manifest.txt'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "manifest missing: $manifestPath" }
    $manifestHashPath = Join-Path $BackupDir 'manifest.sha256'
    if (-not (Test-Path -LiteralPath $manifestHashPath)) { throw "manifest hash missing: $manifestHashPath" }
    $savedManifestHash = (Get-Content -LiteralPath $manifestHashPath -Raw -ErrorAction Stop).Trim()
    if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256 -ErrorAction Stop).Hash -cne $savedManifestHash) {
        throw "manifest changed: $manifestPath"
    }
    $expected = $stepFiles[(Split-Path -Leaf $BackupDir)]
    if (-not $expected) { throw "unknown backup step: $BackupDir" }
    $lines = @(Get-Content -LiteralPath $manifestPath -ErrorAction Stop)
    if ($lines.Count -ne $expected.Count) { throw "manifest entry count mismatch: $manifestPath" }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $parts = $lines[$i] -split "`t", 3
        if ($parts.Count -ne 3 -or
            $parts[0] -cne (Join-Path $BackupDir ('{0:D2}' -f ($i + 1))) -or
            $parts[2] -cne $expected[$i] -or
            $parts[1] -cnotin @('True', 'False')) { throw "invalid manifest entry: $manifestPath" }
        if ($parts[1] -eq 'True') {
            $snapshot = Join-Path $parts[0] (Split-Path -Leaf $parts[2])
            $hashPath = "$($parts[0]).sha256"
            if (-not (Test-Path -LiteralPath $snapshot) -or -not (Test-Path -LiteralPath $hashPath)) {
                throw "snapshot missing for: $($parts[2])"
            }
            $savedHash = (Get-Content -LiteralPath $hashPath -Raw -ErrorAction Stop).Trim()
            if ((Get-SnapshotHash -Path $snapshot) -cne $savedHash) {
                throw "snapshot changed for: $($parts[2])"
            }
        }
    }
    foreach ($line in $lines) {
        $parts = $line -split "`t", 3
        $entry, $exists, $target = $parts
        if ($exists -ne 'True') {
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
            continue
        }
        $src = Join-Path $entry (Split-Path -Leaf $target)
        if ((Get-Item -LiteralPath $src -ErrorAction Stop).PSIsContainer) {
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
            Copy-Item -LiteralPath $src -Destination $target -Recurse -Force -ErrorAction Stop
        } else {
            Copy-Item -LiteralPath $src -Destination $target -Force -ErrorAction Stop
        }
    }
}

function Prune-Backups {
    if (-not (Test-Path -LiteralPath $backupRoot)) { return }
    $dirs = Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object Name -Descending
    if ($dirs.Count -gt 5) {
        $dirs | Select-Object -Skip 5 | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
    }
}

# Step -> files/directories the step writes
#
# sync-skills is deliberately absent. Its source of truth (~/.agents/skills) is
# never written by the step, the step is idempotent, and re-running it repairs
# any partial copy -- so the canonical set IS the backup for that layer. The
# step also runs with -NoPrune, so it never deletes a skill unattended; pruning
# stays a manual, attended action.
#
# repair-config is absent for the same kind of reason: the configuration repo
# is its own backup. A snapshot would fight the restore the step performs, and
# rolling a commit back is not what a failed step means here. A file it cannot
# restore stays broken and is reported in the failure log, and the broken copy
# is kept next to it as <name>.broken-<stamp>.
$stepFiles = @{
    'sync-taste'             = @(
        (Join-Path $env:USERPROFILE '.codex\AGENTS.md'),
        (Join-Path $env:USERPROFILE '.config\opencode\AGENTS.md'),
        (Join-Path $env:USERPROFILE '.commandcode\AGENTS.md'),
        (Join-Path $env:USERPROFILE '.claude\CLAUDE.md'),
        (Join-Path $env:USERPROFILE '.gemini\GEMINI.md')
    )
    'sync-agents'            = @(
        (Join-Path $env:USERPROFILE '.codex\agents'),
        (Join-Path $env:USERPROFILE '.config\opencode\agents'),
        (Join-Path $env:USERPROFILE '.commandcode\agents')
    )
    'sync-agent-instructions' = @(
        (Join-Path $env:USERPROFILE '.config\opencode\AGENTS.md'),
        (Join-Path $env:USERPROFILE '.commandcode\AGENTS.md')
    )
    'refresh-free-models'    = @((Join-Path $PSScriptRoot 'free-models.json'))
    'memory-curate'          = @((Join-Path $env:USERPROFILE '.codex\memories\extensions\ad_hoc\notes'))
    'memory-consolidate'     = @(
        (Join-Path $env:USERPROFILE '.codex\memories\MEMORY.md'),
        (Join-Path $env:USERPROFILE '.codex\memories\extensions\ad_hoc\notes\.consolidated')
    )
    'tier-adapt'             = @((Join-Path $PSScriptRoot 'agent-tier-thresholds.json'))
    'taste-promote'          = @((Join-Path $PSScriptRoot 'taste-candidates.md'))
    'credit-check'           = @((Join-Path $PSScriptRoot 'agent-backend-health.json'))
}

$steps = @(
    @{ Name = 'repair-config';         Script = 'repair-config.ps1' },
    @{ Name = 'sync-taste';             Script = 'sync-taste.ps1' },
    @{ Name = 'sync-agents';            Script = 'sync-agents.ps1' },
    @{ Name = 'sync-agent-instructions'; Script = 'sync-agent-instructions.ps1' },
    @{ Name = 'sync-skills';            Script = 'sync-skills.ps1'; Args = '-NoPrune' },
    @{ Name = 'refresh-free-models';    Script = 'refresh-free-models.ps1' },
    @{ Name = 'memory-curate';          Script = 'memory-curate.ps1' },
    @{ Name = 'memory-consolidate';     Script = 'memory-consolidate.ps1' },
    @{ Name = 'tier-adapt';             Script = 'tier-adapt.ps1' },
    @{ Name = 'taste-promote';          Script = 'taste-promote.ps1' },
    @{ Name = 'credit-check';           Script = 'credit-check.ps1' },
    @{ Name = 'verify';                 Script = 'verify.ps1' }
)

Prune-Backups

$failures = @()
foreach ($s in $steps) {
    $path = Join-Path $PSScriptRoot $s.Script
    if (-not (Test-Path -LiteralPath $path)) { Write-Step $s.Name 'MISSING'; $failures += $s.Name; continue }

    $files = $stepFiles[$s.Name]
    $backupDir = $null
    if ($files) {
        try {
            $backupDir = Backup-Files -Files $files -Step $s.Name
        } catch {
            Write-Step $s.Name "BACKUP FAILED: $($_.Exception.Message)"
            $failures += $s.Name
            continue
        }
    }

    $out = ''
    $code = 1
    try {
        if ($s.Args) {
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path $s.Args 2>&1 | Out-String
        } else {
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
        }
        $code = $LASTEXITCODE
    } catch {
        $out = $_.Exception.Message
        $code = 1
    }

    $lines = @($out.Trim() -split "`r?`n" | Where-Object { $_.Trim() })
    $last = if ($lines.Count -gt 0) { $lines[-1] } else { '' }

    if ($code -eq 0) {
        Write-Step $s.Name $last
        continue
    }

    $failures += $s.Name
    Write-Step $s.Name "FAILED (exit $code): $last"
    $detail = $out.Trim()
    if ($detail.Length -gt 4000) { $detail = $detail.Substring(0, 4000) + "`n... truncated" }
    Add-Content -LiteralPath $failureLog -Encoding UTF8 -Value @(
        ("==== {0} {1} exit={2} ====" -f $runStamp, $s.Name, $code),
        $detail,
        ''
    )
    if ($backupDir) {
        try {
            Restore-Files -BackupDir $backupDir
            Write-Step $s.Name 'ROLLED BACK'
        } catch {
            Write-Step $s.Name "ROLLBACK FAILED: $($_.Exception.Message)"
        }
    }
}

Prune-Backups
Write-Step 'self-repair' ("run complete ok={0} failed={1}" -f ($steps.Count - $failures.Count), $failures.Count)
if ($failures.Count -gt 0) { exit 1 }
exit 0
