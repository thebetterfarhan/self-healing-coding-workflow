#Requires -Version 5
<#
  roster.ps1 - shared reader for workflows/agents.toml.

  Dot-source this to read the roster, which is the single source of truth for
  the agent roster and the tier table. The reader handles the subset
  agents.toml uses: [tables], key = "string", key = """multiline""", and
  # comments. Enough for agents.toml; not a general TOML parser.

  .EXAMPLE
  . "$PSScriptRoot\roster.ps1"
  $doc = ConvertFrom-RosterToml -Path $path
#>
function ConvertFrom-RosterToml {
  <#  Minimal TOML reader for the roster subset: [tables], key = "string",
      key = """multiline""", # comments. Enough for agents.toml; not general. #>
  param([string]$Path)
  $root = @{}
  $cur = $root
  $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
    if ($line -match '^\s*\[([^\]]+)\]\s*(#.*)?$') {
      $cur = $root
      foreach ($part in $matches[1].Split('.')) {
        if (-not $cur.ContainsKey($part)) { $cur[$part] = @{} }
        $cur = $cur[$part]
      }
      continue
    }
    if ($line -match '^\s*([A-Za-z0-9_-]+)\s*=\s*(.+)$') {
      $key = $matches[1]
      $val = $matches[2].Trim()
      if ($val.StartsWith('"""')) {
        $buf = $val.Substring(3)
        while ($buf -notmatch '"""') {
          $i++
          if ($i -ge $lines.Count) { throw "unterminated multiline string for '$key'" }
          $buf += "`n" + $lines[$i]
        }
        $val = $buf.Substring(0, $buf.IndexOf('"""')).Trim()
      } elseif ($val.StartsWith('"')) {
        $val = $val -replace '^(?s)"(.*)"\s*(#.*)?$', '$1'
        $val = $val -replace '\\"', '"'
      } else {
        $val = $val -replace '\s+#.*$', ''
      }
      $cur[$key] = $val
      continue
    }
    throw "unrecognised roster line $($i+1): $line"
  }
  return $root
}

function Get-RosterTierTable {
  <#  Builds the router's tier table from the roster: tier -> backend ->
      @{ Model = ...; Effort = ... }. Effort is omitted where the model takes
      none, which reads back as $null. #>
  param([string]$Path)
  $doc = ConvertFrom-RosterToml -Path $Path
  if (-not $doc.ContainsKey('tiers')) { throw "no [tiers] section in $Path" }
  $table = [ordered]@{}
  foreach ($tier in ($doc.tiers.Keys | Sort-Object)) {
    $row = $doc.tiers[$tier]
    $entry = [ordered]@{}
    foreach ($backend in @('commandcode', 'codex', 'opencode')) {
      $model = $row["${backend}_model"]
      if (-not $model) { continue }
      $cell = @{ Model = $model }
      $effort = $row["${backend}_effort"]
      if ($effort) { $cell.Effort = $effort }
      $entry[$backend] = $cell
    }
    $table[$tier] = $entry
  }
  return $table
}
