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

# ---------------------------------------------------------------------------
# Bundle README
# ---------------------------------------------------------------------------
$skillsNote = if ($skillCount -gt 0) {
    "The canonical skill set travels with this bundle in ``workflow/skills/`` ($skillCount skills). The installer copies it into ``~/.agents/skills``."
} else {
    "The canonical skill set is **not** bundled. The workflow works without it: the task cues run as prose instructions."
}

$readme = @"
# Self-Healing Coding Workflow

A self-healing, self-repairing workflow for Codex, OpenCode and Command Code.

**Author:** Farhan Khan ([@thebetterfarhan](https://github.com/thebetterfarhan))
**License:** MIT

## Install

```
# 1. Unzip anywhere, e.g. ~/Documents/Codex
# 2. Install
cd tools
powershell -NoProfile -ExecutionPolicy Bypass -File ./setup.ps1
```

\`setup.ps1 -Check\` reports what it would do and writes nothing.

Open a new PowerShell window afterwards, then run:

```
work 'Find the setting that controls focus return' -Preview
```

Read \`START-HERE.md\` next. It is the shortest path to "useful".

## Requirements

- Windows 10/11 with PowerShell 5.1 (any modern Windows).
- git.
- At least one coding CLI (Codex, OpenCode or Command Code). The workflow
  degrades gracefully if one is missing.

## Optional

- **rtk** - token-saving command wrapper. Without it, commands run normally.
- **Superpowers skills** - guided workflows for the four task cues. Without
  them, the cues still work as prose instructions.
- **Audio feedback** - never installed by default.

$skillsNote

## What is in here

| Path | What |
| --- | --- |
| \`START-HERE.md\` | Read this first. |
| \`SELF-HEALING-WORKFLOW.md\` | The complete reference, basics to advanced. |
| \`WORKFLOW-USAGE.md\` | Operator quick reference. |
| \`workflows/\` | Canonical config: the agent roster. |
| \`workflow/\` | Install payload: the policy template, the starter taste, the permission template. |
| \`tools/\` | Every script. Plain PowerShell with a header comment each. |
| \`html/\` | This documentation, published for a screen reader. |
| \`LICENSE\` | MIT. |

## Check it any time

\`\`\`
workflow-status
\`\`\`

One screen: install state, the nightly job and its last result, drift per
layer, backend health, and spend. Exit 0 means healthy.

## The one thing to edit

\`~/.commandcode/taste/taste.md\` - your preferences. It ships with a baseline
that you correct once. The nightly job renders it into every agent's
instruction file, so one edit applies to all three.

## The configuration repository

The workspace is a git repository that holds the configuration only - the
policy, the docs, \`workflows/\`, \`workflow/\`, \`tools/\` and the HTML. The
project repositories in the same folder are ignored.

\`tools/repair-config.ps1\` is the first step of the nightly job: it validates
every tracked file, restores a broken one from the last good commit and
records the validated state. It creates the repository if it is missing, so a
fresh install heals itself from the first run. There is no remote - nothing is
pushed.


## The nightly job

At 03:00 a scheduled task re-syncs the configuration, refreshes the model
catalogs, distils the day's sessions into memory, and rolls back any step
that fails. Log: \`tools/self-repair.log\`.

Turn it off:
\`\`\`
Unregister-ScheduledTask CodexWorkflowSelfHeal -Confirm:\$false
\`\`\`

## Rebuilding the HTML

\`\`\`
cd tools/docgen
npm install
node convert-docs.mjs
node verify-html.mjs
\`\`\`

Built with marked 18.1.1 (MIT).
"@
[System.IO.File]::WriteAllText((Join-Path (Join-Path $Stage $Name) 'README.md'), $readme, (New-Object System.Text.UTF8Encoding($false)))

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
