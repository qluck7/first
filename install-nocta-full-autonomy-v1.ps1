#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'qluck7/ProjectX'
$RunnerName = 'NOKTA-PILOT-AMS'
$GuardianIssue = 83
$Root = 'C:\Nocta'
$BinDir = Join-Path $Root 'bin'
$StateDir = Join-Path $Root 'state'
$LogDir = Join-Path $Root 'logs\autonomy'
$GuardianPath = Join-Path $BinDir 'NoctaRunnerGuardian.ps1'
$GuardianMinuteTask = 'NoctaRunnerGuardianMinute'
$GuardianStartupTask = 'NoctaRunnerGuardianStartup'
$ReportPath = Join-Path $StateDir 'nocta-full-autonomy.json'
$LogPath = Join-Path $LogDir ("install-full-autonomy-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $BinDir,$StateDir,$LogDir | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Write-JsonNoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    [IO.File]::WriteAllText($Path,(($Value | ConvertTo-Json -Depth 40) + "`r`n"),$Utf8NoBom)
}

function Get-RunnerService {
    $service = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'qluck7-ProjectX' }) | Select-Object -First 1
    if (-not $service) { throw 'The qluck7/ProjectX GitHub Actions runner service is missing.' }
    return $service
}

function Wait-RunnerOnline {
    param([int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        try {
            $raw = (& gh.exe api "repos/$Repo/actions/runners?per_page=100" | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $response = $raw | ConvertFrom-Json
                $runner = @($response.runners | Where-Object { [string]$_.name -eq $RunnerName }) | Select-Object -First 1
                if ($runner -and [string]$runner.status -eq 'online') { return $runner }
            }
        }
        catch {}
    }
    throw "Runner $RunnerName did not become online within $TimeoutSeconds seconds."
}

function Install-LocalGuardian {
    param([Parameter(Mandatory)][string]$ServiceName)

    $guardian = @'
$ErrorActionPreference = 'SilentlyContinue'
$StateDir = 'C:\Nocta\state'
$StatePath = Join-Path $StateDir 'runner-guardian.json'
$ServicePattern = 'qluck7-ProjectX'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$mutex = New-Object Threading.Mutex($false,'Global\NoctaRunnerGuardianV1')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    $previous = $null
    if (Test-Path $StatePath) {
        try { $previous = Get-Content $StatePath -Raw | ConvertFrom-Json } catch {}
    }
    $failureCount = if ($previous -and $previous.failure_count) { [int]$previous.failure_count } else { 0 }
    $service = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $ServicePattern }) | Select-Object -First 1
    $action = 'NONE'
    $status = 'SERVICE_MISSING'
    $workerAgeMinutes = $null
    $network443 = $false
    try { $network443 = Test-NetConnection github.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue } catch {}

    if ($service) {
        try { Set-Service -Name $service.Name -StartupType Automatic } catch {}
        $workers = @(Get-CimInstance Win32_Process -Filter "Name='Runner.Worker.exe'" -ErrorAction SilentlyContinue)
        if ($workers.Count -gt 0) {
            $oldest = $workers | Sort-Object CreationDate | Select-Object -First 1
            try { $workerAgeMinutes = [math]::Round(((Get-Date) - [datetime]$oldest.CreationDate).TotalMinutes,1) } catch {}
        }
        if ($workerAgeMinutes -ne $null -and $workerAgeMinutes -gt 430) {
            foreach ($worker in $workers) { try { & taskkill.exe /PID ([int]$worker.ProcessId) /T /F 2>$null | Out-Null } catch {} }
            try { Restart-Service -Name $service.Name -Force } catch {}
            $action = 'KILLED_STALE_WORKER_AND_RESTARTED'
            Start-Sleep -Seconds 10
        }
        elseif ($service.Status -ne 'Running') {
            try { Start-Service -Name $service.Name } catch { try { Restart-Service -Name $service.Name -Force } catch {} }
            $action = 'STARTED_SERVICE'
            Start-Sleep -Seconds 10
        }
        else {
            $listeners = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)
            if ($listeners.Count -eq 0 -and $workers.Count -eq 0) {
                try { Restart-Service -Name $service.Name -Force } catch {}
                $action = 'RESTARTED_MISSING_LISTENER'
                Start-Sleep -Seconds 10
            }
        }

        $service.Refresh()
        $listenersAfter = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)
        $workersAfter = @(Get-Process -Name 'Runner.Worker' -ErrorAction SilentlyContinue)
        if ($service.Status -eq 'Running' -and ($listenersAfter.Count -gt 0 -or $workersAfter.Count -gt 0)) {
            $status = 'HEALTHY'
            $failureCount = 0
        }
        else {
            $status = 'UNHEALTHY'
            $failureCount++
        }

        if ($failureCount -ge 10 -and $workersAfter.Count -eq 0) {
            $status = 'SOFT_REBOOT_SCHEDULED'
            $action = 'SOFT_REBOOT_AFTER_10_FAILED_CHECKS'
            $failureCount = 0
            & shutdown.exe /r /t 60 /c "NOCTA GitHub runner guardian could not restore the runner service" /d p:4:1 | Out-Null
        }

        $payload = [ordered]@{
            schema = 'nocta-local-runner-guardian/v1'
            checked_at = [DateTimeOffset]::UtcNow.ToString('o')
            computer = $env:COMPUTERNAME
            status = $status
            action = $action
            failure_count = $failureCount
            service = [ordered]@{
                name = $service.Name
                status = $service.Status.ToString()
                start_type = $service.StartType.ToString()
            }
            listener_processes = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue).Count
            worker_processes = @(Get-Process -Name 'Runner.Worker' -ErrorAction SilentlyContinue).Count
            oldest_worker_age_minutes = $workerAgeMinutes
            github_443_reachable = [bool]$network443
        }
    }
    else {
        $failureCount++
        $payload = [ordered]@{
            schema = 'nocta-local-runner-guardian/v1'
            checked_at = [DateTimeOffset]::UtcNow.ToString('o')
            computer = $env:COMPUTERNAME
            status = $status
            action = $action
            failure_count = $failureCount
            service = $null
            listener_processes = 0
            worker_processes = 0
            oldest_worker_age_minutes = $null
            github_443_reachable = [bool]$network443
        }
    }
    [IO.File]::WriteAllText($StatePath,(($payload | ConvertTo-Json -Depth 20) + "`r`n"),$Utf8NoBom)
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
'@

    [IO.File]::WriteAllText($GuardianPath,$guardian,$Utf8NoBom)
    [void][scriptblock]::Create((Get-Content $GuardianPath -Raw))

    $taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$GuardianPath`""
    & schtasks.exe /Create /TN $GuardianMinuteTask /TR $taskCommand /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to create $GuardianMinuteTask." }
    & schtasks.exe /Create /TN $GuardianStartupTask /TR $taskCommand /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to create $GuardianStartupTask." }

    & sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    & sc.exe failureflag $ServiceName 1 | Out-Null

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $GuardianPath
}

function Invoke-CodexSmoke {
    $pwsh = Get-Command pwsh.exe -ErrorAction Stop
    $codex = Get-Command codex.exe -ErrorAction Stop
    $work = Join-Path $env:TEMP ("nocta-codex-smoke-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $last = Join-Path $work 'last-message.txt'
    $stdout = Join-Path $work 'stdout.jsonl'
    $stderr = Join-Path $work 'stderr.log'
    $smokeScript = Join-Path $work 'smoke.ps1'
    $codexPath = $codex.Source.Replace("'","''")
    $lastPath = $last.Replace("'","''")
    $scriptText = @"
`$ErrorActionPreference = 'Stop'
`$prompt = 'Respond with exactly CODEX_READY. Do not read, write, or modify project files. Do not execute shell commands.'
`$prompt | & '$codexPath' exec --sandbox read-only --json --output-last-message '$lastPath' -
exit `$LASTEXITCODE
"@
    [IO.File]::WriteAllText($smokeScript,$scriptText,$Utf8NoBom)
    [void][scriptblock]::Create((Get-Content $smokeScript -Raw))

    $argumentLine = "-NoProfile -ExecutionPolicy Bypass -File `"$smokeScript`""
    $process = Start-Process -FilePath $pwsh.Source -ArgumentList $argumentLine -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(180)
    while (-not $process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2; $process.Refresh() }
    if (-not $process.HasExited) {
        try { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null } catch {}
        throw 'Codex smoke test timed out after 180 seconds.'
    }
    $process.Refresh()
    $exitCode = $process.ExitCode
    $message = if (Test-Path $last) { (Get-Content $last -Raw).Trim() } else { '' }
    $stderrText = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { '' }
    if ($exitCode -ne 0) { throw "Codex smoke test failed with exit code $exitCode. stderr: $stderrText" }
    if ($message -ne 'CODEX_READY') { throw "Unexpected Codex smoke response: $message" }
    return [ordered]@{
        status = 'PASS'
        version = (& $codex.Source --version 2>&1 | Out-String).Trim()
        response = $message
        stdout = $stdout
        stderr = $stderr
    }
}

function Configure-ServerspaceGuardian {
    $answer = Read-Host 'Configure external Serverspace recovery now? Type YES or press Enter to skip'
    if ($answer -ne 'YES') {
        return [ordered]@{ configured = $false; reason = 'Skipped by user; local self-healing remains active.' }
    }

    Write-Host ''
    Write-Host 'Paste the Serverspace project API key into the secure LOCAL prompt.' -ForegroundColor Yellow
    Write-Host 'The key is sent directly to GitHub Secrets and is never written to disk or chat.' -ForegroundColor Yellow
    $secure = Read-Host 'Serverspace API key' -AsSecureString
    $plain = [Net.NetworkCredential]::new('', $secure).Password
    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'Serverspace API key is empty.' }
    try {
        $headers = @{ 'X-API-KEY' = $plain; 'Accept' = 'application/json' }
        $response = Invoke-RestMethod -Uri 'https://api.serverspace.io/api/v1/servers' -Headers $headers -Method Get -TimeoutSec 30
        $externalIp = $null
        try { $externalIp = [string](Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 20).ip } catch {}
        $servers = @($response.servers)
        $match = $null
        if ($externalIp) {
            $match = @($servers | Where-Object { @($_.nics | ForEach-Object { [string]$_.ip_address }) -contains $externalIp }) | Select-Object -First 1
        }
        if (-not $match) {
            $match = @($servers | Where-Object { [string]$_.name -match '^nokta-pilot-ams' }) | Select-Object -First 1
        }
        if (-not $match) { throw "Unable to identify this VPS in Serverspace. External IP=$externalIp" }
        $serverId = [string]$match.id
        if ([string]::IsNullOrWhiteSpace($serverId)) { throw 'Serverspace server ID is empty.' }

        $plain | & gh.exe secret set SERVERSPACE_API_KEY --repo $Repo
        if ($LASTEXITCODE -ne 0) { throw 'Unable to set SERVERSPACE_API_KEY GitHub secret.' }
        $serverId | & gh.exe secret set SERVERSPACE_SERVER_ID --repo $Repo
        if ($LASTEXITCODE -ne 0) { throw 'Unable to set SERVERSPACE_SERVER_ID GitHub secret.' }

        & gh.exe workflow run nocta-serverspace-guardian.yml --repo $Repo | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to trigger the Serverspace guardian workflow.' }
        return [ordered]@{
            configured = $true
            server_id = $serverId
            server_name = [string]$match.name
            external_ip = $externalIp
            guardian_issue = $GuardianIssue
        }
    }
    finally {
        $plain = $null
        $secure = $null
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as Administrator.' }
    foreach ($command in @('gh.exe','pwsh.exe','codex.exe','powershell.exe','schtasks.exe','sc.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command is missing: $command" }
    }
    & gh.exe auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }
    & gh.exe repo view $Repo --json nameWithOwner,isPrivate *> $null
    if ($LASTEXITCODE -ne 0) { throw "Unable to access private repository $Repo." }

    Write-Host '=== Installing local SYSTEM runner guardian before all tests ===' -ForegroundColor Cyan
    $service = Get-RunnerService
    Install-LocalGuardian -ServiceName $service.Name

    Write-Host '=== Restoring and verifying GitHub runner ===' -ForegroundColor Cyan
    $service.Refresh()
    if ($service.Status -ne 'Running') { Start-Service -Name $service.Name }
    Set-Service -Name $service.Name -StartupType Automatic
    $runner = Wait-RunnerOnline -TimeoutSeconds 180

    Write-Host '=== Running PowerShell 7 Codex smoke test ===' -ForegroundColor Cyan
    $codex = Invoke-CodexSmoke

    Write-Host '=== Optionally enabling external Serverspace recovery ===' -ForegroundColor Cyan
    $serverspace = Configure-ServerspaceGuardian

    Write-Host '=== Triggering the current queued VPS command ===' -ForegroundColor Cyan
    & gh.exe workflow run nocta-vps-command.yml --repo $Repo | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to trigger the NOCTA VPS command workflow.' }

    $service.Refresh()
    $guardianState = $null
    $guardianStatePath = Join-Path $StateDir 'runner-guardian.json'
    if (Test-Path $guardianStatePath) { try { $guardianState = Get-Content $guardianStatePath -Raw | ConvertFrom-Json } catch {} }
    $report = [ordered]@{
        schema = 'nocta-full-autonomy-installation/v1'
        status = 'PASS'
        completed_at = [DateTimeOffset]::UtcNow.ToString('o')
        computer = $env:COMPUTERNAME
        repository = $Repo
        runner = [ordered]@{
            id = $runner.id
            name = $runner.name
            status = $runner.status
            busy = $runner.busy
            labels = @($runner.labels | ForEach-Object { $_.name })
        }
        service = [ordered]@{
            name = $service.Name
            status = $service.Status.ToString()
            start_type = $service.StartType.ToString()
        }
        local_guardian = [ordered]@{
            minute_task = $GuardianMinuteTask
            startup_task = $GuardianStartupTask
            script = $GuardianPath
            state = $guardianState
        }
        codex = $codex
        external_serverspace_guardian = $serverspace
        guardian_issue = $GuardianIssue
        log = $LogPath
    }
    Write-JsonNoBom -Path $ReportPath -Value $report

    Write-Host ''
    Write-Host '=== NOCTA FULL AUTONOMY V1 PASS ===' -ForegroundColor Green
    Write-Host "Runner: $($runner.status); service: $($service.Status); Codex: $($codex.response)"
    Write-Host "Local guardian: $GuardianMinuteTask + $GuardianStartupTask"
    Write-Host "External Serverspace guardian configured: $($serverspace.configured)"
    Write-Host "Report: $ReportPath"
    Write-Host 'After this PASS, normal operation no longer requires RDP.' -ForegroundColor Yellow
}
catch {
    try {
        $service = Get-RunnerService
        Set-Service -Name $service.Name -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $service.Name -ErrorAction SilentlyContinue
    } catch {}
    $failure = [ordered]@{
        schema = 'nocta-full-autonomy-installation/v1'
        status = 'FAIL'
        failed_at = [DateTimeOffset]::UtcNow.ToString('o')
        error = $_.Exception.Message
        log = $LogPath
        note = 'The script attempted to leave the GitHub runner service enabled and running even after failure.'
    }
    Write-JsonNoBom -Path $ReportPath -Value $failure
    Write-Host ''
    Write-Host '=== NOCTA FULL AUTONOMY V1 FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
