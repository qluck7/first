#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\Nocta'
$ControlRepo = Join-Path $Root 'development\ProjectX'
$NoctaRepo = Join-Path $Root 'development\NoctaDev'
$CollectorRepo = Join-Path $Root 'collector\ProjectX'
$BinDir = Join-Path $Root 'bin'
$StateDir = Join-Path $Root 'state'
$DataDir = Join-Path $Root 'data\segments'
$Python = 'C:\Python312\python.exe'

New-Item -ItemType Directory -Force -Path $BinDir, $StateDir, $DataDir | Out-Null

function Run-Git {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    & git.exe -C $WorkingDirectory @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ('git failed in {0}: {1}' -f $WorkingDirectory, ($Arguments -join ' '))
    }
}

if (-not (Test-Path $Python)) {
    throw "Python 3.12 not found: $Python"
}
if (-not (Test-Path (Join-Path $ControlRepo '.git'))) {
    throw "Control repository not found: $ControlRepo"
}

Write-Host '=== Ensuring collector Python dependencies ===' -ForegroundColor Cyan
& $Python -m pip install --disable-pip-version-check --upgrade requests pytest tzdata
if ($LASTEXITCODE -ne 0) { throw 'Unable to install collector Python dependencies' }

Write-Host '=== Refreshing ProjectX ===' -ForegroundColor Cyan
Run-Git -WorkingDirectory $ControlRepo -Arguments @('fetch', '--all', '--prune')
Run-Git -WorkingDirectory $ControlRepo -Arguments @('worktree', 'prune')

if (-not (Test-Path $NoctaRepo)) {
    Write-Host '=== Creating isolated Nocta development worktree ===' -ForegroundColor Cyan
    & git.exe -C $ControlRepo worktree add --detach $NoctaRepo origin/main
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create Nocta worktree' }
} elseif (-not (Test-Path (Join-Path $NoctaRepo '.git'))) {
    throw "Nocta path exists but is not a Git worktree: $NoctaRepo"
} else {
    Run-Git -WorkingDirectory $NoctaRepo -Arguments @('fetch', 'origin', '--prune')
}

if (-not (Test-Path $CollectorRepo)) {
    Write-Host '=== Creating isolated MOEX collector worktree ===' -ForegroundColor Cyan
    & git.exe -C $ControlRepo worktree add --detach $CollectorRepo origin/agent/moex-v62-segmented
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create collector worktree' }
} elseif (-not (Test-Path (Join-Path $CollectorRepo '.git'))) {
    throw "Collector path exists but is not a Git worktree: $CollectorRepo"
} else {
    Write-Host '=== Synchronizing MOEX collector with repaired branch ===' -ForegroundColor Cyan
    Run-Git -WorkingDirectory $CollectorRepo -Arguments @('fetch', 'origin', 'agent/moex-v62-segmented')
    Run-Git -WorkingDirectory $CollectorRepo -Arguments @('reset', '--hard', 'origin/agent/moex-v62-segmented')
    Run-Git -WorkingDirectory $CollectorRepo -Arguments @('clean', '-fd')
}

Write-Host '=== Testing segmented collector mechanism ===' -ForegroundColor Cyan
Push-Location $CollectorRepo
try {
    $env:PYTHONPATH = $CollectorRepo

    & $Python -m compileall -q tools\moex_v6_collector.py tools\moex_v6_runner.py tools\moex_v6_validate.py tools\moex_v6_segment.py tools\moex_v6_assemble.py
    if ($LASTEXITCODE -ne 0) { throw 'Collector compile check failed' }

    & $Python -m pytest -q tests\moex_collector\test_operational_v6.py tests\moex_collector\test_operational_v6_actual_dates.py tests\moex_collector\test_operational_v6_segments.py tests\moex_collector\test_operational_v6_windows_paths.py
    if ($LASTEXITCODE -ne 0) { throw 'Collector regression tests failed' }
}
finally {
    Pop-Location
}

$StartCodex = @'
@echo off
cd /d C:\Nocta\development\NoctaDev
codex
'@
Set-Content -Path (Join-Path $BinDir 'start-codex-nocta.cmd') -Value $StartCodex -Encoding ASCII

$RunTqbr = @'
#requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$Repo = 'C:\Nocta\collector\ProjectX'
$Output = 'C:\Nocta\data\segments\shares-tqbr'
$Python = 'C:\Python312\python.exe'
Set-Location $Repo
$env:PYTHONPATH = $Repo
& $Python -u tools\moex_v6_segment.py --segment-id shares-tqbr --scope stock/shares --board TQBR --partition-count 1 --partition-index 0 --output $Output --config config\moex_operational_v6.json --heartbeat-seconds 20
if ($LASTEXITCODE -ne 0) { throw 'TQBR collection failed' }
& $Python -u tools\moex_v6_validate.py --output $Output
if ($LASTEXITCODE -ne 0) { throw 'TQBR validation failed' }
Write-Host 'TQBR SEGMENT PASS' -ForegroundColor Green
'@
Set-Content -Path (Join-Path $BinDir 'run-moex-tqbr.ps1') -Value $RunTqbr -Encoding UTF8

$Report = [ordered]@{
    status = 'PASS'
    generated_at = (Get-Date).ToString('o')
    control_repo = $ControlRepo
    nocta_development = $NoctaRepo
    collector = $CollectorRepo
    collector_ref = (& git.exe -C $CollectorRepo rev-parse HEAD).Trim()
    nocta_ref = (& git.exe -C $NoctaRepo rev-parse HEAD).Trim()
    commands = [ordered]@{
        start_codex = 'C:\Nocta\bin\start-codex-nocta.cmd'
        run_tqbr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Nocta\bin\run-moex-tqbr.ps1'
    }
}

$Report | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $StateDir 'workspace-setup-report.json') -Encoding UTF8

Write-Host ''
Write-Host '=== WORKSPACE SETUP PASS ===' -ForegroundColor Green
Write-Host "Nocta development: $NoctaRepo"
Write-Host "MOEX collector:     $CollectorRepo"
Write-Host "Collector commit:   $($Report.collector_ref)"
Write-Host "Report:             $(Join-Path $StateDir 'workspace-setup-report.json')"
