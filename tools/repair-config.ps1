#Requires -Version 5.1
<#
.SYNOPSIS
  Keep the workflow configuration healthy and recoverable.

.DESCRIPTION
  The workflow configuration lives in its own git repo at the workspace root:
  the policy, the docs, the canonical config in workflows/, the install
  payload in workflow/, the scripts in tools/ and the published HTML. The
  project repositories are ignored - each one keeps its own history.

  This is that repo's self-healing step:

    1. validate every tracked file by type - PowerShell parse, Python syntax
       and TOML parse, JSON parse, node --check;
    2. restore a file that fails validation from the last good commit, keeping
       the broken copy next to it as <name>.broken-<stamp>;
    3. commit the validated files, so the next run has something to restore
       from.

  With -Check it only validates: nothing is written and nothing is committed.

  Exit 0 when the configuration is healthy, 1 when a file is broken and could
  not be restored.

.PARAMETER Check
  Validate only. No restore, no commit.

.EXAMPLE
  ./repair-config.ps1 -Check
  ./repair-config.ps1
#>
[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$Tools = $PSScriptRoot
$Root  = Split-Path $Tools -Parent

# Everything this repo owns. The project repositories are not in the list.
$managed = @(
    '.gitignore', 'AGENTS.md', 'AGENTS-compat.md', 'START-HERE.md', 'LICENSE',
    'SELF-HEALING-WORKFLOW.md', 'WORKFLOW-USAGE.md',
    'WORKFLOW-AUDIT-2026-10-14.md', 'WORKFLOW-AUDIT-2026-10-18.md',
    'workflows', 'workflow', 'tools', 'html'
)

$python = Get-Command python -ErrorAction SilentlyContinue
$node   = Get-Command node.exe -ErrorAction SilentlyContinue

function Invoke-Git {
    param([string[]]$Arguments)
    $out = & git -C $Root @Arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}

function Get-TrackedFiles {
    $r = Invoke-Git @('ls-files')
    if ($r.Code -ne 0) { return @() }
    return @($r.Out -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
}

# Returns a hashtable of absolute path -> reason. Empty means healthy.
function Get-ConfigProblems {
    param([string[]]$Files)

    $problems = @{}
    $py = @(); $toml = @(); $json = @(); $js = @()
    foreach ($rel in $Files) {
        $abs = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $abs)) {
            $problems[$abs] = 'missing from disk'
            continue
        }
        if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }

        switch -Wildcard ($rel) {
            '*.ps1' {
                $errs = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile($abs, [ref]$null, [ref]$errs)
                if ($errs) { $problems[$abs] = 'PowerShell parse error: ' + $errs[0].Message }
                break
            }
            '*.py'  { $py   += $abs; break }
            '*.toml'{ $toml += $abs; break }
            '*.json'{ $json += $abs; break }
            '*.mjs' { $js   += $abs; break }
            '*.js'  { $js   += $abs; break }
            default {
                if ((Get-Item -LiteralPath $abs).Length -eq 0) { $problems[$abs] = 'empty file' }
            }
        }
    }

    if (($py.Count + $toml.Count + $json.Count) -gt 0) {
        if ($python) {
            $all = @($py + $toml + $json)
            $saved = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $out = & $python.Source (Join-Path $Tools 'config_check.py') @all 2>&1 | Out-String
            $code = $LASTEXITCODE
            $ErrorActionPreference = $saved
            $parsed = 0
            foreach ($line in ($out -split "`r?`n")) {
                if ($line -match '^FAIL\t(.+?)\t(.*)$') {
                    $problems[$Matches[1]] = $Matches[2]
                    $parsed++
                }
            }
            if ($parsed -eq 0 -and $code -ne 0) {
                foreach ($file in $all) { $problems[$file] = 'python check failed' }
            }
        }
    }

    foreach ($file in $js) {
        if (-not $node) { continue }
        $out = & $node.Source --check $file 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { $problems[$file] = 'JavaScript syntax error: ' + $out.Trim() }
    }

    return $problems
}

function Restore-FromGit {
    param([string]$AbsolutePath, [string]$RelativePath)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $kept = "$AbsolutePath.broken-$stamp"
    Copy-Item -LiteralPath $AbsolutePath -Destination $kept -Force -ErrorAction SilentlyContinue

    $r = Invoke-Git @('restore', '--source=HEAD', '--', $RelativePath)
    if ($r.Code -ne 0) { return $false }
    return (Test-Path -LiteralPath $AbsolutePath)
}

# Keep the five newest broken copies of each file, like every other backup here.
function Remove-OldBrokenCopies {
    param([string[]]$Folders)

    foreach ($folder in $Folders) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        Get-ChildItem -LiteralPath $folder -Filter '*.broken-*' -File -Recurse -ErrorAction SilentlyContinue |
            Group-Object { $_.DirectoryName + '\' + ($_.Name -replace '\.broken-.*$', '') } |
            ForEach-Object {
                $_.Group | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            }
    }
}

# --- run ---------------------------------------------------------------------

# Only the paths that exist: git refuses a pathspec that matches nothing, and
# a fresh install does not have every one of them yet.
$managedPaths = @($managed | Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) })

if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
    if ($Check) {
        Write-Output 'config repo missing: no git repository at the workspace root'
        exit 1
    }
    Write-Output 'config repo missing - creating it from the current configuration'
    & git -C $Root init -q -b main | Out-Null
    if ($managedPaths.Count -gt 0) {
        & git -C $Root add -A -- $managedPaths | Out-Null
        $staged = Invoke-Git @('diff', '--cached', '--quiet')
        if ($staged.Code -ne 0) {
            & git -C $Root commit -q -m 'workflow: track the workflow configuration' | Out-Null
        }
    }
}

$files = Get-TrackedFiles
if (-not $files -or $files.Count -eq 0) {
    if ($managedPaths.Count -eq 0) {
        Write-Output 'config repo: no configuration files found - nothing to track'
        exit 0
    }
    Write-Output 'config repo has no tracked files'
    exit 1
}

$problems = Get-ConfigProblems -Files $files
$restored = @()
$failed = @()

if ($problems.Count -gt 0) {
    foreach ($abs in $problems.Keys) {
        $rel = $abs.Substring($Root.Length).TrimStart('\', '/')
        if ($Check) { continue }
        if (Restore-FromGit -AbsolutePath $abs -RelativePath $rel) {
            $restored += $rel
        } else {
            $failed += $rel
        }
    }
    if (-not $Check -and $restored.Count -gt 0) {
        $still = Get-ConfigProblems -Files $files
        foreach ($abs in $still.Keys) {
            $rel = $abs.Substring($Root.Length).TrimStart('\', '/')
            if ($restored -contains $rel) { $failed += $rel }
        }
    }
}

if ($Check) {
    if ($problems.Count -gt 0) {
        foreach ($abs in $problems.Keys) {
            $rel = $abs.Substring($Root.Length).TrimStart('\', '/')
            Write-Output ("BROKEN {0}: {1}" -f $rel, $problems[$abs])
        }
        Write-Output ("config check FAILED: {0} broken file(s)" -f $problems.Count)
        exit 1
    }
    Write-Output ("config check OK: {0} tracked file(s)" -f $files.Count)
    exit 0
}

if ($failed.Count -gt 0) {
    foreach ($rel in $failed) { Write-Output ("UNHEALED {0}" -f $rel) }
    Write-Output ("config repair FAILED: {0} file(s) could not be restored" -f $failed.Count)
    exit 1
}

# Record the validated state, so the next run has something to restore from.
if ($managedPaths.Count -gt 0) {
    & git -C $Root add -A -- $managedPaths | Out-Null
}
# The broken copies are evidence, not configuration: they never get committed.
$kept = @(& git -C $Root diff --cached --name-only -- '*.broken-*' 2>$null | Where-Object { $_ })
if ($kept.Count -gt 0) {
    & git -C $Root reset -q -- $kept | Out-Null
}
Remove-OldBrokenCopies -Folders @((Join-Path $Root 'tools'), (Join-Path $Root 'workflows'), (Join-Path $Root 'workflow'))
$staged = Invoke-Git @('diff', '--cached', '--quiet')
$restoredNote = if ($restored.Count -gt 0) { ", {0} restored" -f $restored.Count } else { '' }
if ($staged.Code -eq 0) {
    Write-Output ("config healthy: {0} tracked file(s){1}, nothing to commit" -f $files.Count, $restoredNote)
    exit 0
}

$subject = (& git -C $Root diff --cached --name-only | Out-String).Trim()
$count = @($subject -split "`r?`n" | Where-Object { $_ }).Count
& git -C $Root commit -q -m ("workflow: record the validated configuration ({0} file(s))" -f $count) | Out-Null

Write-Output ("config healthy: {0} tracked file(s){1}, committed {2} change(s)" -f $files.Count, $restoredNote, $count)
exit 0
