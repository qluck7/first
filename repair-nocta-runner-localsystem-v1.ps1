#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'qluck7/ProjectX'
$RunnerName = 'NOKTA-PILOT-AMS'
$Root = 'C:\Nocta'
$BinDir = Join-Path $Root 'bin'
$StateDir = Join-Path $Root 'state'
$LogDir = Join-Path $Root 'logs\runner-repair'
$ReportPath = Join-Path $StateDir 'runner-localsystem-repair-v1.json'
$LogPath = Join-Path $LogDir ("runner-localsystem-repair-v1-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$SystemProfile = Join-Path $env:SystemRoot 'System32\config\systemprofile'
$SystemCodex = Join-Path $SystemProfile '.codex'
$SystemGh = Join-Path $SystemProfile 'AppData\Roaming\GitHub CLI'
$SmokeScript = Join-Path $BinDir 'Test-NoctaCodexAsSystem.ps1'
$SmokeResult = Join-Path $StateDir 'codex-system-smoke.json'
$SmokeTask = 'NoctaCodexSystemSmoke'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $BinDir,$StateDir,$LogDir,$SystemProfile | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Write-JsonNoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    [IO.File]::WriteAllText($Path,(($Value | ConvertTo-Json -Depth 40) + "`r`n"),$Utf8NoBom)
}

function Get-RunnerService {
    $service = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'actions.runner.*' -and $_.Name -match 'qluck7-ProjectX' }) |
        Select-Object -First 1
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

function Copy-PrivateDirectory {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination)
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & robocopy.exe $Source $Destination /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    $code = $LASTEXITCODE
    if ($code -gt 7) { throw "Unable to copy private directory from $Source to $Destination; robocopy exit code $code." }
    & icacls.exe $Destination /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to secure copied directory: $Destination" }
    return $true
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
        } catch {}
    }
    throw "Runner $RunnerName did not become online within $TimeoutSeconds seconds."
}

function Install-SystemCodexSmoke {
    param([Parameter(Mandatory)][string]$CodexPath)
    $repoPath = 'C:\Nocta\development\NoctaDev'
    $codexEsc = $CodexPath.Replace("'","''")
    $repoEsc = $repoPath.Replace("'","''")
    $resultEsc = $SmokeResult.Replace("'","''")
    $text = @"
`$ErrorActionPreference = 'Stop'
`$result = [ordered]@{status='FAIL';completed_at=[DateTimeOffset]::UtcNow.ToString('o');user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;response=`$null;version=`$null;error=`$null}
try {
    Set-Location -LiteralPath '$repoEsc'
    `$codex = '$codexEsc'
    `$result.version = (& `$codex --version 2>&1 | Out-String).Trim()
    `$work = Join-Path `$env:TEMP ('nocta-system-codex-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path `$work | Out-Null
    `$last = Join-Path `$work 'last-message.txt'
    `$psi = New-Object Diagnostics.ProcessStartInfo
    `$psi.FileName = `$codex
    `$psi.WorkingDirectory = '$repoEsc'
    `$psi.UseShellExecute = `$false
    `$psi.CreateNoWindow = `$true
    `$psi.RedirectStandardInput = `$true
    `$psi.RedirectStandardOutput = `$true
    `$psi.RedirectStandardError = `$true
    `$psi.Arguments = 'exec --skip-git-repo-check --sandbox read-only --json --output-last-message "' + `$last + '" -'
    `$process = New-Object Diagnostics.Process
    `$process.StartInfo = `$psi
    if (-not `$process.Start()) { throw 'Unable to start Codex as SYSTEM.' }
    `$stdoutTask = `$process.StandardOutput.ReadToEndAsync()
    `$stderrTask = `$process.StandardError.ReadToEndAsync()
    `$process.StandardInput.Write('Respond with exactly CODEX_READY. Do not read, write, or modify project files. Do not execute shell commands.')
    `$process.StandardInput.Close()
    if (-not `$process.WaitForExit(180000)) { try { `$process.Kill() } catch {}; throw 'SYSTEM Codex smoke timed out.' }
    `$process.WaitForExit()
    `$stdout = `$stdoutTask.GetAwaiter().GetResult()
    `$stderr = `$stderrTask.GetAwaiter().GetResult()
    `$exitCode = `$process.ExitCode
    `$process.Dispose()
    `$message = if (Test-Path `$last) { (Get-Content `$last -Raw).Trim() } else { '' }
    if (`$exitCode -ne 0) { throw "Codex exited with code `$exitCode. stderr: `$stderr" }
    if (`$message -ne 'CODEX_READY') { throw "Unexpected Codex response: `$message" }
    `$result.status = 'PASS'
    `$result.response = `$message
}
catch { `$result.error = `$_.Exception.Message }
`$result.completed_at = [DateTimeOffset]::UtcNow.ToString('o')
[IO.File]::WriteAllText('$resultEsc', ((`$result | ConvertTo-Json -Depth 20) + "`r`n"), (New-Object Text.UTF8Encoding(`$false)))
if (`$result.status -ne 'PASS') { exit 1 }
"@
    [IO.File]::WriteAllText($SmokeScript,$text,$Utf8NoBom)
    [void][scriptblock]::Create((Get-Content $SmokeScript -Raw))
    Remove-Item $SmokeResult -Force -ErrorAction SilentlyContinue
    $taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SmokeScript`""
    & schtasks.exe /Create /TN $SmokeTask /TR $taskCommand /SC ONCE /ST 23:59 /RU SYSTEM /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to create $SmokeTask." }
    & schtasks.exe /Run /TN $SmokeTask | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to start $SmokeTask." }
    $deadline = (Get-Date).AddSeconds(190)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $SmokeResult)) { Start-Sleep -Seconds 3 }
    if (-not (Test-Path $SmokeResult)) { throw 'SYSTEM Codex smoke result was not created.' }
    $result = Get-Content $SmokeResult -Raw | ConvertFrom-Json
    if ([string]$result.status -ne 'PASS') { throw "SYSTEM Codex smoke failed: $($result.error)" }
    return $result
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as Administrator.' }
    foreach ($command in @('gh.exe','codex.exe','git.exe','powershell.exe','schtasks.exe','sc.exe','robocopy.exe','icacls.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Missing required command: $command" }
    }
    & gh.exe auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated for the Administrator session.' }

    $serviceBefore = Get-RunnerService
    $serviceName = [string]$serviceBefore.Name
    $codexPath = (Get-Command codex.exe -ErrorAction Stop).Source
    $codexDirectory = Split-Path -Parent $codexPath

    Write-Host '=== Copying Codex and GitHub CLI credentials to the SYSTEM profile ===' -ForegroundColor Cyan
    $copiedCodex = Copy-PrivateDirectory -Source (Join-Path $env:USERPROFILE '.codex') -Destination $SystemCodex
    $adminGh = Join-Path $env:APPDATA 'GitHub CLI'
    $copiedGh = Copy-PrivateDirectory -Source $adminGh -Destination $SystemGh

    Write-Host '=== Ensuring Codex is available in the machine PATH ===' -ForegroundColor Cyan
    $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
    $parts = @($machinePath -split ';' | Where-Object { $_ })
    if ($codexDirectory -notin $parts) {
        [Environment]::SetEnvironmentVariable('Path',(($parts + $codexDirectory) -join ';'),'Machine')
    }
    & icacls.exe $codexDirectory /grant '*S-1-5-18:(OI)(CI)RX' /T /C | Out-Null

    Write-Host '=== Converting GitHub Actions runner service to LocalSystem ===' -ForegroundColor Cyan
    try { Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 3
    $killed = Stop-RunnerProcesses
    & sc.exe config $serviceName obj= LocalSystem start= auto | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to change the runner service account to LocalSystem.' }
    & sc.exe failure $serviceName reset= 86400 actions= restart/30000/restart/60000/restart/120000 | Out-Null
    & sc.exe failureflag $serviceName 1 | Out-Null
    Start-Service -Name $serviceName

    Write-Host '=== Waiting for the repository runner to reconnect ===' -ForegroundColor Cyan
    $runner = Wait-RunnerOnline -TimeoutSeconds 180
    $serviceAfter = Get-RunnerService

    Write-Host '=== Proving Codex works in the SYSTEM service context ===' -ForegroundColor Cyan
    $codexSmoke = Install-SystemCodexSmoke -CodexPath $codexPath

    Write-Host '=== Dispatching the hardened priority Codex audit ===' -ForegroundColor Cyan
    & gh.exe workflow run nocta-vps-codex-priority.yml --repo $Repo --ref main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to dispatch the priority Codex workflow.' }

    $workflow = $null
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        try {
            $raw = (& gh.exe api "repos/$Repo/actions/workflows/nocta-vps-codex-priority.yml/runs?per_page=5" | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $runs = ($raw | ConvertFrom-Json).workflow_runs
                $workflow = @($runs | Where-Object { $_.event -eq 'workflow_dispatch' } | Sort-Object created_at -Descending) | Select-Object -First 1
                if ($workflow -and [string]$workflow.status -in @('queued','in_progress','completed')) { break }
            }
        } catch {}
    }
    if (-not $workflow) { throw 'GitHub did not expose the dispatched priority Codex workflow within 90 seconds.' }

    $report = [ordered]@{
        schema = 'nocta-runner-localsystem-repair/v1'
        status = 'PASS'
        completed_at = [DateTimeOffset]::UtcNow.ToString('o')
        computer = $env:COMPUTERNAME
        service = [ordered]@{
            name = $serviceName
            start_name_before = [string]$serviceBefore.StartName
            start_name_after = [string]$serviceAfter.StartName
            state = [string]$serviceAfter.State
            start_mode = [string]$serviceAfter.StartMode
            killed_stale_processes = $killed
        }
        runner = [ordered]@{
            id = $runner.id
            name = $runner.name
            status = $runner.status
            busy = $runner.busy
            labels = @($runner.labels | ForEach-Object { $_.name })
        }
        credentials = [ordered]@{
            codex_copied_to_system = $copiedCodex
            github_cli_copied_to_system = $copiedGh
        }
        codex_system_smoke = $codexSmoke
        dispatched_workflow = [ordered]@{
            id = $workflow.id
            status = $workflow.status
            conclusion = $workflow.conclusion
            created_at = $workflow.created_at
            html_url = $workflow.html_url
        }
        log = $LogPath
    }
    Write-JsonNoBom -Path $ReportPath -Value $report

    Write-Host ''
    Write-Host '=== NOCTA RUNNER LOCALSYSTEM REPAIR V1 PASS ===' -ForegroundColor Green
    Write-Host "Service account: $($serviceBefore.StartName) -> $($serviceAfter.StartName)"
    Write-Host "Runner: $($runner.status); busy: $($runner.busy)"
    Write-Host "Codex as SYSTEM: $($codexSmoke.status) / $($codexSmoke.response)"
    Write-Host "Codex audit workflow: $($workflow.status); run id: $($workflow.id)"
    Write-Host "Report: $ReportPath"
    Write-Host 'After this PASS, the runner no longer depends on the Administrator password or login session.' -ForegroundColor Yellow
}
catch {
    $failure = [ordered]@{
        schema = 'nocta-runner-localsystem-repair/v1'
        status = 'FAIL'
        failed_at = [DateTimeOffset]::UtcNow.ToString('o')
        error = $_.Exception.Message
        log = $LogPath
    }
    Write-JsonNoBom -Path $ReportPath -Value $failure
    Write-Host ''
    Write-Host '=== NOCTA RUNNER LOCALSYSTEM REPAIR V1 FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
