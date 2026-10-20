<#
  agent-usage.ps1 — where your usage actually lives, and what the router does
  about it.

  Command Code credits CANNOT be read headlessly (the docs say the plan is not
  readable from disk, and /usage is interactive-only). So this reports:
    - the exact places to read the live number (interactive /usage, usage page)
    - the router's Command Code and OpenCode cooldowns, recorded automatically
      when a run hits the 5-hour limit (see agent-route.ps1 / agent-task.ps1)
    - OpenCode spend, read live from its local SQLite DB

  Usage:
    .\agent-usage.ps1              # report
    .\agent-usage.ps1 -Refresh     # no-op (cooldowns self-update)
    .\agent-usage.ps1 -ClearCooldown
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Refresh,
    [switch]$ClearCooldown,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agent-route.ps1')

$OpenCodeDb = Join-Path $HOME '.local\share\opencode\opencode.db'

function Get-OpenCodeCosts {
    <#  Real spend recorded by OpenCode in its local DB (SQLite). #>
    param([string]$TotalsSql)
    if (-not (Test-Path -LiteralPath $OpenCodeDb -ErrorAction SilentlyContinue)) { return $null }
    if (-not (Get-Command sqlite3 -ErrorAction SilentlyContinue)) { return $null }
    try { $row = (sqlite3 -readonly $OpenCodeDb $TotalsSql | Out-String).Trim() } catch { return $null }
    if (-not $row) { return $null }
    try { $v = @($row -split '\|') } catch { return $null }
    if ($v.Count -lt 6) { return $null }

    $windows = @{
        d24 = "((strftime('%s','now') - 86400) * 1000)"
        d7  = "((strftime('%s','now') - 604800) * 1000)"
    }
    $recent = @{}
    foreach ($k in @('d24', 'd7')) {
        $sql = "SELECT COUNT(*), ROUND(COALESCE(SUM(json_extract(data,'`$.cost')),0),4) FROM message WHERE json_extract(data,'`$.role')='assistant' AND time_created >= {0};" -f $windows[$k]
        $r = @((sqlite3 -readonly $OpenCodeDb $sql) -split '\|')
        $recent[$k] = @{ requests = [int]$r[0]; cost = [double]$r[1] }
    }
    $models = @(& sqlite3 -readonly $OpenCodeDb "SELECT json_extract(data,'`$.modelID'), COUNT(*), ROUND(SUM(json_extract(data,'`$.cost')),4) FROM message WHERE json_extract(data,'`$.role')='assistant' GROUP BY 1 ORDER BY 3 DESC LIMIT 10;" | ForEach-Object {
        $m = ($_ -split '\|'); [pscustomobject]@{ model = $m[0]; requests = [int]$m[1]; cost = [double]$m[2] }
    })
    [ordered]@{
        db           = $OpenCodeDb
        span         = @{ from = $v[0]; to = $v[1] }
        requests     = [int64]$v[2]
        inputTokens  = [int64]$v[3]
        outputTokens = [int64]$v[4]
        total        = [double]$v[5]
        last24h      = $recent.d24
        last7d       = $recent.d7
        topModels    = $models
        checkedAt    = (Get-Date).ToString('s')
    }
}

# one row: span, requests, input, output, cost
$CostTotalsSql = @"
SELECT datetime(MIN(time_created)/1000,'unixepoch'), datetime(MAX(time_created)/1000,'unixepoch'), COUNT(*),
       COALESCE(SUM(json_extract(data,'`$.tokens.input')) + SUM(json_extract(data,'`$.tokens.cache.read')),0),
       COALESCE(SUM(json_extract(data,'`$.tokens.output')),0),
       ROUND(COALESCE(SUM(json_extract(data,'`$.cost')),0),4)
FROM message WHERE json_extract(data,'`$.role')='assistant';
"@


if ($ClearCooldown) {
    Clear-CommandCodeCooldown
    Clear-OpenCodeCooldown
    Write-Host 'Command Code and OpenCode cooldowns cleared.'
    return
}

if ($Refresh) {
    Write-Host 'Nothing to refresh: cooldowns update automatically from run results; OpenCode spend is read live from its DB.'
}

$state     = Get-UsageState
$cooling   = Test-CommandCodeCoolingDown
$cooldown  = if ($state -and $state.commandcode) { $state.commandcode } else { $null }
$opCooling = Test-OpenCodeCoolingDown
$opCool    = if ($state -and $state.opencode) { $state.opencode } else { $null }
$opCosts   = Get-OpenCodeCosts -TotalsSql $CostTotalsSql

if ($Json) {
    [pscustomobject]@{
        commandCode = [pscustomobject]@{
            readableHeadlessly = $false
            coolingDown        = $cooling
            cooldownUntil      = if ($cooldown) { $cooldown.cooldownUntil } else { $null }
            reason             = if ($cooldown) { $cooldown.reason } else { $null }
            liveUsage          = '/usage in a session, or https://commandcode.ai/usage'
        }
        opencode = [pscustomobject]@{
            coolingDown   = $opCooling
            cooldownUntil = if ($opCool) { $opCool.cooldownUntil } else { $null }
            reason        = if ($opCool) { $opCool.reason } else { $null }
            costs         = $opCosts
        }
    } | ConvertTo-Json -Depth 6
    return
}

Write-Host ''
Write-Host 'Command Code usage'
Write-Host '  Credits and the 5-hour / weekly meters are not readable headlessly.'
Write-Host '  Read them with    : /usage  (in an interactive session)'
Write-Host '  Or on the page    : https://commandcode.ai/usage'
if ($cooling) {
    Write-Host "  Router cooldown   : ACTIVE until $($cooldown.cooldownUntil) ($($cooldown.reason))"
    Write-Host '                      -> paid Command Code models are withheld; the router selects a free model,'
    Write-Host '                         and reroutes to another backend only if no free model fits.'
} else {
    Write-Host '  Router cooldown   : none recorded'
}
Write-Host ''
Write-Host 'OpenCode usage'
if ($opCooling) {
    Write-Host "  Router cooldown   : ACTIVE until $($opCool.cooldownUntil) ($($opCool.reason))"
    Write-Host '                      -> the router selects a free OpenCode model.'
} else {
    Write-Host '  Router cooldown   : none recorded'
}
Write-Host ''
Write-Host 'OpenCode (DB-selectable) spend'
if ($opCosts) {
    Write-Host ("  Span      : {0} -> {1}" -f $opCosts.span.from, $opCosts.span.to)
    Write-Host ("  Total     : {0} assistant requests, {1:N4} USD ({2:N0} in / {3:N0} out tokens)" -f
        $opCosts.requests, $opCosts.total, $opCosts.inputTokens, $opCosts.outputTokens)
    Write-Host ("  Last 24h  : {0} requests, {1:N4} USD" -f $opCosts.last24h.requests, $opCosts.last24h.cost)
    Write-Host ("  Last 7d   : {0} requests, {1:N4} USD" -f $opCosts.last7d.requests, $opCosts.last7d.cost)
    $big = $opCosts.topModels | Select-Object -First 5
    foreach ($m in $big) {
        Write-Host ("  top model : {0,-28} {1,5} req   {2:N4} USD" -f $m.model, $m.requests, $m.cost)
    }
} else {
    Write-Host '  Not available (no opencode.db or sqlite3 not on PATH).'
}
Write-Host ''

Write-Host 'Model rule in force (agent-route.ps1)'
Write-Host '  quick tier   : cheapest eligible model, which may be a free one'
Write-Host '  standard/deep: cheapest eligible paid model'
Write-Host '  free model   : only for quick, or as a fallback when no paid model is'
Write-Host '                 available (over the usage window, plan-restricted, or rejected),'
Write-Host '                 never from an upstream that may train on your prompts'
Write-Host '  fallback     : paid -> free model on the same backend -> other backend'
Write-Host ''

exit 0
