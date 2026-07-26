#requires -Version 5.1

param([switch]$Loop)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\Nocta'
$AgentDir = Join-Path $Root 'control\agent'
$StateDir = Join-Path $AgentDir 'state'
$HistoryDir = Join-Path $StateDir 'history'
$SegmentsRoot = Join-Path $Root 'data\segments'
$RepoName = 'qluck7/ProjectX'
$ControlIssue = 80
$AgentTaskName = 'NoctaVpsAgentV1'
$Version = '2.1'
$PollSeconds = 30
$HeartbeatSeconds = 120
$StartupGraceSeconds = 300
$CheckpointStaleSeconds = 600
$CheckpointMissingSeconds = 900

New-Item -ItemType Directory -Force -Path $StateDir, $HistoryDir, $SegmentsRoot | Out-Null
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-TextNoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Write-JsonFile {
    param([string]$Path, $Value)
    $temporary = "$Path.tmp"
    Write-TextNoBom -Path $temporary -Text (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
    Move-Item -Force $temporary $Path
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Safe-Id {
    param([string]$Value)
    $safe = ([string]$Value) -replace '[^A-Za-z0-9._-]', '_'
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0, 120) }
    return $safe
}

function Post-Comment {
    param($Payload)
    $json = $Payload | ConvertTo-Json -Depth 30
    $body = '```json' + [Environment]::NewLine + $json + [Environment]::NewLine + '```'
    $file = Join-Path $StateDir ("watchdog-comment-{0}.md" -f ([guid]::NewGuid().ToString('N')))
    Write-TextNoBom -Path $file -Text $body
    try {
        & gh.exe issue comment $ControlIssue --repo $RepoName --body-file $file | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to post issue comment: $LASTEXITCODE" }
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
    if ([string]$task.schema -ne 'nocta-vps-control/v1') { throw "Unsupported schema: $($task.schema)" }
    if ([string]::IsNullOrWhiteSpace([string]$task.task_id)) { throw 'Control task id is empty' }
    return $task
}

function Set-ControlTask {
    param($Task)
    $file = Join-Path $StateDir ("watchdog-task-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    Write-TextNoBom -Path $file -Text (($Task | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
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
        $_.CommandLine -and $_.CommandLine -match 'nocta-vps-agent-v1\.ps1' -and $_.CommandLine -match '-Loop'
    })
}

function Get-CollectorProcesses {
    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'moex_v6_segment\.py'
    })
}

function Stop-Tree {
    param([int]$Id)
    & taskkill.exe /PID $Id /T /F 2>$null | Out-Null
}

function Start-Agent {
    if (@(Get-AgentProcesses).Count -gt 0) { return }
    if (Get-ScheduledTask -TaskName $AgentTaskName -ErrorAction SilentlyContinue) {
        Start-ScheduledTask -TaskName $AgentTaskName
        return
    }
    throw "Scheduled task is missing: $AgentTaskName"
}

function Get-Checkpoint {
    param($Task)
    $result = [ordered]@{ exists = $false; path = $null; age_seconds = $null; last_write_utc = $null; summary = $null }
    if ([string]$Task.action -ne 'collect_segment') { return $result }
    $segmentId = [string]$Task.params.segment_id
    if ([string]::IsNullOrWhiteSpace($segmentId)) { return $result }
    $path = Join-Path (Join-Path $SegmentsRoot $segmentId) 'state\segment_checkpoint.json'
    $result.path = $path
    if (-not (Test-Path $path)) { return $result }
    $item = Get-Item $path
    $result.exists = $true
    $result.age_seconds = [math]::Round(((Get-Date).ToUniversalTime() - $item.LastWriteTimeUtc).TotalSeconds, 0)
    $result.last_write_utc = $item.LastWriteTimeUtc.ToString('o')
    $checkpoint = Read-JsonFile $path
    if ($checkpoint) {
        $summary = [ordered]@{}
        foreach ($property in $checkpoint.PSObject.Properties) {
            if ($summary.Count -ge 30) { break }
            $value = $property.Value
            if ($null -eq $value -or $value -is [string] -or $value -is [bool] -or
                $value -is [int16] -or $value -is [int32] -or $value -is [int64] -or
                $value -is [single] -or $value -is [double] -or $value -is [decimal]) {
                $summary[$property.Name] = $value
            }
        }
        $result.summary = $summary
    }
    return $result
}

function Get-SegmentState {
    param($Task)
    $result = [ordered]@{
        manifest_exists = $false; manifest_status = $null
        validation_exists = $false; validation_status = $null
        instrument_count = $null; candle_count = $null; trading_dates = @()
    }
    if ([string]$Task.action -ne 'collect_segment') { return $result }
    $segmentId = [string]$Task.params.segment_id
    if ([string]::IsNullOrWhiteSpace($segmentId)) { return $result }
    $root = Join-Path $SegmentsRoot $segmentId
    $manifest = Read-JsonFile (Join-Path $root 'metadata\dataset_manifest.json')
    $validation = Read-JsonFile (Join-Path $root 'state\latest_validation.json')
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
    param($Task)
    if ($Task.params -and $Task.params.max_runtime_minutes) { return [math]::Max(5, [int]$Task.params.max_runtime_minutes) }
    if ([string]$Task.action -eq 'collect_segment') { return 120 }
    return 60
}

function Publish-Heartbeat {
    param($Latest, $Task, [double]$Elapsed, $Checkpoint, $Segment, [int]$AgentCount, [int]$CollectorCount)
    $payload = [ordered]@{
        schema = 'nocta-vps-agent-heartbeat/v2'
        watchdog_version = $Version
        task_id = [string]$Latest.task_id
        control_task_id = [string]$Task.task_id
        action = [string]$Latest.action
        status = 'HEARTBEAT'
        observed_at = (Get-Date).ToUniversalTime().ToString('o')
        elapsed_seconds = [math]::Round($Elapsed, 0)
        agent_processes = $AgentCount
        collector_processes = $CollectorCount
        checkpoint = $Checkpoint
        segment_state = $Segment
        computer = $env:COMPUTERNAME
    }
    Post-Comment $payload
    Write-JsonFile (Join-Path $StateDir 'watchdog-heartbeat.json') $payload
}

function Finish-Validated {
    param($Latest, $Segment)
    $payload = [ordered]@{
        schema = 'nocta-vps-watchdog-result/v2'
        watchdog_version = $Version
        task_id = [string]$Latest.task_id
        action = [string]$Latest.action
        status = 'PASS'
        completed_at = (Get-Date).ToUniversalTime().ToString('o')
        completion_source = 'WATCHDOG_VALIDATED_SEGMENT_RECOVERY'
        result = $Segment
        computer = $env:COMPUTERNAME
    }
    Write-JsonFile (Join-Path $StateDir 'latest.json') $payload
    Write-JsonFile (Join-Path $StateDir 'last-task.json') ([ordered]@{
        task_id = [string]$Latest.task_id; status = 'PASS'; completed_at = $payload.completed_at
    })
    Write-JsonFile (Join-Path $HistoryDir ((Safe-Id ([string]$Latest.task_id)) + '-watchdog-pass.json')) $payload
    Post-Comment $payload
}

function Convert-Params {
    param($Params)
    $copy = [ordered]@{}
    if ($Params) { foreach ($property in $Params.PSObject.Properties) { $copy[$property.Name] = $property.Value } }
    return $copy
}

function Recover-Task {
    param($Latest, $Task, [string]$Reason, [string]$FailureCode, $Checkpoint)
    try { Stop-ScheduledTask -TaskName $AgentTaskName -ErrorAction SilentlyContinue } catch {}
    foreach ($process in @(Get-CollectorProcesses)) { try { Stop-Tree ([int]$process.ProcessId) } catch {} }
    foreach ($process in @(Get-AgentProcesses)) { try { Stop-Tree ([int]$process.ProcessId) } catch {} }

    $terminal = [ordered]@{
        schema = 'nocta-vps-watchdog-result/v2'
        watchdog_version = $Version
        task_id = [string]$Latest.task_id
        action = [string]$Latest.action
        status = 'FAIL'
        completed_at = (Get-Date).ToUniversalTime().ToString('o')
        failure_code = $FailureCode
        error = $Reason
        checkpoint = $Checkpoint
        computer = $env:COMPUTERNAME
    }
    Write-JsonFile (Join-Path $StateDir 'latest.json') $terminal
    Write-JsonFile (Join-Path $HistoryDir ((Safe-Id ([string]$Latest.task_id)) + '-watchdog-fail.json')) $terminal
    Post-Comment $terminal

    $params = Convert-Params $Task.params
    $attempt = if ($params.Contains('attempt')) { [int]$params['attempt'] } else { 1 }
    $maxAttempts = if ($params.Contains('max_attempts')) { [int]$params['max_attempts'] } else { 3 }
    if ($attempt -ge $maxAttempts) {
        Write-JsonFile (Join-Path $StateDir 'last-task.json') ([ordered]@{
            task_id = [string]$Latest.task_id; status = 'FAIL'; completed_at = $terminal.completed_at
        })
        return
    }

    $nextAttempt = $attempt + 1
    $params['attempt'] = $nextAttempt
    $params['max_attempts'] = $maxAttempts
    $params['retry_of'] = [string]$Latest.task_id
    $segmentName = if ($Task.params.segment_id) { Safe-Id ([string]$Task.params.segment_id) } else { 'task' }
    $retry = [ordered]@{
        schema = 'nocta-vps-control/v1'
        task_id = ('{0}-retry-{1}-attempt-{2}' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')), $segmentName, $nextAttempt)
        enabled = $true
        action = [string]$Task.action
        params = $params
    }
    Set-ControlTask $retry
    Remove-Item (Join-Path $StateDir 'last-task.json') -Force -ErrorAction SilentlyContinue
    Start-Sleep 3
    Start-Agent
}

function Publish-Error {
    param($Record)
    $payload = [ordered]@{
        schema = 'nocta-vps-watchdog-error/v2'
        watchdog_version = $Version
        status = 'WATCHDOG_ERROR'
        failed_at = (Get-Date).ToUniversalTime().ToString('o')
        error = $Record.Exception.Message
        script_stack = $Record.ScriptStackTrace
        computer = $env:COMPUTERNAME
    }
    Write-JsonFile (Join-Path $StateDir 'watchdog-error.json') $payload
    $markerPath = Join-Path $StateDir 'watchdog-error-marker.json'
    $marker = Read-JsonFile $markerPath
    $shouldPost = $true
    if ($marker -and [string]$marker.signature -eq [string]$payload.error -and $marker.posted_at) {
        try {
            $last = [datetimeoffset]::Parse([string]$marker.posted_at)
            if (((Get-Date).ToUniversalTime() - $last.UtcDateTime).TotalSeconds -lt 600) { $shouldPost = $false }
        } catch {}
    }
    if ($shouldPost) {
        try { Post-Comment $payload } catch {}
        Write-JsonFile $markerPath ([ordered]@{ signature = [string]$payload.error; posted_at = (Get-Date).ToUniversalTime().ToString('o') })
    }
}

function Invoke-Cycle {
    & gh.exe auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated' }

    $latest = Read-JsonFile (Join-Path $StateDir 'latest.json')
    if (-not $latest -or [string]$latest.status -ne 'RUNNING') { Start-Agent; return }

    $task = Get-ControlTask
    $started = [datetimeoffset]::Parse([string]$latest.started_at)
    $elapsed = ((Get-Date).ToUniversalTime() - $started.UtcDateTime).TotalSeconds
    $agents = @(Get-AgentProcesses)
    $collectors = @(Get-CollectorProcesses)
    $checkpoint = Get-Checkpoint $task
    $segment = Get-SegmentState $task

    $statePath = Join-Path $StateDir 'watchdog-state.json'
    $state = Read-JsonFile $statePath
    $due = $true
    if ($state -and [string]$state.task_id -eq [string]$latest.task_id -and $state.last_heartbeat_at) {
        try {
            $last = [datetimeoffset]::Parse([string]$state.last_heartbeat_at)
            $due = (((Get-Date).ToUniversalTime() - $last.UtcDateTime).TotalSeconds -ge $HeartbeatSeconds)
        } catch { $due = $true }
    }
    if ($due) {
        Publish-Heartbeat $latest $task $elapsed $checkpoint $segment $agents.Count $collectors.Count
        Write-JsonFile $statePath ([ordered]@{ task_id = [string]$latest.task_id; last_heartbeat_at = (Get-Date).ToUniversalTime().ToString('o') })
    }

    if ([string]$task.task_id -ne [string]$latest.task_id) { throw "Control task mismatch: $($task.task_id) != $($latest.task_id)" }

    if ($segment.manifest_status -eq 'PASS' -and $segment.validation_status -eq 'PASS' -and $collectors.Count -eq 0) {
        Finish-Validated $latest $segment
        return
    }

    $maxSeconds = (Get-MaxRuntimeMinutes $task) * 60
    if ($elapsed -gt $maxSeconds) {
        Recover-Task $latest $task "Task exceeded $([math]::Round($maxSeconds / 60, 0)) minutes." 'WATCHDOG_TIMEOUT' $checkpoint
        return
    }

    if ([string]$latest.action -eq 'collect_segment' -and $elapsed -gt $StartupGraceSeconds) {
        if ($collectors.Count -eq 0 -and $segment.manifest_status -ne 'PASS') {
            Recover-Task $latest $task 'Collector process is absent while task is RUNNING.' 'WATCHDOG_PROCESS_MISSING' $checkpoint
            return
        }
        if ($collectors.Count -gt 0 -and $checkpoint.exists -and [double]$checkpoint.age_seconds -gt $CheckpointStaleSeconds) {
            Recover-Task $latest $task "Checkpoint is stale for $($checkpoint.age_seconds) seconds." 'WATCHDOG_CHECKPOINT_STALE' $checkpoint
            return
        }
        if ($collectors.Count -gt 0 -and -not $checkpoint.exists -and $elapsed -gt $CheckpointMissingSeconds) {
            Recover-Task $latest $task 'Collector did not create a checkpoint.' 'WATCHDOG_CHECKPOINT_MISSING' $checkpoint
            return
        }
    }
}

$mutex = [System.Threading.Mutex]::new($false, 'Global\NoctaVpsWatchdogV21')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    $ready = [ordered]@{
        schema = 'nocta-vps-watchdog-status/v2'
        watchdog_version = $Version
        status = 'READY'
        started_at = (Get-Date).ToUniversalTime().ToString('o')
        computer = $env:COMPUTERNAME
        heartbeat_seconds = $HeartbeatSeconds
        checkpoint_stale_seconds = $CheckpointStaleSeconds
    }
    Write-JsonFile (Join-Path $StateDir 'watchdog-ready.json') $ready
    Post-Comment $ready

    if ($Loop) {
        while ($true) {
            try {
                Invoke-Cycle
                Remove-Item (Join-Path $StateDir 'watchdog-error.json') -Force -ErrorAction SilentlyContinue
            }
            catch { Publish-Error $_ }
            Start-Sleep $PollSeconds
        }
    }
    else {
        try { Invoke-Cycle } catch { Publish-Error $_; exit 2 }
    }
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
