#Requires -Version 5.1
<#
.SYNOPSIS
  Build a clean, shareable bundle of the workflow.

.DESCRIPTION
  The workspace folder is not shippable as-is: it holds worktrees, project
  repositories, build artifacts, per-machine backups, logs and live state.
  This script copies an explicit allowlist into a staging folder and zips it.

  What ships:
    - the policy and the docs (Markdown + generated HTML)
    - the canonical config (workflows/)
    - the install payload (workflow/)
    - every script (tools/*.ps1)
    - the doc generator, without its node_modules

  What never ships: worktrees, project repos, *.bak*, self-repair backups,
  logs, live state files, docgen/node_modules.

  Nothing is deleted from the source. The staging folder is rebuilt each run.

.PARAMETER Out
  Output zip path. Default: <workspace>\workflow-kit.zip

.PARAMETER NoHtml
  Skip the generated HTML pages.

.PARAMETER IncludeHtml
  Force the HTML pages in even if they have not been generated.

.PARAMETER NoSkills
  Leave the canonical skill set out of the bundle. The public release ships
  without skills: the set is not ours to redistribute.

.EXAMPLE
  ./package.ps1
  ./package.ps1 -Out D:\share\workflow-kit.zip
#>
[CmdletBinding()]
param(
    [string]$Out,
    [switch]$NoHtml,
    [switch]$IncludeHtml,
    [switch]$NoSkills
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'leak-scan.ps1')
$Tools    = $PSScriptRoot
$Root     = Split-Path $Tools -Parent
$Name     = 'workflow-kit'
$Stage    = Join-Path $env:TEMP ("workflow-kit-stage-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
if (-not $Out) { $Out = Join-Path $Root 'workflow-kit.zip' }

Write-Host ''
Write-Host 'Packaging the workflow' -ForegroundColor Cyan
Write-Host "  source: $Root" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Allowlist. Everything here is copied by explicit path - nothing is picked up
# by a wildcard over the workspace, so a stray file can never leak.
#
# Machine-specific and project-specific documents are deliberately excluded:
# the workspace AGENTS.md, the handover, the dated audits and the Kodi report.
# setup.ps1 generates a fresh workspace AGENTS.md and handover for the
# recipient, so the bundle stays free of this machine's state and paths.
# ---------------------------------------------------------------------------
$files = @(
    'START-HERE.md'
    'SELF-HEALING-WORKFLOW.md'
    'WORKFLOW-USAGE.md'
    'AGENTS-compat.md'
    'CHANGELOG.md'
    'CONTRIBUTING.md'
    'SECURITY.md'
    '.github\workflows\verify.yml'
    '.github\workflows\release.yml'
    '.github\workflows\drift.yml'
    '.github\workflows\install-check.yml'
    'LICENSE'
    '.gitignore'
    'workflows\agents.toml'
    'workflows\workflow.toml'
    'workflows\workflow.md'
    'workflow\AGENTS.template.md'
    'workflow\taste-starter\taste.md'
    'workflow\commandcode-settings.template.json'
    'workflow\commandcode-hooks\superpowers-bootstrap.mjs'
    'tools\AGENT-SETUP.md'
    'tools\DEV-SETUP.md'
    'tools\README.template.md'
    'tools\model-prices.json'
    'tools\free-models.json'
    'tools\agent-interop\server.mjs'
    'tools\agent-interop\package.json'
    'tools\agent-interop\package-lock.json'
    'tools\docgen\convert-docs.mjs'
    'tools\docgen\verify-html.mjs'
    'tools\docgen\package.json'
    'tools\docgen\package-lock.json'
)

# Every script in tools/, by extension - no .bak files match.
Get-ChildItem -LiteralPath $Tools -Filter '*.ps1' -File | ForEach-Object {
    $files += ('tools\' + $_.Name)
}

# The Python helpers the scripts call: the continuation runner, the config
# checker and its test.
Get-ChildItem -LiteralPath $Tools -Filter '*.py' -File | ForEach-Object {
    $files += ('tools\' + $_.Name)
}

# The canonical skill set travels with the bundle, so a new user gets a
# working skill layer instead of "canonical skill set missing" - unless the
# bundle is the public release, which ships without skills.
$skillsSrc = Join-Path $env:USERPROFILE '.agents\skills'
if ($NoSkills) {
    Write-Host '    skills left out (public release)' -ForegroundColor Yellow
} elseif (Test-Path $skillsSrc) {
    $skillsOut = Join-Path (Join-Path $Stage $Name) 'workflow\skills'
    New-Item -ItemType Directory -Force -Path $skillsOut | Out-Null
    Get-ChildItem -LiteralPath $skillsSrc -Directory | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $skillsOut $_.Name) -Recurse -Force
    }
    $skillCount = @(Get-ChildItem $skillsOut -Directory).Count
} else {
    Write-Host '    canonical skill set not found - the bundle will ship without skills' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# HTML: render the generic subset so the bundle index has no dead links.
# ---------------------------------------------------------------------------
$htmlDocs = @(
    'start-here'
    'self-healing-workflow'
    'workflow-usage'
    'agent-setup'
    'dev-setup'
    'agents-compat'
)
$htmlFiles = @()
if (-not $NoHtml) {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    $docgen = Join-Path $Tools 'docgen'
    if ($node -and (Test-Path (Join-Path $docgen 'node_modules\marked'))) {
        $htmlOut = Join-Path (Join-Path $Stage $Name) 'html'
        New-Item -ItemType Directory -Force -Path $htmlOut | Out-Null
        & $node.Source (Join-Path $docgen 'convert-docs.mjs') "--only=$($htmlDocs -join ',')" "--out=$htmlOut" | Out-Null
        $htmlFiles = @(Get-ChildItem -LiteralPath $htmlOut -Filter '*.html' -File | ForEach-Object { 'html\' + $_.Name })
    } else {
        Write-Host '    node or marked not found - shipping without the HTML pages' -ForegroundColor Yellow
        Write-Host '    (regenerate later: cd tools\docgen; npm install; node convert-docs.mjs)' -ForegroundColor DarkYellow
    }
}

$copied = 0; $missing = @()
New-Item -ItemType Directory -Force -Path (Join-Path $Stage $Name) | Out-Null
foreach ($rel in ($files + $htmlFiles)) {
    $src = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $src)) { $missing += $rel; continue }
    $dst = Join-Path (Join-Path $Stage $Name) $rel
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $copied++
}

# The policy in the bundle is the live canonical one with the generated taste
# block removed: taste is per-user and is injected after installation. This way
# the release always carries the current policy - no refresh step to forget.
$livePolicy = Join-Path $env:USERPROFILE '.codex\AGENTS.md'
$stagedTemplate = Join-Path (Join-Path $Stage $Name) 'workflow\AGENTS.template.md'
if (Test-Path $livePolicy) {
    $stagedDir = Split-Path $stagedTemplate -Parent
    if (-not (Test-Path -LiteralPath $stagedDir)) { New-Item -ItemType Directory -Force -Path $stagedDir | Out-Null }
    . (Join-Path $PSScriptRoot 'policy_template.ps1')
    [System.IO.File]::WriteAllText($stagedTemplate, (Get-PolicyTemplateText -LivePath $livePolicy), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host '    policy refreshed from the live canonical AGENTS.md' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Refuse to ship a taste block, a credential or a machine path.
#
# The bundle is public. The learned taste is per-user and must never travel
# with it, and a credential or a personal path in a public release is a leak
# that cannot be undone by deleting the file later. The scan runs at the end
# of this script, after every file is written.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Bundle README
# ---------------------------------------------------------------------------
$skillsNote = if ($skillCount -gt 0) {
    "The canonical skill set travels with this bundle in ``workflow/skills/`` ($skillCount skills). The installer copies it into ``~/.agents/skills``."
} else {
    "The canonical skill set is **not** bundled. The workflow works without it: the task cues run as prose instructions."
}

$readmeTemplate = Join-Path $Tools 'README.template.md'
if (-not (Test-Path -LiteralPath $readmeTemplate)) { throw "README template missing: $readmeTemplate" }
$readme = [System.IO.File]::ReadAllText($readmeTemplate, [System.Text.Encoding]::UTF8)
$readme = $readme.Replace('{{SKILLS_NOTE}}', $skillsNote)
[System.IO.File]::WriteAllText((Join-Path (Join-Path $Stage $Name) 'README.md'), $readme, (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------------------
# Refuse to ship a taste block, a credential, a machine path or anything in
# the personal leak patterns. Every file is written by now, the README
# included, so nothing can slip in behind the scan.
#
# The scanner lives in tools/leak-scan.ps1, shared with the CI workflow that
# scans this repository's tracked files.
# ---------------------------------------------------------------------------
$leaks = @(Get-StagedLeaks -StageRoot (Join-Path $Stage $Name))
if ($leaks.Count -gt 0) {
    Write-Host '    REFUSING TO SHIP - the bundle contains things that must stay private:' -ForegroundColor Red
    $leaks | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    Remove-Item $Stage -Recurse -Force
    exit 1
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
$live = Join-Path $env:USERPROFILE '.codex\AGENTS.md'
$policyHash = 'not found'
if (Test-Path $live) {
    $t = [System.IO.File]::ReadAllText($live)
    $a = $t.IndexOf('<!-- TASTE:BEGIN'); $b = $t.IndexOf('<!-- TASTE:END -->')
    if ($a -ge 0 -and $b -gt $a) { $t = $t.Substring(0, $a).TrimEnd() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $policyHash = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($t))) }
    finally { $sha.Dispose() }
}
$manifest = @(
    "workflow-kit manifest"
    "built:      " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    "source:     (not recorded - the bundle is machine independent)"
    "files:      $copied"
    "skills:     $skillCount"
    "policy sha: $policyHash"
    ""
    "contents:"
) + ($files + $htmlFiles | Sort-Object | ForEach-Object { "  $_" }) + @(
    "  README.md"
) + $(if ($skillCount -gt 0) { @("  workflow\skills\  ($skillCount canonical skills)") } else { @("  (no skills - the public release ships without them)") }) + @(
    ""
    "excluded by design: .worktrees\, project repositories, *.bak*,"
    "  self-repair-backups\, *.log, live state json, docgen\node_modules,"
    "  the workspace AGENTS.md and HANDOVER (setup.ps1 generates those)"
)
[System.IO.File]::WriteAllLines((Join-Path (Join-Path $Stage $Name) 'BUNDLE-MANIFEST.txt'), $manifest, (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------------------
# Zip
# ---------------------------------------------------------------------------
# A ZIP entry cannot store a timestamp before 1980, and some skill files carry
# an epoch timestamp from extraction. Normalise every staged file first.
$now = Get-Date
Get-ChildItem -LiteralPath (Join-Path $Stage $Name) -Recurse -Force | ForEach-Object {
    try { $_.LastWriteTime = $now } catch { }
}
if (Test-Path $Out) { Remove-Item $Out -Force }
$outDir = Split-Path $Out -Parent
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
Compress-Archive -Path (Join-Path $Stage $Name) -DestinationPath $Out -CompressionLevel Optimal
Remove-Item $Stage -Recurse -Force

$size = [math]::Round((Get-Item $Out).Length / 1KB, 1)
Write-Host "    bundled $copied files -> $Out ($size KB)" -ForegroundColor Green
if ($missing.Count) {
    Write-Host '    not found (skipped):' -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
}
Write-Host ''
Write-Host 'Check it before sharing:' -ForegroundColor White
Write-Host "  Expand-Archive -Path '$Out' -DestinationPath <dir>" -ForegroundColor DarkGray
Write-Host '  then: cd <dir>\workflow-kit\tools; powershell -File .\setup.ps1 -Check' -ForegroundColor DarkGray
exit 0
