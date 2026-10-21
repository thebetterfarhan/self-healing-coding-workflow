#Requires -Version 5
<#
  check-workflow-pins.ps1 - check that every action a workflow pins still exists.

  A workflow that pins an action to a commit SHA is reproducible, and that is
  the point of pinning. It is also a promise: the commit has to still be there
  when the workflow runs. An action repository that rewrites its release
  branch deletes the commit the pin named, and the workflow then fails before
  its first step, with no log to read.

  This finds those dead pins before a workflow reaches a runner.

  .EXAMPLE
  ./check-workflow-pins.ps1 -Repo owner/name
  ./check-workflow-pins.ps1 -Path .github/workflows
#>
[CmdletBinding()]
param(
    # Repositories to scan, as owner/name.
    [string[]]$Repos = @(),
    # Local directories to scan instead of repositories.
    [string[]]$Path = @(),
    [switch]$List
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'the GitHub CLI (gh) is not on PATH'
}

# Every `uses:` value is owner/repo[/path]@ref. Only the SHA pins are checked:
# a tag is resolved at run time, so it cannot be dead before the run. The
# pattern uses [ \t] and not \s: \s matches a line break, and the pattern
# would then swallow the next line and miss every pin but the first.
$pinPattern = '(?m)^[ \t]*-?[ \t]*uses:[ \t]*["'']?([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(/[A-Za-z0-9_./-]+)?@([0-9a-f]{40})["'']?[ \t]*\r?$'

# A GitHub error is an answer, not a crash: the point of the check is to find
# the pins that are gone, so the error text has to be read, not thrown on.
function Invoke-Gh {
    param([string[]]$Arguments)
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

$dead = @()
$checked = 0

function Test-Pins {
    param([string]$Label, [hashtable]$Files)

    foreach ($name in ($Files.Keys | Sort-Object)) {
        $text = $Files[$name]
        foreach ($m in [regex]::Matches($text, $pinPattern)) {
            $owner = $m.Groups[1].Value
            $repo = $m.Groups[2].Value
            $sha = $m.Groups[4].Value
            $script:checked++
            $found = Invoke-Gh -Arguments @('api', "repos/$owner/$repo/commits/$sha")
            if ($found.Code -eq 0 -and $found.Out -match '"sha"') { continue }
            $script:dead += [pscustomobject]@{ Where = "$Label/$name"; Action = "$owner/$repo"; Sha = $sha }
        }
    }
}

if ($Path) {
    foreach ($dir in $Path) {
        Test-Pins -Label $dir -Files (Get-LocalWorkflowFiles -Dir $dir)
    }
}
foreach ($repo in $Repos) {
    Test-Pins -Label $repo -Files (Get-WorkflowFiles -Repo $repo)
}

Write-Output ("checked {0} pinned action(s)" -f $checked)
if ($dead.Count -eq 0) {
    Write-Output 'every pinned action still exists'
    exit 0
}
foreach ($d in $dead) {
    Write-Output ("DEAD PIN: {0} -> {1}@{2}" -f $d.Where, $d.Action, $d.Sha)
}
exit 1
