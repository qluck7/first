#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$Root = 'C:\Nocta'
$StateDir = Join-Path $Root 'state'
$LogDir = Join-Path $Root 'logs\github-runner'
$BinDir = Join-Path $Root 'bin'
$Repo = 'qluck7/ProjectX'
$RunnerName = 'NOKTA-PILOT-AMS'
$GuardianPath = Join-Path $BinDir 'Ensure-NoctaGithubRunner.ps1'
$GuardianTask = 'NoctaGitHubRunnerGuardian'
$LogPath = Join-Path $LogDir ("repair-runner-codex-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$ReportPath = Join-Path $StateDir 'runner-codex-recovery.json'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $StateDir,$LogDir,$BinDir | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Write-JsonNoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    [IO.File]::WriteAllText($Path,(($Value | ConvertTo-Json -Depth 30) + "`r`n"),$Utf8NoBom)
}

function Stop-ProcessTreeByPattern {
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
    return $items.Count
}

function Invoke-CodexSmoke {
    $codex = Get-Command codex.exe -ErrorAction Stop
    $work = Join-Path $env:TEMP ("nocta-codex-smoke-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $last = Join-Path $work 'last-message.txt'
    $stdout = Join-Path $work 'stdout.jsonl'
    $stderr = Join-Path $work 'stderr.log'
    $prompt = 'Respond with exactly CODEX_READY. Do not read, write, or modify project files. Do not execute shell commands.'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $codex.Source
    $psi.WorkingDirectory = $env:TEMP
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($arg in @('exec','--sandbox','read-only','--json','--output-last-message',$last,'-')) {
        [void]$psi.ArgumentList.Add($arg)
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw 'Unable to start Codex smoke test.' }
    $process.StandardInput.Write($prompt)
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(180000)) {
        try { $process.Kill($true) } catch {}
        throw 'Codex smoke test timed out after 180 seconds.'
    }
    $outText = $stdoutTask.GetAwaiter().GetResult()
    $errText = $stderrTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText($stdout,$outText,$Utf8NoBom)
    [IO.File]::WriteAllText($stderr,$errText,$Utf8NoBom)
    $exitCode = $process.ExitCode
    $process.Dispose()
    $message = if (Test-Path $last) { (Get-Content $last -Raw).Trim() } else { '' }
    if ($exitCode -ne 0) { throw "Codex smoke test failed with exit code $exitCode. stderr: $errText" }
    if ($message -ne 'CODEX_READY') { throw "Unexpected Codex smoke response: $message" }
    return [ordered]@{
        status = 'PASS'
        version = (& $codex.Source --version 2>&1 | Out-String).Trim()
        response = $message
        stdout = $stdout
        stderr = $stderr
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator.'
    }
    foreach ($command in @('gh.exe','codex.exe','powershell.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command is missing: $command" }
    }
    & gh.exe auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }

    $service = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'qluck7-ProjectX' }) | Select-Object -First 1
    if (-not $service) { throw 'The ProjectX GitHub Actions runner service is missing.' }

    Write-Host '=== Stopping runner service and stale job processes ===' -ForegroundColor Cyan
    Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $stopped = Stop-ProcessTreeByPattern -Patterns @(
        'Runner\.Worker',
        'Runner\.Listener',
        'Collect-NoctaRequiredDataset\.ps1',
        'Invoke-NoctaVpsCommand\.ps1',
        'moex_v6_segment\.py',
        'codex\.exe.*exec'
    )

    Write-Host '=== Running direct Codex smoke test as Administrator ===' -ForegroundColor Cyan
    $codexResult = Invoke-CodexSmoke

    Write-Host '=== Installing local runner guardian ===' -ForegroundColor Cyan
    $guardian = @'
$ErrorActionPreference = 'SilentlyContinue'
$StateDir = 'C:\Nocta\state'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$service = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'qluck7-ProjectX' }) | Select-Object -First 1
$status = 'SERVICE_MISSING'
if ($service) {
    $listener = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)
    if ($service.Status -ne 'Running' -or $listener.Count -eq 0) {
        try { Restart-Service -Name $service.Name -Force -ErrorAction Stop } catch { try { Start-Service -Name $service.Name } catch {} }
        Start-Sleep -Seconds 5
        $service.Refresh()
    }
    $status = $service.Status.ToString()
}
$result = [ordered]@{
    checked_at = [DateTimeOffset]::UtcNow.ToString('o')
    service = if ($service) { $service.Name } else { $null }
    status = $status
    listener_processes = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue).Count
}
$result | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $StateDir 'github-runner-guardian.json') -Encoding UTF8
'@
    [IO.File]::WriteAllText($GuardianPath,$guardian,$Utf8NoBom)
    & schtasks.exe /Create /TN $GuardianTask /TR ("powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$GuardianPath`"") /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to register the runner guardian task.' }

    Write-Host '=== Enabling service recovery and restarting runner ===' -ForegroundColor Cyan
    & sc.exe failure $service.Name reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    Set-Service -Name $service.Name -StartupType Automatic
    Start-Service -Name $service.Name

    $runner = $null
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $json = (& gh.exe api "repos/$Repo/actions/runners?per_page=100" | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $json) {
            $response = $json | ConvertFrom-Json
            $runner = @($response.runners | Where-Object { [string]$_.name -eq $RunnerName }) | Select-Object -First 1
            if ($runner -and [string]$runner.status -eq 'online') { break }
        }
    }
    if (-not $runner -or [string]$runner.status -ne 'online') { throw 'Runner did not return online within 120 seconds.' }

    $service.Refresh()
    $report = [ordered]@{
        status = 'PASS'
        completed_at = [DateTimeOffset]::UtcNow.ToString('o')
        computer = $env:COMPUTERNAME
        stopped_stale_processes = $stopped
        codex = $codexResult
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
        guardian_task = $GuardianTask
        guardian_path = $GuardianPath
        log = $LogPath
    }
    Write-JsonNoBom -Path $ReportPath -Value $report
    Write-Host ''
    Write-Host '=== NOCTA RUNNER RECOVERY AND CODEX TEST PASS ===' -ForegroundColor Green
    $report.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $ReportPath"
    Write-Host 'Queued GitHub jobs may now start automatically.' -ForegroundColor Yellow
}
catch {
    $failure = [ordered]@{
        status = 'FAIL'
        failed_at = [DateTimeOffset]::UtcNow.ToString('o')
        error = $_.Exception.Message
        log = $LogPath
    }
    Write-JsonNoBom -Path $ReportPath -Value $failure
    Write-Host ''
    Write-Host '=== NOCTA RUNNER RECOVERY AND CODEX TEST FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
