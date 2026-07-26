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
$LogDir = Join-Path $Root 'logs\agent'
$CollectorRepo = Join-Path $Root 'collector\ProjectX'
$NoctaRepo = Join-Path $Root 'development\NoctaDev'
$SegmentsRoot = Join-Path $Root 'data\segments'
$AssembledRoot = Join-Path $Root 'data\assembled'
$Python = 'C:\Python312\python.exe'
$RepoName = 'qluck7/ProjectX'
$ControlIssue = 80
$PollSeconds = 60

New-Item -ItemType Directory -Force -Path $AgentDir, $StateDir, $HistoryDir, $LogDir, $SegmentsRoot, $AssembledRoot | Out-Null

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

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    & git.exe -C $WorkingDirectory @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ('git failed in {0}: {1}' -f $WorkingDirectory, ($Arguments -join ' '))
    }
}

function Read-SegmentResult {
    param([Parameter(Mandatory)][string]$SegmentId)
    $root = Join-Path $SegmentsRoot $SegmentId
    $manifestPath = Join-Path $root 'metadata\dataset_manifest.json'
    $validationPath = Join-Path $root 'state\latest_validation.json'
    if (-not (Test-Path $manifestPath)) { throw "Manifest missing for $SegmentId" }
    if (-not (Test-Path $validationPath)) { throw "Validation missing for $SegmentId" }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $validation = Get-Content $validationPath -Raw | ConvertFrom-Json
    if ($manifest.status -ne 'PASS') { throw "Manifest status for $SegmentId is $($manifest.status)" }
    if ($validation.status -ne 'PASS') { throw "Validation status for $SegmentId is $($validation.status)" }
    $bytes = (Get-ChildItem $root -File -Recurse | Measure-Object Length -Sum).Sum
    return [ordered]@{
        segment_id = $SegmentId
        status = 'PASS'
        instrument_count = [int]$manifest.instrument_count
        candle_count = [int]$manifest.candle_count
        trading_dates = @($manifest.trading_dates)
        validated_files = [int]$validation.validated_files
        failures = @($validation.failures)
        bytes = [int64]$bytes
        mib = [math]::Round($bytes / 1MB, 2)
        manifest = $manifestPath
        validation = $validationPath
    }
}

function Invoke-CollectSegment {
    param([Parameter(Mandatory)]$Task)
    if (-not (Test-Path $Python)) { throw "Python not found: $Python" }
    if (-not (Test-Path (Join-Path $CollectorRepo '.git'))) { throw "Collector repo missing: $CollectorRepo" }

    $segmentId = [string]$Task.params.segment_id
    if ([string]::IsNullOrWhiteSpace($segmentId)) { throw 'segment_id is required' }

    Invoke-Git -WorkingDirectory $CollectorRepo -Arguments @('fetch', 'origin', 'agent/moex-v62-segmented')
    Invoke-Git -WorkingDirectory $CollectorRepo -Arguments @('reset', '--hard', 'origin/agent/moex-v62-segmented')

    $planPath = Join-Path $CollectorRepo 'config\moex_operational_v62_segments.json'
    $plan = Get-Content $planPath -Raw | ConvertFrom-Json
    $matches = @($plan.segments | Where-Object { [string]$_.id -eq $segmentId })
    if ($matches.Count -ne 1) { throw "Segment is absent or ambiguous in plan: $segmentId" }
    $spec = $matches[0]

    $output = Join-Path $SegmentsRoot $segmentId
    if (Test-Path $output) { Remove-Item -Recurse -Force $output }

    Set-Location $CollectorRepo
    $env:PYTHONPATH = $CollectorRepo
    $arguments = @(
        '-u', 'tools\moex_v6_segment.py',
        '--segment-id', $segmentId,
        '--scope', [string]$spec.scope,
        '--partition-count', [string]$spec.partition_count,
        '--partition-index', [string]$spec.partition_index,
        '--output', $output,
        '--config', 'config\moex_operational_v6.json',
        '--heartbeat-seconds', '20'
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$spec.board)) {
        $arguments += @('--board', [string]$spec.board)
    }

    & $Python @arguments
    if ($LASTEXITCODE -ne 0) { throw "Collection failed for $segmentId with exit code $LASTEXITCODE" }
    & $Python -u tools\moex_v6_validate.py --output $output
    if ($LASTEXITCODE -ne 0) { throw "Validation failed for $segmentId with exit code $LASTEXITCODE" }
    return Read-SegmentResult -SegmentId $segmentId
}

function Invoke-ValidateSegment {
    param([Parameter(Mandatory)]$Task)
    $segmentId = [string]$Task.params.segment_id
    if ([string]::IsNullOrWhiteSpace($segmentId)) { throw 'segment_id is required' }
    $output = Join-Path $SegmentsRoot $segmentId
    Set-Location $CollectorRepo
    $env:PYTHONPATH = $CollectorRepo
    & $Python -u tools\moex_v6_validate.py --output $output
    if ($LASTEXITCODE -ne 0) { throw "Validation failed for $segmentId with exit code $LASTEXITCODE" }
    return Read-SegmentResult -SegmentId $segmentId
}

function Invoke-AssembleDataset {
    param([Parameter(Mandatory)]$Task)
    $output = Join-Path $AssembledRoot 'moex-v62'
    if (Test-Path $output) { Remove-Item -Recurse -Force $output }
    Set-Location $CollectorRepo
    $env:PYTHONPATH = $CollectorRepo
    & $Python -u tools\moex_v6_assemble.py --segments-root $SegmentsRoot --output $output --config config\moex_operational_v6.json --plan config\moex_operational_v62_segments.json --required-only
    if ($LASTEXITCODE -ne 0) { throw "Assembly failed with exit code $LASTEXITCODE" }
    & $Python -u tools\moex_v6_validate.py --output $output
    if ($LASTEXITCODE -ne 0) { throw "Assembled dataset validation failed with exit code $LASTEXITCODE" }
    $manifest = Get-Content (Join-Path $output 'metadata\dataset_manifest.json') -Raw | ConvertFrom-Json
    $bytes = (Get-ChildItem $output -File -Recurse | Measure-Object Length -Sum).Sum
    return [ordered]@{
        status = 'PASS'
        output = $output
        segment_count = [int]$manifest.segment_count
        instrument_count = [int]$manifest.instrument_count
        candle_count = [int]$manifest.candle_count
        trading_dates = @($manifest.trading_dates)
        bytes = [int64]$bytes
        mib = [math]::Round($bytes / 1MB, 2)
    }
}

function Invoke-CodexTask {
    param([Parameter(Mandatory)]$Task)
    if (-not (Test-Path (Join-Path $NoctaRepo '.git'))) { throw "Nocta worktree missing: $NoctaRepo" }
    $prompt = [string]$Task.params.prompt
    if ([string]::IsNullOrWhiteSpace($prompt)) { throw 'Codex task prompt is empty' }

    $safeId = Safe-Id -Value ([string]$Task.task_id)
    $branch = "agent/nocta-$safeId"
    $taskDir = Join-Path $AgentDir "codex\$safeId"
    New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
    $promptPath = Join-Path $taskDir 'prompt.md'
    $codexLog = Join-Path $taskDir 'codex.jsonl'
    $lastMessage = Join-Path $taskDir 'last-message.md'
    $exitPath = Join-Path $taskDir 'exit-code.txt'
    Set-Content -Path $promptPath -Value $prompt -Encoding UTF8

    Invoke-Git -WorkingDirectory $NoctaRepo -Arguments @('fetch', 'origin', 'main')
    Invoke-Git -WorkingDirectory $NoctaRepo -Arguments @('reset', '--hard', 'origin/main')
    Invoke-Git -WorkingDirectory $NoctaRepo -Arguments @('clean', '-fd')
    Invoke-Git -WorkingDirectory $NoctaRepo -Arguments @('switch', '-C', $branch)
    & git.exe -C $NoctaRepo config user.name 'Nocta VPS Agent'
    & git.exe -C $NoctaRepo config user.email 'nocta-vps-agent@users.noreply.github.com'

    $codexPath = (Get-Command codex.exe -ErrorAction Stop).Source
    $job = Start-Job -ScriptBlock {
        param($Repo, $PromptPath, $CodexPath, $LogPath, $LastMessagePath, $ExitPath)
        Set-Location $Repo
        $promptText = Get-Content $PromptPath -Raw
        $promptText | & $CodexPath exec --sandbox workspace-write --json --output-last-message $LastMessagePath - 2>&1 | Tee-Object -FilePath $LogPath
        Set-Content -Path $ExitPath -Value $LASTEXITCODE -Encoding ASCII
    } -ArgumentList $NoctaRepo, $promptPath, $codexPath, $codexLog, $lastMessage, $exitPath

    $timeoutMinutes = 120
    if ($Task.params.timeout_minutes) { $timeoutMinutes = [int]$Task.params.timeout_minutes }
    $completed = Wait-Job -Job $job -Timeout ($timeoutMinutes * 60)
    if (-not $completed) {
        Stop-Job $job -Force | Out-Null
        Remove-Job $job -Force | Out-Null
        throw "Codex task timed out after $timeoutMinutes minutes"
    }
    Receive-Job $job | Out-Null
    Remove-Job $job -Force | Out-Null
    $exitCode = if (Test-Path $exitPath) { [int](Get-Content $exitPath -Raw).Trim() } else { -1 }
    if ($exitCode -ne 0) { throw "Codex exec failed with exit code $exitCode" }

    $statusLines = @(& git.exe -C $NoctaRepo status --porcelain)
    $commitSha = (& git.exe -C $NoctaRepo rev-parse HEAD).Trim()
    if ($statusLines.Count -gt 0) {
        Invoke-Git -WorkingDirectory $NoctaRepo -Arguments @('add', '-A')
        & git.exe -C $NoctaRepo commit -m "agent(nocta): $safeId"
        if ($LASTEXITCODE -ne 0) { throw 'Unable to commit Codex changes' }
        Invoke-Git -WorkingDirectory $NoctaRepo -Arguments @('push', '--force-with-lease', '-u', 'origin', $branch)
        $commitSha = (& git.exe -C $NoctaRepo rev-parse HEAD).Trim()
    }

    return [ordered]@{
        status = 'PASS'
        branch = $branch
        commit_sha = $commitSha
        changed_files = $statusLines.Count
        last_message = if (Test-Path $lastMessage) { (Get-Content $lastMessage -Raw) } else { '' }
        codex_log = $codexLog
    }
}

function Invoke-Health {
    $disk = Get-Volume -DriveLetter C
    return [ordered]@{
        status = 'PASS'
        computer = $env:COMPUTERNAME
        utc = (Get-Date).ToUniversalTime().ToString('o')
        free_gb = [math]::Round($disk.SizeRemaining / 1GB, 2)
        total_gb = [math]::Round($disk.Size / 1GB, 2)
        collector_repo = Test-Path (Join-Path $CollectorRepo '.git')
        nocta_repo = Test-Path (Join-Path $NoctaRepo '.git')
        github = (& gh.exe auth status 2>&1 | Out-String).Trim()
        codex = (& codex.exe --version 2>&1 | Out-String).Trim()
    }
}

function Invoke-OneTask {
    $mutex = [Threading.Mutex]::new($false, 'Global\NoctaVpsAgentV1')
    if (-not $mutex.WaitOne(0)) { return }
    try {
        & gh.exe auth status | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated' }

        $task = Get-ControlTask
        if (-not [bool]$task.enabled) { return }
        $taskId = [string]$task.task_id
        $safeId = Safe-Id -Value $taskId
        $last = Read-JsonFile -Path (Join-Path $StateDir 'last-task.json')
        if ($last -and [string]$last.task_id -eq $taskId) { return }

        $startedAt = (Get-Date).ToUniversalTime().ToString('o')
        $logPath = Join-Path $LogDir ("{0}-{1}.log" -f $safeId, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $running = [ordered]@{
            schema = 'nocta-vps-agent-result/v1'
            task_id = $taskId
            action = [string]$task.action
            status = 'RUNNING'
            started_at = $startedAt
            computer = $env:COMPUTERNAME
            log = $logPath
        }
        Write-JsonFile -Path (Join-Path $StateDir 'latest.json') -Value $running
        Post-ControlComment -Payload $running

        Start-Transcript -Path $logPath -Force | Out-Null
        try {
            switch ([string]$task.action) {
                'collect_segment' { $result = Invoke-CollectSegment -Task $task }
                'validate_segment' { $result = Invoke-ValidateSegment -Task $task }
                'assemble_dataset' { $result = Invoke-AssembleDataset -Task $task }
                'codex_task' { $result = Invoke-CodexTask -Task $task }
                'health' { $result = Invoke-Health }
                default { throw "Unsupported action: $($task.action)" }
            }
            $completed = [ordered]@{
                schema = 'nocta-vps-agent-result/v1'
                task_id = $taskId
                action = [string]$task.action
                status = 'PASS'
                started_at = $startedAt
                completed_at = (Get-Date).ToUniversalTime().ToString('o')
                result = $result
                log = $logPath
            }
        }
        catch {
            $tail = @()
            if (Test-Path $logPath) { $tail = @(Get-Content $logPath -Tail 80) }
            $completed = [ordered]@{
                schema = 'nocta-vps-agent-result/v1'
                task_id = $taskId
                action = [string]$task.action
                status = 'FAIL'
                started_at = $startedAt
                completed_at = (Get-Date).ToUniversalTime().ToString('o')
                error = $_.Exception.Message
                log = $logPath
                log_tail = $tail
            }
        }
        finally {
            try { Stop-Transcript | Out-Null } catch {}
        }

        Write-JsonFile -Path (Join-Path $StateDir 'latest.json') -Value $completed
        Write-JsonFile -Path (Join-Path $HistoryDir "$safeId.json") -Value $completed
        Write-JsonFile -Path (Join-Path $StateDir 'last-task.json') -Value ([ordered]@{
            task_id = $taskId
            status = $completed.status
            completed_at = $completed.completed_at
        })
        Post-ControlComment -Payload $completed
    }
    catch {
        $agentError = [ordered]@{
            schema = 'nocta-vps-agent-error/v1'
            status = 'AGENT_ERROR'
            failed_at = (Get-Date).ToUniversalTime().ToString('o')
            error = $_.Exception.Message
        }
        Write-JsonFile -Path (Join-Path $StateDir 'agent-error.json') -Value $agentError
    }
    finally {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}

if ($Loop) {
    while ($true) {
        Invoke-OneTask
        Start-Sleep -Seconds $PollSeconds
    }
}
else {
    Invoke-OneTask
}
