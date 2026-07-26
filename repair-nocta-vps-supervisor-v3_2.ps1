#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = 'C:\Nocta'
$SupervisorDir = Join-Path $Root 'control\supervisor-v3'
$SupervisorState = Join-Path $SupervisorDir 'state'
$SupervisorHistory = Join-Path $SupervisorState 'history'
$LogDir = Join-Path $Root 'logs\supervisor-v3'
$CanonicalSupervisor = Join-Path $SupervisorDir 'nocta-vps-supervisor-v3.ps1'
$LegacyAgentPath = 'C:\Nocta\control\agent\nocta-vps-agent-v1.ps1'
$LegacyWatchdogPath = 'C:\Nocta\control\agent\nocta-vps-watchdog-v1.ps1'
$DownloadPath = Join-Path $SupervisorDir 'nocta-vps-supervisor-v3.download.ps1'
$SupervisorUrl = 'https://raw.githubusercontent.com/qluck7/first/main/nocta-vps-supervisor-v3.ps1?rev=b964e991'
$RepoName = 'qluck7/ProjectX'
$ControlIssue = 80
$PersistentTaskName = 'NoctaVpsAgentV1'
$ObsoleteWatchdogTaskName = 'NoctaVpsWatchdogV1'
$LogPath = Join-Path $LogDir ("repair-supervisor-v32-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $SupervisorDir,$SupervisorState,$SupervisorHistory,$LogDir | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Write-NoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)
}

function Stop-ProcessTrees {
    param([Parameter(Mandatory)][string[]]$Patterns)
    $items = @(Get-CimInstance Win32_Process | Where-Object {
        if (-not $_.CommandLine -or $_.ProcessId -eq $PID) { return $false }
        foreach ($pattern in $Patterns) {
            if ([string]$_.CommandLine -match $pattern) { return $true }
        }
        return $false
    })
    foreach ($item in $items) {
        try { & taskkill.exe /PID ([int]$item.ProcessId) /T /F 2>$null | Out-Null } catch {}
    }
}

function Set-ControlTask {
    param([Parameter(Mandatory)]$Task)
    $file = Join-Path $SupervisorState ("control-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    Write-NoBom -Path $file -Text (($Task | ConvertTo-Json -Depth 30) + "`r`n")
    try {
        & gh.exe issue edit $ControlIssue --repo $RepoName --body-file $file | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "GitHub issue update failed: $LASTEXITCODE" }
    }
    finally {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

function Publish-HoldTask {
    param([string]$Reason)
    $hold = [ordered]@{
        schema='nocta-vps-control/v1'
        task_id=('{0}-supervisor-v32-hold' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')))
        enabled=$false
        action='collect_segment'
        params=[ordered]@{
            segment_id='shares-tqtf'
            recovery_reason=$Reason
        }
    }
    try { Set-ControlTask -Task $hold } catch {}
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator.'
    }

    foreach ($command in @('gh.exe','git.exe','powershell.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command missing: $command" }
    }
    if (-not (Test-Path 'C:\Python312\python.exe')) { throw 'Python 3.12 is missing.' }
    if (-not (Test-Path 'C:\Nocta\collector\ProjectX\.git')) { throw 'Collector worktree is missing.' }
    & gh.exe auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }

    $persistentTask = Get-ScheduledTask -TaskName $PersistentTaskName -ErrorAction SilentlyContinue
    if (-not $persistentTask) { throw "Persistent task is missing: $PersistentTaskName" }
    $existingAction = @($persistentTask.Actions)[0]
    $existingArguments = [string]$existingAction.Arguments
    if ($existingArguments -notmatch 'nocta-vps-agent-v1\.ps1') {
        throw "Persistent task no longer points to the legacy agent path. Current arguments: $existingArguments"
    }

    Write-Host '=== Stop obsolete agent, watchdog, and collector ===' -ForegroundColor Cyan
    Stop-ScheduledTask -TaskName $PersistentTaskName -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $ObsoleteWatchdogTaskName -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName $ObsoleteWatchdogTaskName -ErrorAction SilentlyContinue | Out-Null
    Stop-ProcessTrees -Patterns @(
        'nocta-vps-agent-v1\.ps1',
        'nocta-vps-watchdog-v1\.ps1',
        'nocta-vps-supervisor-v3\.ps1',
        'moex_v6_segment\.py'
    )
    Start-Sleep -Seconds 3

    Write-Host '=== Archive the old launch scripts and state ===' -ForegroundColor Cyan
    $archive = Join-Path $SupervisorHistory ("pre-v32-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $archive | Out-Null
    foreach ($source in @($LegacyAgentPath,$LegacyWatchdogPath)) {
        if (Test-Path $source) { Copy-Item -Force $source (Join-Path $archive ([IO.Path]::GetFileName($source))) }
    }
    foreach ($name in @('ready.json','latest.json','last-task.json','active-run.json','error.json','installation.json')) {
        $source = Join-Path $SupervisorState $name
        if (Test-Path $source) { Move-Item -Force $source (Join-Path $archive $name) }
    }

    Write-Host '=== Download and parse Supervisor v3.1 ===' -ForegroundColor Cyan
    Invoke-WebRequest -Uri $SupervisorUrl -UseBasicParsing -OutFile $DownloadPath
    if (-not (Test-Path $DownloadPath)) { throw 'Supervisor download failed.' }
    $sourceText = Get-Content $DownloadPath -Raw
    [void][scriptblock]::Create($sourceText)
    if ($sourceText -notmatch '\$Version\s*=\s*''3\.1''') { throw 'Downloaded supervisor is not v3.1.' }

    Write-Host '=== Replace script contents without changing Task Scheduler credentials ===' -ForegroundColor Cyan
    Copy-Item -Force $DownloadPath $CanonicalSupervisor
    Copy-Item -Force $DownloadPath $LegacyAgentPath
    Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue

    Write-Host '=== Publish clean TQTF task ===' -ForegroundColor Cyan
    $taskId = '{0}-collect-shares-tqtf-supervisor-v32' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
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
            recovery_reason='Clean retry under unified Supervisor v3.1; existing scheduled-task credentials preserved.'
        }
    }
    Set-ControlTask -Task $task

    Write-Host '=== Start the unchanged persistent task ===' -ForegroundColor Cyan
    Enable-ScheduledTask -TaskName $PersistentTaskName | Out-Null
    Start-ScheduledTask -TaskName $PersistentTaskName
    Start-Sleep -Seconds 30

    $supervisorProcesses = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'nocta-vps-agent-v1\.ps1' -and $_.CommandLine -match '-Loop'
    })
    if ($supervisorProcesses.Count -ne 1) {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $PersistentTaskName -ErrorAction SilentlyContinue
        $lastResult = if ($taskInfo) { $taskInfo.LastTaskResult } else { $null }
        throw "Expected one Supervisor process, found $($supervisorProcesses.Count). Scheduled task LastTaskResult=$lastResult"
    }

    $readyPath = Join-Path $SupervisorState 'ready.json'
    $latestPath = Join-Path $SupervisorState 'latest.json'
    $activeRunPath = Join-Path $SupervisorState 'active-run.json'
    foreach ($path in @($readyPath,$latestPath,$activeRunPath)) {
        if (-not (Test-Path $path)) { throw "Missing verification file: $path" }
    }

    $ready = Get-Content $readyPath -Raw | ConvertFrom-Json
    $latest = Get-Content $latestPath -Raw | ConvertFrom-Json
    $activeRun = Get-Content $activeRunPath -Raw | ConvertFrom-Json
    if ([string]$ready.supervisor_version -ne '3.1') { throw "Unexpected Supervisor version: $($ready.supervisor_version)" }
    if ([string]$latest.task_id -ne $taskId) { throw "Unexpected active task: $($latest.task_id)" }
    if ([string]$latest.status -notin @('RUNNING','HEARTBEAT','PASS')) { throw "Unexpected active status: $($latest.status)" }
    $collector = Get-Process -Id ([int]$activeRun.process_id) -ErrorAction SilentlyContinue
    if (-not $collector -and [string]$latest.status -ne 'PASS') { throw 'Collector process is absent after Supervisor startup.' }

    $report = [ordered]@{
        status='PASS'
        installed_at=(Get-Date).ToUniversalTime().ToString('o')
        supervisor_version='3.1'
        persistent_task=$PersistentTaskName
        task_action_unchanged=$existingArguments
        obsolete_watchdog_disabled=$ObsoleteWatchdogTaskName
        supervisor_processes=$supervisorProcesses.Count
        control_task_id=$taskId
        first_status=[string]$latest.status
        collector_pid=$activeRun.process_id
        canonical_supervisor=$CanonicalSupervisor
        launch_script=$LegacyAgentPath
        install_log=$LogPath
    }
    $reportPath = Join-Path $SupervisorState 'installation-v32.json'
    $report | ConvertTo-Json -Depth 15 | Set-Content -Path $reportPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== NOCTA VPS SUPERVISOR REPAIR V3.2 PASS ===' -ForegroundColor Green
    $report.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $reportPath"
    Write-Host 'No password was required. RDP may now be disconnected.' -ForegroundColor Yellow
}
catch {
    Publish-HoldTask -Reason ("Supervisor v3.2 repair failed: " + $_.Exception.Message)
    $failure = [ordered]@{
        status='FAIL'
        failed_at=(Get-Date).ToUniversalTime().ToString('o')
        error=$_.Exception.Message
        install_log=$LogPath
    }
    $failurePath = Join-Path $SupervisorState 'installation-v32.json'
    $failure | ConvertTo-Json -Depth 10 | Set-Content -Path $failurePath -Encoding UTF8
    Write-Host ''
    Write-Host '=== NOCTA VPS SUPERVISOR REPAIR V3.2 FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally {
    Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch {}
}
