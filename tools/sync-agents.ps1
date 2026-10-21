#Requires -Version 5
<#
.SYNOPSIS
  Render the static agent roster (workflows/agents.toml) into each tool's
  native agent format.

.DESCRIPTION
  Single source of truth is workflows/agents.toml. This writes:
    - Codex       agents    -> ~\.codex\agents\<name>.toml
    - OpenCode    subagents -> ~\.config\opencode\agents\<name>.md
    - CommandCode subagents -> ~\.commandcode\agents\<name>.md

  Superseded agents (the old Codex set and the OpenCode cavecrew set) are
  removed on render, so a rename in the roster cleans up after itself.

  CommandCode subagents load from ~/.commandcode/agents/ (personal scope) or
  .commandcode/agents/ (project scope); the parent reaches them through its
  built-in `agent` tool, which is available in headless `-p` turns. The roster
  also reaches CommandCode as prose in the global AGENTS.md ("Multi-agent
  roster" section), kept in sync by sync-agent-instructions.ps1.

.EXAMPLE
  .\sync-agents.ps1            # render the roster to all tools
  .\sync-agents.ps1 -Check     # report drift, change nothing (exit 2 if any)
#>
param(
  [string]$Roster = (Join-Path $PSScriptRoot '..\workflows\agents.toml'),
  [string]$CodexDir = (Join-Path $env:USERPROFILE '.codex\agents'),
  [string]$OpenCodeDir = (Join-Path $env:USERPROFILE '.config\opencode\agents'),
  [string]$CommandCodeDir = (Join-Path $env:USERPROFILE '.commandcode\agents'),
  [switch]$Check
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'roster.ps1')

# Agents this tool used to write, now replaced by the roster. Removed on render.
$Superseded = @(
  (Join-Path $CodexDir 'accessibility_explorer.toml'),
  (Join-Path $CodexDir 'implementer.toml'),
  (Join-Path $CodexDir 'reviewer.toml'),
  (Join-Path $CodexDir 'tester.toml'),
  (Join-Path $OpenCodeDir 'cavecrew-investigator.md'),
  (Join-Path $OpenCodeDir 'cavecrew-builder.md'),
  (Join-Path $OpenCodeDir 'cavecrew-reviewer.md')
)

function ConvertTo-TomlString { param([string]$s) return ($s -replace '\\', '\\' -replace '"', '\"') }
function ConvertTo-YamlString { param([string]$s) return ('"' + ($s -replace '"', '\"') + '"') }

function New-CodexAgent {
  param($Name, $A, $DefaultModel, $DefaultEffort)
  $model = if ($A.codex_model) { $A.codex_model } else { $DefaultModel }
  $effort = if ($A.codex_effort) { $A.codex_effort } else { $DefaultEffort }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("name = `"$Name`"")
  [void]$sb.AppendLine("description = `"$(ConvertTo-TomlString $A.description)`"")
  [void]$sb.AppendLine("model = `"$model`"")
  [void]$sb.AppendLine("model_reasoning_effort = `"$effort`"")
  if ($A.kind -eq 'read-only') { [void]$sb.AppendLine('sandbox_mode = "read-only"') }
  [void]$sb.AppendLine('developer_instructions = """')
  [void]$sb.AppendLine($A.instructions.Trim())
  [void]$sb.AppendLine('"""')
  return $sb.ToString()
}

function New-OpenCodeAgent {
  param($Name, $A)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('---')
  [void]$sb.AppendLine("description: $(ConvertTo-YamlString $A.description)")
  [void]$sb.AppendLine('mode: subagent')
  if ($A.opencode_model) { [void]$sb.AppendLine("model: $($A.opencode_model)") }
  if ($A.opencode_effort) { [void]$sb.AppendLine("reasoningEffort: $($A.opencode_effort)") }
  if ($A.opencode_steps) { [void]$sb.AppendLine("steps: $($A.opencode_steps)") }
  if ($A.kind -eq 'read-only') {
    [void]$sb.AppendLine('permission:')
    [void]$sb.AppendLine('  edit: deny')
  }
  [void]$sb.AppendLine('---')
  [void]$sb.AppendLine()
  [void]$sb.AppendLine($A.instructions.Trim())
  return $sb.ToString()
}

function New-CommandCodeAgent {
  param($Name, $A)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('---')
  [void]$sb.AppendLine("name: $Name")
  [void]$sb.AppendLine("description: $(ConvertTo-YamlString $A.description)")
  # CommandCode reads `model` and `reasoningEffort` from the front matter. Without
  # a pin the agent follows the session model, which left all four roster agents
  # on the same free model; the roster now names one per role.
  if ($A.commandcode_model) { [void]$sb.AppendLine("model: $($A.commandcode_model)") }
  if ($A.commandcode_effort) { [void]$sb.AppendLine("reasoningEffort: $($A.commandcode_effort)") }
  # CommandCode has no per-command shell allow-list, so a read-only agent is the
  # read/search/exec tools minus the two writers. shell_command stays because the
  # roster's read-only agents need rg and git, and a headless turn cannot answer
  # an ask; the residual risk is a write through the shell, as documented in
  # AGENT-SETUP.md.
  if ($A.kind -eq 'read-only') {
    [void]$sb.AppendLine('tools: read_file, read_directory, grep, glob, shell_command')
    [void]$sb.AppendLine('disallowedTools: edit_file, write_file')
  } else {
    [void]$sb.AppendLine('tools: "*"')
  }
  [void]$sb.AppendLine('---')
  [void]$sb.AppendLine()
  [void]$sb.AppendLine($A.instructions.Trim())
  return $sb.ToString()
}

# --- parse ---------------------------------------------------------------
$doc = ConvertFrom-RosterToml -Path $Roster
if (-not $doc.ContainsKey('agents') -or $doc.agents.Count -eq 0) { throw "No [agents.*] in $Roster" }
$defaultModel = if ($doc.roster -and $doc.roster.codex_default_model) { $doc.roster.codex_default_model } else { 'gpt-6-luna' }
$defaultEffort = if ($doc.roster -and $doc.roster.codex_default_effort) { $doc.roster.codex_default_effort } else { 'low' }
$utf8 = New-Object System.Text.UTF8Encoding($false)

# --- build artifacts -----------------------------------------------------
$artifacts = @{}
foreach ($name in ($doc.agents.Keys | Sort-Object)) {
  $a = $doc.agents[$name]
  $artifacts[(Join-Path $CodexDir "$name.toml")] = New-CodexAgent -Name $name -A $a -DefaultModel $defaultModel -DefaultEffort $defaultEffort
  $artifacts[(Join-Path $OpenCodeDir "$name.md")] = New-OpenCodeAgent -Name $name -A $a
  $artifacts[(Join-Path $CommandCodeDir "$name.md")] = New-CommandCodeAgent -Name $name -A $a
}

# --- write or check ------------------------------------------------------
$drift = $false
foreach ($path in $artifacts.Keys) {
  $content = $artifacts[$path]
  $existing = if (Test-Path -LiteralPath $path) { [System.IO.File]::ReadAllText($path) } else { $null }
  if ($null -ne $existing -and ($existing -replace "`r`n", "`n") -eq ($content -replace "`r`n", "`n")) {
    if ($Check) { "in sync  $path" }
    continue
  }
  $drift = $true
  if ($Check) { "DRIFTED  $path"; continue }
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllText($path, $content, $utf8)
  "wrote    $path"
}

# --- prune superseded ----------------------------------------------------
foreach ($path in $Superseded) {
  if (Test-Path -LiteralPath $path) {
    if ($Check) { "STALE    $path"; $drift = $true; continue }
    $ts = Get-Date -Format yyyyMMdd-HHmmss
    Move-Item -LiteralPath $path "$path.superseded-$ts" -Force
    "removed  $path"
  }
}

if ($Check -and $drift) { exit 2 }
if ($Check) { exit 0 }
if (-not $Check) { "roster: $($doc.agents.Count) agents -> $CodexDir, $OpenCodeDir, $CommandCodeDir" }
