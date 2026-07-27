#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = 'C:\Nocta'
$AgentDir = Join-Path $Root 'control\agent'
$ControllerDir = Join-Path $Root 'control\controller-v2'
$StateDir = Join-Path $ControllerDir 'state'
$HistoryDir = Join-Path $StateDir 'history'
$LogDir = Join-Path $Root 'logs\controller-v2'
$LaunchPath = Join-Path $AgentDir 'nocta-vps-agent-v1.ps1'
$ControllerPath = Join-Path $AgentDir 'nocta_vps_controller_v2.py'
$PayloadPath = Join-Path $AgentDir 'nocta_vps_controller_v2.py.gz.b64'
$WrapperDownload = Join-Path $AgentDir 'nocta-vps-controller-v2-wrapper.download.ps1'
$PayloadUrl = 'https://raw.githubusercontent.com/qluck7/first/main/nocta_vps_controller_v2.py.gz.b64?rev=2f747041'
$WrapperUrl = 'https://raw.githubusercontent.com/qluck7/first/main/nocta-vps-controller-v2-wrapper.ps1?rev=33d5c183'
$ExpectedControllerSha256 = 'e926959db4d451d9b5004fbc9050b4d76325d4c12432adb86f9e784ce21c3b55'
$ExpectedWrapperSha256 = '9b74d012d9c69fd447bcd4e74a8b90aea3b90d06935eaaa1450e5b91d337654e'
$Python = 'C:\Python312\python.exe'
$RepoName = 'qluck7/ProjectX'
$ControlIssue = 81
$AgentTask = 'NoctaVpsAgentV1'
$WatchdogTask = 'NoctaVpsWatchdogV1'
$InstallLog = Join-Path $LogDir ("install-controller-v2-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $AgentDir,$ControllerDir,$StateDir,$HistoryDir,$LogDir | Out-Null
Start-Transcript -Path $InstallLog -Force | Out-Null

function Write-NoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)
}

function Set-ControlHold {
    param([Parameter(Mandatory)][string]$Reason)
    $payload = [ordered]@{
        schema = 'nocta-vps-control/v2'
        task_id = ('hold-{0}' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')))
        enabled = $false
        action = 'collect_segment'
        params = [ordered]@{
            segment_id = 'shares-tqtf'
            max_runtime_minutes = 45
            reason = $Reason
        }
    }
    $file = Join-Path $StateDir ("hold-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    Write-NoBom -Path $file -Text (($payload | ConvertTo-Json -Depth 20) + "`r`n")
    try {
        & gh.exe issue edit $ControlIssue --repo $RepoName --body-file $file | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to place issue #$ControlIssue on HOLD." }
    }
    finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
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

function Expand-ControllerPayload {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $base64 = (Get-Content $InputPath -Raw).Trim()
    $compressed = [Convert]::FromBase64String($base64)
    $inputStream = New-Object IO.MemoryStream(,$compressed)
    $gzip = New-Object IO.Compression.GZipStream($inputStream,[IO.Compression.CompressionMode]::Decompress)
    $outputStream = New-Object IO.MemoryStream
    try {
        $gzip.CopyTo($outputStream)
        [IO.File]::WriteAllBytes($OutputPath,$outputStream.ToArray())
    }
    finally {
        $gzip.Dispose()
        $inputStream.Dispose()
        $outputStream.Dispose()
    }
}

function Wait-ForControllerReady {
    param([int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $readyPath = Join-Path $StateDir 'ready.json'
    while ((Get-Date) -lt $deadline) {
        $processes = @(Get-CimInstance Win32_Process | Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match 'nocta_vps_controller_v2\.py' -and
            $_.CommandLine -match '--loop'
        })
        if ($processes.Count -eq 1 -and (Test-Path $readyPath)) {
            return [ordered]@{ processes = $processes; ready_path = $readyPath }
        }
        Start-Sleep -Seconds 3
    }
    throw "Controller did not become READY within $TimeoutSeconds seconds."
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator.'
    }

    foreach ($command in @('gh.exe','powershell.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Missing command: $command" }
    }
    if (-not (Test-Path $Python)) { throw "Python is missing: $Python" }
    if (-not (Test-Path 'C:\Nocta\collector\ProjectX\.git')) { throw 'Collector worktree is missing.' }
    & gh.exe auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }
    & gh.exe issue view $ControlIssue --repo $RepoName --json number,title *> $null
    if ($LASTEXITCODE -ne 0) { throw "Cannot access control issue #$ControlIssue." }

    $persistentTask = Get-ScheduledTask -TaskName $AgentTask -ErrorAction SilentlyContinue
    if (-not $persistentTask) { throw "Persistent scheduled task is missing: $AgentTask" }
    $arguments = [string](@($persistentTask.Actions)[0].Arguments)
    if ($arguments -notmatch 'nocta-vps-agent-v1\.ps1') {
        throw "Persistent task no longer points to the stable launch path: $arguments"
    }

    Write-Host '=== Freezing the new control channel ===' -ForegroundColor Cyan
    Set-ControlHold -Reason 'Controller v2 installation in progress.'

    Write-Host '=== Stopping all obsolete controller processes ===' -ForegroundColor Cyan
    Stop-ScheduledTask -TaskName $AgentTask -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $WatchdogTask -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName $WatchdogTask -ErrorAction SilentlyContinue | Out-Null
    Stop-ProcessTrees -Patterns @(
        'nocta-vps-agent-v1\.ps1',
        'nocta-vps-watchdog-v1\.ps1',
        'nocta-vps-supervisor-v3\.ps1',
        'nocta_vps_controller_v2\.py',
        'moex_v6_segment\.py'
    )
    Start-Sleep -Seconds 3

    Write-Host '=== Archiving the old launch file and state ===' -ForegroundColor Cyan
    $archive = Join-Path $HistoryDir ("pre-controller-v2-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $archive | Out-Null
    foreach ($path in @($LaunchPath,$ControllerPath)) {
        if (Test-Path $path) { Copy-Item -Force $path (Join-Path $archive ([IO.Path]::GetFileName($path))) }
    }
    foreach ($name in @('ready.json','latest.json','last_task.json','active_task.json','controller_error.json','ready_publish_error.json','hold.json','controller.lock')) {
        $path = Join-Path $StateDir $name
        if (Test-Path $path) { Move-Item -Force $path (Join-Path $archive $name) }
    }

    Write-Host '=== Downloading controller payload and wrapper ===' -ForegroundColor Cyan
    Invoke-WebRequest -Uri $PayloadUrl -UseBasicParsing -OutFile $PayloadPath
    Invoke-WebRequest -Uri $WrapperUrl -UseBasicParsing -OutFile $WrapperDownload
    if (-not (Test-Path $PayloadPath)) { throw 'Controller payload download failed.' }
    if (-not (Test-Path $WrapperDownload)) { throw 'Controller wrapper download failed.' }

    Write-Host '=== Expanding and validating the Python controller ===' -ForegroundColor Cyan
    Expand-ControllerPayload -InputPath $PayloadPath -OutputPath $ControllerPath
    $controllerSha = (Get-FileHash -Algorithm SHA256 $ControllerPath).Hash.ToLowerInvariant()
    if ($controllerSha -ne $ExpectedControllerSha256) { throw "Controller SHA-256 mismatch: $controllerSha" }
    & $Python -m py_compile $ControllerPath
    if ($LASTEXITCODE -ne 0) { throw 'Python controller syntax validation failed.' }

    $wrapperSha = (Get-FileHash -Algorithm SHA256 $WrapperDownload).Hash.ToLowerInvariant()
    if ($wrapperSha -ne $ExpectedWrapperSha256) { throw "Wrapper SHA-256 mismatch: $wrapperSha" }
    Copy-Item -Force $WrapperDownload $LaunchPath

    Remove-Item $PayloadPath,$WrapperDownload -Force -ErrorAction SilentlyContinue

    Write-Host '=== Starting the minimal controller under HOLD ===' -ForegroundColor Cyan
    Enable-ScheduledTask -TaskName $AgentTask | Out-Null
    Start-ScheduledTask -TaskName $AgentTask
    $readyInfo = Wait-ForControllerReady -TimeoutSeconds 60
    Start-Sleep -Seconds 5

    $ready = Get-Content $readyInfo.ready_path -Raw | ConvertFrom-Json
    if ([string]$ready.controller_version -ne '2.0.0') { throw "Unexpected controller version: $($ready.controller_version)" }
    if ([int]$ready.control_issue -ne $ControlIssue) { throw "Unexpected control issue: $($ready.control_issue)" }

    $lastComment = (& gh.exe api "repos/qluck7/ProjectX/issues/$ControlIssue/comments" --jq '.[-1].body' | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read controller telemetry from GitHub.' }
    if ($lastComment -notmatch 'nocta-vps-controller-status/v2' -or $lastComment -notmatch '"status":\s*"READY"') {
        throw 'GitHub did not receive the controller READY telemetry.'
    }

    $report = [ordered]@{
        status = 'PASS'
        installed_at = (Get-Date).ToUniversalTime().ToString('o')
        controller_version = [string]$ready.controller_version
        control_issue = $ControlIssue
        process_count = $readyInfo.processes.Count
        controller_pid = $ready.pid
        scheduled_task = $AgentTask
        scheduled_task_state = (Get-ScheduledTask -TaskName $AgentTask).State.ToString()
        watchdog_disabled = $WatchdogTask
        controller_sha256 = $controllerSha
        wrapper_sha256 = $wrapperSha
        install_log = $InstallLog
    }
    $reportPath = Join-Path $StateDir 'installation.json'
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== NOCTA VPS CONTROLLER V2 PASS ===' -ForegroundColor Green
    $report.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $reportPath"
    Write-Host 'The controller is online on issue #81. Collection remains on HOLD.' -ForegroundColor Yellow
}
catch {
    try { Set-ControlHold -Reason ("Controller v2 installation failed: " + $_.Exception.Message) } catch {}
    try { Stop-ScheduledTask -TaskName $AgentTask -ErrorAction SilentlyContinue } catch {}
    $failure = [ordered]@{
        status = 'FAIL'
        failed_at = (Get-Date).ToUniversalTime().ToString('o')
        error = $_.Exception.Message
        install_log = $InstallLog
    }
    $failurePath = Join-Path $StateDir 'installation.json'
    $failure | ConvertTo-Json -Depth 10 | Set-Content -Path $failurePath -Encoding UTF8
    Write-Host ''
    Write-Host '=== NOCTA VPS CONTROLLER V2 FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $InstallLog"
    exit 1
}
finally {
    Remove-Item $PayloadPath,$WrapperDownload -Force -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch {}
}
