#Requires -Version 5
<#
  run-ci-checks.ps1 - run a repository's workflows on GitHub's own runners and
  report what failed.

  Nothing is built or tested on this machine: the script dispatches the
  workflows (so they run on GitHub-hosted runners), waits for them, and reads
  the outcome and the failing log back.

  Only workflows that declare workflow_dispatch can be dispatched, so those
  are the ones this script finds.

  .EXAMPLE
  ./run-ci-checks.ps1 -Repos owner/name -List
  ./run-ci-checks.ps1 -Repos owner/name -Wait

  .EXAMPLE
  ./run-ci-checks.ps1 -ConfigFile tools/ci-repos.local.json -Wait
#>
[CmdletBinding()]
param(
    # Repositories to run, as owner/name. Overrides the config file.
    [string[]]$Repos = @(),
    # A JSON file: { "repos": ["owner/name"], "workflows": ["Tests"] }.
    [string]$ConfigFile = '',
    # Only these workflows (name or path, case-insensitive). Empty = all.
    [string[]]$Workflows = @(),
    # Run these even when the name matches the skip list.
    [string[]]$Include = @(),
    [switch]$Wait,
    [int]$TimeoutMinutes = 30,
    # List what would run, without dispatching anything.
    [switch]$List
)

$ErrorActionPreference = 'Stop'

function Get-Gh {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # The output is joined into one string: gh can write more than one line,
    # and ConvertFrom-Json needs the whole document.
    $out = ((@(& gh @Arguments 2>&1)) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0) { throw ("gh {0} failed: {1}" -f ($Arguments -join ' '), $out) }
    return $out
}

function Get-GhJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $raw = Get-Gh -Arguments $Arguments
    if (-not $raw) { return @() }
    return ($raw | ConvertFrom-Json)
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'the GitHub CLI (gh) is not on PATH - install it and sign in with gh auth login'
}

# --- the list of repositories -------------------------------------------------

if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'ci-repos.local.json' }

if (-not $Repos) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "no repositories given and no config file at $ConfigFile"
    }
    $cfg = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    $Repos = @($cfg.repos)
    if (-not $Workflows -and $cfg.workflows) { $Workflows = @($cfg.workflows) }
}
if (-not $Repos) { throw 'no repositories to run' }

# An action a workflow uses can be forbidden by the repository's own policy,
# and the run then stops before its first step with no log to read. Those are
# found first, so the cause is on the screen next to the failures.
$actionChecker = Join-Path $PSScriptRoot 'check-workflow-actions.ps1'
if (Test-Path -LiteralPath $actionChecker) {
    & $actionChecker -Repos $Repos
    if ($LASTEXITCODE -ne 0) { Write-Output 'a workflow uses an action its repository does not allow - see above' }
}

# --- what can be dispatched ---------------------------------------------------

# Workflows that publish something, and the ones GitHub runs on its own
# schedule, are not run by default: a check run must not create a release,
# deploy a site or close an issue. Name a workflow with -Include to run it.
$skip = @('release', 'publish', 'deploy', 'pages', 'dependabot', 'dependency graph', 'close ')

function Test-Skipped {
    param([string]$Name, [string]$Path)
    foreach ($pattern in $Include) {
        if ($Name -like "*$pattern*" -or $Path -like "*$pattern*") { return $false }
    }
    foreach ($pattern in $skip) {
        if ($Name -like "*$pattern*" -or $Path -like "*$pattern*") { return $true }
    }
    return $false
}

$planned = @()
foreach ($repo in $Repos) {
    $listed = Get-GhJson -Arguments @('api', "repos/$repo/actions/workflows", '--paginate')
    # The endpoint answers with { total_count, workflows: [...] }.
    $repoWorkflows = if ($listed.workflows) { @($listed.workflows) } else { @($listed) }
    foreach ($w in $repoWorkflows) {
        if ($w.state -ne 'active') { continue }
        $hasDispatch = $true
        try {
            $content = Get-GhJson -Arguments @('api', "repos/$repo/contents/$($w.path)")
            $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(($content.content -replace '\s', '')))
            $hasDispatch = ($text -match 'workflow_dispatch')
        } catch {
            # A workflow GitHub provides itself (the default CodeQL setup) has
            # no file in the repository. It is dispatched by name below.
            $hasDispatch = $true
        }
        if (-not $hasDispatch) { continue }
        if (Test-Skipped -Name $w.name -Path $w.path) { continue }
        if ($Workflows.Count -gt 0) {
            $hit = $false
            foreach ($filter in $Workflows) {
                if ($w.name -like "*$filter*" -or $w.path -like "*$filter*") { $hit = $true; break }
            }
            if (-not $hit) { continue }
        }
        $planned += [pscustomobject]@{ Repo = $repo; Name = $w.name; Path = $w.path }
    }
}

if ($planned.Count -eq 0) { Write-Output 'no dispatchable workflows found'; exit 0 }

$planned | ForEach-Object { "{0,-45} {1}" -f $_.Repo, $_.Name }
if ($List) { exit 0 }

# --- dispatch -----------------------------------------------------------------

$runs = @()
foreach ($p in $planned) {
    $dispatched = $false
    # Only runs started after this moment count, so an earlier run of the same
    # workflow is never mistaken for this one.
    $before = (Get-Date).ToUniversalTime().AddSeconds(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')
    foreach ($target in @($p.Path, $p.Name)) {
        try {
            Get-Gh -Arguments @('workflow', 'run', $target, '--repo', $p.Repo) | Out-Null
            $dispatched = $true
            break
        } catch {
            # A workflow that needs an input cannot be dispatched without it,
            # and one GitHub provides itself is addressed by name. Neither is
            # fatal: the other workflows still run.
        }
    }
    if (-not $dispatched) {
        $runs += [pscustomobject]@{ Repo = $p.Repo; Name = $p.Name; Id = 0; Status = 'not dispatched'; Conclusion = 'the workflow could not be dispatched (it needs an input, or it is not dispatchable)'; Url = '' }
        continue
    }
    # The run appears a moment after the dispatch; find the newest one for this
    # workflow and remember it, so a later run cannot be mistaken for it.
    $found = $null
    for ($i = 0; $i -lt 20 -and -not $found; $i++) {
        Start-Sleep -Seconds 3
        $recent = @(Get-GhJson -Arguments @('run', 'list', '--repo', $p.Repo, '--workflow', $p.Name, '--event', 'workflow_dispatch', '--limit', '5',
            '--json', 'databaseId,status,conclusion,createdAt,url') | Where-Object { $_.createdAt -gt $before })
        if ($recent.Count -gt 0) { $found = $recent | Sort-Object createdAt -Descending | Select-Object -First 1 }
    }
    if (-not $found) {
        $runs += [pscustomobject]@{ Repo = $p.Repo; Name = $p.Name; Id = 0; Status = 'not started'; Conclusion = 'unknown'; Url = '' }
        continue
    }
    $runs += [pscustomobject]@{ Repo = $p.Repo; Name = $p.Name; Id = $found.databaseId; Status = $found.status; Conclusion = $found.conclusion; Url = $found.url }
}

# --- wait ---------------------------------------------------------------------

if ($Wait) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $pending = @($runs | Where-Object { $_.Status -ne 'completed' -and $_.Id -ne 0 })
        if ($pending.Count -eq 0) { break }
        Start-Sleep -Seconds 20
        foreach ($r in $pending) {
            $one = Get-GhJson -Arguments @('run', 'view', $r.Id, '--repo', $r.Repo, '--json', 'status,conclusion,url')
            $r.Status = $one.status
            $r.Conclusion = $one.conclusion
            if ($one.url) { $r.Url = $one.url }
        }
    }
}

# --- report -------------------------------------------------------------------

Write-Output ''
$failed = @()
$warned = @()
foreach ($r in $runs) {
    "{0,-45} {1,-22} {2,-12} {3}" -f $r.Repo, $r.Name, $r.Conclusion, $r.Url
    if ($r.Conclusion -eq 'success') { continue }
    if ($r.Id -eq 0) { $warned += $r; continue }
    $failed += $r
}
foreach ($r in $warned) {
    Write-Output ("warning: {0} / {1}: {2}" -f $r.Repo, $r.Name, $r.Conclusion)
}

if ($failed.Count -gt 0) {
    Write-Output ''
    Write-Output '--- the failing steps ---'
    foreach ($r in $failed) {
        Write-Output ("=== {0} / {1} (run {2}) ===" -f $r.Repo, $r.Name, $r.Id)
        $log = & gh run view $r.Id --repo $r.Repo --log-failed 2>&1 | Out-String
        if (-not $log.Trim()) { $log = (& gh run view $r.Id --repo $r.Repo 2>&1 | Out-String) }
        $lines = @($log -split "`r?`n" | Where-Object { $_ })
        $lines | Select-Object -Last 40 | ForEach-Object { Write-Output $_ }
    }
    exit 1
}

Write-Output ''
Write-Output 'every dispatched workflow passed'
exit 0
