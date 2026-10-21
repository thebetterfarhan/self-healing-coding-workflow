<#
  agent-route.ps1 — shared, task-based model selection.

  Dot-source this from agent-task.ps1. It defines the
  classification and the model chooser; it performs no work on load.

  Two layers:
    1. Capability tier — a text heuristic on the task string (quick/standard/deep).
    2. Model within the tier — cheapest eligible Command Code model, priced from
       tools/model-prices.json (regenerate with tools/refresh-model-prices.ps1,
       which reads the CLI's own catalog). Cost is blended over a typical request
       (see $CostProfile), so cache-read price matters most, as it does in reality.

  $AgentRouteTable is the static fallback and the source of the Codex ids
  (Codex runs on a subscription, so price does not apply there). It is read
  from workflows/agents.toml, the same file that holds the per-role pins, so
  the two cannot drift apart.

  Notes on this machine:
    - Command Code plan is Go-tier: gpt-6.1-sol / gpt-6-astra / Claude / Gemini
      return 403 MODEL_NOT_IN_PLAN. Plan-restricted models are filtered out.
    - Effort is derived per model from the catalog, because several cheap models
      accept no effort at all (their column is "—").
#>

. (Join-Path $PSScriptRoot 'roster.ps1')

$AgentRouteTable = Get-RosterTierTable -Path (Join-Path $PSScriptRoot '..\workflows\agents.toml')

# --------------------------------------------------------------------------
# Free-model fallback catalog
#
# When a paid model is unavailable (plan-restricted, over the usage window, or
# rejected at run time), the router falls back to a free model instead of
# failing. The list is generated per backend by refresh-free-models.ps1 from
# each tool's own catalog, so it tracks changes without editing code.
# --------------------------------------------------------------------------

$FreeCatalogPath = Join-Path $PSScriptRoot 'free-models.json'

function Get-FreeModels {
    param([Parameter(Mandatory)][string]$Backend)
    if (-not (Test-Path -LiteralPath $FreeCatalogPath)) { return @() }
    try { $doc = Get-Content -LiteralPath $FreeCatalogPath -Raw | ConvertFrom-Json } catch { return @() }
    # A stale catalog is worse than none: it still offers retired models (the
    # Ling retirement). Older than 3 days -> treat as unavailable so the caller
    # reroutes to another backend; the daily self-repair keeps it fresh.
    try {
        if ($doc.generatedAt) {
            $age = ((Get-Date).ToUniversalTime() - ([datetime]$doc.generatedAt.ToUniversalTime())).TotalDays
            if ($age -gt 3) { return @() }
        }
    } catch {}
    if (-not $doc.$Backend) { return @() }
    return @($doc.$Backend)
}

# --------------------------------------------------------------------------
# Route feedback (learning)
#
# agent-task.ps1 records every attempt here with Add-RouteOutcome. Models
# collecting two or more infra failures within a week are demoted for
# selection until one success on that model clears the record. This is what
# turns a wrong route (e.g. a retired free model 404-ing) into a rule instead
# of a repeated accident between catalog refreshes.
# --------------------------------------------------------------------------

$RouteFeedbackPath = Join-Path $PSScriptRoot 'agent-route-feedback.jsonl'
$RouteFailureLimit = 2
$RouteFailureDays  = 7

function Add-RouteOutcome {
    param(
        [Parameter(Mandatory)][string]$Backend,
        [Parameter(Mandatory)][string]$Model,
        [string]$Tier,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$InfraFailure
    )
    try {
        $rec = [ordered]@{
            time         = (Get-Date).ToString('s')
            backend      = $Backend
            model        = $Model
            tier         = $Tier
            exitCode     = $ExitCode
            infraFailure = $InfraFailure
        }
        Add-Content -LiteralPath $RouteFeedbackPath -Value ($rec | ConvertTo-Json -Compress) -Encoding UTF8
    } catch {}
}

function Get-RoutePenalties {
    <#  Models with >= 2 infra failures inside the window. A success clears a
        model's failures, so a flaky day never permanently demotes a good model. #>
    $fail = @{}
    try {
        foreach ($line in (Get-Content -LiteralPath $RouteFeedbackPath -ErrorAction SilentlyContinue)) {
            if (-not $line.Trim()) { continue }
            try { $r = $line | ConvertFrom-Json } catch { continue }
            $t = [datetime]$r.time; if (((Get-Date) - $t).TotalDays -gt $RouteFailureDays) { continue }
            if (-not $r.model) { continue }
            if ($r.exitCode -eq 0) { if ($fail.ContainsKey($r.model)) { $fail.Remove($r.model) } }
            elseif ($r.infraFailure) { $fail[$r.model] = [int]$fail[$r.model] + 1 }
        }
    } catch {}
    return @( $fail.GetEnumerator() | Where-Object { $_.Value -ge $RouteFailureLimit } | ForEach-Object { $_.Key } )
}

function Select-FreeModel {
    <#  First free model for the backend not already tried or penalized, or $null. #>
    param(
        [Parameter(Mandatory)][string]$Backend,
        [string[]]$Exclude = @()
    )
    $penalized = Get-RoutePenalties
    foreach ($id in (Get-FreeModels -Backend $Backend)) {
        if ($Exclude -contains $id) { continue }
        if ($penalized -contains $id) { continue }
        return $id
    }
    return $null
}

$AgentLookupRequest = '(?i)^\s*(explain|summari[sz]e|find|locate|list|show|what|where|check|how|why|which|who|whose|is|are|does|do|did|can|could|will|would|should|may|might)\b'
$AgentSmallEdit     = '(?i)^\s*(fix|change|rename|update|remove|add)\b.*\b(typo|label|wording|text|string|comment|one file|single file|small)\b'
$AgentHighRisk      = '(?i)\b(security|auth(?:entication|orization)?|permission|privacy|accessibility|screen.?reader|migration|architecture|release|deploy|payment|data.?loss|race.?condition|concurren|multi.?agent|multiple repos|cross.?repo|refactor)\b'

# --------------------------------------------------------------------------
# Price-aware selection for the Command Code backend
# --------------------------------------------------------------------------

$PriceCatalogPath = Join-Path $PSScriptRoot 'model-prices.json'

# Per-request token profile used to compare models. Cache reads dominate a real
# session (every turn re-reads context), so they carry the most weight. This
# matches the "typical request" the Command Code pricing page quotes.
$CostProfile = @{ Input = 800; Output = 160; CacheRead = 50000 }

$PlanRank = @{ go = 1; goat = 2; pro = 3; max = 4 }

# Candidate models per capability tier. Capability is a human judgement; the
# picker only decides price among these. Cheapest eligible wins.
$TierCandidates = [ordered]@{
    quick = @(
        'poolside/laguna-s-2.1-free',
        'stealth/cat-jam:free',
        'meta/muse-spark-1.3-contributor',
        'xiaomi/mimo-v2.5',
        'qwen/qwen3.7-flash',
        'qwen/qwen3.8-flash',
        'deepseek/deepseek-v4-flash',
        'deepseek/deepseek-v4.1-flash',
        'z-ai/glm-5.3-flash'
    )
    standard = @(
        'deepseek/deepseek-v4-pro',
        'minimaxai/minimax-m3',
        'moonshotai/kimi-k2.7-code',
        'zai-org/glm-5.3',
        'xai/grok-4.5'
    )
    deep = @(
        'moonshotai/kimi-k3',
        'qwen/qwen3.8-max',
        'zai-org/glm-5.3',
        'minimaxai/minimax-m3',
        'xai/grok-4.5',
        'deepseek/deepseek-v4-pro'
    )
}

# Upstreams that may train on your prompts (from the pricing page). Excluded by
# default so cheap never means careless. Substring match so a provider prefix
# (stealth/glyph-cluster:free) is still excluded.
$TrainingModels = @('glyph-cluster:free')

function Test-TrainingModel {
    param([string]$Id)
    foreach ($t in $TrainingModels) { if ($Id -like "*$t*") { return $true } }
    return $false
}

function Get-PriceCatalog {
    if (-not (Test-Path -LiteralPath $PriceCatalogPath)) { return $null }
    try { return (Get-Content -LiteralPath $PriceCatalogPath -Raw | ConvertFrom-Json).models }
    catch { return $null }
}

function Test-PlanEligible {
    param([string]$MinPlan, [string]$MaxPlan = 'go')
    if (-not $MinPlan) { return $true }
    $m = $MinPlan.ToLower()
    $need = 4
    if ($m -match 'goat') { $need = 2 }
    elseif ($m -match '\bpro\b') { $need = 3 }
    elseif ($m -match '\bmax\b') { $need = 4 }
    elseif ($m -match '\bgo\b') { $need = 1 }
    return ($need -le [int]$PlanRank[$MaxPlan])
}

function Test-DeepSeekPeak {
    param([datetime]$Now = (Get-Date).ToUniversalTime())
    if ($Now.DayOfWeek -eq 'Saturday' -or $Now.DayOfWeek -eq 'Sunday') { return $false }
    $h = $Now.Hour
    return (($h -ge 1 -and $h -lt 4) -or ($h -ge 6 -and $h -lt 10))
}

function Get-ModelCost {
    param($Entry, [switch]$Peak)
    $i = [double]$Entry.input; $o = [double]$Entry.output; $c = [double]$Entry.cacheRead
    if ($Peak -and $Entry.peak) { $i = [double]$Entry.peak.input; $o = [double]$Entry.peak.output }
    return ($CostProfile.Input * $i + $CostProfile.Output * $o + $CostProfile.CacheRead * $c) / 1000000
}

function Resolve-Effort {
    <#  Returns the best effort the model actually accepts, or $null to omit. #>
    param($Entry, [string[]]$Preferred = @('high', 'medium', 'low'))
    if (-not $Entry -or -not $Entry.efforts) { return $null }
    $list = @($Entry.efforts -split ',' | ForEach-Object { $_.Trim().ToLower() })
    foreach ($want in $Preferred) { if ($list -contains $want) { return $want } }
    return $null
}

# --------------------------------------------------------------------------
# Usage state
#
# Command Code credits CANNOT be read headlessly: /usage is interactive-only and
# the docs say the plan is not readable from disk. The only automatic signal is
# the CLI's own limit message, so when a run hits one its reset time is recorded
# here and paid models are withheld until it passes. Read the live number with
# /usage in a session, or https://commandcode.ai/usage.
# --------------------------------------------------------------------------

$UsageStatePath = Join-Path $PSScriptRoot 'agent-usage.json'

# Provider credit/limit errors. Some CLIs abort the run on these and still exit
# 0 (Command Code v1.84.0 exits 0 after "Insufficient credits for Command
# Code."), so the exit code alone reports a success that never ran the task.
$CreditFailurePattern = '(?i)(Insufficient credits for Command Code|insufficient credits to make this request|hit your usage limit)'

function Test-CreditFailure {
    <#  True when the tail of a run's output carries a provider credit/limit
        error. Only the tail is read: a long transcript may mention credits in
        passing, but a provider error lands at the end of the output. #>
    param([string]$OutFile)
    if (-not $OutFile -or -not (Test-Path -LiteralPath $OutFile)) { return $false }
    $text = Get-Content -LiteralPath $OutFile -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return $false }
    if ($text.Length -gt 1500) { $text = $text.Substring($text.Length - 1500) }
    return [bool]($text -match $CreditFailurePattern)
}

function Resolve-RunExit {
    <#  The exit code a run really had. A provider credit/limit error with exit
        code 0 is a failure: the task never ran. #>
    param([int]$ExitCode, [string]$OutFile)
    if ($ExitCode -eq 0 -and (Test-CreditFailure -OutFile $OutFile)) { return 1 }
    return $ExitCode
}

function Get-UsageState {
    if (-not (Test-Path -LiteralPath $UsageStatePath)) { return $null }
    try { return (Get-Content -LiteralPath $UsageStatePath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Test-CommandCodeCoolingDown {
    $s = Get-UsageState
    if (-not $s -or -not $s.commandcode -or -not $s.commandcode.cooldownUntil) { return $false }
    try { return ([datetime]$s.commandcode.cooldownUntil) -gt (Get-Date) } catch { return $false }
}

function Set-CommandCodeCooldown {
    param([int]$Minutes, [string]$Reason = 'usage limit')
    $state = @{}
    $existing = Get-UsageState
    if ($existing) { foreach ($p in $existing.PSObject.Properties) { $state[$p.Name] = $p.Value } }
    $state['commandcode'] = @{
        cooldownUntil = (Get-Date).AddMinutes([Math]::Max(1, $Minutes)).ToString('s')
        reason        = $Reason
        recordedAt    = (Get-Date).ToString('s')
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $UsageStatePath -Encoding UTF8
}

function Clear-CommandCodeCooldown {
    $existing = Get-UsageState
    if (-not $existing) { return }
    $state = @{}
    foreach ($p in $existing.PSObject.Properties) { if ($p.Name -ne 'commandcode') { $state[$p.Name] = $p.Value } }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $UsageStatePath -Encoding UTF8
}

# OpenCode has its own usage window; the same cooldown pattern applies so a run
# that hits it drops to a free model instead of failing.

function Test-OpenCodeCoolingDown {
    $s = Get-UsageState
    if (-not $s -or -not $s.opencode -or -not $s.opencode.cooldownUntil) { return $false }
    try { return ([datetime]$s.opencode.cooldownUntil) -gt (Get-Date) } catch { return $false }
}

function Set-OpenCodeCooldown {
    param([int]$Minutes, [string]$Reason = 'usage limit')
    $state = @{}
    $existing = Get-UsageState
    if ($existing) { foreach ($p in $existing.PSObject.Properties) { $state[$p.Name] = $p.Value } }
    $state['opencode'] = @{
        cooldownUntil = (Get-Date).AddMinutes([Math]::Max(1, $Minutes)).ToString('s')
        reason        = $Reason
        recordedAt    = (Get-Date).ToString('s')
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $UsageStatePath -Encoding UTF8
}

function Clear-OpenCodeCooldown {
    $existing = Get-UsageState
    if (-not $existing) { return }
    $state = @{}
    foreach ($p in $existing.PSObject.Properties) { if ($p.Name -ne 'opencode') { $state[$p.Name] = $p.Value } }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $UsageStatePath -Encoding UTF8
}

# ==========================================================================
# Backend health (auto-skip dead backends)
# Tracks which backends have failed recently so the router can skip them
# instead of trying-and-failing every run. A backend that fails is marked
# unhealthy for $BackendUnhealthyMinutes; a success clears it. This is what
# makes `work` fully automatic: if Codex and Command Code are both out of
# credits, the router goes straight to OpenCode without wasting a turn.
# ==========================================================================

$BackendHealthPath       = Join-Path $PSScriptRoot 'agent-backend-health.json'
$BackendUnhealthyMinutes = 30

function Get-BackendHealth {
    if (-not (Test-Path -LiteralPath $BackendHealthPath)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $BackendHealthPath -Raw | ConvertFrom-Json
        $h = @{}
        if ($raw) {
            foreach ($p in $raw.PSObject.Properties) {
                if ($p.Name -in @('IsFixedSize','IsSynchronized','IsReadOnly','Count','Keys','Values','SyncRoot')) { continue }
                $h[$p.Name] = $p.Value
            }
        }
        return $h
    } catch { return @{} }
}

function Test-BackendHealthy {
    param([Parameter(Mandatory)][string]$Backend)
    $h = Get-BackendHealth
    if (-not $h.$Backend) { return $true }
    try {
        $until = [datetime]$h.$Backend.unhealthyUntil
        if ($until -gt (Get-Date)) { return $false }
    } catch {}
    return $true
}

function Test-PaidExhausted {
    param([Parameter(Mandatory)][string]$Backend)
    $h = Get-BackendHealth
    if (-not $h.$Backend) { return $false }
    if (-not $h.$Backend.paidExhausted) { return $false }
    try {
        $until = [datetime]$h.$Backend.paidExhaustedUntil
        if ($until -gt (Get-Date)) { return $true }
    } catch {}
    return $false
}

function Set-PaidExhausted {
    param([Parameter(Mandatory)][string]$Backend, [int]$Minutes = 120, [string]$Reason = 'insufficient credits')
    $h = Get-BackendHealth
    if (-not $h.$Backend) { $h[$Backend] = @{} }
    # The health file round-trips through JSON, so an existing entry comes back
    # as a PSCustomObject: dot-assigning a property it does not have yet fails.
    # Copy it to a hashtable first.
    if ($h[$Backend] -isnot [hashtable]) {
        $t = @{}
        foreach ($p in $h[$Backend].PSObject.Properties) { $t[$p.Name] = $p.Value }
        $h[$Backend] = $t
    }
    # Preserve existing unhealthy status
    $existingUnhealthy = if ($h.$Backend.unhealthyUntil) { $h[$Backend].unhealthyUntil } else { $null }
    $existingReason = if ($h.$Backend.reason) { $h[$Backend].reason } else { $null }
    $existingRecorded = if ($h.$Backend.recordedAt) { $h[$Backend].recordedAt } else { $null }
    $h[$Backend].paidExhausted = $true
    $h[$Backend].paidExhaustedUntil = (Get-Date).AddMinutes([Math]::Max(1, $Minutes)).ToString('s')
    $h[$Backend].paidExhaustedReason = $Reason
    $h[$Backend].paidExhaustedAt = (Get-Date).ToString('s')
    if ($existingUnhealthy) { $h[$Backend].unhealthyUntil = $existingUnhealthy }
    if ($existingReason) { $h[$Backend].reason = $existingReason }
    if ($existingRecorded) { $h[$Backend].recordedAt = $existingRecorded }
    $obj = [pscustomobject]@{}
    foreach ($k in $h.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $h[$k] -Force }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BackendHealthPath -Encoding UTF8
}

function Clear-PaidExhausted {
    param([Parameter(Mandatory)][string]$Backend)
    $h = Get-BackendHealth
    if ($h.$Backend) {
        $h[$Backend].paidExhausted = $false
        $h[$Backend].paidExhaustedUntil = $null
    }
    $obj = [pscustomobject]@{}
    foreach ($k in $h.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $h[$k] -Force }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BackendHealthPath -Encoding UTF8
}

function Set-BackendUnhealthy {
    param([Parameter(Mandatory)][string]$Backend, [int]$Minutes = $BackendUnhealthyMinutes, [string]$Reason = 'failure')
    $h = Get-BackendHealth
    $existingPaidExhausted = if ($h.$Backend) { $h[$Backend].paidExhausted } else { $false }
    $existingPaidUntil = if ($h.$Backend) { $h[$Backend].paidExhaustedUntil } else { $null }
    $existingPaidReason = if ($h.$Backend) { $h[$Backend].paidExhaustedReason } else { $null }
    $h[$Backend] = @{
        unhealthyUntil = (Get-Date).AddMinutes([Math]::Max(1, $Minutes)).ToString('s')
        reason         = $Reason
        recordedAt     = (Get-Date).ToString('s')
        paidExhausted  = $existingPaidExhausted
        paidExhaustedUntil = $existingPaidUntil
        paidExhaustedReason = $existingPaidReason
    }
    $obj = [pscustomobject]@{}
    foreach ($k in $h.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $h[$k] -Force }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BackendHealthPath -Encoding UTF8
}

function Clear-BackendUnhealthy {
    param([Parameter(Mandatory)][string]$Backend)
    $h = Get-BackendHealth
    if (-not $h[$Backend]) { return }
    $be = $h[$Backend]
    # A success on a free model does not mean the paid credits came back, so
    # the paid-exhausted flags stay until their own expiry.
    if ($be.paidExhausted) {
        $h[$Backend] = [pscustomobject]@{
            paidExhausted       = $true
            paidExhaustedUntil  = $be.paidExhaustedUntil
            paidExhaustedReason = $be.paidExhaustedReason
            paidExhaustedAt     = $be.paidExhaustedAt
        }
    } else {
        $h.Remove($Backend)
    }
    $obj = [pscustomobject]@{}
    foreach ($k in $h.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $h[$k] -Force }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BackendHealthPath -Encoding UTF8
}

function Get-BackendRanking {
    <#  Rank backends by recent success rate (from agent-route-feedback.jsonl).
        Returns an array of backend names, best first. Falls back to the
        static preference order if there is no data. #>
    param(
        [int]$Days = 7,
        [switch]$PaidFirst  # prefer paid backends for quality (standard/deep)
    )
    $stats = @{}
    $cutoff = (Get-Date).AddDays(-$Days)
    try {
        foreach ($line in (Get-Content -LiteralPath $RouteFeedbackPath -ErrorAction SilentlyContinue)) {
            if (-not $line.Trim()) { continue }
            try { $r = $line | ConvertFrom-Json } catch { continue }
            try { $t = [datetime]$r.time } catch { continue }
            if ($t -lt $cutoff) { continue }
            $b = $r.backend
            if (-not $b) { continue }
            if (-not $stats.ContainsKey($b)) { $stats[$b] = @{ success = 0; total = 0 } }
            $stats[$b].total++
            if ($r.exitCode -eq 0) { $stats[$b].success++ }
        }
    } catch {}

    $backends = @('codex', 'commandcode', 'opencode')
    # Filter to healthy only
    $healthy = @($backends | Where-Object { Test-BackendHealthy -Backend $_ })
    if ($healthy.Count -eq 0) { $healthy = $backends }

    # Score each backend: success rate + small bonus for paid (quality) on non-quick
    $scored = @()
    foreach ($b in $healthy) {
        $s = if ($stats.ContainsKey($b)) { $stats[$b] } else { @{ success = 0; total = 0 } }
        $rate = if ($s.total -gt 0) { [double]$s.success / [double]$s.total } else { 0.5 }
        # Paid bonus: codex and commandcode are paid; opencode is free-only
        $paidBonus = if ($PaidFirst -and $b -in @('codex', 'commandcode')) { 0.15 } else { 0 }
        $score = $rate + $paidBonus
        $scored += [pscustomobject]@{ Backend = $b; Score = $score; Success = $s.success; Total = $s.total }
    }

    # Sort by score descending; ties broken by static preference order
    $prefOrder = @{ codex = 0; commandcode = 1; opencode = 2 }
    $sorted = $scored | Sort-Object -Property @{ Expression = { -($_.Score) } }, @{ Expression = { $prefOrder[$_.Backend] } }
    return ,@($sorted | ForEach-Object { $_.Backend })
}

function Get-AutoBackend {
    <#  Pick the best backend for auto-selection using learned rankings.
        Falls back to static preference if no data. #>
    param([switch]$ReadOnly, [string]$Complexity = 'standard')
    $paidFirst = -not ($ReadOnly -or $Complexity -eq 'quick')
    $ranked = Get-BackendRanking -PaidFirst:$paidFirst
    # Ensure array (single-element results can unwrap to a string)
    if ($ranked -is [string]) { $ranked = @($ranked) }
    if ($ranked.Count -eq 0) {
        $ranked = if ($ReadOnly -or $Complexity -eq 'quick') { @('commandcode', 'codex', 'opencode') } else { @('codex', 'commandcode', 'opencode') }
    }
    # Print ranking summary for transparency
    $rankingStr = ($ranked | ForEach-Object {
        $h = if (Test-BackendHealthy -Backend $_) { 'ok' } else { 'DEAD' }
        "{0}({1})" -f $_, $h
    }) -join ' > '
    Write-Host ("  (backend ranking: {0})" -f $rankingStr)
    return $ranked[0]
}

function Select-CheapModel {
    <#  Cheapest eligible model for the tier, or $null if none is eligible. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('quick', 'standard', 'deep')][string]$Tier,
        [string]$MaxPlan = 'go',
        [switch]$IncludeFree,      # allow free models (they win on price for the quick tier)
        [switch]$IncludeTraining,
        [switch]$NoFreeFallback    # do not fall back to a free model when no paid model fits
    )
    $catalog = Get-PriceCatalog
    if (-not $catalog) { return $null }

    $peak = Test-DeepSeekPeak
    $coolingDown = Test-CommandCodeCoolingDown
    $penalized = Get-RoutePenalties
    $best = $null; $bestCost = [double]::MaxValue
    foreach ($id in $TierCandidates[$Tier]) {
        $e = $catalog.$id
        if (-not $e) { continue }
        if (-not $IncludeTraining -and (Test-TrainingModel $id)) { continue }
        if ($penalized -contains $id) { continue }

        $isFree = [bool]$e.free
        # Free models are normally only for the quick tier. When every paid
        # backend is dead OR this backend's paid credits are exhausted, free
        # is all we have, so they become eligible for standard/deep too.
        $paidDead = (-not (Test-BackendHealthy -Backend 'codex')) -and (-not (Test-BackendHealthy -Backend 'commandcode'))
        $thisPaidExhausted = Test-PaidExhausted -Backend 'commandcode'
        $allowFreeAllTiers = $paidDead -or $thisPaidExhausted
        if ($isFree -and $Tier -ne 'quick' -and -not $allowFreeAllTiers) { continue }
        if ($isFree -and -not $IncludeFree -and -not $allowFreeAllTiers) { continue }
        # Skip paid models when this backend's paid credits are exhausted
        if (-not $isFree -and $thisPaidExhausted) { continue }
        # While the 5-hour window is exhausted, paid models are withheld.
        if ($coolingDown -and -not $isFree) { continue }

        if (-not (Test-PlanEligible -MinPlan $e.minPlan -MaxPlan $MaxPlan)) { continue }
        $cost = Get-ModelCost -Entry $e -Peak:$peak
        if ($cost -lt $bestCost) { $bestCost = $cost; $best = $id }
    }
    # Paid-first: if no paid model is eligible (over the usage window, or every
    # candidate is plan-restricted), fall back to a free model rather than
    # failing. This is the only path that lets standard/deep run free.
    if (-not $best -and $IncludeFree -and -not $NoFreeFallback) {
        $free = Select-FreeModel -Backend 'commandcode'
        if ($free) {
            return [pscustomobject]@{
                Id     = $free
                Cost   = 0
                Effort = Resolve-Effort -Entry $catalog.$free
                Peak   = $peak
                Free   = $true
            }
        }
    }
    if (-not $best) { return $null }
    [pscustomobject]@{
        Id     = $best
        Cost   = $bestCost
        Effort = Resolve-Effort -Entry $catalog.$best
        Peak   = $peak
        Free   = [bool]$catalog.$best.free
    }
}

function Get-TaskTier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Task,
        [ValidateSet('auto', 'quick', 'standard', 'deep')][string]$Complexity = 'auto'
    )
    if ($Complexity -ne 'auto') { return $Complexity }
    if ($Task -match $AgentHighRisk) { return 'deep' }
    # Adaptive thresholds (from tier-adapt.ps1)
    $maxQuick = 180
    $thresholdPath = Join-Path $PSScriptRoot 'agent-tier-thresholds.json'
    if (Test-Path -LiteralPath $thresholdPath) {
        try { $t = Get-Content -LiteralPath $thresholdPath -Raw | ConvertFrom-Json; if ($t.maxQuickLength) { $maxQuick = [int]$t.maxQuickLength } } catch {}
    }
    if ($Task.Length -le $maxQuick -and ($Task -match $AgentLookupRequest -or $Task -match $AgentSmallEdit)) { return 'quick' }
    return 'standard'
}

function Get-AgentRoute {
    <#  Returns { Tier, Backend, Model, Effort, Cost, Priced }. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Task,
        [ValidateSet('auto', 'quick', 'standard', 'deep')][string]$Complexity = 'auto',
        [Parameter(Mandatory)][ValidateSet('codex', 'commandcode', 'opencode')][string]$Backend,
        [switch]$Static,      # use the hand-picked table, not the price picker
        [switch]$NoFree       # exclude free models (no fallback)
    )
    $tier  = Get-TaskTier -Task $Task -Complexity $Complexity
    $entry = $AgentRouteTable[$tier][$Backend]
    $model = $entry.Model
    $effort = $entry.Effort
    $cost = $null
    $priced = $false

    if ($Backend -eq 'commandcode' -and -not $Static) {
        $paidDead = (-not (Test-BackendHealthy -Backend 'codex')) -and (-not (Test-BackendHealthy -Backend 'commandcode'))
        $includeFree = if ($paidDead) { $true } else { (-not $NoFree) }
        $pick = Select-CheapModel -Tier $tier -IncludeFree:$includeFree -NoFreeFallback:$NoFree
        if ($pick) {
            $model  = $pick.Id
            $effort = $pick.Effort
            $cost   = $pick.Cost
            $priced = $true
        } elseif (Test-CommandCodeCoolingDown) {
            # 5-hour window exhausted and no free model was available to fall
            # back to: report "no model" and let the caller reroute.
            $model  = $null
            $effort = $null
        } elseif (Test-PaidExhausted -Backend 'commandcode') {
            # Paid credits are gone. The free models are not in the standard/deep
            # candidate lists, so the picker had nothing to return and the static
            # paid model would be used and fail. Take a free model instead.
            $free = Select-FreeModel -Backend 'commandcode'
            if ($free) { $model = $free; $effort = $null; $priced = $true }
        }
    }

    if ($Backend -eq 'opencode' -and -not $NoFree) {
        $paidDead = (-not (Test-BackendHealthy -Backend 'codex')) -and (-not (Test-BackendHealthy -Backend 'commandcode'))
        if ($paidDead -or (Test-OpenCodeCoolingDown)) {
            # All paid backends dead, or OpenCode's own window exhausted:
            # choose the free fallback up front.
            $free = Select-FreeModel -Backend 'opencode'
            if ($free) { $model = $free; $effort = $null; $priced = $true }
        }
    }

    [pscustomobject]@{
        Tier    = $tier
        Backend = $Backend
        Model   = $model
        Effort  = $effort
        Cost    = $cost
        Priced  = $priced
    }
}
