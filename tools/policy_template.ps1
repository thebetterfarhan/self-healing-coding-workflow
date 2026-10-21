#Requires -Version 5.1
<#
  policy_template.ps1 - the distributable copy of the global policy.

  The template is the canonical ~/.codex/AGENTS.md with the generated taste
  block removed: taste is per-user and is injected by tools/sync-taste.ps1
  after installation, so it must never travel with the template.

  Both setup.ps1 (-RefreshTemplate) and package.ps1 (the public bundle) write
  it, so the text lives here once - two copies of this drifted apart before.
#>

function Get-PolicyTemplateText {
    <#
    .SYNOPSIS
      The template text for the canonical policy at $LivePath.

    .OUTPUTS
      The header plus the policy, without the generated taste block.
    #>
    param([Parameter(Mandatory)][string]$LivePath)

    if (-not (Test-Path -LiteralPath $LivePath)) { throw "No live AGENTS.md at $LivePath" }
    $text = [System.IO.File]::ReadAllText($LivePath)
    $begin = '<!-- TASTE:BEGIN'; $end = '<!-- TASTE:END -->'
    $a = $text.IndexOf($begin); $b = $text.IndexOf($end)
    if ($a -ge 0 -and $b -gt $a) { $text = $text.Substring(0, $a).TrimEnd() + "`n" }
    $header = @(
        '<!--'
        '  AGENTS.template.md - the global policy, distributable.'
        ''
        '  A frozen snapshot of the canonical ~/.codex/AGENTS.md with the generated'
        '  taste block removed. Taste is per-user and is injected by'
        '  tools/sync-taste.ps1 after installation.'
        ''
        '  Refresh with:  ~/Documents/Codex/tools/setup.ps1 -RefreshTemplate'
        '-->'
        ''
        ''
    ) -join "`n"
    return $header + $text
}
