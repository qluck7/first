#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'qluck7/ProjectX'
$RepoUrl = 'https://github.com/qluck7/ProjectX'
$RunnerName = $env:COMPUTERNAME
$RunnerLabels = 'nocta-vps,moex-collector,nocta-build'
$RunnerRoot = 'C:\actions-runner'
$RunnerArchiveRoot = 'C:\Nocta\archives\actions-runner'
$StateDir = 'C:\Nocta\state'
$LogDir = 'C:\Nocta\logs\github-runner'
$OldTasks = @('NoctaVpsAgentV1', 'NoctaVpsWatchdogV1')
$LogPath = Join-Path $LogDir ("install-github-runner-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$ReportPath = Join-Path $StateDir 'github-runner-installation.json'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $RunnerArchiveRoot, $StateDir, $LogDir | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Write-JsonNoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 30) + "`r`n"), $Utf8NoBom)
}

function Quote-NativeArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $PWD.Path,
        [int]$TimeoutSeconds = 600
    )

    $stdoutPath = Join-Path $env:TEMP ("nocta-native-{0}.stdout.log" -f ([guid]::NewGuid().ToString('N')))
    $stderrPath = Join-Path $env:TEMP ("nocta-native-{0}.stderr.log" -f ([guid]::NewGuid().ToString('N')))
    $joinedArguments = (($Arguments | ForEach-Object { Quote-NativeArgument -Value ([string]$_) }) -join ' ')
    $effectiveFilePath = $FilePath
    $effectiveArgumentLine = $joinedArguments
    if ([IO.Path]::GetExtension($FilePath) -in @('.cmd', '.bat')) {
        $effectiveFilePath = $env:ComSpec
        $effectiveArgumentLine = "/d /c $FilePath $joinedArguments"
    }

    try {
        $process = Start-Process `
            -FilePath $effectiveFilePath `
            -ArgumentList $effectiveArgumentLine `
            -WorkingDirectory $WorkingDirectory `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -WindowStyle Hidden `
            -PassThru

        try {
            Wait-Process -Id $process.Id -Timeout $TimeoutSeconds -ErrorAction Stop
        }
        catch {
            try { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null } catch {}
            throw "Process timed out after $TimeoutSeconds seconds: $FilePath"
        }
        $process.Refresh()
        return [ordered]@{
            exit_code = $process.ExitCode
            stdout = if (Test-Path $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
            stderr = if (Test-Path $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Stop-OldNoctaProcesses {
    $patterns = @(
        'nocta-vps-agent-v1\.ps1',
        'nocta-vps-watchdog-v1\.ps1',
        'nocta-vps-supervisor-v3\.ps1',
        'nocta_vps_controller_v2\.py',
        'moex_v6_segment\.py'
    )
    $items = @(Get-CimInstance Win32_Process | Where-Object {
        if (-not $_.CommandLine -or $_.ProcessId -eq $PID) { return $false }
        foreach ($pattern in $patterns) {
            if ([string]$_.CommandLine -match $pattern) { return $true }
        }
        return $false
    })
    foreach ($item in $items) {
        try { & taskkill.exe /PID ([int]$item.ProcessId) /T /F 2>$null | Out-Null } catch {}
    }
}

function Test-WindowsPassword {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$Password
    )

    if (-not ('Nocta.NativeLogon' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace Nocta {
    public static class NativeLogon {
        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern bool LogonUser(
            string userName,
            string domain,
            string password,
            int logonType,
            int logonProvider,
            out IntPtr token);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool CloseHandle(IntPtr handle);
    }
}
"@
    }

    $tokenHandle = [IntPtr]::Zero
    $ok = [Nocta.NativeLogon]::LogonUser($UserName, $Domain, $Password, 2, 0, [ref]$tokenHandle)
    if ($tokenHandle -ne [IntPtr]::Zero) { [void][Nocta.NativeLogon]::CloseHandle($tokenHandle) }
    return $ok
}

function Get-RepoRunner {
    param([Parameter(Mandatory)][string]$Name)
    $json = (& gh.exe api "repos/$Repo/actions/runners?per_page=100" | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to list repository runners.' }
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }
    $response = $json | ConvertFrom-Json
    return @($response.runners | Where-Object { [string]$_.name -eq $Name }) | Select-Object -First 1
}

function Remove-ExistingRunnerRegistration {
    param([Parameter(Mandatory)][string]$Directory)
    $config = Join-Path $Directory 'config.cmd'
    $runnerMarker = Join-Path $Directory '.runner'
    if (-not (Test-Path $config) -or -not (Test-Path $runnerMarker)) { return }

    Write-Host 'Removing the previous GitHub runner registration...' -ForegroundColor Yellow
    $removeToken = (& gh.exe api --method POST "repos/$Repo/actions/runners/remove-token" --jq '.token' | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($removeToken)) {
        throw 'Unable to obtain a GitHub runner removal token.'
    }
    $result = Invoke-Native -FilePath $config -Arguments @('remove', '--unattended', '--token', $removeToken) -WorkingDirectory $Directory -TimeoutSeconds 180
    if ([int]$result.exit_code -ne 0) {
        Write-Host 'Previous runner removal returned an error; continuing with a clean replacement.' -ForegroundColor Yellow
        Write-Host $result.stderr -ForegroundColor DarkYellow
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator.'
    }

    foreach ($command in @('gh.exe', 'git.exe', 'powershell.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command is missing: $command"
        }
    }
    & gh.exe auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }
    & gh.exe repo view $Repo --json nameWithOwner,isPrivate *> $null
    if ($LASTEXITCODE -ne 0) { throw "Unable to access private repository $Repo." }

    Write-Host '=== Retiring the old custom control chain ===' -ForegroundColor Cyan
    foreach ($taskName in $OldTasks) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            try {
                $xml = Export-ScheduledTask -TaskName $taskName
                $taskArchive = Join-Path $RunnerArchiveRoot ("scheduled-task-{0}-{1}.xml" -f $taskName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
                [IO.File]::WriteAllText($taskArchive, $xml, $Utf8NoBom)
            } catch {}
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Disable-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Stop-OldNoctaProcesses
    Start-Sleep -Seconds 2

    $existingServices = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue)
    foreach ($service in $existingServices) {
        try { Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue } catch {}
    }

    if (Test-Path $RunnerRoot) {
        try { Remove-ExistingRunnerRegistration -Directory $RunnerRoot } catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
        $archive = Join-Path $RunnerArchiveRoot ("actions-runner-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $RunnerRoot -Destination $archive -Force
    }
    New-Item -ItemType Directory -Force -Path $RunnerRoot | Out-Null

    Write-Host '=== Resolving the latest official Windows x64 runner ===' -ForegroundColor Cyan
    $releaseHeaders = @{
        'User-Agent' = 'nocta-vps-runner-bootstrap'
        'Accept' = 'application/vnd.github+json'
    }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' -Headers $releaseHeaders -UseBasicParsing
    $asset = @($release.assets | Where-Object { [string]$_.name -match '^actions-runner-win-x64-.*\.zip$' }) | Select-Object -First 1
    if (-not $asset) { throw 'The latest GitHub Actions runner release has no Windows x64 ZIP asset.' }

    $zipPath = Join-Path $RunnerRoot ([string]$asset.name)
    Write-Host ("Downloading {0} ({1})..." -f $asset.name, $release.tag_name) -ForegroundColor Cyan
    Invoke-WebRequest -Uri ([string]$asset.browser_download_url) -UseBasicParsing -OutFile $zipPath
    if (-not (Test-Path $zipPath)) { throw 'GitHub Actions runner download failed.' }

    $downloadSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
    $expectedDigest = [string]$asset.digest
    if (-not [string]::IsNullOrWhiteSpace($expectedDigest) -and $expectedDigest -match '^sha256:(.+)$') {
        $expectedSha = $Matches[1].ToLowerInvariant()
        if ($downloadSha -ne $expectedSha) {
            throw "Runner SHA-256 mismatch: expected $expectedSha, got $downloadSha"
        }
    }

    Write-Host '=== Extracting the official runner ===' -ForegroundColor Cyan
    Expand-Archive -LiteralPath $zipPath -DestinationPath $RunnerRoot -Force
    Remove-Item -LiteralPath $zipPath -Force
    $configPath = Join-Path $RunnerRoot 'config.cmd'
    if (-not (Test-Path $configPath)) { throw 'config.cmd is missing after runner extraction.' }

    Write-Host ''
    Write-Host 'Enter the Windows Administrator password in the secure LOCAL prompt.' -ForegroundColor Yellow
    Write-Host 'It is used only to register the Windows service and must not be sent to chat.' -ForegroundColor Yellow
    $securePassword = Read-Host 'Administrator password' -AsSecureString
    if (-not $securePassword) { throw 'Administrator password was not supplied.' }
    $plainPassword = [Net.NetworkCredential]::new('', $securePassword).Password
    if ([string]::IsNullOrWhiteSpace($plainPassword)) { throw 'Administrator password is empty.' }

    $account = $identity.Name
    $accountParts = @($account -split '\\', 2)
    $domain = if ($accountParts.Count -eq 2) { $accountParts[0] } else { $env:COMPUTERNAME }
    $userName = if ($accountParts.Count -eq 2) { $accountParts[1] } else { $env:USERNAME }
    if (-not (Test-WindowsPassword -UserName $userName -Domain $domain -Password $plainPassword)) {
        throw 'The Windows Administrator password is incorrect.'
    }

    Write-Host '=== Obtaining a one-hour repository registration token ===' -ForegroundColor Cyan
    $registrationToken = (& gh.exe api --method POST "repos/$Repo/actions/runners/registration-token" --jq '.token' | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($registrationToken)) {
        throw 'Unable to obtain a GitHub runner registration token.'
    }

    Write-Host '=== Registering the runner as a Windows service ===' -ForegroundColor Cyan
    $env:ACTIONS_RUNNER_INPUT_WINDOWSLOGONPASSWORD = $plainPassword
    $env:VSTS_AGENT_INPUT_WINDOWSLOGONPASSWORD = $plainPassword
    try {
        $configure = Invoke-Native `
            -FilePath $configPath `
            -Arguments @(
                '--unattended',
                '--url', $RepoUrl,
                '--token', $registrationToken,
                '--name', $RunnerName,
                '--labels', $RunnerLabels,
                '--work', '_work',
                '--replace',
                '--runasservice',
                '--windowslogonaccount', $account
            ) `
            -WorkingDirectory $RunnerRoot `
            -TimeoutSeconds 300
    }
    finally {
        Remove-Item Env:ACTIONS_RUNNER_INPUT_WINDOWSLOGONPASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:VSTS_AGENT_INPUT_WINDOWSLOGONPASSWORD -ErrorAction SilentlyContinue
        $plainPassword = $null
        $securePassword = $null
    }
    if ([int]$configure.exit_code -ne 0) {
        throw "Runner configuration failed with exit code $($configure.exit_code): $($configure.stderr) $($configure.stdout)"
    }

    $service = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match [regex]::Escape($RunnerName) }) | Select-Object -First 1
    if (-not $service) {
        $service = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue) | Select-Object -First 1
    }
    if (-not $service) { throw 'The GitHub Actions runner service was not created.' }

    Set-Service -Name $service.Name -StartupType Automatic
    if ((Get-Service -Name $service.Name).Status -ne 'Running') { Start-Service -Name $service.Name }
    & sc.exe failure $service.Name reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    & sc.exe failureflag $service.Name 1 | Out-Null

    Write-Host '=== Waiting for the runner to become ONLINE ===' -ForegroundColor Cyan
    $runner = $null
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        try { $runner = Get-RepoRunner -Name $RunnerName } catch { $runner = $null }
        if ($runner -and [string]$runner.status -eq 'online') { break }
    }
    if (-not $runner) { throw "Runner $RunnerName was not found in repository $Repo." }
    if ([string]$runner.status -ne 'online') { throw "Runner $RunnerName is registered but not online; status=$($runner.status)" }
    $labelNames = @($runner.labels | ForEach-Object { [string]$_.name })
    if ($labelNames -notcontains 'nocta-vps') { throw 'Runner is online but the custom label nocta-vps is missing.' }

    $serviceInfo = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $service.Name.Replace("'", "''"))
    $report = [ordered]@{
        status = 'PASS'
        installed_at = (Get-Date).ToUniversalTime().ToString('o')
        repository = $Repo
        repository_private = $true
        runner_name = [string]$runner.name
        runner_id = $runner.id
        runner_status = [string]$runner.status
        runner_busy = [bool]$runner.busy
        runner_labels = $labelNames
        runner_release = [string]$release.tag_name
        runner_asset = [string]$asset.name
        runner_sha256 = $downloadSha
        service_name = $service.Name
        service_status = (Get-Service -Name $service.Name).Status.ToString()
        service_start_type = $serviceInfo.StartMode
        service_account = $account
        runner_root = $RunnerRoot
        old_tasks_disabled = $OldTasks
        install_log = $LogPath
    }
    Write-JsonNoBom -Path $ReportPath -Value $report

    Write-Host ''
    Write-Host '=== NOCTA GITHUB RUNNER INSTALL PASS ===' -ForegroundColor Green
    $report.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $ReportPath"
    Write-Host 'The official self-hosted runner is online. Old custom controllers are disabled.' -ForegroundColor Yellow
}
catch {
    $failure = [ordered]@{
        status = 'FAIL'
        failed_at = (Get-Date).ToUniversalTime().ToString('o')
        error = $_.Exception.Message
        install_log = $LogPath
    }
    Write-JsonNoBom -Path $ReportPath -Value $failure
    Write-Host ''
    Write-Host '=== NOCTA GITHUB RUNNER INSTALL FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally {
    Remove-Item Env:ACTIONS_RUNNER_INPUT_WINDOWSLOGONPASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:VSTS_AGENT_INPUT_WINDOWSLOGONPASSWORD -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch {}
}
