#Requires -Version 5.1
<#
.SYNOPSIS
  Scaffold a project AGENTS.md with an inner loop and a completion gate.

.DESCRIPTION
  The global policy says to write both commands - the inner loop and the gate -
  into the project's AGENTS.md so the next session does not rediscover the
  trap. This script does the mechanical half of that: it detects the build
  system, proposes the two commands, and writes them in the house format.

  Detection is evidence-based:
    - the build manifest picks the ecosystem
    - a CI workflow, when present, is treated as the authority for the gate
    - the test directory name picks the test path

  Commands it cannot verify are marked as such. It never overwrites an
  existing AGENTS.md without -Force, and never touches any other file.

.PARAMETER Repo
  The project directory.

.PARAMETER Force
  Overwrite an existing AGENTS.md (it is backed up first).

.PARAMETER Check
  Print what would be written. Writes nothing.

.EXAMPLE
  ./init-project.ps1 -Repo C:\path\to\repo
  ./init-project.ps1 -Repo C:\path\to\repo -Check
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [switch]$Force,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

$Repo = (Resolve-Path -LiteralPath $Repo).Path
if (-not (Test-Path (Join-Path $Repo '.git'))) {
    Write-Host "    !!   not a git repository root: $Repo" -ForegroundColor Yellow
    exit 1
}

function Has($rel) { Test-Path -LiteralPath (Join-Path $Repo $rel) }
function HasAny($rels) { foreach ($r in $rels) { if (Has $r) { return $true } }; return $false }

# ---------------------------------------------------------------------------
# Detect the ecosystem
# ---------------------------------------------------------------------------
$ecosystem = $null
$inner = @()
$gate = @()
$notes = @()
$detected = @()

# Signals that a repository is Python even without a standard manifest.
$pyFiles = @(Get-ChildItem -LiteralPath $Repo -Filter '*.py' -File -ErrorAction SilentlyContinue).Count
$hasRuff = Has 'ruff.toml'
$hasTests = (Has 'tests') -or (Has 'test')

# NOTE: every call in a condition is wrapped in parentheses. PowerShell parses
# a bare `Has 'x' -or Has 'y'` as ONE call to Has with the arguments
# ('x', '-or', 'Has', 'y') - the operator is never applied. This bit a real
# detection chain; do not drop the parentheses.
if ((Has 'uv.lock') -or ((Has 'pyproject.toml') -and (Select-String -LiteralPath (Join-Path $Repo 'pyproject.toml') -Pattern '^\s*\[tool\.uv' -Quiet -ErrorAction SilentlyContinue))) {
    $ecosystem = 'Python (uv)'
    $detected += 'pyproject.toml'
    if (Has 'uv.lock') { $detected += 'uv.lock' }
    $inner += 'uv sync'
    $inner += 'uv run ruff check .'
    $inner += 'uv run pytest -x -q'
    $gate  += 'uv run ruff check .'
    $gate  += 'uv run pytest'
    $notes += '`uv run pytest` may need a display for GUI tests. Restrict the inner loop with `-m "not gui"` if the project marks GUI tests.'
}
elseif ((Has 'pyproject.toml') -or (Has 'setup.py') -or (Has 'requirements.txt') -or (Has 'Pipfile') -or (HasAny @('requirements.txt', 'requirements-dev.txt', 'requirements-build.txt')) -or $hasRuff -or (($pyFiles -gt 0) -and $hasTests) -or ((HasAny @('requirements.txt','requirements-dev.txt','requirements-build.txt','setup.py')) -and $hasTests)) {
    $ecosystem = 'Python'
    foreach ($f in @('pyproject.toml', 'setup.py', 'requirements.txt', 'requirements-dev.txt', 'requirements-build.txt', 'Pipfile')) { if (Has $f) { $detected += $f } }
    $inner += 'python -m pytest -x -q'
    $gate  += 'python -m pytest'
}
elseif (Has 'Cargo.toml') {
    $ecosystem = 'Rust'
    $detected += 'Cargo.toml'
    $inner += 'cargo check'
    $gate  += 'cargo clippy --all-targets'
    $gate  += 'cargo test'
}
elseif (Has 'go.mod') {
    $ecosystem = 'Go'
    $detected += 'go.mod'
    $inner += 'go build ./...'
    $gate  += 'go vet ./...'
    $gate  += 'go test ./...'
}
elseif (HasAny @('build.gradle', 'build.gradle.kts', 'settings.gradle', 'settings.gradle.kts')) {
    $ecosystem = 'Gradle'
    foreach ($f in @('build.gradle', 'build.gradle.kts', 'settings.gradle', 'settings.gradle.kts')) { if (Has $f) { $detected += $f } }
    $inner += '.\gradlew.bat test'
    $gate  += '.\gradlew.bat build'
    $notes += 'On a multi-module project, narrow the inner loop to one module and one test class: `.\gradlew.bat :app:testDebugUnitTest --tests="*SuiteName*"`.'
    $notes += 'Keep the gate to ONE Gradle invocation so lint and assembly reuse the compile.'
}
elseif (Has 'pom.xml') {
    $ecosystem = 'Maven'
    $detected += 'pom.xml'
    $inner += 'mvn -q test'
    $gate  += 'mvn -q verify'
}
elseif (Has 'package.json') {
    $ecosystem = 'Node'
    $detected += 'package.json'
    $pkg = $null
    try { $pkg = Get-Content (Join-Path $Repo 'package.json') -Raw | ConvertFrom-Json } catch {}
    $scripts = @()
    if ($pkg -and $pkg.scripts) { $scripts = @($pkg.scripts.PSObject.Properties.Name) }
    if ($scripts -contains 'lint') { $inner += 'npm run lint' }
    if ($scripts -contains 'typecheck') { $inner += 'npm run typecheck' }
    if ($scripts -contains 'test') { $inner += 'npm test' } elseif ($scripts -contains 'test:unit') { $inner += 'npm run test:unit' }
    $gate += 'npm run build'
    if ($scripts -contains 'test') { $gate += 'npm test' }
    if ($scripts -notcontains 'build') { $gate = @('npm test') }
    $notes += 'Node scripts found: ' + ($scripts -join ', ')
}
elseif (Has 'CMakeLists.txt') {
    $ecosystem = 'C/C++ (CMake)'
    $detected += 'CMakeLists.txt'
    $inner += 'cmake --build build'
    $gate  += 'ctest --test-dir build --output-on-failure'
}
elseif (Has 'composer.json') {
    $ecosystem = 'PHP'
    $detected += 'composer.json'
    $inner += 'composer test'
    $gate  += 'composer test'
}
elseif (Has 'Gemfile') {
    $ecosystem = 'Ruby'
    $detected += 'Gemfile'
    $inner += 'bundle exec rspec'
    $gate  += 'bundle exec rspec'
}
elseif (HasAny @('global.json', 'Directory.Build.props')) {
    $ecosystem = '.NET'
    $detected += 'global.json'
    $inner += 'dotnet build'
    $gate  += 'dotnet test'
}
elseif (Has 'Makefile') {
    $ecosystem = 'Make'
    $detected += 'Makefile'
    $inner += 'make'
    $gate  += 'make test'
}
else {
    $ecosystem = 'unknown'
    $notes += 'No build manifest was found. Add the inner loop and gate commands by hand.'
}

# The ecosystem's own default gate, captured before the CI block replaces it.
$ecosystemGate = @($gate)

# ---------------------------------------------------------------------------
# A CI workflow is the authority for the gate
# ---------------------------------------------------------------------------
$ciDir = Join-Path $Repo '.github\workflows'
if (Test-Path $ciDir) {
    $ciRuns = @()
    # A gate command is a test, lint, typecheck or build. Setup, packaging and
    # shell plumbing are not. `uv run X` and `npm run X` ARE commands - only
    # the install-ish subcommands are excluded.
    $plumbing = '(?i)^(mkdir|find|cp|mv|rm|echo|curl|wget|chmod|chown|export|source|set|tar|unzip|zip|cd|sleep|cat|true|false|sudo|brew|apt|apt-get|dnf|yum|choco|winget)\b'
    $setup = '(?i)^(pip|npm|npx|cargo|gem|bundle|uv|dotnet|go|python)\s+(install|ci|add|sync|pull|get|init|pub|upgrade)\b|^python\s+-m\s+pip\b'
    $alsoPlumbing = '(?i)(\$\{\{|Rename-Item|Copy-Item|Remove-Item|New-Item|Set-Content|Add-Content|Compress-Archive|Invoke-|Out-File|--version|--no-lock|--save)'
    # Substring matching, not \b: Gradle task names are camelCase
    # (testDebugUnitTest, lintDebug) and a trailing word boundary misses them.
    $isGate = '(?i)(test|pytest|unittest|nose|vitest|jest|mocha|go test|cargo test|gradlew|mvn|npm run|ruff|clippy|lint|typecheck|fmt|format|check|build|verify|assemble|compile)'
    foreach ($wf in (Get-ChildItem $ciDir -Filter '*.y*ml' -File -ErrorAction SilentlyContinue)) {
        $lines = Get-Content $wf.FullName
        foreach ($l in $lines) {
            if ($l -match '^\s*-?\s*run:\s*(.+)$') {
                $cmd = $Matches[1].Trim().Trim('"').Trim("'")
                if ($cmd -match $plumbing) { continue }
                if ($cmd -match $setup) { continue }
                if ($cmd -match $alsoPlumbing) { continue }
                if ($cmd -match '[;&|]') { continue }
                if ($cmd -notmatch $isGate) { continue }
                $ciRuns += $cmd
            }
        }
    }
    if ($ciRuns.Count) {
        $detected += ('CI: ' + (Get-ChildItem $ciDir -Filter '*.y*ml' -File).Count + ' workflow(s)')
        $notes += 'The gate below was read from the CI workflow, so it should match what the pipeline runs. Check it against the file.'
        # Test and lint commands first, then the rest, capped so the gate stays readable.
        $uniq = @($ciRuns | Select-Object -Unique)
        $isTestish = '(?i)(test|pytest|unittest|lint|ruff|clippy|typecheck)'
        $first = @($uniq | Where-Object { $_ -match $isTestish })
        $rest = @($uniq | Where-Object { $_ -notmatch $isTestish })
        $gate = @(($first + $rest) | Select-Object -First 5)
        # A CI that runs no tests still needs a test in the gate.
        if (-not (@($gate | Where-Object { $_ -match $isTestish }).Count)) {
            $fallback = @($ecosystemGate | Where-Object { $gate -notcontains $_ })
            if ($fallback.Count) {
                $gate += $fallback
                $notes += 'The CI workflow runs no tests. The test command from the ecosystem default was added to the gate - check whether it belongs there.'
            }
        }
    }
}

# Use the Windows Gradle wrapper when the repo has one.
if (Has 'gradlew.bat') {
    $inner = @($inner | ForEach-Object { $_ -replace '(?i)\./gradlew\b', '.\gradlew.bat' })
    $gate  = @($gate  | ForEach-Object { $_ -replace '(?i)\./gradlew\b', '.\gradlew.bat' })
}

# ---------------------------------------------------------------------------
# Test directory, for a more specific inner loop
# ---------------------------------------------------------------------------
$testDir = @('tests', 'test', 'spec', '__tests__') | Where-Object { Has $_ } | Select-Object -First 1
if ($testDir) { $detected += "tests: $testDir" }

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------
$name = Split-Path $Repo -Leaf
$title = "$name contributor guide"

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# $title")
[void]$sb.AppendLine()
[void]$sb.AppendLine("A $ecosystem project. The global policy in ``~/.codex/AGENTS.md`` applies; this")
[void]$sb.AppendLine("file adds the commands that are specific to this repository.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("## Inner loop")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Fast check after each edit, in this repository root:")
[void]$sb.AppendLine()
[void]$sb.AppendLine('```powershell')
foreach ($c in $inner) { [void]$sb.AppendLine($c) }
[void]$sb.AppendLine('```')
[void]$sb.AppendLine()
[void]$sb.AppendLine("## Gate")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Before a commit or PR, all of these must exit 0:")
[void]$sb.AppendLine()
[void]$sb.AppendLine('```powershell')
foreach ($c in $gate) { [void]$sb.AppendLine($c) }
[void]$sb.AppendLine('```')
[void]$sb.AppendLine()
if ($notes.Count) {
    foreach ($n in $notes) { [void]$sb.AppendLine($n); [void]$sb.AppendLine() }
}
[void]$sb.AppendLine("## Notes")
[void]$sb.AppendLine()
[void]$sb.AppendLine('- These commands were proposed by `tools/init-project.ps1` from the build manifests and')
[void]$sb.AppendLine("  the CI workflow. **Run each one once and correct anything that is wrong** - then")
[void]$sb.AppendLine("  delete this line.")
[void]$sb.AppendLine("- Write the real inner loop and gate here. Narrow the inner loop to the changed")
[void]$sb.AppendLine("  area; keep the gate to one invocation.")

$body = $sb.ToString()
$target = Join-Path $Repo 'AGENTS.md'

Write-Host ''
Write-Host "Project scaffold for $name" -ForegroundColor Cyan
Write-Host "  repository : $Repo" -ForegroundColor DarkGray
Write-Host "  ecosystem  : $ecosystem" -ForegroundColor DarkGray
Write-Host "  detected   : $($detected -join ', ')" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  inner loop:' -ForegroundColor Gray
foreach ($c in $inner) { Write-Host "    $c" -ForegroundColor Gray }
Write-Host '  gate:' -ForegroundColor Gray
foreach ($c in $gate) { Write-Host "    $c" -ForegroundColor Gray }
Write-Host ''

if (Test-Path $target) {
    if ($Force) {
        if ($Check) { Write-Host "  would overwrite $target" -ForegroundColor Yellow }
        else {
            $bak = "$target.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
            Copy-Item $target $bak -Force
            [System.IO.File]::WriteAllText($target, $body, $Utf8)
            Write-Host "  wrote $target (backup: $(Split-Path $bak -Leaf))" -ForegroundColor Green
        }
    } else {
        Write-Host "  !!   $target already exists - not overwriting (use -Force)" -ForegroundColor Yellow
        Write-Host '  !!   merge the inner loop and gate sections above into it by hand' -ForegroundColor Yellow
        exit 2
    }
} elseif ($Check) {
    Write-Host "  would write $target" -ForegroundColor Yellow
} else {
    [System.IO.File]::WriteAllText($target, $body, $Utf8)
    Write-Host "  wrote $target" -ForegroundColor Green
    Write-Host '  !!   run each command once and correct it, then delete the "These commands were proposed"' -ForegroundColor Yellow
    Write-Host '      note in the file.' -ForegroundColor Yellow
}
exit 0
