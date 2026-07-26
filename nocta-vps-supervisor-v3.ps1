#requires -Version 5.1

param(
    [switch]$Loop
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Version = '3.0'
$Root = 'C:\Nocta'
$ControlDir = Join-Path $Root 'control\supervisor-v3'
$StateDir = Join-Path $ControlDir 'state'
$HistoryDir = Join-Path $StateDir 'history'
$LogDir = Join-Path $Root 'logs\supervisor-v3'
$SegmentsRoot = Join-Path $Root 'data\segments'
$CollectorRepo = Join-Path $Root 'collector\ProjectX'
$Python = 'C:\Python312\python.exe'
$RepoName = 'qluck7/ProjectX'
$ControlIssue = 80
$PollSeconds = 10
$GithubHeartbeatSeconds = 120
$CheckpointStaleSeconds = 600
$CheckpointMissingSeconds = 600
$DefaultRuntimeMinutes = 60
$TaskName = 'NoctaVpsSupervisorV3'

New-Item -ItemType Directory -Force -Path $ControlDir, $StateDir, $HistoryDir, $LogDir, $SegmentsRoot | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-TextNoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $tmp = "$Path.tmp"
    Write-TextNoBom -Path $tmp -Text (($Value | ConvertTo-Json -Depth 40) + "`r`n")
    Move-Item -Force $tmp $Path
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return Get-Content $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Safe-Id {
    param([Parameter(Mandatory)][string]$Value)
    $safe = $Value -replace '[^A-Za-z0-9._-]', '_'
    if ($safe.Length -gt 100) { $safe = $safe.Substring(0, 100) }
    return $safe
}

function Invoke-Gh {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & gh.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh failed ($LASTEXITCODE): $($output | Out-String)" }
    return $output
}

function Post-Comment {
    param([Parameter(Mandatory)]$Payload)
    $body = "```json`r`n$($Payload | ConvertTo-Json -Depth 40)`r`n```"
    $file = Join-Path $StateDir ("comment-{0}.md" -f ([guid]::NewGuid().ToString('N')))
    Write-TextNoBom -Path $file -Text $body
    try { [void](Invoke-Gh -Arguments @('issue','comment',[string]$ControlIssue,'--repo',$RepoName,'--body-file',$file)) }
    finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
}

function Get-ControlTask {
    $body = (Invoke-Gh -Arguments @('issue','view',[string]$ControlIssue,'--repo',$RepoName,'--json','body','--jq','.body') | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($body)) { throw 'Control issue body is empty.' }
    $task = $body | ConvertFrom-Json
    if ([string]$task.schema -ne 'nocta-vps-control/v1') { throw "Unsupported schema: $($task.schema)" }
    if ([string]::IsNullOrWhiteSpace([string]$task.task_id)) { throw 'Control task_id is empty.' }
    return $task
}

function Set-ControlTask {
    param([Parameter(Mandatory)]$Task)
    $file = Join-Path $StateDir ("task-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    Write-TextNoBom -Path $file -Text (($Task | ConvertTo-Json -Depth 40) + "`r`n")
    try { [void](Invoke-Gh -Arguments @('issue','edit',[string]$ControlIssue,'--repo',$RepoName,'--body-file',$file)) }
    finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
}

function Get-SegmentPlanSpec {
    param([Parameter(Mandatory)][string]$SegmentId)
    $planPath = Join-Path $CollectorRepo 'config\moex_operational_v62_segments.json'
    if (-not (Test-Path $planPath)) { throw "Segment plan missing: $planPath" }
    $plan = Get-Content $planPath -Raw | ConvertFrom-Json
    $matches = @($plan.segments | Where-Object { [string]$_.id -eq $SegmentId })
    if ($matches.Count -ne 1) { throw "Segment absent or ambiguous: $SegmentId" }
    return $matches[0]
}

function Get-CheckpointState {
    param([Parameter(Mandatory)][string]$SegmentId)
    $path = Join-Path (Join-Path $SegmentsRoot $SegmentId) 'state\segment_checkpoint.json'
    $result = [ordered]@{ exists=$false; path=$path; age_seconds=$null; last_write_utc=$null; status=$null; pid=$null; heartbeat_at=$null }
    if (-not (Test-Path $path)) { return $result }
    $item = Get-Item $path
    $checkpoint = Read-JsonFile -Path $path
    $result.exists = $true
    $result.age_seconds = [math]::Round(((Get-Date).ToUniversalTime() - $item.LastWriteTimeUtc).TotalSeconds,0)
    $result.last_write_utc = $item.LastWriteTimeUtc.ToString('o')
    if ($checkpoint) {
        $result.status = [string]$checkpoint.status
        $result.pid = $checkpoint.pid
        $result.heartbeat_at = $checkpoint.heartbeat_at
    }
    return $result
}

function Get-SegmentState {
    param([Parameter(Mandatory)][string]$SegmentId)
    $root = Join-Path $SegmentsRoot $SegmentId
    $manifestPath = Join-Path $root 'metadata\dataset_manifest.json'
    $validationPath = Join-Path $root 'state\latest_validation.json'
    $manifest = Read-JsonFile -Path $manifestPath
    $validation = Read-JsonFile -Path $validationPath
    $bytes = 0
    if (Test-Path $root) { $bytes = [int64]((Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) }
    return [ordered]@{
        root=$root
        manifest_exists=[bool]$manifest
        manifest_status=if($manifest){[string]$manifest.status}else{$null}
        validation_exists=[bool]$validation
        validation_status=if($validation){[string]$validation.status}else{$null}
        instrument_count=if($manifest){$manifest.instrument_count}else{$null}
        candle_count=if($manifest){$manifest.candle_count}else{$null}
        trading_dates=if($manifest){@($manifest.trading_dates)}else{@()}
        bytes=$bytes
        mib=[math]::Round($bytes/1MB,2)
    }
}

function Stop-ProcessTree {
    param([Parameter(Mandatory)][int]$ProcessId)
    try { & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null } catch {}
}

function Stop-LegacyProcesses {
    $patterns = @('nocta-vps-agent-v1\.ps1','nocta-vps-watchdog-v1\.ps1','moex_v6_segment\.py')
    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        $line = [string]$_.CommandLine
        if (-not $line -or $_.ProcessId -eq $PID) { return $false }
        foreach ($pattern in $patterns) { if ($line -match $pattern) { return $true } }
        return $false
    })
    foreach ($process in $processes) { Stop-ProcessTree -ProcessId ([int]$process.ProcessId) }
}

function New-RunContext {
    param([Parameter(Mandatory)]$Task)
    $segmentId = [string]$Task.params.segment_id
    $safe = Safe-Id -Value ([string]$Task.task_id)
    $runDir = Join-Path $ControlDir ("runs\$safe")
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    return [ordered]@{
        task_id=[string]$Task.task_id
        segment_id=$segmentId
        safe_id=$safe
        run_dir=$runDir
        stdout=Join-Path $runDir 'collector.stdout.log'
        stderr=Join-Path $runDir 'collector.stderr.log'
        state=Join-Path $runDir 'run-state.json'
        started_at=(Get-Date).ToUniversalTime().ToString('o')
    }
}

function Start-SegmentProcess {
    param([Parameter(Mandatory)]$Task)
    $segmentId = [string]$Task.params.segment_id
    if ([string]::IsNullOrWhiteSpace($segmentId)) { throw 'segment_id is required.' }
    if (-not (Test-Path $Python)) { throw "Python missing: $Python" }
    if (-not (Test-Path (Join-Path $CollectorRepo '.git'))) { throw "Collector repo missing: $CollectorRepo" }

    $spec = Get-SegmentPlanSpec -SegmentId $segmentId
    $ctx = New-RunContext -Task $Task
    $output = Join-Path $SegmentsRoot $segmentId
    if (Test-Path $output) {
        $archiveRoot = Join-Path $SegmentsRoot '_failed_archives'
        New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
        $archive = Join-Path $archiveRoot ("{0}-{1}" -f $segmentId,(Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -Force $output $archive
    }
    New-Item -ItemType Directory -Force -Path $output | Out-Null

    & git.exe -C $CollectorRepo fetch origin agent/moex-v62-segmented 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Collector branch fetch failed.' }
    & git.exe -C $CollectorRepo reset --hard origin/agent/moex-v62-segmented 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Collector branch reset failed.' }

    $args = @(
        '-u','tools\moex_v6_segment.py',
        '--segment-id',$segmentId,
        '--scope',[string]$spec.scope,
        '--partition-count',[string]$spec.partition_count,
        '--partition-index',[string]$spec.partition_index,
        '--output',$output,
        '--config','config\moex_operational_v6.json',
        '--heartbeat-seconds','20'
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$spec.board)) { $args += @('--board',[string]$spec.board) }

    $oldPythonPath = $env:PYTHONPATH
    $env:PYTHONPATH = $CollectorRepo
    try {
        $process = Start-Process -FilePath $Python -ArgumentList $args -WorkingDirectory $CollectorRepo -RedirectStandardOutput $ctx.stdout -RedirectStandardError $ctx.stderr -PassThru -WindowStyle Hidden
    }
    finally { $env:PYTHONPATH = $oldPythonPath }

    $ctx.process_id = [int]$process.Id
    $ctx.output = $output
    $ctx.command = "$Python $($args -join ' ')"
    Write-JsonFile -Path $ctx.state -Value $ctx
    Write-JsonFile -Path (Join-Path $StateDir 'active-run.json') -Value $ctx
    return $ctx
}

function Validate-Segment {
    param([Parameter(Mandatory)][string]$SegmentId)
    $output = Join-Path $SegmentsRoot $SegmentId
    $oldPythonPath = $env:PYTHONPATH
    $env:PYTHONPATH = $CollectorRepo
    try { & $Python -u (Join-Path $CollectorRepo 'tools\moex_v6_validate.py') --output $output 2>&1 | Tee-Object -FilePath (Join-Path $LogDir ("validate-$SegmentId-$(Get-Date -Format yyyyMMdd-HHmmss).log")) }
    finally { $env:PYTHONPATH = $oldPythonPath }
    if ($LASTEXITCODE -ne 0) { throw "Validation failed for $SegmentId with exit code $LASTEXITCODE" }
    $state = Get-SegmentState -SegmentId $SegmentId
    if ($state.manifest_status -ne 'PASS' -or $state.validation_status -ne 'PASS') { throw "Validated segment is not PASS: $SegmentId" }
    return $state
}

function Publish-Status {
    param([Parameter(Mandatory)][string]$Status, [Parameter(Mandatory)]$Task, $Context, $Extra)
    $segmentId = [string]$Task.params.segment_id
    $payload = [ordered]@{
        schema='nocta-vps-supervisor-result/v3'
        supervisor_version=$Version
        task_id=[string]$Task.task_id
        action=[string]$Task.action
        status=$Status
        observed_at=(Get-Date).ToUniversalTime().ToString('o')
        computer=$env:COMPUTERNAME
        segment_id=$segmentId
        process_id=if($Context){$Context.process_id}else{$null}
        checkpoint=if($segmentId){Get-CheckpointState -SegmentId $segmentId}else{$null}
        segment_state=if($segmentId){Get-SegmentState -SegmentId $segmentId}else{$null}
        extra=$Extra
    }
    Write-JsonFile -Path (Join-Path $StateDir 'latest.json') -Value $payload
    Post-Comment -Payload $payload
    return $payload
}

function Get-MaxRuntimeMinutes {
    param([Parameter(Mandatory)]$Task)
    if ($Task.params -and $Task.params.max_runtime_minutes) { return [math]::Max(5,[int]$Task.params.max_runtime_minutes) }
    return $DefaultRuntimeMinutes
}

function Run-ControlTask {
    param([Parameter(Mandatory)]$Task)
    if (-not [bool]$Task.enabled) { return }
    if ([string]$Task.action -ne 'collect_segment') { throw "Supervisor v3 currently supports collect_segment only, got: $($Task.action)" }

    $last = Read-JsonFile -Path (Join-Path $StateDir 'last-task.json')
    if ($last -and [string]$last.task_id -eq [string]$Task.task_id -and [string]$last.status -in @('PASS','FAIL','CANCELLED')) { return }

    Stop-LegacyProcesses
    $ctx = Start-SegmentProcess -Task $Task
    [void](Publish-Status -Status 'RUNNING' -Task $Task -Context $ctx -Extra ([ordered]@{message='Collector started under supervisor v3.'}))

    $started = [datetimeoffset]::Parse([string]$ctx.started_at)
    $lastGithubHeartbeat = [datetimeoffset]::MinValue
    $missingSince = $null
    $lastCheckpointWrite = $null

    while ($true) {
        Start-Sleep -Seconds $PollSeconds
        $process = Get-Process -Id ([int]$ctx.process_id) -ErrorAction SilentlyContinue
        $elapsed = ((Get-Date).ToUniversalTime() - $started.UtcDateTime).TotalSeconds
        $checkpoint = Get-CheckpointState -SegmentId ([string]$ctx.segment_id)

        if ($checkpoint.exists) {
            $missingSince = $null
            $lastCheckpointWrite = $checkpoint.last_write_utc
        } elseif (-not $missingSince) {
            $missingSince = (Get-Date).ToUniversalTime()
        }

        if (((Get-Date).ToUniversalTime() - $lastGithubHeartbeat.UtcDateTime).TotalSeconds -ge $GithubHeartbeatSeconds) {
            [void](Publish-Status -Status 'HEARTBEAT' -Task $Task -Context $ctx -Extra ([ordered]@{elapsed_seconds=[math]::Round($elapsed,0); process_alive=[bool]$process; last_checkpoint_write=$lastCheckpointWrite}))
            $lastGithubHeartbeat = [datetimeoffset](Get-Date).ToUniversalTime()
        }

        if (-not $process) {
            $exitCode = $null
            try { $ctxProcess = [System.Diagnostics.Process]::GetProcessById([int]$ctx.process_id); $exitCode = $ctxProcess.ExitCode } catch {}
            try {
                $segmentState = Validate-Segment -SegmentId ([string]$ctx.segment_id)
                [void](Publish-Status -Status 'PASS' -Task $Task -Context $ctx -Extra ([ordered]@{exit_code=$exitCode; validation=$segmentState}))
                Write-JsonFile -Path (Join-Path $StateDir 'last-task.json') -Value ([ordered]@{task_id=[string]$Task.task_id;status='PASS';completed_at=(Get-Date).ToUniversalTime().ToString('o')})
            }
            catch {
                $tailOut = if(Test-Path $ctx.stdout){@(Get-Content $ctx.stdout -Tail 80)}else{@()}
                $tailErr = if(Test-Path $ctx.stderr){@(Get-Content $ctx.stderr -Tail 80)}else{@()}
                [void](Publish-Status -Status 'FAIL' -Task $Task -Context $ctx -Extra ([ordered]@{exit_code=$exitCode;error=$_.Exception.Message;stdout_tail=$tailOut;stderr_tail=$tailErr}))
                Write-JsonFile -Path (Join-Path $StateDir 'last-task.json') -Value ([ordered]@{task_id=[string]$Task.task_id;status='FAIL';completed_at=(Get-Date).ToUniversalTime().ToString('o')})
            }
            return
        }

        if ($elapsed -gt ((Get-MaxRuntimeMinutes -Task $Task) * 60)) {
            Stop-ProcessTree -ProcessId ([int]$ctx.process_id)
            $tailOut = if(Test-Path $ctx.stdout){@(Get-Content $ctx.stdout -Tail 80)}else{@()}
            $tailErr = if(Test-Path $ctx.stderr){@(Get-Content $ctx.stderr -Tail 80)}else{@()}
            [void](Publish-Status -Status 'FAIL' -Task $Task -Context $ctx -Extra ([ordered]@{failure_code='SUPERVISOR_TIMEOUT';elapsed_seconds=[math]::Round($elapsed,0);stdout_tail=$tailOut;stderr_tail=$tailErr}))
            Write-JsonFile -Path (Join-Path $StateDir 'last-task.json') -Value ([ordered]@{task_id=[string]$Task.task_id;status='FAIL';completed_at=(Get-Date).ToUniversalTime().ToString('o')})
            return
        }

        if ($checkpoint.exists -and [double]$checkpoint.age_seconds -gt $CheckpointStaleSeconds) {
            Stop-ProcessTree -ProcessId ([int]$ctx.process_id)
            [void](Publish-Status -Status 'FAIL' -Task $Task -Context $ctx -Extra ([ordered]@{failure_code='SUPERVISOR_CHECKPOINT_STALE';checkpoint_age_seconds=$checkpoint.age_seconds}))
            Write-JsonFile -Path (Join-Path $StateDir 'last-task.json') -Value ([ordered]@{task_id=[string]$Task.task_id;status='FAIL';completed_at=(Get-Date).ToUniversalTime().ToString('o')})
            return
        }

        if ($missingSince -and (((Get-Date).ToUniversalTime() - $missingSince).TotalSeconds -gt $CheckpointMissingSeconds)) {
            Stop-ProcessTree -ProcessId ([int]$ctx.process_id)
            [void](Publish-Status -Status 'FAIL' -Task $Task -Context $ctx -Extra ([ordered]@{failure_code='SUPERVISOR_CHECKPOINT_MISSING'}))
            Write-JsonFile -Path (Join-Path $StateDir 'last-task.json') -Value ([ordered]@{task_id=[string]$Task.task_id;status='FAIL';completed_at=(Get-Date).ToUniversalTime().ToString('o')})
            return
        }
    }
}

function Invoke-OneCycle {
    [void](Invoke-Gh -Arguments @('auth','status'))
    $task = Get-ControlTask
    if (-not [bool]$task.enabled) { return }
    Run-ControlTask -Task $task
}

$mutex = [Threading.Mutex]::new($false,'Global\NoctaVpsSupervisorV3')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    $ready = [ordered]@{schema='nocta-vps-supervisor-status/v3';status='READY';supervisor_version=$Version;started_at=(Get-Date).ToUniversalTime().ToString('o');computer=$env:COMPUTERNAME}
    Write-JsonFile -Path (Join-Path $StateDir 'ready.json') -Value $ready
    try { Post-Comment -Payload $ready } catch {}
    if ($Loop) {
        while ($true) {
            try { Invoke-OneCycle }
            catch {
                $errorPayload = [ordered]@{schema='nocta-vps-supervisor-error/v3';status='SUPERVISOR_ERROR';supervisor_version=$Version;failed_at=(Get-Date).ToUniversalTime().ToString('o');error=$_.Exception.Message;computer=$env:COMPUTERNAME}
                Write-JsonFile -Path (Join-Path $StateDir 'error.json') -Value $errorPayload
                try { Post-Comment -Payload $errorPayload } catch {}
            }
            Start-Sleep -Seconds 30
        }
    } else { Invoke-OneCycle }
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
