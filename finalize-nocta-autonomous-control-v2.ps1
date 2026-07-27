#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'qluck7/ProjectX'
$RunnerName = 'NOKTA-PILOT-AMS'
$Root = 'C:\Nocta'
$BinDir = Join-Path $Root 'bin'
$StateDir = Join-Path $Root 'state'
$LogDir = Join-Path $Root 'logs\autonomy'
$AgentPath = Join-Path $BinDir 'NoctaOobAgent.ps1'
$AgentDownload = Join-Path $BinDir 'NoctaOobAgent.download.ps1'
$AgentUrl = 'https://raw.githubusercontent.com/qluck7/first/main/NoctaOobAgent.ps1?rev=970be268'
$AgentSha256 = '81bd92adad8c46791fc80e4e1d050575611e13b6d20cc720a7b8450f2c8d119d'
$MinuteTask = 'NoctaOobAgentMinute'
$StartupTask = 'NoctaOobAgentStartup'
$ReportPath = Join-Path $StateDir 'nocta-autonomous-control-v2.json'
$LogPath = Join-Path $LogDir ("finalize-autonomous-control-v2-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $BinDir,$StateDir,$LogDir | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Write-JsonNoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    [IO.File]::WriteAllText($Path,(($Value | ConvertTo-Json -Depth 40) + "`r`n"),$Utf8NoBom)
}

function Get-RunnerService {
    $service = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'qluck7-ProjectX' }) | Select-Object -First 1
    if (-not $service) { throw 'ProjectX GitHub Actions runner service is missing.' }
    return $service
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

function Wait-RunnerOnline {
    param([int]$TimeoutSeconds=180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        try {
            $raw = (& gh.exe api "repos/$Repo/actions/runners?per_page=100" | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $obj = $raw | ConvertFrom-Json
                $runner = @($obj.runners | Where-Object { [string]$_.name -eq $RunnerName }) | Select-Object -First 1
                if ($runner -and [string]$runner.status -eq 'online') { return $runner }
            }
        } catch {}
    }
    throw "Runner $RunnerName did not become online within $TimeoutSeconds seconds."
}

function Invoke-CodexSmoke {
    $result = [ordered]@{
        status='NOT_RUN'
        response=$null
        version=$null
        exit_code=$null
        error=$null
        working_directory='C:\Nocta\development\NoctaDev'
        stdout=$null
        stderr=$null
    }
    try {
        $repoPath = [string]$result.working_directory
        if (-not (Test-Path (Join-Path $repoPath '.git'))) { throw "Trusted NOCTA worktree is missing: $repoPath" }
        $codex = (Get-Command codex.exe -ErrorAction Stop).Source
        $result.version = (& $codex --version 2>&1 | Out-String).Trim()
        $work = Join-Path $env:TEMP ("nocta-codex-smoke-{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $last = Join-Path $work 'last-message.txt'
        $stdout = Join-Path $work 'stdout.jsonl'
        $stderr = Join-Path $work 'stderr.log'
        $result.stdout = $stdout
        $result.stderr = $stderr

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $codex
        $psi.WorkingDirectory = $repoPath
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.Arguments = 'exec --skip-git-repo-check --sandbox read-only --json --output-last-message "' + $last + '" -'

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        if (-not $process.Start()) { throw 'Unable to start Codex smoke test.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write('Respond with exactly CODEX_READY. Do not read, write, or modify project files. Do not execute shell commands.')
        $process.StandardInput.Close()

        if (-not $process.WaitForExit(180000)) {
            try { $process.Kill() } catch {}
            throw 'Codex smoke test timed out after 180 seconds.'
        }
        $process.WaitForExit()
        $outText = $stdoutTask.GetAwaiter().GetResult()
        $errText = $stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText($stdout,$outText,$Utf8NoBom)
        [IO.File]::WriteAllText($stderr,$errText,$Utf8NoBom)
        $exitCode = [int]$process.ExitCode
        $process.Dispose()
        $message = if (Test-Path $last) { (Get-Content $last -Raw).Trim() } else { '' }
        $result.exit_code = $exitCode
        $result.response = $message
        if ($exitCode -ne 0) { throw "Codex exited with code $exitCode. stderr: $errText" }
        if ($message -ne 'CODEX_READY') { throw "Unexpected Codex response: $message" }
        $result.status = 'PASS'
    }
    catch {
        $result.status = 'FAIL'
        $result.error = $_.Exception.Message
    }
    return $result
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as Administrator.' }
    foreach ($command in @('gh.exe','codex.exe','powershell.exe','schtasks.exe','sc.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Missing command: $command" }
    }
    & gh.exe auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }

    Write-Host '=== Installing independent out-of-band control agent ===' -ForegroundColor Cyan
    Invoke-WebRequest -Uri $AgentUrl -UseBasicParsing -OutFile $AgentDownload
    $actualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $AgentDownload).Hash.ToLowerInvariant()
    if ($actualSha -ne $AgentSha256) { throw "OOB agent SHA-256 mismatch: $actualSha" }
    [void][scriptblock]::Create((Get-Content $AgentDownload -Raw))
    Copy-Item -LiteralPath $AgentDownload -Destination $AgentPath -Force
    Remove-Item $AgentDownload -Force -ErrorAction SilentlyContinue

    $taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AgentPath`""
    & schtasks.exe /Create /TN $MinuteTask /TR $taskCommand /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to create $MinuteTask." }
    & schtasks.exe /Create /TN $StartupTask /TR $taskCommand /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to create $StartupTask." }

    Write-Host '=== Force-recovering official GitHub runner once ===' -ForegroundColor Cyan
    $service = Get-RunnerService
    try { Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue } catch {}
    $killed = Stop-RunnerProcesses
    Set-Service -Name $service.Name -StartupType Automatic
    & sc.exe failure $service.Name reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    & sc.exe failureflag $service.Name 1 | Out-Null
    Start-Service -Name $service.Name
    $runner = Wait-RunnerOnline -TimeoutSeconds 180

    Write-Host '=== Running non-blocking Codex proof ===' -ForegroundColor Cyan
    $codex = Invoke-CodexSmoke

    Write-Host '=== Triggering queued health command ===' -ForegroundColor Cyan
    $workflowTriggered = $false
    try {
        & gh.exe workflow run nocta-vps-command.yml --repo $Repo | Out-Null
        $workflowTriggered = ($LASTEXITCODE -eq 0)
    } catch {}

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AgentPath
    $oobState = $null
    if (Test-Path (Join-Path $StateDir 'oob-agent.json')) {
        try { $oobState = Get-Content (Join-Path $StateDir 'oob-agent.json') -Raw | ConvertFrom-Json } catch {}
    }

    $secretNames = @()
    try { $secretNames = @(& gh.exe secret list --repo $Repo --json name --jq '.[].name' 2>$null) } catch {}
    $requiredSecrets = @('SERVERSPACE_API_KEY','SERVERSPACE_SERVER_ID','SERVERSPACE_API_BASE')
    $missingSecrets = @($requiredSecrets | Where-Object { $_ -notin $secretNames })

    $service.Refresh()
    $report = [ordered]@{
        schema='nocta-autonomous-control/v2'
        status='PASS'
        completed_at=[DateTimeOffset]::UtcNow.ToString('o')
        computer=$env:COMPUTERNAME
        runner=[ordered]@{
            id=$runner.id
            name=$runner.name
            status=$runner.status
            busy=$runner.busy
            labels=@($runner.labels | ForEach-Object { $_.name })
        }
        service=[ordered]@{
            name=$service.Name
            status=$service.Status.ToString()
            start_type=$service.StartType.ToString()
            killed_stale_processes=$killed
        }
        out_of_band=[ordered]@{
            agent_path=$AgentPath
            minute_task=$MinuteTask
            startup_task=$StartupTask
            command_url='https://raw.githubusercontent.com/qluck7/first/main/nocta-oob-command.json'
            state=$oobState
        }
        codex=$codex
        workflow_triggered=$workflowTriggered
        serverspace_secrets_present=($missingSecrets.Count -eq 0)
        missing_serverspace_secret_names=$missingSecrets
        log=$LogPath
    }
    Write-JsonNoBom -Path $ReportPath -Value $report

    Write-Host ''
    Write-Host '=== NOCTA AUTONOMOUS CONTROL V2 PASS ===' -ForegroundColor Green
    Write-Host "Runner: $($runner.status); service: $($service.Status)"
    Write-Host "OOB control: $MinuteTask + $StartupTask"
    Write-Host "Codex smoke: $($codex.status) $($codex.response)"
    Write-Host "Serverspace secrets present: $($missingSecrets.Count -eq 0)"
    Write-Host "Report: $ReportPath"
    Write-Host 'Normal runner recovery no longer requires RDP.' -ForegroundColor Yellow
}
catch {
    try {
        if (Test-Path $AgentPath) {
            & schtasks.exe /Run /TN $MinuteTask 2>$null | Out-Null
        }
    } catch {}
    $failure = [ordered]@{
        schema='nocta-autonomous-control/v2'
        status='FAIL'
        failed_at=[DateTimeOffset]::UtcNow.ToString('o')
        error=$_.Exception.Message
        log=$LogPath
        note='The installer attempted to leave the OOB recovery tasks active.'
    }
    Write-JsonNoBom -Path $ReportPath -Value $failure
    Write-Host ''
    Write-Host '=== NOCTA AUTONOMOUS CONTROL V2 FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally {
    Remove-Item $AgentDownload -Force -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch {}
}
