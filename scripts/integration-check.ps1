# Run each desktop integration entry in its own app process and owned data root.
# Requires generated FRB/l10n sources and the Flutter/native toolchain.
[CmdletBinding()]
param(
    [ValidateSet('windows', 'linux')]
    [string]$Device = 'windows'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = Split-Path -Parent $PSScriptRoot

function Invoke-IsolatedIntegrationTest {
    param([string]$Target, [string]$LogPath, [hashtable]$Record)
    $previousDataDir = $env:KEEL_DATA_DIR
    $previousToken = $env:KEEL_FRB_TEST_TOKEN
    $token = [Guid]::NewGuid().ToString('N')
    $testDir = Join-Path ([IO.Path]::GetTempPath()) "keel-frb-$token"
    $marker = Join-Path $testDir '.keel-frb-test-owner'
    $created = $false
    try {
        # Never adopt or clear a caller-provided data directory.
        if (Test-Path -LiteralPath $testDir) {
            throw "Integration test directory already exists: $testDir"
        }
        New-Item -ItemType Directory -Path $testDir | Out-Null
        $created = $true
        [IO.File]::WriteAllText($marker, $token)
        $env:KEEL_DATA_DIR = $testDir
        $env:KEEL_FRB_TEST_TOKEN = $token
        Write-Host "`n> flutter test $Target -d $Device" -ForegroundColor Cyan
        & flutter test $Target -d $Device 2>&1 |
            Tee-Object -FilePath $LogPath | Out-Host
        $Record.exit_code = $LASTEXITCODE
        if ($Record.exit_code -ne 0) {
            throw "flutter failed with exit code $($Record.exit_code). Stop at this entry: $Target"
        }
    } finally {
        # Restore first, even if validation or cleanup throws.
        $env:KEEL_DATA_DIR = $previousDataDir
        $env:KEEL_FRB_TEST_TOKEN = $previousToken
        if ($created -and (Test-Path -LiteralPath $testDir)) {
            $rootItem = Get-Item -Force -LiteralPath $testDir
            if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing cleanup of a replaced integration directory: $testDir"
            }
            # Check each level before descending; never traverse junctions/symlinks.
            $pending = [Collections.Generic.Stack[string]]::new()
            $pending.Push($testDir)
            while ($pending.Count -gt 0) {
                foreach ($item in Get-ChildItem -Force -LiteralPath ($pending.Pop())) {
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        throw "Refusing cleanup containing a reparse point: $testDir"
                    }
                    if ($item.PSIsContainer) { $pending.Push($item.FullName) }
                }
            }
            if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
                [IO.File]::ReadAllText($marker) -cne $token) {
                throw "Integration directory ownership check failed: $testDir"
            }
            # Only this invocation's exact, explicitly created path is removed.
            # The app process may still be exiting when flutter returns, and
            # antivirus can briefly scan fresh keel.db files; retry bounded
            # before failing so the ownership checks above stay authoritative.
            $removed = $false
            for ($attempt = 0; $attempt -lt 12 -and -not $removed; $attempt++) {
                try {
                    Remove-Item -LiteralPath $testDir -Recurse -Force
                    $removed = $true
                } catch {
                    if ($attempt -eq 11) { throw }
                    Start-Sleep -Milliseconds 1000
                }
            }
        }
    }
}

Push-Location $projectRoot
$report = @{
    schema = 1
    kind = 'desktop-integration-smoke'
    device = $Device
    status = 'FAIL'
    started_at = [DateTimeOffset]::UtcNow.ToString('o')
    finished_at = $null
    commit = $env:GITHUB_SHA
    run_id = $env:GITHUB_RUN_ID
    powershell = $PSVersionTable.PSVersion.ToString()
    entries = @()
    error = $null
    limitations = @('Automated integration smoke does not prove DPI, system printing or desktop acceptance.')
}
$reportDirectory = $null
try {
    $reportDirectory = Join-Path $projectRoot (
        'build/reports/integration-{0}-{1}' -f $Device, [Guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $reportDirectory | Out-Null
    # Separate app processes and data roots: Rust state is process-global.
    $integrationTargets = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'integration_test') -Filter '*_test.dart' -File |
        Sort-Object Name)
    if ($integrationTargets.Count -eq 0) {
        throw 'No integration_test/*_test.dart entries found.'
    }
    $report.entries = @($integrationTargets | ForEach-Object {
        @{
            target = 'integration_test/' + $_.Name
            status = 'NOT_RUN'
            started_at = $null
            finished_at = $null
            exit_code = $null
            log = $_.BaseName + '.log'
            error = $null
        }
    })
    if (-not (Get-Command 'flutter' -ErrorAction SilentlyContinue)) {
        throw 'Missing tool: flutter. See README environment requirements.'
    }
    $index = 0
    foreach ($target in $integrationTargets) {
        $entry = $report.entries[$index]
        $entry.started_at = [DateTimeOffset]::UtcNow.ToString('o')
        try {
            Invoke-IsolatedIntegrationTest -Target $target.FullName `
                -LogPath (Join-Path $reportDirectory $entry.log) -Record $entry
            # Includes ownership validation and cleanup, not just Flutter's exit code.
            $entry.status = 'PASS'
        } catch {
            $entry.status = 'FAIL'
            $entry.error = $_.Exception.Message
            throw
        } finally {
            $entry.finished_at = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $index++
    }
    $report.status = 'PASS'
} catch {
    $report.error = $_.Exception.Message
    throw
} finally {
    try {
        if ($null -ne $reportDirectory -and (Test-Path -LiteralPath $reportDirectory)) {
            $report.finished_at = [DateTimeOffset]::UtcNow.ToString('o')
            $report | ConvertTo-Json -Depth 6 |
                Set-Content -LiteralPath (Join-Path $reportDirectory 'summary.json') -Encoding utf8
            Write-Host "Integration evidence: $reportDirectory"
        }
    } finally {
        Pop-Location
    }
}
