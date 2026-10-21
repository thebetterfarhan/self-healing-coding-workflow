<#
  sync-skills.ps1

  One-way skill sync: ~/.agents/skills is the canonical set (you edit there,
  skills share out to every CLI). Pushes>Add-OrUpdate skills into
  ~/.codex/skills, ~/.config/opencode/skills, ~/.commandcode/skills.

  Behavior:
    - Mirror: a destination skill absent from the canonical set is deleted
      unless it is in the keep-home list (-NoPrune to skip pruning entirely).
    - Copies whole directories (fast robust copy, no symlink tricks).
    - .system (agent-only private helpers) is never shipped.

  Usage:
    sync-skills.ps1 -Check     # list what WOULD change, change nothing
    sync-skills.ps1            # apply

  Exit codes: 0 ok (-Check with pending changes exits 2, like sync-agents).
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$NoPrune
)
$ErrorActionPreference = 'Stop'

# $env:USERPROFILE, not $HOME: Windows PowerShell sets $HOME once, when it
# starts, and it does not follow a changed $env:USERPROFILE. The install check
# points USERPROFILE at an empty profile, so $HOME would still point at the
# real one and the install would write outside the profile it is testing.
$source = Join-Path $env:USERPROFILE '.agents\skills'
if (-not (Test-Path -LiteralPath $source)) {
    # No canonical set on this machine, so there is nothing to share out. That
    # is not an error: the public bundle ships without skills and the workflow
    # runs without them. It used to throw, which made the whole install fail
    # on a clean machine.
    Write-Output 'sync-skills: no canonical skill set - nothing to sync'
    exit 0
}

$dests = @(
    (Join-Path $env:USERPROFILE '.codex\skills'),
    (Join-Path $env:USERPROFILE '.config\opencode\skills'),
    (Join-Path $env:USERPROFILE '.commandcode\skills')
)

$skip = @('.system')

function Get-CanonicalNames {
    Get-ChildItem -LiteralPath $source -Directory |
        Where-Object { $_.Name -notin $skip } |
        ForEach-Object { $_.Name }
}

function Copy-Skill {
    param([string]$Name, [string]$Dest)
    $target = Join-Path $Dest $Name
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $source $Name) -Destination $target -Recurse -Force
}

$pending = 0
foreach ($dest in $dests) {
    if (-not (Test-Path -LiteralPath $dest)) {
        if ($Check) { Write-Output "CREATE dir: $dest"; $pending++; continue }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }
    $have  = if (Test-Path -LiteralPath $dest) { @(Get-ChildItem -LiteralPath $dest -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } else { @() }
    $want  = @(Get-CanonicalNames)

    # additions/updates
    foreach ($name in $want) {
        $src = Join-Path $source $name
        $dst = Join-Path $dest $name
        if (-not (Test-Path -LiteralPath $dst)) {
            if ($Check) { Write-Output "ADD $dest -> $name"; $pending++ }
            else { Copy-Skill -Name $name -Dest $dest; Write-Output "added $name -> $dest" }
            continue
        }
        # changed? compare SKILL.md content and file count (cheap enough).
        $srcMd = Join-Path $src 'SKILL.md'
        $dstMd = Join-Path $dst 'SKILL.md'
        $same = $false
        if ((Test-Path -LiteralPath $srcMd) -and (Test-Path -LiteralPath $dstMd)) {
            $a = Get-Content -LiteralPath $srcMd -Raw -ErrorAction SilentlyContinue
            $b = Get-Content -LiteralPath $dstMd -Raw -ErrorAction SilentlyContinue
            $srcCount = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force).Count
            $dstCount = @(Get-ChildItem -LiteralPath $dst -Recurse -File -Force).Count
            $same = ($a -eq $b) -and ($srcCount -eq $dstCount)
        }
        if (-not $same) {
            if ($Check) { Write-Output "UPDATE $dest -> $name"; $pending++ }
            else { Copy-Skill -Name $name -Dest $dest; Write-Output "updated $name -> $dest" }
        }
    }

    # pruning: destination-only skills the user moved out of the canonical set
    if (-not $NoPrune) {
        foreach ($name in ($have | Where-Object { $_ -notin $want -and $_ -notin $skip })) {
            if ($Check) { Write-Output "PRUNE $dest -> $name (not in canonical set)"; $pending++ }
            else {
                Remove-Item -LiteralPath (Join-Path $dest $name) -Recurse -Force
                Write-Output "pruned $name from $dest"
            }
        }
    }
}

if ($Check -and $pending) {
    Write-Output "sync-skills: $pending pending change(s); run without -Check to apply"
    exit 2
}
if ($Check) { Write-Output 'sync-skills: in sync' ; exit 0 }
Write-Output 'sync-skills: done'
exit 0
