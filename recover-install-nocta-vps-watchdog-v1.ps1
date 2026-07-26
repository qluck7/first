#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = 'C:\Nocta'
$AgentDir = Join-Path $Root 'control\agent'
$StateDir = Join-Path $AgentDir 'state'
$HistoryDir = Join-Path $StateDir 'history'
$LogDir = Join-Path $Root 'logs\watchdog'
$AgentPath = Join-Path $AgentDir 'nocta-vps-agent-v1.ps1'
$WatchdogPath = Join-Path $AgentDir 'nocta-vps-watchdog-v1.ps1'
$AgentUrl = 'https://raw.githubusercontent.com/qluck7/first/main/nocta-vps-agent-v1.ps1'
$WatchdogUrl = 'https://raw.githubusercontent.com/qluck7/first/main/nocta-vps-watchdog-v1.ps1'
$RepoName = 'qluck7/ProjectX'
$ControlIssue = 80
$AgentTaskName = 'NoctaVpsAgentV1'
$WatchdogTaskName = 'NoctaVpsWatchdogV1'
$InstallerLog = Join-Path $LogDir ("recover-watchdog-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

New-Item -ItemType Directory -Force -Path $AgentDir, $StateDir, $HistoryDir, $LogDir | Out-Null
Start-Transcript -Path $InstallerLog -Force | Out-Null

function Stop-TreeByPattern {
    param([Parameter(Mandatory)][string]$Pattern)
    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match $Pattern -and $_.ProcessId -ne $PID
    })
    foreach ($process in $processes) {
        try {
            & taskkill.exe /PID ([int]$process.ProcessId) /T /F 2>$null | Out-Null
        }
        catch {}
    }
}

function Register-PersistentTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][pscredential]$Credential
    )

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Loop' -f $ScriptPath)
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn -User $Credential.UserName)
    )
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Days 3650)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $triggers `
        -Settings $settings `
        -User $Credential.UserName `
        -Password $Credential.GetNetworkCredential().Password `
        -RunLevel Highest `
        -Force | Out-Null
}

function Set-RecoveryTask {
    $taskId = '{0}-recover-shares-tqtf-attempt-1' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
    $task = [ordered]@{
        schema = 'nocta-vps-control/v1'
        task_id = $taskId
        enabled = $true
        action = 'collect_segment'
        params = [ordered]@{
            segment_id = 'shares-tqtf'
            attempt = 1
            max_attempts = 3
            max_runtime_minutes = 60
            recovery_reason = 'Previous agent run remained RUNNING without a final status.'
        }
    }
    $json = $task | ConvertTo-Json -Depth 20
    & gh.exe issue edit $ControlIssue --repo $RepoName --body $json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to place recovery task in control issue.' }
    return $taskId
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator.'
    }

    foreach ($command in @('gh.exe', 'git.exe', 'powershell.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command is missing: $command"
        }
    }
    & gh.exe auth status | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }
    & gh.exe issue view $ControlIssue --repo $RepoName --json number,title | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to access control issue #80.' }

    Write-Host '=== Stopping old agent and collector processes ===' -ForegroundColor Cyan
    Stop-TreeByPattern -Pattern 'nocta-vps-agent-v1\.ps1'
    Stop-TreeByPattern -Pattern 'nocta-vps-watchdog-v1\.ps1'
    Stop-TreeByPattern -Pattern 'moex_v6_segment\.py'
    Start-Sleep -Seconds 2

    Write-Host '=== Downloading current agent and watchdog ===' -ForegroundColor Cyan
    Invoke-WebRequest -Uri ($AgentUrl + '?rev=1157c8e7') -UseBasicParsing -OutFile $AgentPath
    Invoke-WebRequest -Uri ($WatchdogUrl + '?rev=346d5ab5') -UseBasicParsing -OutFile $WatchdogPath
    if (-not (Test-Path $AgentPath)) { throw 'Agent download failed.' }
    if (-not (Test-Path $WatchdogPath)) { throw 'Watchdog download failed.' }

    # Prevent the watchdog from starting a duplicate agent while a prior task is still marked RUNNING.
    $watchdogText = Get-Content $WatchdogPath -Raw
    $oldBlock = "    Start-Agent`r`n    `$latest = Read-JsonFile -Path (Join-Path `$StateDir 'latest.json')`r`n    if (-not `$latest -or [string]`$latest.status -ne 'RUNNING') { return }"
    $newBlock = "    `$latest = Read-JsonFile -Path (Join-Path `$StateDir 'latest.json')`r`n    if (-not `$latest -or [string]`$latest.status -ne 'RUNNING') { Start-Agent; return }"
    if ($watchdogText.Contains($oldBlock)) {
        $watchdogText = $watchdogText.Replace($oldBlock, $newBlock)
        Set-Content -Path $WatchdogPath -Value $watchdogText -Encoding UTF8
    }

    Write-Host '=== Archiving stale control state ===' -ForegroundColor Cyan
    $archive = Join-Path $HistoryDir ("pre-watchdog-recovery-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $archive | Out-Null
    foreach ($name in @('latest.json', 'last-task.json', 'agent-error.json', 'watchdog-error.json', 'watchdog-state.json')) {
        $source = Join-Path $StateDir $name
        if (Test-Path $source) { Move-Item -Force $source (Join-Path $archive $name) }
    }

    Write-Host ''
    Write-Host 'Enter the Windows Administrator password in the secure local prompt.' -ForegroundColor Yellow
    Write-Host 'The password is stored only by Windows Task Scheduler and must not be sent to chat.' -ForegroundColor Yellow
    $account = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $credential = Get-Credential -UserName $account -Message 'Credentials for automatic VPS agent startup before RDP login'
    if (-not $credential) { throw 'Credentials were not supplied.' }

    Write-Host '=== Registering startup tasks ===' -ForegroundColor Cyan
    Register-PersistentTask -TaskName $AgentTaskName -ScriptPath $AgentPath -Credential $credential
    Register-PersistentTask -TaskName $WatchdogTaskName -ScriptPath $WatchdogPath -Credential $credential

    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'NoctaVpsAgent' -ErrorAction SilentlyContinue

    Write-Host '=== Publishing clean TQTF retry task ===' -ForegroundColor Cyan
    $taskId = Set-RecoveryTask

    Write-Host '=== Starting persistent agent and watchdog ===' -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $AgentTaskName
    Start-Sleep -Seconds 5
    Start-ScheduledTask -TaskName $WatchdogTaskName
    Start-Sleep -Seconds 10

    $agentProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'nocta-vps-agent-v1\.ps1' -and $_.CommandLine -match '-Loop'
    })
    $watchdogProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'nocta-vps-watchdog-v1\.ps1' -and $_.CommandLine -match '-Loop'
    })
    if ($agentProcesses.Count -eq 0) { throw 'Agent scheduled task did not start.' }
    if ($watchdogProcesses.Count -eq 0) { throw 'Watchdog scheduled task did not start.' }

    $report = [ordered]@{
        status = 'PASS'
        installed_at = (Get-Date).ToUniversalTime().ToString('o')
        task_id = $taskId
        agent_processes = $agentProcesses.Count
        watchdog_processes = $watchdogProcesses.Count
        agent_task = $AgentTaskName
        watchdog_task = $WatchdogTaskName
        startup_mode = 'Windows Task Scheduler: AtStartup and AtLogOn'
        heartbeat_seconds = 120
        checkpoint_stale_seconds = 600
        automatic_retry_attempts = 3
        installer_log = $InstallerLog
    }
    $reportPath = Join-Path $StateDir 'watchdog-installation.json'
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== NOCTA VPS WATCHDOG RECOVERY PASS ===' -ForegroundColor Green
    $report.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $reportPath"
    Write-Host 'RDP may now be disconnected. The agent will continue before and without an interactive login.' -ForegroundColor Yellow
}
catch {
    $failure = [ordered]@{
        status = 'FAIL'
        failed_at = (Get-Date).ToUniversalTime().ToString('o')
        error = $_.Exception.Message
        installer_log = $InstallerLog
    }
    $failure | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $StateDir 'watchdog-installation.json') -Encoding UTF8
    Write-Host ''
    Write-Host '=== NOCTA VPS WATCHDOG RECOVERY FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $InstallerLog"
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
