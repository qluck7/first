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
$AgentTaskName = 'NoctaVpsAgentV1'
$WatchdogTaskName = 'NoctaVpsWatchdogV1'
$RepoName = 'qluck7/ProjectX'
$ControlIssue = 80
$RepairLog = Join-Path $LogDir ("repair-start-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

New-Item -ItemType Directory -Force -Path $AgentDir, $StateDir, $HistoryDir, $LogDir | Out-Null
Start-Transcript -Path $RepairLog -Force | Out-Null

function Stop-TreeByPattern {
    param([Parameter(Mandatory)][string]$Pattern)
    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match $Pattern -and $_.ProcessId -ne $PID
    })
    foreach ($process in $processes) {
        try { & taskkill.exe /PID ([int]$process.ProcessId) /T /F 2>$null | Out-Null } catch {}
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator.'
    }

    foreach ($command in @('gh.exe', 'powershell.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command is missing: $command"
        }
    }
    & gh.exe auth status | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }

    if (-not (Test-Path $AgentPath)) { throw "Agent file is missing: $AgentPath" }
    if (-not (Test-Path $WatchdogPath)) { throw "Watchdog file is missing: $WatchdogPath" }
    if (-not (Get-ScheduledTask -TaskName $AgentTaskName -ErrorAction SilentlyContinue)) {
        throw "Scheduled task is missing: $AgentTaskName"
    }
    if (-not (Get-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue)) {
        throw "Scheduled task is missing: $WatchdogTaskName"
    }

    Write-Host '=== Stopping incomplete processes ===' -ForegroundColor Cyan
    Stop-ScheduledTask -TaskName $AgentTaskName -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue
    Stop-TreeByPattern -Pattern 'nocta-vps-agent-v1\.ps1'
    Stop-TreeByPattern -Pattern 'nocta-vps-watchdog-v1\.ps1'
    Stop-TreeByPattern -Pattern 'moex_v6_segment\.py'
    Start-Sleep -Seconds 2

    Write-Host '=== Hardening watchdog startup logic ===' -ForegroundColor Cyan
    $lines = @(Get-Content $WatchdogPath)
    $index = -1
    for ($i = 0; $i -lt ($lines.Count - 2); $i++) {
        if ($lines[$i].Trim() -eq 'Start-Agent' -and
            $lines[$i + 1] -match '^\s*\$latest = Read-JsonFile' -and
            $lines[$i + 2] -match "^\s*if \(-not \$latest -or \[string\]\$latest\.status -ne 'RUNNING'\) \{ return \}$") {
            $index = $i
            break
        }
    }
    if ($index -ge 0) {
        $before = if ($index -gt 0) { @($lines[0..($index - 1)]) } else { @() }
        $afterStart = $index + 3
        $after = if ($afterStart -lt $lines.Count) { @($lines[$afterStart..($lines.Count - 1)]) } else { @() }
        $replacement = @(
            "    `$latest = Read-JsonFile -Path (Join-Path `$StateDir 'latest.json')",
            "    if (-not `$latest -or [string]`$latest.status -ne 'RUNNING') { Start-Agent; return }"
        )
        @($before + $replacement + $after) | Set-Content -Path $WatchdogPath -Encoding UTF8
    }

    Write-Host '=== Archiving incomplete state ===' -ForegroundColor Cyan
    $archive = Join-Path $HistoryDir ("repair-v12-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $archive | Out-Null
    foreach ($name in @('latest.json', 'last-task.json', 'agent-error.json', 'watchdog-error.json', 'watchdog-state.json')) {
        $source = Join-Path $StateDir $name
        if (Test-Path $source) { Move-Item -Force $source (Join-Path $archive $name) }
    }

    Write-Host '=== Publishing clean TQTF retry through GitHub API ===' -ForegroundColor Cyan
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
            recovery_reason = 'Repair v1.2 after malformed gh issue edit invocation.'
        }
    }
    $taskJson = $task | ConvertTo-Json -Depth 20
    $apiPayload = [ordered]@{ body = $taskJson }
    $apiFile = Join-Path $StateDir 'issue-update-payload.json'
    $apiPayload | ConvertTo-Json -Depth 30 | Set-Content -Path $apiFile -Encoding UTF8
    & gh.exe api "repos/qluck7/ProjectX/issues/$ControlIssue" --method PATCH --input $apiFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "GitHub API issue update failed with exit code $LASTEXITCODE" }

    $publishedBody = & gh.exe issue view $ControlIssue --repo $RepoName --json body --jq '.body'
    if ($LASTEXITCODE -ne 0) { throw 'Unable to verify the control issue body.' }
    $publishedTask = $publishedBody | ConvertFrom-Json
    if ([string]$publishedTask.task_id -ne $taskId) {
        throw "Control issue verification failed: expected $taskId"
    }

    Write-Host '=== Starting persistent agent and watchdog ===' -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $AgentTaskName
    Start-Sleep -Seconds 5
    Start-ScheduledTask -TaskName $WatchdogTaskName
    Start-Sleep -Seconds 12

    $agentProcesses = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'nocta-vps-agent-v1\.ps1' -and $_.CommandLine -match '-Loop'
    })
    $watchdogProcesses = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'nocta-vps-watchdog-v1\.ps1' -and $_.CommandLine -match '-Loop'
    })
    if ($agentProcesses.Count -eq 0) { throw 'Agent scheduled task did not start.' }
    if ($watchdogProcesses.Count -eq 0) { throw 'Watchdog scheduled task did not start.' }

    $report = [ordered]@{
        status = 'PASS'
        repaired_at = (Get-Date).ToUniversalTime().ToString('o')
        task_id = $taskId
        agent_processes = $agentProcesses.Count
        watchdog_processes = $watchdogProcesses.Count
        agent_task_state = (Get-ScheduledTask -TaskName $AgentTaskName).State.ToString()
        watchdog_task_state = (Get-ScheduledTask -TaskName $WatchdogTaskName).State.ToString()
        repair_log = $RepairLog
    }
    $reportPath = Join-Path $StateDir 'watchdog-repair-v12.json'
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== NOCTA VPS WATCHDOG REPAIR V1.2 PASS ===' -ForegroundColor Green
    $report.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $reportPath"
    Write-Host 'No password is required. RDP may now be disconnected.' -ForegroundColor Yellow
}
catch {
    $failure = [ordered]@{
        status = 'FAIL'
        failed_at = (Get-Date).ToUniversalTime().ToString('o')
        error = $_.Exception.Message
        repair_log = $RepairLog
    }
    $failure | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $StateDir 'watchdog-repair-v12.json') -Encoding UTF8
    Write-Host ''
    Write-Host '=== NOCTA VPS WATCHDOG REPAIR V1.2 FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $RepairLog"
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
