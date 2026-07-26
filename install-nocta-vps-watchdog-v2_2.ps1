#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = 'C:\Nocta'
$AgentDir = Join-Path $Root 'control\agent'
$StateDir = Join-Path $AgentDir 'state'
$LogDir = Join-Path $Root 'logs\watchdog'
$Target = Join-Path $AgentDir 'nocta-vps-watchdog-v1.ps1'
$Temporary = Join-Path $AgentDir 'nocta-vps-watchdog-v2_1.download.ps1'
$Url = 'https://raw.githubusercontent.com/qluck7/first/main/nocta-vps-watchdog-v2_1.ps1?rev=5efdc1a9'
$TaskName = 'NoctaVpsWatchdogV1'
$InstallLog = Join-Path $LogDir ("install-watchdog-v22-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

New-Item -ItemType Directory -Force -Path $AgentDir, $StateDir, $LogDir | Out-Null
Start-Transcript -Path $InstallLog -Force | Out-Null

function Stop-WatchdogProcesses {
    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'nocta-vps-watchdog-v1\.ps1' -and $_.ProcessId -ne $PID
    })
    foreach ($process in $processes) {
        try { & taskkill.exe /PID ([int]$process.ProcessId) /T /F 2>$null | Out-Null } catch {}
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as Administrator.' }
    foreach ($command in @('gh.exe', 'powershell.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command is missing: $command" }
    }
    & gh.exe auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { throw "Scheduled task is missing: $TaskName" }

    Write-Host '=== Downloading watchdog v2.1 ===' -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -UseBasicParsing -OutFile $Temporary
    if (-not (Test-Path $Temporary)) { throw 'Watchdog download failed.' }

    Write-Host '=== Parsing watchdog before installation ===' -ForegroundColor Cyan
    $source = Get-Content $Temporary -Raw
    [void][scriptblock]::Create($source)
    if ($source -notmatch '\$Version\s*=\s*''2\.1''') { throw 'Downloaded script does not identify itself as v2.1.' }

    Write-Host '=== Replacing only watchdog; collector remains running ===' -ForegroundColor Cyan
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Stop-WatchdogProcesses
    Start-Sleep 2
    Copy-Item -Force $Temporary $Target
    Remove-Item $Temporary -Force -ErrorAction SilentlyContinue
    foreach ($name in @('watchdog-error.json','watchdog-error-marker.json','watchdog-state.json','watchdog-heartbeat.json','watchdog-ready.json')) {
        Remove-Item (Join-Path $StateDir $name) -Force -ErrorAction SilentlyContinue
    }

    Write-Host '=== Starting watchdog v2.1 ===' -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep 15

    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'nocta-vps-watchdog-v1\.ps1' -and $_.CommandLine -match '-Loop'
    })
    if ($processes.Count -eq 0) { throw 'Watchdog process did not start.' }

    $readyPath = Join-Path $StateDir 'watchdog-ready.json'
    $heartbeatPath = Join-Path $StateDir 'watchdog-heartbeat.json'
    $errorPath = Join-Path $StateDir 'watchdog-error.json'
    $latestPath = Join-Path $StateDir 'latest.json'
    if (-not (Test-Path $readyPath)) { throw 'Watchdog did not create READY state.' }
    $ready = Get-Content $readyPath -Raw | ConvertFrom-Json
    if ([string]$ready.watchdog_version -ne '2.1') { throw "Unexpected watchdog version: $($ready.watchdog_version)" }

    if (Test-Path $errorPath) {
        $failure = Get-Content $errorPath -Raw | ConvertFrom-Json
        throw "Watchdog cycle failed: $($failure.error)"
    }

    $heartbeat = $null
    $latest = $null
    if (Test-Path $heartbeatPath) { $heartbeat = Get-Content $heartbeatPath -Raw | ConvertFrom-Json }
    if (Test-Path $latestPath) { $latest = Get-Content $latestPath -Raw | ConvertFrom-Json }
    $running = $latest -and [string]$latest.status -eq 'RUNNING'
    if ($running) {
        if (-not $heartbeat) { throw 'Active task exists, but watchdog did not create the first heartbeat.' }
        if ([string]$heartbeat.watchdog_version -ne '2.1' -or [string]$heartbeat.status -ne 'HEARTBEAT') {
            throw 'Heartbeat file is not a valid v2.1 heartbeat.'
        }
    }

    $report = [ordered]@{
        status = 'PASS'
        installed_at = (Get-Date).ToUniversalTime().ToString('o')
        watchdog_version = '2.1'
        process_count = $processes.Count
        task_state = (Get-ScheduledTask -TaskName $TaskName).State.ToString()
        observed_task_status = if ($latest) { [string]$latest.status } else { 'NONE' }
        heartbeat_task_id = if ($heartbeat) { [string]$heartbeat.task_id } else { $null }
        collector_processes = if ($heartbeat) { $heartbeat.collector_processes } else { $null }
        checkpoint = if ($heartbeat) { $heartbeat.checkpoint } else { $null }
        segment_state = if ($heartbeat) { $heartbeat.segment_state } else { $null }
        install_log = $InstallLog
    }
    $reportPath = Join-Path $StateDir 'watchdog-v22-installation.json'
    $report | ConvertTo-Json -Depth 20 | Set-Content -Path $reportPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== NOCTA VPS WATCHDOG V2.1 PASS ===' -ForegroundColor Green
    $report.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $reportPath"
    Write-Host 'The current collector was not stopped. RDP may be disconnected.' -ForegroundColor Yellow
}
catch {
    $failure = [ordered]@{
        status = 'FAIL'
        failed_at = (Get-Date).ToUniversalTime().ToString('o')
        error = $_.Exception.Message
        install_log = $InstallLog
    }
    $failure | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $StateDir 'watchdog-v22-installation.json') -Encoding UTF8
    Write-Host ''
    Write-Host '=== NOCTA VPS WATCHDOG V2.1 FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $InstallLog"
    exit 1
}
finally {
    Remove-Item $Temporary -Force -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch {}
}
