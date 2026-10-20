#Requires -Version 5
<#
  memory-curate.ps1 — keep curated Memory growing without waiting for an ask.

  Codex only updates MEMORY.md when the user explicitly asks, so raw rollout
  summaries accumulate faster than curation. This script does the mechanical
  half, deterministically, on the memory system's own write path:

    - Reads rollout summaries updated since the last processed pass.
    - For each, extracts the title, outcome, and the "Failures and how to do
      differently" / "Reusable knowledge" bullets.
    - Writes one small proposed update per summary to
      .codex\memories\extensions\ad_hoc\notes\<timestamp>-<slug>.md — the
      sanctioned append-only note format the merge pipeline already accepts.

  No model calls, so nothing is hallucinated; bullets are verbatim extractions.
  Already-processed summaries (by hash) are recorded in .processed and skipped.
#>

$ErrorActionPreference = 'Stop'
$NotesDir  = Join-Path $env:USERPROFILE '.codex\memories\extensions\ad_hoc\notes'
$IndexFile = Join-Path $NotesDir '.processed'
$Rollouts  = Join-Path $env:USERPROFILE '.codex\memories\rollout_summaries'

if (-not (Test-Path -LiteralPath $NotesDir)) { New-Item -ItemType Directory -Force -Path $NotesDir | Out-Null }
if (-not (Test-Path -LiteralPath $Rollouts)) { Write-Output 'no rollout_summaries yet'; exit 0 }

$done = @{}
if (Test-Path -LiteralPath $IndexFile) { foreach ($l in Get-Content -LiteralPath $IndexFile) { $done[$l.Trim()] = $true } }

function Get-Slug {
    param([string]$Text)
    $s = $Text -replace '[^a-zA-Z0-9]+', '-'
    $s = $s.Trim('-').ToLower()
    if ($s.Length -gt 60) { $s = $s.Substring(0, 60).Trim('-') }
    if (-not $s) { $s = 'rollout' }
    return $s
}

$created = 0
foreach ($f in (Get-ChildItem -LiteralPath $Rollouts -Filter *.md | Sort-Object LastWriteTime)) {
    $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm MD5).Hash
    $key = $f.Name + ':' + $hash + ':v2'
    # Honour the pre-v2 key too: bumping the key format must not re-curate a
    # summary that was already distilled (that produced a duplicate note batch).
    $legacyKey = $f.Name + ':' + $hash
    if ($done.ContainsKey($key) -or $done.ContainsKey($legacyKey)) { continue }

    $text = Get-Content -LiteralPath $f.FullName -Raw
    $title = ''
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match '^# (.+)$') { $title = $Matches[1]; break }
    }
    if (-not $title) { $title = $f.BaseName }

    # Rollout id for provenance (thread_id line or filename uuid)
    $rolloutId = ''
    if ($text -match 'thread_id:\s*([0-9a-f\-]{36})') { $rolloutId = $Matches[1] }

    $bullets = @()
    # Rollout summaries use colon-terminated section headers (not markdown ##),
    # e.g. "Failures and how to do differently:" followed by bullet lines.
    $term = '(?=^(?:## [^\r\n]*|Outcome:|Preference signals:|Key steps[^\r\n]*:|Failures and how to do differently:|Reusable knowledge:)\s*$|\z)'
    foreach ($section in @('Failures and how to do differently', 'Reusable knowledge')) {
        $pattern = '(?ms)^' + [regex]::Escape($section) + ':\s*\r?\n(.*?)(?:' + $term + ')'
        foreach ($m in [regex]::Matches($text, $pattern)) {
            $body = $m.Groups[1].Value
            $bullets += ($body -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
        }
    }
    $outcome = ''
    if ($text -match '(?m)^Outcome:\s*(.+)$') { $outcome = $Matches[1].Trim() }

    $lines = @()
    $lines += ('Proposed memory update distilled from rollout summary {0}' -f $f.Name)
    $lines += ('    (title: {0})' -f $title)
    if ($outcome) { $lines += ('    (outcome: {0})' -f $outcome) }
    $lines += ''
    if ($rolloutId) {
        $lines += 'Rollout ids to cite:'
        $lines += $rolloutId
        $lines += ''
    }
    if ($bullets.Count -gt 0) {
        $lines += 'Learnings to consider adding:'
        $lines += $bullets
    }
    else {
        $lines += 'No structured learnings found; review the summary manually when relevant.'
    }

    $slug = Get-Slug $title
    $name = '{0}-{1}.md' -f (Get-Date -Format 'yyyyMMddTHHmmss'), $slug
    $dest = Join-Path $NotesDir $name
    $lines | Set-Content -LiteralPath $dest -Encoding UTF8
    Add-Content -LiteralPath $IndexFile -Value $key -Encoding UTF8
    $created++
}

Write-Output ("curated {0} rollout summary(ies) -> {1}" -f $created, $NotesDir)
