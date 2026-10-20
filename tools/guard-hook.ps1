<#
  guard-hook.ps1  -  deterministic PreToolUse gate for Codex hooks.

  Contract (https://developers.openai.com/codex/hooks): Codex calls the hook
  with a JSON object on stdin. PreToolUse fires for `Bash` and `apply_patch`.
  Fields used here: tool_name, tool_input.command (the patch text).

  Guards:
    1. Protected paths - deny `apply_patch` touches of signing/SDK/local files.
    2. Secret scanning - deny patches whose added lines contain key material.

  Deny shape (stdout JSON):
    {"hookSpecificOutput":{"hookEventName":"PreToolUse",
      "permissionDecision":"deny","permissionDecisionReason":"..."}}

  Any other outcome: exit 0 with no output (allow, silent).

  Self-test: run with -SelfTest; feeds itself synthetic payloads
  (deny case + allow case) and asserts the outcomes, exit 1 on fail.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ProtectedPathPatterns = @(
    '\.keystore$', '\.jks$', 'keystore\.properties$', 'local\.properties$',
    '\.pem$', '\.key$', '\.env[^/]*$'
)

$SecretPatterns = @(
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    'AKIA[0-9A-Z]{16}',
    'ghp_[A-Za-z0-9]{20,}',
    'github_pat_[A-Za-z0-9_]{20,}',
    'sk-ant-[A-Za-z0-9-]{20,}',
    'xox[bpoa]-[A-Za-z0-9-]{10,}',
    'AIza[0-9A-Za-z_-]{35}'
)

function Test-TouchedPath {
    param([Parameter(Mandatory)][string]$Text)
    $paths = @()
    foreach ($line in ($Text -split "`n")) {
        if ($line -match '^\*\*\* (Add|Update|Delete) File: (.+)$') {
            $paths += $Matches[2].Trim()
        }
    }
    return , $paths
}

function Get-DenyReason {
    param([Parameter(Mandatory)][string]$PatchText)
    foreach ($path in (Test-TouchedPath $PatchText)) {
        foreach ($pattern in $ProtectedPathPatterns) {
            if ($path -match $pattern) {
                return "Protected file '$path' - guard-hook blocks patches matching $pattern. Move secrets out of band or ask the user to make this change by hand."
            }
        }
    }
    $added = @($PatchText -split "`r?`n" | Where-Object { $_.StartsWith('+') -and -not $_.StartsWith('+++') })
    foreach ($line in $added) {
        foreach ($pattern in $SecretPatterns) {
            if ($line -match $pattern) {
                $preview = if ($line.Length -gt 60) { $line.Substring(0, 60) + '...' } else { $line }
                return "Secret-shaped line detected in patch: '$preview' - guard-hook blocks applying it."
            }
        }
    }
    return $null
}

function Invoke-GuardHook {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$StdinJson)
    if (-not $StdinJson.Trim()) { return @{ Exit = 0; Output = '' } }
    try { $data = $StdinJson | ConvertFrom-Json } catch { return @{ Exit = 0; Output = '' } }
    if ($data.tool_name -ne 'apply_patch') { return @{ Exit = 0; Output = '' } }
    $command = [string]$data.tool_input.command
    if (-not $command) { return @{ Exit = 0; Output = '' } }
    $reason = Get-DenyReason $command
    if ($reason) {
        $out = [ordered]@{
            hookSpecificOutput = [ordered]@{
                hookEventName = 'PreToolUse'
                permissionDecision = 'deny'
                permissionDecisionReason = $reason
            }
        } | ConvertTo-Json -Depth 5 -Compress
        return @{ Exit = 0; Output = $out }   # deny is signalled in JSON; exit stays 0 per the docs
    }
    return @{ Exit = 0; Output = '' }
}

if ($SelfTest) {
    $deny = @{ tool_name = 'apply_patch'; tool_input = @{ command = "*** Begin Patch`n*** Add File: app/keystore.properties`n+storePassword=guesswhat`n*** End Patch" } } | ConvertTo-Json -Compress
    $secret = @{ tool_name = 'apply_patch'; tool_input = @{ command = "*** Begin Patch`n*** Update File: src/config.py`n+api_key = sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234`n*** End Patch" } } | ConvertTo-Json -Compress
    $clean = @{ tool_name = 'apply_patch'; tool_input = @{ command = "*** Begin Patch`n*** Update File: src/util.py`n+return n * 2`n*** End Patch" } } | ConvertTo-Json -Compress
    $bash = @{ tool_name = 'Bash'; tool_input = @{ command = 'rm -rf .git' } } | ConvertTo-Json -Compress

    $d = Invoke-GuardHook $deny
    if ($d.Output -notmatch '"permissionDecision"\s*:\s*"deny"') { Write-Error 'self-test failed: protected path not denied'; exit 1 }
    if ($d.Output -notmatch 'keystore\.properties') { Write-Error 'self-test failed: deny reason missing path'; exit 1 }
    $s = Invoke-GuardHook $secret
    if ($s.Output -notmatch '"permissionDecision"\s*:\s*"deny"') { Write-Error 'self-test failed: secret not denied'; exit 1 }
    $c = Invoke-GuardHook $clean
    if ($c.Output -ne '') { Write-Error 'self-test failed: clean patch denied'; exit 1 }
    $b = Invoke-GuardHook $bash
    if ($b.Output -ne '') { Write-Error 'self-test failed: non-patch tool denied'; exit 1 }
    Write-Output 'self-test: 5/5 pass (protected path denied, secret denied, clean allowed, Bash untouched, deny carries path)'
    exit 0
}

$stdinText = [Console]::In.ReadToEnd()
$result = Invoke-GuardHook $stdinText
if ($result.Output) { Write-Output $result.Output }
exit $result.Exit
