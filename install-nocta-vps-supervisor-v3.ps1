#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = 'C:\Nocta'
$InstallDir = Join-Path $Root 'control\supervisor-v3'
$StateDir = Join-Path $InstallDir 'state'
$HistoryDir = Join-Path $StateDir 'history'
$LogDir = Join-Path $Root 'logs\supervisor-v3'
$Target = Join-Path $InstallDir 'nocta-vps-supervisor-v3.ps1'
$Download = Join-Path $InstallDir 'nocta-vps-supervisor-v3.download.ps1'
$Url = 'https://raw.githubusercontent.com/qluck7/first/main/nocta-vps-supervisor-v3.ps1?rev=b964e991'
$RepoName = 'qluck7/ProjectX'
$ControlIssue = 80
$AgentTask = 'NoctaVpsAgentV1'
$WatchdogTask = 'NoctaVpsWatchdogV1'
$Log = Join-Path $LogDir ("install-supervisor-v3-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $InstallDir,$StateDir,$HistoryDir,$LogDir | Out-Null
Start-Transcript -Path $Log -Force | Out-Null

function Write-NoBom([string]$Path,[string]$Text) {
    [IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)
}

function Stop-Tree([string[]]$Patterns) {
    $items = @(Get-CimInstance Win32_Process | Where-Object {
        if (-not $_.CommandLine -or $_.ProcessId -eq $PID) { return $false }
        foreach ($p in $Patterns) { if ([string]$_.CommandLine -match $p) { return $true } }
        return $false
    })
    foreach ($item in $items) {
        try { & taskkill.exe /PID ([int]$item.ProcessId) /T /F 2>$null | Out-Null } catch {}
    }
}

function Set-Control([object]$Task) {
    $file = Join-Path $StateDir ("control-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    Write-NoBom $file (($Task | ConvertTo-Json -Depth 30) + "`r`n")
    try {
        & gh.exe issue edit $ControlIssue --repo $RepoName --body-file $file | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "GitHub issue update failed: $LASTEXITCODE" }
    }
    finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
}

try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $wp = [Security.Principal.WindowsPrincipal]::new($id)
    if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as Administrator.' }

    foreach ($cmd in @('gh.exe','git.exe','powershell.exe')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "Missing command: $cmd" }
    }
    if (-not (Test-Path 'C:\Python312\python.exe')) { throw 'Python 3.12 is missing.' }
    if (-not (Test-Path 'C:\Nocta\collector\ProjectX\.git')) { throw 'Collector worktree is missing.' }
    & gh.exe auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }

    $existing = Get-ScheduledTask -TaskName $AgentTask -ErrorAction SilentlyContinue
    if (-not $existing) { throw "Persistent task missing: $AgentTask" }

    Write-Host '=== Stop old controller ===' -ForegroundColor Cyan
    Stop-ScheduledTask -TaskName $AgentTask -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $WatchdogTask -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName $WatchdogTask -ErrorAction SilentlyContinue | Out-Null
    Stop-Tree @('nocta-vps-agent-v1\.ps1','nocta-vps-watchdog-v1\.ps1','nocta-vps-supervisor-v3\.ps1','moex_v6_segment\.py')
    Start-Sleep 3

    Write-Host '=== Archive old state ===' -ForegroundColor Cyan
    $archive = Join-Path $HistoryDir ("pre-v3-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $archive | Out-Null
    foreach ($name in @('latest.json','last-task.json','agent-error.json','watchdog-error.json','watchdog-state.json','watchdog-heartbeat.json')) {
        $old = Join-Path 'C:\Nocta\control\agent\state' $name
        if (Test-Path $old) { Move-Item -Force $old (Join-Path $archive $name) }
    }

    Write-Host '=== Download and parse supervisor v3.1 ===' -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -UseBasicParsing -OutFile $Download
    $text = Get-Content $Download -Raw
    [void][scriptblock]::Create($text)
    if ($text -notmatch '\$Version\s*=\s*''3\.1''') { throw 'Wrong supervisor version.' }
    Copy-Item -Force $Download $Target
    Remove-Item $Download -Force -ErrorAction SilentlyContinue

    Write-Host '=== Replace task action, preserving stored credentials ===' -ForegroundColor Cyan
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Loop' -f $Target)
    Set-ScheduledTask -TaskName $AgentTask -Action $action | Out-Null
    Enable-ScheduledTask -TaskName $AgentTask | Out-Null

    $taskId = '{0}-collect-shares-tqtf-supervisor-v3' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
    $task = [ordered]@{
        schema='nocta-vps-control/v1'
        task_id=$taskId
        enabled=$true
        action='collect_segment'
        params=[ordered]@{
            segment_id='shares-tqtf'
            attempt=1
            max_attempts=1
            max_runtime_minutes=45
            recovery_reason='Clean retry under supervisor v3.1'
        }
    }
    Write-Host '=== Publish clean TQTF task ===' -ForegroundColor Cyan
    Set-Control $task

    Write-Host '=== Start supervisor and verify ===' -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $AgentTask
    Start-Sleep 30

    $procs = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'nocta-vps-supervisor-v3\.ps1' -and $_.CommandLine -match '-Loop'
    })
    if ($procs.Count -ne 1) { throw "Expected one supervisor process, found $($procs.Count)." }

    $readyPath = Join-Path $StateDir 'ready.json'
    $latestPath = Join-Path $StateDir 'latest.json'
    $runPath = Join-Path $StateDir 'active-run.json'
    foreach ($path in @($readyPath,$latestPath,$runPath)) {
        if (-not (Test-Path $path)) { throw "Missing verification file: $path" }
    }
    $ready = Get-Content $readyPath -Raw | ConvertFrom-Json
    $latest = Get-Content $latestPath -Raw | ConvertFrom-Json
    $run = Get-Content $runPath -Raw | ConvertFrom-Json
    if ([string]$ready.supervisor_version -ne '3.1') { throw "Wrong ready version: $($ready.supervisor_version)" }
    if ([string]$latest.task_id -ne $taskId) { throw "Wrong active task: $($latest.task_id)" }
    if ([string]$latest.status -notin @('RUNNING','HEARTBEAT','PASS')) { throw "Bad active status: $($latest.status)" }
    $collector = Get-Process -Id ([int]$run.process_id) -ErrorAction SilentlyContinue
    if (-not $collector -and [string]$latest.status -ne 'PASS') { throw 'Collector process is absent.' }

    $report = [ordered]@{
        status='PASS'
        installed_at=(Get-Date).ToUniversalTime().ToString('o')
        supervisor_version='3.1'
        persistent_task=$AgentTask
        persistent_task_state=(Get-ScheduledTask -TaskName $AgentTask).State.ToString()
        disabled_watchdog_task=$WatchdogTask
        supervisor_processes=$procs.Count
        task_id=$taskId
        first_status=[string]$latest.status
        collector_pid=$run.process_id
        install_log=$Log
    }
    $reportPath = Join-Path $StateDir 'installation.json'
    $report | ConvertTo-Json -Depth 15 | Set-Content -Path $reportPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== NOCTA VPS SUPERVISOR V3.1 PASS ===' -ForegroundColor Green
    $report.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $reportPath"
    Write-Host 'RDP may now be disconnected.' -ForegroundColor Yellow
}
catch {
    $failure = [ordered]@{status='FAIL';failed_at=(Get-Date).ToUniversalTime().ToString('o');error=$_.Exception.Message;install_log=$Log}
    $failure | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $StateDir 'installation.json') -Encoding UTF8
    Write-Host ''
    Write-Host '=== NOCTA VPS SUPERVISOR V3.1 FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $Log"
    exit 1
}
finally {
    Remove-Item $Download -Force -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch {}
}
