#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = 'C:\Nocta'
$AgentDir = Join-Path $Root 'control\agent'
$AgentPath = Join-Path $AgentDir 'nocta-vps-agent-v1.ps1'
$StateDir = Join-Path $AgentDir 'state'
$InstallerLogDir = Join-Path $Root 'logs\agent'
$InstallerLog = Join-Path $InstallerLogDir ("install-agent-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$AgentUrl = 'https://raw.githubusercontent.com/qluck7/first/main/nocta-vps-agent-v1.ps1'
$StartupKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$StartupName = 'NoctaVpsAgent'

New-Item -ItemType Directory -Force -Path $AgentDir, $StateDir, $InstallerLogDir | Out-Null
Start-Transcript -Path $InstallerLog -Force | Out-Null

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator.'
    }

    foreach ($command in @('gh.exe', 'git.exe', 'codex.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command is missing: $command"
        }
    }
    if (-not (Test-Path 'C:\Python312\python.exe')) { throw 'Python 3.12 is missing.' }
    if (-not (Test-Path 'C:\Nocta\collector\ProjectX\.git')) { throw 'Collector worktree is missing.' }
    if (-not (Test-Path 'C:\Nocta\development\NoctaDev\.git')) { throw 'Nocta worktree is missing.' }

    & gh.exe auth status | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }
    & gh.exe issue view 80 --repo qluck7/ProjectX --json number,title | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to access control issue #80.' }

    Write-Host '=== Downloading control agent ===' -ForegroundColor Cyan
    Invoke-WebRequest -Uri $AgentUrl -UseBasicParsing -OutFile $AgentPath
    if (-not (Test-Path $AgentPath)) { throw 'Agent download failed.' }

    Write-Host '=== Stopping older agent instances ===' -ForegroundColor Cyan
    $escaped = [regex]::Escape($AgentPath)
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $escaped } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
        }

    $startupCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Loop' -f $AgentPath
    New-Item -Path $StartupKey -Force | Out-Null
    New-ItemProperty -Path $StartupKey -Name $StartupName -PropertyType String -Value $startupCommand -Force | Out-Null

    Write-Host '=== Starting control agent ===' -ForegroundColor Cyan
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $AgentPath),
        '-Loop'
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 8
    if ($process.HasExited) {
        throw "Agent exited immediately with code $($process.ExitCode)."
    }

    $report = [ordered]@{
        status = 'PASS'
        installed_at = (Get-Date).ToUniversalTime().ToString('o')
        agent_path = $AgentPath
        process_id = $process.Id
        control_repo = 'qluck7/ProjectX'
        control_issue = 80
        startup = $startupCommand
        limitations = @(
            'Agent survives RDP disconnects.',
            'Agent restarts at the next Administrator login.',
            'After a full VPS reboot, log in once until a dedicated service account is configured.'
        )
        installer_log = $InstallerLog
    }
    $reportPath = Join-Path $StateDir 'installation.json'
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== NOCTA VPS AGENT INSTALL PASS ===' -ForegroundColor Green
    $report.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $reportPath"
    Write-Host 'The agent will now execute task 2026-07-26T15:45:00Z-collect-shares-tqtf from GitHub issue #80.' -ForegroundColor Yellow
}
catch {
    $failure = [ordered]@{
        status = 'FAIL'
        failed_at = (Get-Date).ToUniversalTime().ToString('o')
        error = $_.Exception.Message
        installer_log = $InstallerLog
    }
    $failure | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $StateDir 'installation.json') -Encoding UTF8
    Write-Host ''
    Write-Host '=== NOCTA VPS AGENT INSTALL FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
