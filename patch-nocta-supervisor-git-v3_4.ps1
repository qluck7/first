#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$TaskName = 'NoctaVpsAgentV1'
$WatchdogTask = 'NoctaVpsWatchdogV1'
$Canonical = 'C:\Nocta\control\supervisor-v3\nocta-vps-supervisor-v3.ps1'
$LaunchFile = 'C:\Nocta\control\agent\nocta-vps-agent-v1.ps1'
$StateDir = 'C:\Nocta\control\supervisor-v3\state'
$LogDir = 'C:\Nocta\logs\supervisor-v3'
$Log = Join-Path $LogDir ("patch-git-v34-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $StateDir,$LogDir | Out-Null
Start-Transcript -Path $Log -Force | Out-Null

function Stop-ByPattern {
    param([string[]]$Patterns)
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

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator.'
    }

    foreach ($path in @($Canonical,$LaunchFile)) {
        if (-not (Test-Path $path)) { throw "Supervisor file is missing: $path" }
    }
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        throw "Scheduled task is missing: $TaskName"
    }

    Write-Host '=== Stopping old supervisor and collector ===' -ForegroundColor Cyan
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $WatchdogTask -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName $WatchdogTask -ErrorAction SilentlyContinue | Out-Null
    Stop-ByPattern @('nocta-vps-agent-v1\.ps1','nocta-vps-watchdog-v1\.ps1','nocta-vps-supervisor-v3\.ps1','moex_v6_segment\.py')
    Start-Sleep -Seconds 2

    $old = @'
    & git.exe -C $CollectorRepo fetch origin agent/moex-v62-segmented 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Collector branch fetch failed.' }
    & git.exe -C $CollectorRepo reset --hard origin/agent/moex-v62-segmented 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Collector branch reset failed.' }
'@

    $new = @'
    $gitFetchCommand = 'git -C "{0}" fetch origin agent/moex-v62-segmented >nul 2>&1' -f $CollectorRepo
    & cmd.exe /d /c $gitFetchCommand
    if ($LASTEXITCODE -ne 0) { throw 'Collector branch fetch failed.' }
    $gitResetCommand = 'git -C "{0}" reset --hard origin/agent/moex-v62-segmented >nul 2>&1' -f $CollectorRepo
    & cmd.exe /d /c $gitResetCommand
    if ($LASTEXITCODE -ne 0) { throw 'Collector branch reset failed.' }
'@

    Write-Host '=== Applying the exact Git stderr fix ===' -ForegroundColor Cyan
    foreach ($path in @($Canonical,$LaunchFile)) {
        $text = Get-Content $path -Raw
        if (-not $text.Contains($old)) {
            throw "Expected Git block was not found in $path"
        }
        $text = $text.Replace($old,$new)
        $text = $text.Replace("`$Version = '3.1'","`$Version = '3.1.1'")
        [IO.File]::WriteAllText($path,$text,$Utf8NoBom)
        [void][scriptblock]::Create((Get-Content $path -Raw))
    }

    foreach ($name in @('error.json','ready.json','latest.json','active-run.json','last-task.json')) {
        Remove-Item (Join-Path $StateDir $name) -Force -ErrorAction SilentlyContinue
    }

    Write-Host '=== Starting patched supervisor under HOLD ===' -ForegroundColor Cyan
    Enable-ScheduledTask -TaskName $TaskName | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 15

    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'nocta-vps-agent-v1\.ps1' -and $_.CommandLine -match '-Loop'
    })
    if ($processes.Count -ne 1) { throw "Expected one supervisor process, found $($processes.Count)." }

    $readyPath = Join-Path $StateDir 'ready.json'
    $errorPath = Join-Path $StateDir 'error.json'
    if (-not (Test-Path $readyPath)) { throw 'Supervisor did not create ready.json.' }
    $ready = Get-Content $readyPath -Raw | ConvertFrom-Json
    if ([string]$ready.supervisor_version -ne '3.1.1') {
        throw "Unexpected supervisor version: $($ready.supervisor_version)"
    }
    if (Test-Path $errorPath) {
        $failure = Get-Content $errorPath -Raw | ConvertFrom-Json
        throw "Supervisor startup error: $($failure.error)"
    }

    Write-Host ''
    Write-Host '=== NOCTA SUPERVISOR GIT PATCH V3.4 PASS ===' -ForegroundColor Green
    Write-Host "Supervisor version: $($ready.supervisor_version)"
    Write-Host "Supervisor processes: $($processes.Count)"
    Write-Host "Log: $Log"
    Write-Host 'The control issue remains on HOLD; no collection was started.' -ForegroundColor Yellow
}
catch {
    Write-Host ''
    Write-Host '=== NOCTA SUPERVISOR GIT PATCH V3.4 FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $Log"
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
