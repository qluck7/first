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

New-Item -ItemType Directory -Force -Path $BinDir, $StateDir, $DataDir | Out-Null

function Run-Git {
    param([string]$WorkingDirectory, [string[]]$Arguments)
    & git.exe -C $WorkingDirectory @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git failed in $WorkingDirectory: $($Arguments -join ' ')"
    }
}

if (-not (Test-Path (Join-Path $ControlRepo '.git'))) {
    throw "Control repository not found: $ControlRepo"
}

Write-Host '=== Refreshing ProjectX ===' -ForegroundColor Cyan
Run-Git $ControlRepo @('fetch', '--all', '--prune')
Run-Git $ControlRepo @('worktree', 'prune')

if (-not (Test-Path $NoctaRepo)) {
    Write-Host '=== Creating isolated Nocta development worktree ===' -ForegroundColor Cyan
    & git.exe -C $ControlRepo worktree add --detach $NoctaRepo origin/main
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create Nocta worktree' }
} else {
    Run-Git $NoctaRepo @('fetch', 'origin', '--prune')
}

if (-not (Test-Path $CollectorRepo)) {
    Write-Host '=== Creating isolated MOEX collector worktree ===' -ForegroundColor Cyan
    & git.exe -C $ControlRepo worktree add --detach $CollectorRepo origin/agent/moex-v62-segmented
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create collector worktree' }
} else {
    Run-Git $CollectorRepo @('fetch', 'origin', '--prune')
}

Write-Host '=== Testing segmented collector mechanism ===' -ForegroundColor Cyan
Push-Location $CollectorRepo
try {
    $env:PYTHONPATH = $CollectorRepo
    python.exe -m compileall -q tools\moex_v6_collector.py tools\moex_v6_runner.py tools\moex_v6_validate.py tools\moex_v6_segment.py tools\moex_v6_assemble.py
    if ($LASTEXITCODE -ne 0) { throw 'Collector compile check failed' }

    python.exe -m pytest -q tests\moex_collector\test_operational_v6.py tests\moex_collector\test_operational_v6_actual_dates.py tests\moex_collector\test_operational_v6_segments.py
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
Set-Location $Repo
$env:PYTHONPATH = $Repo
python.exe -u tools\moex_v6_segment.py --segment-id shares-tqbr --scope stock/shares --board TQBR --partition-count 1 --partition-index 0 --output $Output --config config\moex_operational_v6.json --heartbeat-seconds 20
if ($LASTEXITCODE -ne 0) { throw 'TQBR collection failed' }
python.exe -u tools\moex_v6_validate.py --output $Output
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
Write-Host "Report:             $(Join-Path $StateDir 'workspace-setup-report.json')"
