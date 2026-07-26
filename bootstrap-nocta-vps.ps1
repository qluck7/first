#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = 'C:\Nocta'
$LogDir = Join-Path $Root 'logs\bootstrap'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogPath = Join-Path $LogDir ("bootstrap-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $LogPath -Force | Out-Null

function Refresh-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Assert-ExitCode {
    param([string]$Name)
    $valid = @(0, 1605, 1614, 1641, 3010)
    if ($valid -notcontains $LASTEXITCODE) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
}

function Install-ChocoPackage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$ExtraArgs = @()
    )
    Write-Host "`n=== Installing/upgrading $Name ===" -ForegroundColor Cyan
    & choco.exe upgrade $Name -y --no-progress @ExtraArgs
    Assert-ExitCode $Name
    Refresh-ProcessPath
}

try {
    Write-Host "=== NOCTA WINDOWS VPS BOOTSTRAP ===" -ForegroundColor Green
    Write-Host "Log: $LogPath"

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator.'
    }

    Set-ExecutionPolicy Bypass -Scope Process -Force

    if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
        Write-Host "`n=== Installing Chocolatey ===" -ForegroundColor Cyan
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        Refresh-ProcessPath
    }

    Install-ChocoPackage -Name 'git.install' -ExtraArgs @('--params', "'/GitAndUnixToolsOnPath /NoAutoCrlf'")
    Install-ChocoPackage -Name 'python312'
    Install-ChocoPackage -Name 'nodejs-lts'
    Install-ChocoPackage -Name 'gh'
    Install-ChocoPackage -Name '7zip'
    Install-ChocoPackage -Name 'powershell-core'

    Write-Host "`n=== Installing Codex CLI from official OpenAI installer ===" -ForegroundColor Cyan
    if (-not (Get-Command codex.exe -ErrorAction SilentlyContinue)) {
        $installer = Invoke-RestMethod -Uri 'https://chatgpt.com/codex/install.ps1'
        Invoke-Expression $installer
        Refresh-ProcessPath
    }

    Write-Host "`n=== Configuring Python toolchain ===" -ForegroundColor Cyan
    & py.exe -3.12 -m pip install --upgrade pip
    if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed: $LASTEXITCODE" }
    & py.exe -3.12 -m pip install --upgrade requests pytest pyinstaller virtualenv psutil
    if ($LASTEXITCODE -ne 0) { throw "Python tooling install failed: $LASTEXITCODE" }

    Write-Host "`n=== Creating Nocta directory layout ===" -ForegroundColor Cyan
    $Directories = @(
        'development\source',
        'development\worktrees',
        'development\tests',
        'runtime\current',
        'runtime\previous',
        'artifacts\candidate',
        'artifacts\approved',
        'market-data\segments',
        'market-data\assembled',
        'control\collector',
        'control\nocta',
        'state',
        'logs\collector',
        'logs\codex',
        'logs\nocta'
    )
    foreach ($relative in $Directories) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Root $relative) | Out-Null
    }

    Write-Host "`n=== Applying safe development settings ===" -ForegroundColor Cyan
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -PropertyType DWord -Value 1 -Force | Out-Null
    & git.exe config --system core.longpaths true
    & git.exe config --global init.defaultBranch main
    & git.exe config --global core.autocrlf true

    Refresh-ProcessPath

    $versions = [ordered]@{
        status = 'PASS'
        completed_at = (Get-Date).ToString('o')
        computer = $env:COMPUTERNAME
        powershell_desktop = $PSVersionTable.PSVersion.ToString()
        git = (& git.exe --version 2>&1 | Out-String).Trim()
        python = (& py.exe -3.12 --version 2>&1 | Out-String).Trim()
        pip = (& py.exe -3.12 -m pip --version 2>&1 | Out-String).Trim()
        node = (& node.exe --version 2>&1 | Out-String).Trim()
        npm = (& npm.cmd --version 2>&1 | Out-String).Trim()
        gh = (& gh.exe --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
        codex = (& codex.exe --version 2>&1 | Out-String).Trim()
        seven_zip = if (Test-Path "$env:ProgramFiles\7-Zip\7z.exe") { (& "$env:ProgramFiles\7-Zip\7z.exe" i 2>&1 | Select-Object -First 2 | Out-String).Trim() } else { 'not-found' }
        root = $Root
        log = $LogPath
    }

    $ReportPath = Join-Path $Root 'state\bootstrap-report.json'
    $versions | ConvertTo-Json -Depth 4 | Set-Content -Path $ReportPath -Encoding UTF8

    Write-Host "`n=== BOOTSTRAP PASS ===" -ForegroundColor Green
    $versions.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $ReportPath"
    Write-Host "Log:    $LogPath"
    Write-Host "`nNext: restart Windows, then run 'gh auth login' and 'codex'." -ForegroundColor Yellow
}
catch {
    $failure = [ordered]@{
        status = 'FAIL'
        failed_at = (Get-Date).ToString('o')
        error = $_.Exception.Message
        script_stack = $_.ScriptStackTrace
        log = $LogPath
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'state') | Out-Null
    $failure | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $Root 'state\bootstrap-report.json') -Encoding UTF8
    Write-Host "`n=== BOOTSTRAP FAIL ===" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
