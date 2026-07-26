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
$AgentTaskName = 'NoctaVpsAgentV1'
$PollSeconds = 30
$HeartbeatSeconds = 120
$CheckpointStaleSeconds = 600
$CheckpointMissingSeconds = 900
$StartupGraceSeconds = 300
$WatchdogVersion = '2.0'

New-Item -ItemType Directory -Force -Path $AgentDir, $StateDir, $HistoryDir, $LogDir, $SegmentsRoot | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-TextNoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $temporary = "$Path.tmp"
    $json = $Value | ConvertTo-Json -Depth 30
    Write-TextNoBom -Path $temporary -Text ($json + "`r`n")
    Move-Item -Force $temporary $Path
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Safe-Id {
    param([Parameter(Mandatory)][string]$Value)
    $safe = $Value -replace '[^A-Za-z0-9._-]', '_'
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0, 120) }
    return $safe
}

function Post-ControlComment {
    param([Parameter(Mandatory)]$Payload)
    $json = $Payload | ConvertTo-Json -Depth 30
    $body = "```json`r`n$json`r`n```"
    $file = Join-Path $StateDir ("watchdog-comment-{0}.md" -f ([guid]::NewGuid().ToString('N')))
    Write-TextNoBom -Path $file -Text $body
    try {
        & gh.exe issue comment $ControlIssue --repo $RepoName --body-file $file | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to post control comment: $LASTEXITCODE" }
    }
    finally {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

function Get-ControlTask {
    $body = (& gh.exe issue view $ControlIssue --repo $RepoName --json body --jq '.body' | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Unable to read control issue: $LASTEXITCODE" }
    if ([string]::IsNullOrWhiteSpace($body)) { throw 'Control issue body is empty' }
    $task = $body | ConvertFrom-Json
    if ($task.schema -ne 'nocta-vps-control/v1') { throw "Unsupported task schema: $($task.schema)" }
    if ([string]::IsNullOrWhiteSpace([string]$task.task_id)) { throw 'Task id is empty' }
    return $task
}

function Set-ControlTask {
    param([Parameter(Mandatory)]$Task)
    $file = Join-Path $StateDir ("watchdog-task-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    Write-TextNoBom -Path $file -Text (($Task | ConvertTo-Json -Depth 30) + "`r`n")
    try {
        & gh.exe issue edit $ControlIssue --repo $RepoName --body-file $file | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to update control issue: $LASTEXITCODE" }
    }
    finally {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

function Get-AgentProcesses {
    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match 'nocta-vps-agent-v1\.ps1' -and
        $_.CommandLine -match '-Loop'
    })
}

function Get-CollectorProcesses {
    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'moex_v6_segment\.py'
    })
}

function Stop-ProcessTree {
    param([Parameter(Mandatory)][int]$ProcessId)
    & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
}

function Start-AgentTask {
    if ((Get-AgentProcesses).Count -gt 0) { return }
    $scheduled = Get-ScheduledTask -TaskName $AgentTaskName -ErrorAction SilentlyContinue
    if ($scheduled) {
        Start-ScheduledTask -TaskName $AgentTaskName
        return
    }
    if (-not (Test-Path $AgentPath)) { throw "Agent script is missing: $AgentPath" }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $AgentPath), '-Loop'
    ) -WindowStyle Hidden | Out-Null
}

function Get-ScalarCheckpoint {
    param([Parameter(Mandatory)]$Checkpoint)
    $summary = [ordered]@{}
    foreach ($property in $Checkpoint.PSObject.Properties) {
        if ($summary.Count -ge 30) { break }
        $value = $property.Value
        if ($null -eq $value -or $value -is [string] -or $value -is [bool] -or
            $value -is [int16] -or $value -is [int32] -or $value -is [int64] -or
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

function Get-SegmentState {
    param([Parameter(Mandatory)]$Task)
    $result = [ordered]@{
        manifest_exists = $false
        manifest_status = $null
        validation_exists = $false
        validation_status = $null
        instrument_count = $null
        candle_count = $null
        trading_dates = @()
    }
    if ([string]$Task.action -ne 'collect_segment') { return $result }
    $segmentId = [string]$Task.params.segment_id
    if ([string]::IsNullOrWhiteSpace($segmentId)) { return $result }
    $root = Join-Path $SegmentsRoot $segmentId
    $manifestPath = Join-Path $root 'metadata\dataset_manifest.json'
    $validationPath = Join-Path $root 'state\latest_validation.json'
    $manifest = Read-JsonFile -Path $manifestPath
    $validation = Read-JsonFile -Path $validationPath
    if ($manifest) {
        $result.manifest_exists = $true
        $result.manifest_status = [string]$manifest.status
        $result.instrument_count = $manifest.instrument_count
        $result.candle_count = $manifest.candle_count
        $result.trading_dates = @($manifest.trading_dates)
    }
    if ($validation) {
        $result.validation_exists = $true
        $result.validation_status = [string]$validation.status
    }
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
        [Parameter(Mandatory)]$SegmentState,
        [Parameter(Mandatory)][int]$AgentProcessCount,
        [Parameter(Mandatory)][int]$CollectorProcessCount
    )
    $payload = [ordered]@{
        schema = 'nocta-vps-agent-heartbeat/v2'
        watchdog_version = $WatchdogVersion
        task_id = [string]$Latest.task_id
        control_task_id = [string]$Task.task_id
        action = [string]$Latest.action
        status = 'HEARTBEAT'
        observed_at = (Get-Date).ToUniversalTime().ToString('o')
        elapsed_seconds = [math]::Round($ElapsedSeconds, 0)
        agent_processes = $AgentProcessCount
        collector_processes = $CollectorProcessCount
        checkpoint = $Checkpoint
        segment_state = $SegmentState
        computer = $env:COMPUTERNAME
    }
    Post-ControlComment -Payload $payload
    Write-JsonFile -Path (Join-Path $StateDir 'watchdog-heartbeat.json') -Value $payload
}

function Complete-FromValidatedSegment {
    param(
        [Parameter(Mandatory)]$Latest,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$SegmentState
    )
    $completed = [ordered]@{
        schema = 'nocta-vps-watchdog-result/v2'
        watchdog_version = $WatchdogVersion
        task_id = [string]$Latest.task_id
        action = [string]$Latest.action
        status = 'PASS'
        completed_at = (Get-Date).ToUniversalTime().ToString('o')
        completion_source = 'WATCHDOG_VALIDATED_SEGMENT_RECOVERY'
        result = $SegmentState
        computer = $env:COMPUTERNAME
    }
    Write-JsonFile -Path (Join-Path $StateDir 'latest.json') -Value $completed
    Write-JsonFile -Path (Join-Path $StateDir 'last-task.json') -Value ([ordered]@{
        task_id = [string]$Latest.task_id
        status = 'PASS'
        completed_at = $completed.completed_at
    })
    Write-JsonFile -Path (Join-Path $HistoryDir ((Safe-Id -Value ([string]$Latest.task_id)) + '-watchdog-pass.json')) -Value $completed
    Post-ControlComment -Payload $completed
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
    try { Stop-ScheduledTask -TaskName $AgentTaskName -ErrorAction SilentlyContinue } catch {}
    foreach ($process in (Get-CollectorProcesses)) {
        try { Stop-ProcessTree -ProcessId ([int]$process.ProcessId) } catch {}
    }
    foreach ($process in (Get-AgentProcesses)) {
        try { Stop-ProcessTree -ProcessId ([int]$process.ProcessId) } catch {}
    }

    $terminalStatus = if ($Cancelled) { 'CANCELLED' } else { 'FAIL' }
    $terminal = [ordered]@{
        schema = 'nocta-vps-watchdog-result/v2'
        watchdog_version = $WatchdogVersion
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
    $attempt = if ($params.Contains('attempt')) { [int]$params['attempt'] } else { 1 }
    $maxAttempts = if ($params.Contains('max_attempts')) { [int]$params['max_attempts'] } else { 3 }
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
    Start-AgentTask
}

function Publish-WatchdogError {
    param([Parameter(Mandatory)]$Exception)
    $failure = [ordered]@{
        schema = 'nocta-vps-watchdog-error/v2'
        watchdog_version = $WatchdogVersion
        status = 'WATCHDOG_ERROR'
        failed_at = (Get-Date).ToUniversalTime().ToString('o')
        error = $Exception.Exception.Message
        script_stack = $Exception.ScriptStackTrace
        computer = $env:COMPUTERNAME
    }
    Write-JsonFile -Path (Join-Path $StateDir 'watchdog-error.json') -Value $failure

    $markerPath = Join-Path $StateDir 'watchdog-error-marker.json'
    $marker = Read-JsonFile -Path $markerPath
    $signature = [string]$failure.error
    $post = $true
    if ($marker -and [string]$marker.signature -eq $signature -and $marker.posted_at) {
        try {
            $posted = [datetimeoffset]::Parse([string]$marker.posted_at)
            if (((Get-Date).ToUniversalTime() - $posted.UtcDateTime).TotalSeconds -lt 600) { $post = $false }
        } catch {}
    }
    if ($post) {
        try { Post-ControlComment -Payload $failure } catch {}
        Write-JsonFile -Path $markerPath -Value ([ordered]@{
            signature = $signature
            posted_at = (Get-Date).ToUniversalTime().ToString('o')
        })
    }
}

function Invoke-WatchdogCycle {
    & gh.exe auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated' }

    $latest = Read-JsonFile -Path (Join-Path $StateDir 'latest.json')
    if (-not $latest -or [string]$latest.status -ne 'RUNNING') {
        Start-AgentTask
        return
    }

    $task = Get-ControlTask
    $started = [datetimeoffset]::Parse([string]$latest.started_at)
    $elapsed = ((Get-Date).ToUniversalTime() - $started.UtcDateTime).TotalSeconds
    $agentProcesses = @(Get-AgentProcesses)
    $collectorProcesses = @(Get-CollectorProcesses)
    $checkpoint = Get-CheckpointState -Task $task
    $segmentState = Get-SegmentState -Task $task

    $watchdogStatePath = Join-Path $StateDir 'watchdog-state.json'
    $watchdogState = Read-JsonFile -Path $watchdogStatePath
    $heartbeatDue = $true
    if ($watchdogState -and [string]$watchdogState.task_id -eq [string]$latest.task_id -and $watchdogState.last_heartbeat_at) {
        try {
            $lastHeartbeat = [datetimeoffset]::Parse([string]$watchdogState.last_heartbeat_at)
            $heartbeatDue = (((Get-Date).ToUniversalTime() - $lastHeartbeat.UtcDateTime).TotalSeconds -ge $HeartbeatSeconds)
        } catch { $heartbeatDue = $true }
    }
    if ($heartbeatDue) {
        Publish-Heartbeat -Latest $latest -Task $task -ElapsedSeconds $elapsed -Checkpoint $checkpoint -SegmentState $segmentState -AgentProcessCount $agentProcesses.Count -CollectorProcessCount $collectorProcesses.Count
        Write-JsonFile -Path $watchdogStatePath -Value ([ordered]@{
            last_heartbeat_at = (Get-Date).ToUniversalTime().ToString('o')
            task_id = [string]$latest.task_id
        })
    }

    if ([string]$task.task_id -ne [string]$latest.task_id) {
        throw "Control task $($task.task_id) does not match running task $($latest.task_id)"
    }

    $cancelled = $false
    if ($task.cancel_task_id -and [string]$task.cancel_task_id -eq [string]$latest.task_id) { $cancelled = $true }
    if ([string]$task.action -eq 'cancel' -and [string]$task.params.task_id -eq [string]$latest.task_id) { $cancelled = $true }
    if ($cancelled) {
        Recover-Task -Latest $latest -Task $task -Reason 'Task cancelled through control issue.' -FailureCode 'WATCHDOG_REMOTE_CANCEL' -Checkpoint $checkpoint -Cancelled
        return
    }

    if ($segmentState.manifest_status -eq 'PASS' -and $segmentState.validation_status -eq 'PASS' -and $collectorProcesses.Count -eq 0) {
        Complete-FromValidatedSegment -Latest $latest -Task $task -SegmentState $segmentState
        return
    }

    $maxRuntimeSeconds = (Get-MaxRuntimeMinutes -Task $task) * 60
    if ($elapsed -gt $maxRuntimeSeconds) {
        Recover-Task -Latest $latest -Task $task -Reason "Task exceeded maximum runtime of $([math]::Round($maxRuntimeSeconds / 60, 0)) minutes." -FailureCode 'WATCHDOG_TIMEOUT' -Checkpoint $checkpoint
        return
    }

    if ([string]$latest.action -eq 'collect_segment' -and $elapsed -gt $StartupGraceSeconds) {
        if ($collectorProcesses.Count -eq 0 -and $segmentState.manifest_status -ne 'PASS') {
            Recover-Task -Latest $latest -Task $task -Reason 'Collector process is absent while task is marked RUNNING.' -FailureCode 'WATCHDOG_PROCESS_MISSING' -Checkpoint $checkpoint
            return
        }
        if ($collectorProcesses.Count -gt 0 -and $checkpoint.exists -and [double]$checkpoint.age_seconds -gt $CheckpointStaleSeconds) {
            Recover-Task -Latest $latest -Task $task -Reason "Collector checkpoint has not changed for $($checkpoint.age_seconds) seconds." -FailureCode 'WATCHDOG_CHECKPOINT_STALE' -Checkpoint $checkpoint
            return
        }
        if ($collectorProcesses.Count -gt 0 -and -not $checkpoint.exists -and $elapsed -gt $CheckpointMissingSeconds) {
            Recover-Task -Latest $latest -Task $task -Reason 'Collector did not create a checkpoint within the allowed period.' -FailureCode 'WATCHDOG_CHECKPOINT_MISSING' -Checkpoint $checkpoint
            return
        }
    }
}

$mutex = New-Object Threading.Mutex($false, 'Global\NoctaVpsWatchdogV2')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    $ready = [ordered]@{
        schema = 'nocta-vps-watchdog-status/v2'
        watchdog_version = $WatchdogVersion
        status = 'READY'
        started_at = (Get-Date).ToUniversalTime().ToString('o')
        computer = $env:COMPUTERNAME
        heartbeat_seconds = $HeartbeatSeconds
        checkpoint_stale_seconds = $CheckpointStaleSeconds
        checkpoint_missing_seconds = $CheckpointMissingSeconds
    }
    Write-JsonFile -Path (Join-Path $StateDir 'watchdog-ready.json') -Value $ready
    Post-ControlComment -Payload $ready

    if ($Loop) {
        while ($true) {
            try {
                Invoke-WatchdogCycle
                Remove-Item (Join-Path $StateDir 'watchdog-error.json') -Force -ErrorAction SilentlyContinue
            }
            catch {
                Publish-WatchdogError -Exception $_
            }
            Start-Sleep -Seconds $PollSeconds
        }
    }
    else {
        try { Invoke-WatchdogCycle } catch { Publish-WatchdogError -Exception $_; exit 2 }
    }
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
