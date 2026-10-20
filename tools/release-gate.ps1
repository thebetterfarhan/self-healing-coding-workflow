<#
  release-gate.ps1  -  one command before any release/push of a repo.

  Steps (fail-fast, exit 1 with numbered evidence):
    1. Working tree clean (status --porcelain empty)
    2. No commit between HEAD and upstream (unless -AllowUnpushed)
    3. Secret scan over tracked content (git grep -I patterns from guard-hook)
    4. The repo's gate commands (pass with -GateCommands)
    5. Optional APK/cert check with -Apk (apksigner verify --print-certs)

  Usage:
    .\tools\release-gate.ps1 -Repo ~\Documents\Codex\gitdock -GateCommands "uv run ruff check src tests"
    .\tools\release-gate.ps1 -Repo ~\Documents\Codex\nuviotv -GateCommands ".\gradlew.bat :app:testFullDebugUnitTest" -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    [string[]]$GateCommands = @(),
    [string]$Apk,
    [switch]$AllowUnpushed,
    [switch]$DryRun
)

$script:failures = 0
$script:stepNo = 0
function Step {
    param([string]$Name, [scriptblock]$Body)
    $script:stepNo++
    if ($DryRun) { Write-Output ("DRY  [{0}] {1}" -f $script:stepNo, $Name); return }
    try {
        & $Body
        Write-Output ("[{0}] PASS {1}" -f $script:stepNo, $Name)
    } catch {
        $script:failures++
        Write-Output ("[{0}] FAIL {1} : {2}" -f $script:stepNo, $Name, $_.Exception.Message)
    }
}

$Repo = (Resolve-Path $Repo).Path
if (-not (Test-Path (Join-Path $Repo '.git'))) { throw "'$Repo' is not a git repository root." }

Write-Output "release-gate: $Repo"
Write-Output ("-" * 60)

# 1. Clean tree
Step 'clean working tree' {
    $dirty = git -C $Repo status --porcelain
    if ($dirty) { throw "dirty tree:`n$($dirty | Out-String)" }
}

# 2. Upstream parity
Step 'unpushed commits check' {
    $up = git -C $Repo rev-parse --abbrev-ref '@{upstream}' 2>$null
    if ( -not $up -and -not $AllowUnpushed ) { throw "no upstream tracking branch (use -AllowUnpushed for a local-only release)" }
    if ($up) {
        $ahead = [int]((git -C $Repo rev-list --count "$up..HEAD" 2>$null | Select-Object -First 1))
        if ($ahead -gt 0 -and -not $AllowUnpushed) { throw "$ahead unpushed commit(s) beyond $up" }
    }
}

# 3. Secret scan
Step 'secret scan (tracked content)' {
    $hits = git -C $Repo grep -I -n -E '-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|sk-ant-[A-Za-z0-9-]{20}|xox[bpoa]-[A-Za-z0-9-]{10}|AIza[0-9A-Za-z_-]{35}' -- . 2>$null
    if ($LASTEXITCODE -eq 0) { throw "secret-shaped line(s) in tracked files:`n$($hits | Out-String)" }
}

# 4. Gate commands
if ($GateCommands) {
    foreach ($cmd in $GateCommands) {
        Step "gate command" {
            Push-Location $Repo
            try {
                Invoke-Expression $cmd *>&1 | Out-String | ForEach-Object { if ($_.Trim()) { Write-Output $_ } }
                if ($LASTEXITCODE -ne 0) { throw "'$cmd' exited $LASTEXITCODE" }
            } finally { Pop-Location }
        }
    }
}

# 5. APK signer
if ($Apk) {
    Step 'apksigner verify' {
        $apk = (Resolve-Path $Apk -ErrorAction Stop).Path
        $signer = Join-Path $env:LOCALAPPDATA 'Android\Sdk\build-tools\36.0.0\apksigner.bat'
        if (-not (Test-Path $signer)) { throw "apksigner not found at $signer" }
        $certs = & $signer verify --print-certs $apk
        if ($LASTEXITCODE -ne 0) { throw "apksigner verify failed" }
        Write-Output ($certs | Out-String)
    }
}

Write-Output ("-" * 60)
if ($failures) { Write-Output "release-gate FAILED: $failures check(s)"; exit 1 }
Write-Output 'release-gate PASS'
exit 0
