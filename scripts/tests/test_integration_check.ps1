# Standalone PowerShell regression. No Flutter, Rust, desktop or Pester required.
# Run in a fresh process: pwsh -NoLogo -NoProfile -File scripts/tests/test_integration_check.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'keel-integration-runner-test-' + [Guid]::NewGuid().ToString('N')
)
$originalData = $env:KEEL_DATA_DIR
$originalToken = $env:KEEL_FRB_TEST_TOKEN
$global:KeelRunnerTestScenario = 'success'
$global:KeelRunnerTestDirectories = [Collections.Generic.List[string]]::new()

function global:Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

# Declared globally because the script under test runs in a separate script scope.
function global:flutter {
    $global:KeelRunnerTestDirectories.Add($env:KEEL_DATA_DIR)
    Assert-True ($env:KEEL_DATA_DIR -ne 'caller-owned-data') 'Caller data was adopted.'
    Assert-True ($env:KEEL_FRB_TEST_TOKEN -ne 'caller-owned-token') 'Token was reused.'
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $env:KEEL_DATA_DIR '.keel-frb-test-owner')) `
            -ceq $env:KEEL_FRB_TEST_TOKEN
    ) 'Missing ownership marker.'
    Write-Output 'fake Flutter output'
    if ($global:KeelRunnerTestScenario -eq 'throw') {
        throw 'fake invocation error'
    }
    if ($global:KeelRunnerTestScenario -eq 'failure') {
        $global:LASTEXITCODE = 7
    } else {
        $global:LASTEXITCODE = 0
    }
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $sourceScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'integration-check.ps1'
    foreach ($scenario in @('success', 'failure', 'throw')) {
        $global:KeelRunnerTestScenario = $scenario
        $caseRoot = Join-Path $fixtureRoot $scenario
        $scripts = Join-Path $caseRoot 'scripts'
        $entries = Join-Path $caseRoot 'integration_test'
        New-Item -ItemType Directory -Path $scripts, $entries | Out-Null
        Copy-Item -LiteralPath $sourceScript -Destination (Join-Path $scripts 'integration-check.ps1')
        Set-Content -LiteralPath (Join-Path $entries 'a_test.dart') -Value '// fixture only'
        Set-Content -LiteralPath (Join-Path $entries 'b_test.dart') -Value '// fixture only'
        $env:KEEL_DATA_DIR = 'caller-owned-data'
        $env:KEEL_FRB_TEST_TOKEN = 'caller-owned-token'
        $failed = $false
        $locationBefore = (Get-Location).Path
        try {
            & (Join-Path $scripts 'integration-check.ps1') -Device linux
        } catch {
            $failed = $true
        }
        Assert-True ($failed -eq ($scenario -ne 'success')) 'Wrong script failure result.'
        Assert-True ((Get-Location).Path -eq $locationBefore) 'Location was not restored.'
        Assert-True ($env:KEEL_DATA_DIR -ceq 'caller-owned-data') 'Data env not restored.'
        Assert-True ($env:KEEL_FRB_TEST_TOKEN -ceq 'caller-owned-token') 'Token env not restored.'
        $summaries = @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'build/reports') `
            -Recurse -Filter 'summary.json' -File)
        Assert-True ($summaries.Count -eq 1) 'Expected one summary.'
        $report = Get-Content -Raw -LiteralPath $summaries[0].FullName | ConvertFrom-Json
        Assert-True ($report.kind -eq 'desktop-integration-smoke') 'Wrong evidence kind.'
        Assert-True ($report.device -eq 'linux') 'Wrong device.'
        Assert-True ($report.entries.Count -eq 2) 'Missing discovered entries.'
        Assert-True ($null -ne $report.finished_at) 'Missing finish timestamp.'
        if ($scenario -eq 'success') {
            Assert-True ($report.status -eq 'PASS') 'Success not recorded.'
            foreach ($entry in $report.entries) {
                Assert-True ($entry.status -eq 'PASS' -and $entry.exit_code -eq 0) 'Wrong success entry.'
            }
        } else {
            Assert-True ($report.status -eq 'FAIL') 'Failure not recorded.'
            Assert-True ($report.entries[0].status -eq 'FAIL') 'Failed entry missing.'
            if ($scenario -eq 'failure') {
                Assert-True ($report.entries[0].exit_code -eq 7) 'Native exit code lost.'
            } else {
                Assert-True ($null -eq $report.entries[0].exit_code) 'Exception has no native exit code.'
            }
            Assert-True ($report.entries[1].status -eq 'NOT_RUN') 'Later entry must not run.'
            Assert-True ($null -eq $report.entries[1].exit_code) 'Unrun entry has exit code.'
        }
        $firstLog = Join-Path $summaries[0].DirectoryName $report.entries[0].log
        Assert-True ((Get-Content -Raw -LiteralPath $firstLog) -match 'fake Flutter output') 'Output log missing.'
    }
    Assert-True ($global:KeelRunnerTestDirectories.Count -eq 4) 'Unexpected invocation count.'
    Assert-True (@($global:KeelRunnerTestDirectories | Select-Object -Unique).Count -eq 4) 'Data roots reused.'
    foreach ($directory in $global:KeelRunnerTestDirectories) {
        Assert-True (-not (Test-Path -LiteralPath $directory)) 'Owned data root not cleaned.'
    }
    Write-Host 'PASS: isolated integration runner mock regression (not desktop acceptance).'
} finally {
    $env:KEEL_DATA_DIR = $originalData
    $env:KEEL_FRB_TEST_TOKEN = $originalToken
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
