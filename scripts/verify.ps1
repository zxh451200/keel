# Run from PowerShell on Windows or Linux; no administrator rights required.
# Default: keep lockfiles fixed. First sync of offline edits:
#   .\scripts\verify.ps1 -ResolveDependencies
# This resolves newly declared dependencies, runs the security gate before
# compilation, regenerates bindings and formats sources. Review and commit
# lockfiles / generated files / formatting afterward.
[CmdletBinding()]
param(
    [switch]$ResolveDependencies,
    [switch]$BuildRelease,
    [switch]$Security,
    [ValidateSet('windows', 'linux')]
    [string]$Device = 'windows'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$reportPath = Join-Path $projectRoot 'verify-output.txt'
$transcriptStarted = $false
$exitStatus = 1
$runSecurity = $Security -or $ResolveDependencies

function Invoke-Check {
    param(
        [string]$Tool,
        [string[]]$ToolArgs
    )
    Write-Host "`n> $Tool $($ToolArgs -join ' ')" -ForegroundColor Cyan
    & $Tool @ToolArgs
    if ($LASTEXITCODE -ne 0) {
        throw "$Tool failed with exit code $LASTEXITCODE. Stop at this step."
    }
}

function Require-Command {
    param(
        [string]$Tool,
        [string]$Hint
    )
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "Missing tool before compilation: $Tool. $Hint"
    }
}

Push-Location $projectRoot
try {
    Start-Transcript -Path $reportPath -Append | Out-Null
    $transcriptStarted = $true
    foreach ($tool in @('flutter', 'dart', 'cargo', 'rustc',
                        'flutter_rust_bridge_codegen', 'python')) {
        Require-Command $tool 'See README environment requirements.'
    }
    if ($runSecurity) {
        Require-Command 'bash' 'Security checks require Bash (Git Bash on Windows) on PATH.'
        $bashPath = (Get-Command 'bash').Source
        if ($Device -eq 'windows' -and "$bashPath" -notmatch '(?i)\\Git\\(?:usr\\)?bin\\bash(?:\.exe)?$') {
            throw "Security checks require Git Bash, but bash resolves to '$bashPath'. Put Git for Windows bash.exe on PATH."
        }
        foreach ($tool in @('cargo-license', 'cargo-deny', 'cargo-audit')) {
            Require-Command $tool 'Install the security tools listed in README environment requirements.'
        }
    }
    Invoke-Check 'flutter' @('--version')
    Invoke-Check 'rustc' @('-vV')
    Invoke-Check 'cargo' @('--version')
    $codegenVersion = & flutter_rust_bridge_codegen --version
    if ($LASTEXITCODE -ne 0 -or "$codegenVersion" -notmatch '\b2\.13\.0\b') {
        throw 'flutter_rust_bridge_codegen 2.13.0 is required.'
    }
    Write-Host $codegenVersion

    # Flutter wrappers can rewrite pubspec.lock to a mirror. Restore the
    # caller's environment even when pub get fails.
    $previousPubHost = $env:PUB_HOSTED_URL
    try {
        $env:PUB_HOSTED_URL = 'https://pub.dev'
        if ($ResolveDependencies) {
            Invoke-Check 'flutter' @('pub', 'get')
        } else {
            Invoke-Check 'flutter' @('pub', 'get', '--enforce-lockfile')
        }
    } finally {
        $env:PUB_HOSTED_URL = $previousPubHost
    }
    $lockText = Get-Content -Raw -LiteralPath 'pubspec.lock'
    foreach ($entry in [regex]::Matches($lockText, '(?m)^\s+url:\s*"?([^"\s]+)"?')) {
        if ($entry.Groups[1].Value.TrimEnd('/') -ne 'https://pub.dev') {
            throw 'pubspec.lock contains a mirror URL. Fix the Flutter wrapper.'
        }
    }
    Push-Location (Join-Path $projectRoot 'rust')
    try {
        if ($ResolveDependencies) {
            Invoke-Check 'cargo' @('fetch')
        } else {
            Invoke-Check 'cargo' @('fetch', '--locked')
        }
    } finally {
        Pop-Location
    }

    if ($runSecurity) {
        if ($ResolveDependencies) {
            Write-Host 'ResolveDependencies enables the security gate automatically.'
        }
        Invoke-Check 'bash' @('scripts/security-check.sh', '--strict')
    } else {
        Write-Host 'Security scans were not run. Use -Security before release.'
    }

    Invoke-Check 'flutter' @('gen-l10n')
    Invoke-Check 'flutter_rust_bridge_codegen' @('generate')
    Invoke-Check 'python' @('-B', 'scripts/check_sources.py')
    # Formatting changes are deliberately retained, never reset.
    Invoke-Check 'dart' @('format', 'lib', 'test', 'integration_test')
    Push-Location (Join-Path $projectRoot 'rust')
    try {
        Invoke-Check 'cargo' @('fmt', '--all')
        Invoke-Check 'cargo' @('clippy', '--locked', '--all-targets', '--', '-D', 'warnings')
        Invoke-Check 'cargo' @('test', '--locked')
    } finally {
        Pop-Location
    }
    Invoke-Check 'flutter' @('analyze')
    Invoke-Check 'flutter' @('test')
    if ($BuildRelease) {
        Invoke-Check 'flutter' @('build', $Device, '--release', '--no-pub')
    }
    & (Join-Path $PSScriptRoot 'integration-check.ps1') -Device $Device
    Write-Host 'Requested checks passed. Review generated files, formatting and lockfile changes.'
    Write-Host 'This local script does not replace CI regeneration checks or release acceptance.'
    $exitStatus = 0
} catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
    Pop-Location
}
exit $exitStatus
