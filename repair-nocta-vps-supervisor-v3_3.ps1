#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = 'C:\Nocta'
$SupervisorDir = Join-Path $Root 'control\supervisor-v3'
$StateDir = Join-Path $SupervisorDir 'state'
$HistoryDir = Join-Path $StateDir 'history'
$LogDir = Join-Path $Root 'logs\supervisor-v3'
$CanonicalPath = Join-Path $SupervisorDir 'nocta-vps-supervisor-v3.ps1'
$LaunchPath = 'C:\Nocta\control\agent\nocta-vps-agent-v1.ps1'
$DownloadPath = Join-Path $SupervisorDir 'nocta-vps-supervisor-v3.source.ps1'
$SourceUrl = 'https://raw.githubusercontent.com/qluck7/first/main/nocta-vps-supervisor-v3.ps1?rev=b964e991'
$RepoName = 'qluck7/ProjectX'
$ControlIssue = 80
$PersistentTaskName = 'NoctaVpsAgentV1'
$ObsoleteWatchdogTaskName = 'NoctaVpsWatchdogV1'
$LogPath = Join-Path $LogDir ("repair-supervisor-v33-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $SupervisorDir,$StateDir,$HistoryDir,$LogDir,(Split-Path $LaunchPath -Parent) | Out-Null
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
    $file = Join-Path $StateDir ("control-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    Write-NoBom -Path $file -Text (($Task | ConvertTo-Json -Depth 30) + "`r`n")
    try {
        & gh.exe issue edit $ControlIssue --repo $RepoName --body-file $file | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "GitHub issue update failed: $LASTEXITCODE" }
    }
    finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
}

function Publish-HoldTask {
    param([Parameter(Mandatory)][string]$Reason)
    $hold = [ordered]@{
        schema='nocta-vps-control/v1'
        task_id=('{0}-supervisor-v33-hold' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')))
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

    Write-Host '=== Stop failed Supervisor, legacy watchdog, and collector ===' -ForegroundColor Cyan
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

    Write-Host '=== Archive failed Supervisor state ===' -ForegroundColor Cyan
    $archive = Join-Path $HistoryDir ("pre-v33-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $archive | Out-Null
    foreach ($path in @($CanonicalPath,$LaunchPath)) {
        if (Test-Path $path) { Copy-Item -Force $path (Join-Path $archive ([IO.Path]::GetFileName($path))) }
    }
    foreach ($name in @('ready.json','latest.json','last-task.json','active-run.json','error.json','installation-v32.json','installation.json')) {
        $path = Join-Path $StateDir $name
        if (Test-Path $path) { Move-Item -Force $path (Join-Path $archive $name) }
    }

    Write-Host '=== Download Supervisor source and patch native Git handling ===' -ForegroundColor Cyan
    Invoke-WebRequest -Uri $SourceUrl -UseBasicParsing -OutFile $DownloadPath
    if (-not (Test-Path $DownloadPath)) { throw 'Supervisor source download failed.' }
    $lines = @(Get-Content $DownloadPath)

    $fetchIndex = -1
    for ($i = 0; $i -lt ($lines.Count - 3); $i++) {
        if ($lines[$i].Trim() -eq '& git.exe -C $CollectorRepo fetch origin agent/moex-v62-segmented 2>&1 | Out-Null' -and
            $lines[$i + 1].Trim() -eq "if (`$LASTEXITCODE -ne 0) { throw 'Collector branch fetch failed.' }" -and
            $lines[$i + 2].Trim() -eq '& git.exe -C $CollectorRepo reset --hard origin/agent/moex-v62-segmented 2>&1 | Out-Null' -and
            $lines[$i + 3].Trim() -eq "if (`$LASTEXITCODE -ne 0) { throw 'Collector branch reset failed.' }") {
            $fetchIndex = $i
            break
        }
    }
    if ($fetchIndex -lt 0) { throw 'Unable to locate the native Git block for patching.' }

    $replacement = @(
        '    $priorErrorPreference = $ErrorActionPreference',
        '    try {',
        '        $ErrorActionPreference = ''Continue''',
        '        $gitFetchOutput = @(& git.exe -C $CollectorRepo fetch origin agent/moex-v62-segmented 2>&1)',
        '        $gitFetchExit = $LASTEXITCODE',
        '    }',
        '    finally { $ErrorActionPreference = $priorErrorPreference }',
        '    if ($gitFetchExit -ne 0) { throw (''Collector branch fetch failed: '' + ($gitFetchOutput -join '' | '')) }',
        '',
        '    $priorErrorPreference = $ErrorActionPreference',
        '    try {',
        '        $ErrorActionPreference = ''Continue''',
        '        $gitResetOutput = @(& git.exe -C $CollectorRepo reset --hard origin/agent/moex-v62-segmented 2>&1)',
        '        $gitResetExit = $LASTEXITCODE',
        '    }',
        '    finally { $ErrorActionPreference = $priorErrorPreference }',
        '    if ($gitResetExit -ne 0) { throw (''Collector branch reset failed: '' + ($gitResetOutput -join '' | '')) }'
    )

    $before = if ($fetchIndex -gt 0) { @($lines[0..($fetchIndex - 1)]) } else { @() }
    $afterStart = $fetchIndex + 4
    $after = if ($afterStart -lt $lines.Count) { @($lines[$afterStart..($lines.Count - 1)]) } else { @() }
    $patched = @($before + $replacement + $after)
    for ($i = 0; $i -lt $patched.Count; $i++) {
        if ($patched[$i].Trim() -eq '$Version = ''3.1''') {
            $patched[$i] = '$Version = ''3.1.1'''
            break
        }
    }
    $patchedText = ($patched -join "`r`n") + "`r`n"
    [void][scriptblock]::Create($patchedText)
    if ($patchedText -notmatch '\$Version\s*=\s*''3\.1\.1''') { throw 'Patched Supervisor version marker is missing.' }

    Write-NoBom -Path $CanonicalPath -Text $patchedText
    Write-NoBom -Path $LaunchPath -Text $patchedText
    Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue

    Write-Host '=== Publish a clean TQTF task ===' -ForegroundColor Cyan
    $taskId = '{0}-collect-shares-tqtf-supervisor-v331' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
    $task = [ordered]@{
        schema='nocta-vps-control/v1'
        task_id=$taskId
        enabled=$true
        action='collect_segment'
        params=[ordered]@{
            segment_id='shares-tqtf'
            attempt=1
            max_attempts=1
            max_runtime_minutes=30
            recovery_reason='Clean retry under Supervisor v3.1.1 with safe native Git handling.'
        }
    }
    Set-ControlTask -Task $task

    Write-Host '=== Start the persistent task and verify real collection ===' -ForegroundColor Cyan
    Enable-ScheduledTask -TaskName $PersistentTaskName | Out-Null
    Start-ScheduledTask -TaskName $PersistentTaskName
    Start-Sleep -Seconds 40

    $supervisorProcesses = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'nocta-vps-agent-v1\.ps1' -and $_.CommandLine -match '-Loop'
    })
    if ($supervisorProcesses.Count -ne 1) {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $PersistentTaskName -ErrorAction SilentlyContinue
        $lastResult = if ($taskInfo) { $taskInfo.LastTaskResult } else { $null }
        throw "Expected one Supervisor process, found $($supervisorProcesses.Count). LastTaskResult=$lastResult"
    }

    $readyPath = Join-Path $StateDir 'ready.json'
    $latestPath = Join-Path $StateDir 'latest.json'
    $activeRunPath = Join-Path $StateDir 'active-run.json'
    $errorPath = Join-Path $StateDir 'error.json'
    if (Test-Path $errorPath) {
        $supervisorError = Get-Content $errorPath -Raw | ConvertFrom-Json
        throw "Supervisor reported an error: $($supervisorError.error)"
    }
    foreach ($path in @($readyPath,$latestPath,$activeRunPath)) {
        if (-not (Test-Path $path)) { throw "Missing verification file: $path" }
    }

    $ready = Get-Content $readyPath -Raw | ConvertFrom-Json
    $latest = Get-Content $latestPath -Raw | ConvertFrom-Json
    $activeRun = Get-Content $activeRunPath -Raw | ConvertFrom-Json
    if ([string]$ready.supervisor_version -ne '3.1.1') { throw "Unexpected Supervisor version: $($ready.supervisor_version)" }
    if ([string]$latest.task_id -ne $taskId) { throw "Unexpected active task: $($latest.task_id)" }
    if ([string]$latest.status -notin @('RUNNING','HEARTBEAT','PASS')) { throw "Unexpected active status: $($latest.status)" }
    $collector = Get-Process -Id ([int]$activeRun.process_id) -ErrorAction SilentlyContinue
    if (-not $collector -and [string]$latest.status -ne 'PASS') { throw 'Collector process is absent after Supervisor startup.' }

    $report = [ordered]@{
        status='PASS'
        installed_at=(Get-Date).ToUniversalTime().ToString('o')
        supervisor_version='3.1.1'
        persistent_task=$PersistentTaskName
        obsolete_watchdog_disabled=$ObsoleteWatchdogTaskName
        supervisor_processes=$supervisorProcesses.Count
        control_task_id=$taskId
        first_status=[string]$latest.status
        collector_pid=$activeRun.process_id
        canonical_supervisor=$CanonicalPath
        launch_script=$LaunchPath
        install_log=$LogPath
    }
    $reportPath = Join-Path $StateDir 'installation-v33.json'
    $report | ConvertTo-Json -Depth 15 | Set-Content -Path $reportPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== NOCTA VPS SUPERVISOR REPAIR V3.3 PASS ===' -ForegroundColor Green
    $report.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $reportPath"
    Write-Host 'Supervisor and collector are running. RDP may be disconnected.' -ForegroundColor Yellow
}
catch {
    Publish-HoldTask -Reason ("Supervisor v3.3 repair failed: " + $_.Exception.Message)
    $failure = [ordered]@{
        status='FAIL'
        failed_at=(Get-Date).ToUniversalTime().ToString('o')
        error=$_.Exception.Message
        install_log=$LogPath
    }
    $failurePath = Join-Path $StateDir 'installation-v33.json'
    $failure | ConvertTo-Json -Depth 10 | Set-Content -Path $failurePath -Encoding UTF8
    Write-Host ''
    Write-Host '=== NOCTA VPS SUPERVISOR REPAIR V3.3 FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally {
    Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch {}
}
