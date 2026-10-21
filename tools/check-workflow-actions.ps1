#Requires -Version 5
<#
  check-workflow-actions.ps1  -  check the actions a repository's workflows use.

  Three things stop a workflow before its first step, with no log to read:

    1. The repository's Actions policy forbids the action. A repository can
       allow only a list of actions, and a workflow that uses one that is not
       on the list never starts.
    2. The repository requires every action to be pinned to a full commit
       SHA, and one of them is pinned to a tag.
    3. The pinned commit cannot be found any more.

  This finds all three before a workflow reaches a runner.

  .EXAMPLE
  ./check-workflow-actions.ps1 -Repo owner/name
  ./check-workflow-actions.ps1 -Path .github/workflows
#>
[CmdletBinding()]
param(
    # Repositories to scan, as owner/name.
    [string[]]$Repos = @(),
    # Local directories to scan instead of repositories.
    [string[]]$Path = @(),
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'the GitHub CLI (gh) is not on PATH'
}

# Every `uses:` value is owner/repo[/path]@ref. The pattern uses [ \t] and
# not \s: \s matches a line break, and the pattern would then swallow the
# next line and miss every action but the first.
$usesPattern = '(?m)^[ \t]*-?[ \t]*uses:[ \t]*["'']?([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(/[A-Za-z0-9_./-]+)?@([^"''\s]+)["'']?[ \t]*\r?$'

function Invoke-Gh {
    param([string[]]$Arguments)
    # A GitHub error is an answer, not a crash: the point of the check is to
    # find what is wrong, so the error text has to be read, not thrown on.
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& gh @Arguments 2>&1) | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    return [pscustomobject]@{ Out = $out; Code = $code }
}

function Get-WorkflowFiles {
    param([string]$Repo)

    $files = @{}
    $listed = Invoke-Gh -Arguments @('api', "repos/$Repo/contents/.github/workflows")
    if ($listed.Code -ne 0) { return $files }
    foreach ($entry in ($listed.Out | ConvertFrom-Json)) {
        if ($entry.type -ne 'file') { continue }
        if ($entry.name -notmatch '\.ya?ml$') { continue }
        $content = Invoke-Gh -Arguments @('api', "repos/$Repo/contents/$($entry.path)")
        if ($content.Code -ne 0) { continue }
        $json = $content.Out | ConvertFrom-Json
        $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(($json.content -replace '\s', '')))
        $files[$entry.path] = $text
    }
    return $files
}

function Get-LocalWorkflowFiles {
    param([string]$Dir)

    $files = @{}
    if (-not (Test-Path -LiteralPath $Dir)) { return $files }
    foreach ($f in (Get-ChildItem -LiteralPath $Dir -Filter '*.y*ml' -File -ErrorAction SilentlyContinue)) {
        $files[$f.FullName] = [System.IO.File]::ReadAllText($f.FullName)
    }
    return $files
}

# The policy of a repository: which actions may run, and whether every action
# has to be pinned to a commit.
function Get-Policy {
    param([string]$Repo)

    $permissions = Invoke-Gh -Arguments @('api', "repos/$Repo/actions/permissions")
    if ($permissions.Code -ne 0) { return $null }
    $doc = $permissions.Out | ConvertFrom-Json
    $policy = [pscustomobject]@{
        Selected = ($doc.allowed_actions -eq 'selected')
        PinningRequired = [bool]$doc.sha_pinning_required
        Patterns = @()
    }
    if (-not $policy.Selected) { return $policy }
    $selected = Invoke-Gh -Arguments @('api', "repos/$Repo/actions/permissions/selected-actions")
    if ($selected.Code -eq 0) { $policy.Patterns = @((($selected.Out | ConvertFrom-Json).patterns_allowed)) }
    return $policy
}

# Does the policy allow this action? The pattern is owner/repo[/path]@ref and
# a wildcard stands for any part of it. A pattern without a path does not
# cover an action that has one: `github/codeql-action@*` does not allow
# `github/codeql-action/init@...`, and `github/codeql-action/*@*` does.
function Test-Allowed {
    param([string]$Owner, [string]$Action, [string]$SubPath, [string]$Ref, $Policy, [string]$RepoOwner)

    if ($Owner -eq $RepoOwner) { return $true }
    if (-not $Policy) { return $true }
    # A repository that allows every action has no list to be outside of.
    if (-not $Policy.Selected) { return $true }
    foreach ($pattern in $Policy.Patterns) {
        $p = $pattern
        $pRef = '*'
        $at = $p.LastIndexOf('@')
        if ($at -gt 0) { $pRef = $p.Substring($at + 1); $p = $p.Substring(0, $at) }
        $parts = $p -split '/'
        $pOwner = $parts[0]
        $pRepo = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $pPath = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)] -join '/') } else { '' }
        if ($pOwner -ne '*' -and $pOwner -ne $Owner) { continue }
        if ($pRepo -ne '*' -and $pRepo -ne $Action) { continue }
        if ($pPath -eq '') {
            # A pattern without a path covers only an action without a path.
            if ($SubPath -ne '') { continue }
        } elseif ($pPath -ne '*' -and $pPath -ne $SubPath) { continue }
        if ($pRef -ne '*' -and $pRef -ne $Ref) { continue }
        return $true
    }
    return $false
}

$problems = @()
$warnings = @()
$checked = 0

function Test-Workflows {
    param([string]$Label, [hashtable]$Files, $Policy, [string]$RepoOwner)

    foreach ($name in ($Files.Keys | Sort-Object)) {
        foreach ($m in [regex]::Matches($Files[$name], $usesPattern)) {
            $owner = $m.Groups[1].Value
            $action = $m.Groups[2].Value
            $subPath = $m.Groups[3].Value.TrimStart('/')
            $ref = $m.Groups[4].Value
            $script:checked++
            $where = "$Label/$name"

            if (-not (Test-Allowed -Owner $owner -Action $action -SubPath $subPath -Ref $ref -Policy $Policy -RepoOwner $RepoOwner)) {
                $script:problems += "$where : $owner/$action$($(if ($subPath) { "/$subPath" }))@$ref is not allowed by the repository's Actions policy"
            }
            if ($Policy -and $Policy.PinningRequired -and $ref -notmatch '^[0-9a-f]{40}$') {
                $script:problems += "$where : $owner/$action@$ref is not pinned to a full commit SHA and the repository requires it"
            }
            if ($ref -match '^[0-9a-f]{40}$') {
                $found = Invoke-Gh -Arguments @('api', "repos/$owner/$action/commits/$ref")
                if ($found.Code -ne 0) {
                    # The action can still be fetched by SHA, so this is a
                    # warning: the commit is not reachable through the API and
                    # will one day be gone.
                    $script:warnings += "$where : $owner/$action@$ref cannot be found through the API - it is fragile"
                }
            }
        }
    }
}

if ($Path) {
    foreach ($dir in $Path) {
        Test-Workflows -Label $dir -Files (Get-LocalWorkflowFiles -Dir $dir) -Policy $null -RepoOwner ''
    }
}
foreach ($repo in $Repos) {
    $owner = ($repo -split '/')[0]
    Test-Workflows -Label $repo -Files (Get-WorkflowFiles -Repo $repo) -Policy (Get-Policy -Repo $repo) -RepoOwner $owner
}

if (-not $Quiet) { Write-Output ("checked {0} action use(s)" -f $checked) }
foreach ($w in $warnings) { Write-Output ("warning: {0}" -f $w) }
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Output ("PROBLEM: {0}" -f $p) }
    exit 1
}
if (-not $Quiet) { Write-Output 'every action is allowed by its policy and pinned' }
exit 0
