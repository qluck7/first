#requires -Version 5.1

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = 'C:\Nocta'
$StateDir = Join-Path $Root 'state'
$LogDir = Join-Path $Root 'logs\oob'
$StatePath = Join-Path $StateDir 'oob-agent.json'
$CommandUrl = 'https://raw.githubusercontent.com/qluck7/first/main/nocta-oob-command.json'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $StateDir,$LogDir | Out-Null
$mutex = New-Object Threading.Mutex($false,'Global\NoctaOutOfBandAgentV1')
if (-not $mutex.WaitOne(0)) { exit 0 }

function Write-State {
    param([Parameter(Mandatory)]$Value)
    try {
        [IO.File]::WriteAllText($StatePath,(($Value | ConvertTo-Json -Depth 30) + "`r`n"),$Utf8NoBom)
    } catch {}
}

function Get-RunnerService {
    return @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'qluck7-ProjectX' }) | Select-Object -First 1
}

function Stop-RunnerProcesses {
    $count = 0
    foreach ($name in @('Runner.Worker','Runner.Listener')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try {
                & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
                $count++
            } catch {}
        }
    }
    return $count
}

function Get-Health {
    $service = Get-RunnerService
    $listeners = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)
    $workers = @(Get-Process -Name 'Runner.Worker' -ErrorAction SilentlyContinue)
    $network = $false
    try { $network = Test-NetConnection github.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue } catch {}
    $oldestWorkerMinutes = $null
    if ($workers.Count -gt 0) {
        try {
            $oldest = $workers | Sort-Object StartTime | Select-Object -First 1
            $oldestWorkerMinutes = [math]::Round(((Get-Date) - $oldest.StartTime).TotalMinutes,1)
        } catch {}
    }
    return [ordered]@{
        service_name = if ($service) { $service.Name } else { $null }
        service_status = if ($service) { $service.Status.ToString() } else { 'MISSING' }
        service_start_type = if ($service) { $service.StartType.ToString() } else { $null }
        listener_processes = $listeners.Count
        worker_processes = $workers.Count
        oldest_worker_minutes = $oldestWorkerMinutes
        github_443_reachable = [bool]$network
    }
}

function Restart-Runner {
    $service = Get-RunnerService
    if (-not $service) { throw 'ProjectX GitHub Actions runner service is missing.' }
    try { Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue } catch {}
    $killed = Stop-RunnerProcesses
    Start-Sleep -Seconds 2
    Set-Service -Name $service.Name -StartupType Automatic
    Start-Service -Name $service.Name
    $deadline = (Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Seconds 3
        $service.Refresh()
        $listeners = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)
        if ($service.Status -eq 'Running' -and $listeners.Count -gt 0) {
            return [ordered]@{ action='RESTARTED_RUNNER'; killed_processes=$killed; health=Get-Health }
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Runner service did not recover within 90 seconds.'
}

function Ensure-RunnerHealthy {
    $service = Get-RunnerService
    if (-not $service) {
        return [ordered]@{ action='SERVICE_MISSING'; health=Get-Health }
    }
    try { Set-Service -Name $service.Name -StartupType Automatic } catch {}
    $health = Get-Health
    if ($health.oldest_worker_minutes -ne $null -and [double]$health.oldest_worker_minutes -gt 370) {
        return Restart-Runner
    }
    if ($service.Status -ne 'Running') {
        return Restart-Runner
    }
    if ([int]$health.listener_processes -eq 0 -and [int]$health.worker_processes -eq 0) {
        return Restart-Runner
    }
    return [ordered]@{ action='NONE'; health=$health }
}

try {
    $guardian = Ensure-RunnerHealthy
    $previous = $null
    if (Test-Path $StatePath) {
        try { $previous = Get-Content $StatePath -Raw | ConvertFrom-Json } catch {}
    }

    $uri = $CommandUrl + '?ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $command = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30
    if ([string]$command.schema -ne 'nocta-oob-command/v1') { throw "Unsupported OOB schema: $($command.schema)" }
    if ([string]::IsNullOrWhiteSpace([string]$command.command_id)) { throw 'OOB command_id is empty.' }

    if (-not [bool]$command.enabled) {
        Write-State ([ordered]@{
            schema='nocta-oob-result/v1'
            command_id=[string]$command.command_id
            action=[string]$command.action
            status='SKIPPED_DISABLED'
            completed_at=[DateTimeOffset]::UtcNow.ToString('o')
            guardian=$guardian
            health=Get-Health
        })
        exit 0
    }

    if ($previous -and [string]$previous.command_id -eq [string]$command.command_id -and
        [string]$previous.status -in @('PASS','FAIL','SKIPPED_DISABLED') -and
        [string]$guardian.action -eq 'NONE') {
        exit 0
    }

    Write-State ([ordered]@{
        schema='nocta-oob-result/v1'
        command_id=[string]$command.command_id
        action=[string]$command.action
        status='RUNNING'
        started_at=[DateTimeOffset]::UtcNow.ToString('o')
        guardian=$guardian
        health=Get-Health
    })

    $details = switch ([string]$command.action) {
        'noop' { [ordered]@{ message='No operation requested.' } }
        'health' { Get-Health }
        'start_runner' {
            $service = Get-RunnerService
            if (-not $service) { throw 'ProjectX GitHub Actions runner service is missing.' }
            Set-Service -Name $service.Name -StartupType Automatic
            if ($service.Status -ne 'Running') { Start-Service -Name $service.Name }
            Start-Sleep -Seconds 8
            Get-Health
        }
        'restart_runner' { Restart-Runner }
        'kill_worker_and_restart' { Restart-Runner }
        'run_local_guardian' { Ensure-RunnerHealthy }
        'reboot' {
            $value = [ordered]@{ message='Windows reboot scheduled in 30 seconds.' }
            Write-State ([ordered]@{
                schema='nocta-oob-result/v1'
                command_id=[string]$command.command_id
                action=[string]$command.action
                status='PASS'
                completed_at=[DateTimeOffset]::UtcNow.ToString('o')
                guardian=$guardian
                details=$value
                health=Get-Health
            })
            & shutdown.exe /r /t 30 /c "NOCTA out-of-band recovery command" /d p:4:1 | Out-Null
            exit 0
        }
        default { throw "Unsupported OOB action: $($command.action)" }
    }

    Write-State ([ordered]@{
        schema='nocta-oob-result/v1'
        command_id=[string]$command.command_id
        action=[string]$command.action
        status='PASS'
        completed_at=[DateTimeOffset]::UtcNow.ToString('o')
        guardian=$guardian
        details=$details
        health=Get-Health
    })
}
catch {
    Write-State ([ordered]@{
        schema='nocta-oob-result/v1'
        command_id=if($command){[string]$command.command_id}else{$null}
        action=if($command){[string]$command.action}else{$null}
        status='FAIL'
        completed_at=[DateTimeOffset]::UtcNow.ToString('o')
        error=$_.Exception.Message
        powershell_error=($_ | Out-String)
        health=Get-Health
    })
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
