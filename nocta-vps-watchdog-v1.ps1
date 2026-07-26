#requires -Version 5.1

param(
    [switch]$Loop
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\Nocta'
$AgentDir = Join-Path $Root 'control\agent'
$StateDir = Join-Path $AgentDir 'state'
$HistoryDir = Join-Path $StateDir 'history'
$LogDir = Join-Path $Root 'logs\watchdog'
$SegmentsRoot = Join-Path $Root 'data\segments'
$AgentPath = Join-Path $AgentDir 'nocta-vps-agent-v1.ps1'
$RepoName = 'qluck7/ProjectX'
$ControlIssue = 80
$PollSeconds = 30
$HeartbeatSeconds = 120
$CheckpointStaleSeconds = 600
$StartupGraceSeconds = 300

New-Item -ItemType Directory -Force -Path $AgentDir, $StateDir, $HistoryDir, $LogDir, $SegmentsRoot | Out-Null

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $temporary = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 20 | Set-Content -Path $temporary -Encoding UTF8
    Move-Item -Force $temporary $Path
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return Get-Content $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Safe-Id {
    param([Parameter(Mandatory)][string]$Value)
    $safe = $Value -replace '[^A-Za-z0-9._-]', '_'
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0, 120) }
    return $safe
}

function Post-ControlComment {
    param([Parameter(Mandatory)]$Payload)
    $json = $Payload | ConvertTo-Json -Depth 20
    $body = "``````json`n$json`n``````"
    & gh.exe issue comment $ControlIssue --repo $RepoName --body $body | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to post control issue comment: $LASTEXITCODE" }
}

function Get-ControlTask {
    $body = & gh.exe issue view $ControlIssue --repo $RepoName --json body --jq '.body'
    if ($LASTEXITCODE -ne 0) { throw "Unable to read control issue: $LASTEXITCODE" }
    if ([string]::IsNullOrWhiteSpace($body)) { throw 'Control issue body is empty' }
    $task = $body | ConvertFrom-Json
    if ($task.schema -ne 'nocta-vps-control/v1') { throw "Unsupported task schema: $($task.schema)" }
    if ([string]::IsNullOrWhiteSpace([string]$task.task_id)) { throw 'Task id is empty' }
    return $task
}

function Set-ControlTask {
    param([Parameter(Mandatory)]$Task)
    $json = $Task | ConvertTo-Json -Depth 20
    & gh.exe issue edit $ControlIssue --repo $RepoName --body $json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to update control issue: $LASTEXITCODE" }
}

function Get-AgentProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match 'nocta-vps-agent-v1\.ps1' -and
            $_.CommandLine -match '-Loop'
        })
}

function Get-CollectorProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match 'moex_v6_segment\.py'
        })
}

function Stop-ProcessTree {
    param([Parameter(Mandatory)][int]$ProcessId)
    & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
}

function Start-Agent {
    if (-not (Test-Path $AgentPath)) { throw "Agent script is missing: $AgentPath" }
    if ((Get-AgentProcesses).Count -gt 0) { return }
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $AgentPath),
        '-Loop'
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Get-ScalarCheckpoint {
    param([Parameter(Mandatory)]$Checkpoint)
    $summary = [ordered]@{}
    foreach ($property in $Checkpoint.PSObject.Properties) {
        if ($summary.Count -ge 24) { break }
        $value = $property.Value
        if ($null -eq $value -or $value -is [string] -or $value -is [bool] -or $value -is [byte] -or
            $value -is [int16] -or $value -is [int32] -or $value -is [int64] -or
            $value -is [uint16] -or $value -is [uint32] -or $value -is [uint64] -or
            $value -is [single] -or $value -is [double] -or $value -is [decimal]) {
            $summary[$property.Name] = $value
        }
    }
    return $summary
}

function Get-CheckpointState {
    param([Parameter(Mandatory)]$Task)
    $result = [ordered]@{
        exists = $false
        path = $null
        age_seconds = $null
        last_write_utc = $null
        summary = $null
    }
    if ([string]$Task.action -ne 'collect_segment') { return $result }
    $segmentId = [string]$Task.params.segment_id
    if ([string]::IsNullOrWhiteSpace($segmentId)) { return $result }
    $path = Join-Path (Join-Path $SegmentsRoot $segmentId) 'state\segment_checkpoint.json'
    $result.path = $path
    if (-not (Test-Path $path)) { return $result }
    $item = Get-Item $path
    $result.exists = $true
    $result.last_write_utc = $item.LastWriteTimeUtc.ToString('o')
    $result.age_seconds = [math]::Round(((Get-Date).ToUniversalTime() - $item.LastWriteTimeUtc).TotalSeconds, 0)
    $checkpoint = Read-JsonFile -Path $path
    if ($checkpoint) { $result.summary = Get-ScalarCheckpoint -Checkpoint $checkpoint }
    return $result
}

function Get-MaxRuntimeMinutes {
    param([Parameter(Mandatory)]$Task)
    if ($Task.params -and $Task.params.max_runtime_minutes) {
        return [math]::Max(5, [int]$Task.params.max_runtime_minutes)
    }
    switch ([string]$Task.action) {
        'collect_segment' { return 120 }
        'assemble_dataset' { return 90 }
        'validate_segment' { return 30 }
        'codex_task' { return 120 }
        default { return 15 }
    }
}

function Convert-ParamsToHashtable {
    param($Params)
    $copy = [ordered]@{}
    if ($Params) {
        foreach ($property in $Params.PSObject.Properties) {
            $copy[$property.Name] = $property.Value
        }
    }
    return $copy
}

function Publish-Heartbeat {
    param(
        [Parameter(Mandatory)]$Latest,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][double]$ElapsedSeconds,
        [Parameter(Mandatory)]$Checkpoint,
        [Parameter(Mandatory)][int]$AgentProcessCount,
        [Parameter(Mandatory)][int]$CollectorProcessCount
    )
    $payload = [ordered]@{
        schema = 'nocta-vps-agent-heartbeat/v1'
        task_id = [string]$Latest.task_id
        action = [string]$Latest.action
        status = 'HEARTBEAT'
        observed_at = (Get-Date).ToUniversalTime().ToString('o')
        elapsed_seconds = [math]::Round($ElapsedSeconds, 0)
        agent_processes = $AgentProcessCount
        collector_processes = $CollectorProcessCount
        checkpoint = $Checkpoint
        computer = $env:COMPUTERNAME
    }
    Post-ControlComment -Payload $payload
    Write-JsonFile -Path (Join-Path $StateDir 'watchdog-heartbeat.json') -Value $payload
}

function Recover-Task {
    param(
        [Parameter(Mandatory)]$Latest,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$FailureCode,
        [Parameter(Mandatory)]$Checkpoint,
        [switch]$Cancelled
    )

    foreach ($process in (Get-CollectorProcesses)) {
        try { Stop-ProcessTree -ProcessId ([int]$process.ProcessId) } catch {}
    }
    foreach ($process in (Get-AgentProcesses)) {
        try { Stop-ProcessTree -ProcessId ([int]$process.ProcessId) } catch {}
    }

    $terminalStatus = if ($Cancelled) { 'CANCELLED' } else { 'FAIL' }
    $terminal = [ordered]@{
        schema = 'nocta-vps-watchdog-result/v1'
        task_id = [string]$Latest.task_id
        action = [string]$Latest.action
        status = $terminalStatus
        completed_at = (Get-Date).ToUniversalTime().ToString('o')
        failure_code = $FailureCode
        error = $Reason
        checkpoint = $Checkpoint
        computer = $env:COMPUTERNAME
    }
    Post-ControlComment -Payload $terminal
    Write-JsonFile -Path (Join-Path $StateDir 'latest.json') -Value $terminal
    Write-JsonFile -Path (Join-Path $HistoryDir ((Safe-Id -Value ([string]$Latest.task_id)) + '-watchdog.json')) -Value $terminal

    if ($Cancelled) {
        Write-JsonFile -Path (Join-Path $StateDir 'last-task.json') -Value ([ordered]@{
            task_id = [string]$Latest.task_id
            status = 'CANCELLED'
            completed_at = $terminal.completed_at
        })
        return
    }

    $params = Convert-ParamsToHashtable -Params $Task.params
    $attempt = 1
    if ($params.Contains('attempt')) { $attempt = [int]$params['attempt'] }
    $maxAttempts = 3
    if ($params.Contains('max_attempts')) { $maxAttempts = [int]$params['max_attempts'] }
    if ($attempt -ge $maxAttempts) {
        Write-JsonFile -Path (Join-Path $StateDir 'last-task.json') -Value ([ordered]@{
            task_id = [string]$Latest.task_id
            status = 'FAIL'
            completed_at = $terminal.completed_at
        })
        return
    }

    $nextAttempt = $attempt + 1
    $params['attempt'] = $nextAttempt
    $params['max_attempts'] = $maxAttempts
    $params['retry_of'] = [string]$Latest.task_id
    $newTaskId = '{0}-retry-{1}-attempt-{2}' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')), (Safe-Id -Value ([string]$Task.params.segment_id)), $nextAttempt
    $retry = [ordered]@{
        schema = 'nocta-vps-control/v1'
        task_id = $newTaskId
        enabled = $true
        action = [string]$Task.action
        params = $params
    }
    Set-ControlTask -Task $retry
    Remove-Item (Join-Path $StateDir 'last-task.json') -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Start-Agent
}

function Invoke-WatchdogCycle {
    & gh.exe auth status | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated' }

    Start-Agent
    $latest = Read-JsonFile -Path (Join-Path $StateDir 'latest.json')
    if (-not $latest -or [string]$latest.status -ne 'RUNNING') { return }

    $task = Get-ControlTask
    $started = [datetimeoffset]::Parse([string]$latest.started_at)
    $elapsed = ((Get-Date).ToUniversalTime() - $started.UtcDateTime).TotalSeconds
    $agentProcesses = Get-AgentProcesses
    $collectorProcesses = Get-CollectorProcesses
    $checkpoint = Get-CheckpointState -Task $task

    $watchdogStatePath = Join-Path $StateDir 'watchdog-state.json'
    $watchdogState = Read-JsonFile -Path $watchdogStatePath
    $lastHeartbeat = [datetimeoffset]::MinValue
    if ($watchdogState -and $watchdogState.last_heartbeat_at) {
        try { $lastHeartbeat = [datetimeoffset]::Parse([string]$watchdogState.last_heartbeat_at) } catch {}
    }
    if (((Get-Date).ToUniversalTime() - $lastHeartbeat.UtcDateTime).TotalSeconds -ge $HeartbeatSeconds) {
        Publish-Heartbeat -Latest $latest -Task $task -ElapsedSeconds $elapsed -Checkpoint $checkpoint -AgentProcessCount $agentProcesses.Count -CollectorProcessCount $collectorProcesses.Count
        Write-JsonFile -Path $watchdogStatePath -Value ([ordered]@{
            last_heartbeat_at = (Get-Date).ToUniversalTime().ToString('o')
            task_id = [string]$latest.task_id
        })
    }

    $cancelled = $false
    if ($task.cancel_task_id -and [string]$task.cancel_task_id -eq [string]$latest.task_id) { $cancelled = $true }
    if ([string]$task.action -eq 'cancel' -and [string]$task.params.task_id -eq [string]$latest.task_id) { $cancelled = $true }
    if ($cancelled) {
        Recover-Task -Latest $latest -Task $task -Reason 'Task cancelled through control issue.' -FailureCode 'WATCHDOG_REMOTE_CANCEL' -Checkpoint $checkpoint -Cancelled
        return
    }

    $maxRuntimeSeconds = (Get-MaxRuntimeMinutes -Task $task) * 60
    if ($elapsed -gt $maxRuntimeSeconds) {
        Recover-Task -Latest $latest -Task $task -Reason "Task exceeded maximum runtime of $([math]::Round($maxRuntimeSeconds / 60, 0)) minutes." -FailureCode 'WATCHDOG_TIMEOUT' -Checkpoint $checkpoint
        return
    }

    if ([string]$latest.action -eq 'collect_segment' -and $elapsed -gt $StartupGraceSeconds) {
        if ($collectorProcesses.Count -eq 0) {
            Recover-Task -Latest $latest -Task $task -Reason 'Collector process is absent while task is marked RUNNING.' -FailureCode 'WATCHDOG_PROCESS_MISSING' -Checkpoint $checkpoint
            return
        }
        if ($checkpoint.exists -and [double]$checkpoint.age_seconds -gt $CheckpointStaleSeconds) {
            Recover-Task -Latest $latest -Task $task -Reason "Collector checkpoint has not changed for $($checkpoint.age_seconds) seconds." -FailureCode 'WATCHDOG_CHECKPOINT_STALE' -Checkpoint $checkpoint
            return
        }
    }
}

$mutex = [Threading.Mutex]::new($false, 'Global\NoctaVpsWatchdogV1')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    $ready = [ordered]@{
        schema = 'nocta-vps-watchdog-status/v1'
        status = 'READY'
        started_at = (Get-Date).ToUniversalTime().ToString('o')
        computer = $env:COMPUTERNAME
        heartbeat_seconds = $HeartbeatSeconds
        checkpoint_stale_seconds = $CheckpointStaleSeconds
    }
    Write-JsonFile -Path (Join-Path $StateDir 'watchdog-ready.json') -Value $ready
    try { Post-ControlComment -Payload $ready } catch {}

    if ($Loop) {
        while ($true) {
            try {
                Invoke-WatchdogCycle
                Remove-Item (Join-Path $StateDir 'watchdog-error.json') -Force -ErrorAction SilentlyContinue
            }
            catch {
                $failure = [ordered]@{
                    schema = 'nocta-vps-watchdog-error/v1'
                    status = 'WATCHDOG_ERROR'
                    failed_at = (Get-Date).ToUniversalTime().ToString('o')
                    error = $_.Exception.Message
                }
                Write-JsonFile -Path (Join-Path $StateDir 'watchdog-error.json') -Value $failure
            }
            Start-Sleep -Seconds $PollSeconds
        }
    }
    else {
        Invoke-WatchdogCycle
    }
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
