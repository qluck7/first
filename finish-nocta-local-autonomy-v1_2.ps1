#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

$Repo = 'qluck7/ProjectX'
$RunnerName = 'NOKTA-PILOT-AMS'
$GuardianIssue = 83
$Root = 'C:\Nocta'
$StateDir = Join-Path $Root 'state'
$BinDir = Join-Path $Root 'bin'
$LogDir = Join-Path $Root 'logs\autonomy'
$GuardianPath = Join-Path $BinDir 'NoctaRunnerGuardian.ps1'
$MinuteTask = 'NoctaRunnerGuardianMinute'
$StartupTask = 'NoctaRunnerGuardianStartup'
$ReportPath = Join-Path $StateDir 'nocta-local-autonomy-v1_2.json'
$LogPath = Join-Path $LogDir ("finish-local-autonomy-v12-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $StateDir,$BinDir,$LogDir | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Write-JsonNoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    [IO.File]::WriteAllText($Path,(($Value | ConvertTo-Json -Depth 40) + "`r`n"),$Utf8NoBom)
}

function Get-RunnerService {
    $service = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'qluck7-ProjectX' }) | Select-Object -First 1
    if (-not $service) { throw 'ProjectX GitHub Actions runner service is missing.' }
    return $service
}

function Install-Guardian {
    $guardian = @'
$ErrorActionPreference = 'SilentlyContinue'
$StateDir = 'C:\Nocta\state'
$StatePath = Join-Path $StateDir 'runner-guardian.json'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$mutex = New-Object Threading.Mutex($false,'Global\NoctaRunnerGuardianV12')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    $previous = $null
    if (Test-Path $StatePath) { try { $previous = Get-Content $StatePath -Raw | ConvertFrom-Json } catch {} }
    $failures = if ($previous -and $previous.failure_count) { [int]$previous.failure_count } else { 0 }
    $service = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'qluck7-ProjectX' }) | Select-Object -First 1
    $action = 'NONE'
    $status = 'SERVICE_MISSING'
    if ($service) {
        try { Set-Service -Name $service.Name -StartupType Automatic } catch {}
        $listeners = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)
        $workers = @(Get-Process -Name 'Runner.Worker' -ErrorAction SilentlyContinue)
        if ($service.Status -ne 'Running') {
            try { Start-Service -Name $service.Name -ErrorAction Stop } catch { try { Restart-Service -Name $service.Name -Force } catch {} }
            $action = 'STARTED_SERVICE'
            Start-Sleep -Seconds 8
        }
        elseif ($listeners.Count -eq 0 -and $workers.Count -eq 0) {
            try { Restart-Service -Name $service.Name -Force } catch {}
            $action = 'RESTARTED_MISSING_RUNNER_PROCESS'
            Start-Sleep -Seconds 8
        }
        $service.Refresh()
        $listeners = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)
        $workers = @(Get-Process -Name 'Runner.Worker' -ErrorAction SilentlyContinue)
        if ($service.Status -eq 'Running' -and ($listeners.Count -gt 0 -or $workers.Count -gt 0)) {
            $status = 'HEALTHY'; $failures = 0
        } else {
            $status = 'UNHEALTHY'; $failures++
        }
        if ($failures -ge 10 -and $workers.Count -eq 0) {
            $status = 'SOFT_REBOOT_SCHEDULED'
            $action = 'SOFT_REBOOT_AFTER_10_FAILURES'
            $failures = 0
            & shutdown.exe /r /t 60 /c "NOCTA runner guardian could not restore the runner" /d p:4:1 | Out-Null
        }
        $payload = [ordered]@{
            schema='nocta-local-runner-guardian/v1.2'
            checked_at=[DateTimeOffset]::UtcNow.ToString('o')
            computer=$env:COMPUTERNAME
            status=$status
            action=$action
            failure_count=$failures
            service=[ordered]@{name=$service.Name;status=$service.Status.ToString();start_type=$service.StartType.ToString()}
            listener_processes=$listeners.Count
            worker_processes=$workers.Count
            github_443_reachable=[bool](Test-NetConnection github.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)
        }
    } else {
        $payload = [ordered]@{schema='nocta-local-runner-guardian/v1.2';checked_at=[DateTimeOffset]::UtcNow.ToString('o');computer=$env:COMPUTERNAME;status=$status;action=$action;failure_count=($failures+1);service=$null;listener_processes=0;worker_processes=0;github_443_reachable=$false}
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
    & schtasks.exe /Create /TN $MinuteTask /TR $taskCommand /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to create $MinuteTask." }
    & schtasks.exe /Create /TN $StartupTask /TR $taskCommand /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to create $StartupTask." }
}

function Wait-RunnerOnline {
    param([int]$TimeoutSeconds=180)
    $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
    while((Get-Date)-lt $deadline){
        Start-Sleep -Seconds 5
        $raw=(& gh.exe api "repos/$Repo/actions/runners?per_page=100" | Out-String).Trim()
        if($LASTEXITCODE -eq 0 -and $raw){
            $obj=$raw|ConvertFrom-Json
            $runner=@($obj.runners|Where-Object{[string]$_.name -eq $RunnerName})|Select-Object -First 1
            if($runner -and [string]$runner.status -eq 'online'){return $runner}
        }
    }
    throw "Runner $RunnerName did not become online within $TimeoutSeconds seconds."
}

function Invoke-CodexSmoke {
    $noctaRepo='C:\Nocta\development\NoctaDev'
    if(-not(Test-Path (Join-Path $noctaRepo '.git'))){throw "Trusted NOCTA worktree is missing: $noctaRepo"}
    $pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
    $codex=(Get-Command codex.exe -ErrorAction Stop).Source
    $work=Join-Path $env:TEMP ("nocta-codex-smoke-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Force -Path $work|Out-Null
    $last=Join-Path $work 'last-message.txt'
    $stdout=Join-Path $work 'stdout.jsonl'
    $stderr=Join-Path $work 'stderr.log'
    $script=Join-Path $work 'smoke.ps1'
    $repoEsc=$noctaRepo.Replace("'","''")
    $codexEsc=$codex.Replace("'","''")
    $lastEsc=$last.Replace("'","''")
    $text=@"
`$ErrorActionPreference='Stop'
Set-Location -LiteralPath '$repoEsc'
`$prompt='Respond with exactly CODEX_READY. Do not read, write, or modify project files. Do not execute shell commands.'
`$prompt | & '$codexEsc' exec --skip-git-repo-check --sandbox read-only --json --output-last-message '$lastEsc' -
exit `$LASTEXITCODE
"@
    [IO.File]::WriteAllText($script,$text,$Utf8NoBom)
    $proc=Start-Process -FilePath $pwsh -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"$script`"") -WorkingDirectory $noctaRepo -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    try{Wait-Process -Id $proc.Id -Timeout 180 -ErrorAction Stop}catch{try{& taskkill.exe /PID $proc.Id /T /F 2>$null|Out-Null}catch{};throw 'Codex smoke test timed out after 180 seconds.'}
    $proc.Refresh()
    $message=if(Test-Path $last){(Get-Content $last -Raw).Trim()}else{''}
    $err=if(Test-Path $stderr){Get-Content $stderr -Raw}else{''}
    if($proc.ExitCode -ne 0){throw "Codex smoke failed with exit code $($proc.ExitCode): $err"}
    if($message -ne 'CODEX_READY'){throw "Unexpected Codex response: $message"}
    return [ordered]@{status='PASS';response=$message;version=(& $codex --version 2>&1|Out-String).Trim();working_directory=$noctaRepo}
}

try {
    foreach($command in @('gh.exe','pwsh.exe','codex.exe','powershell.exe','schtasks.exe','sc.exe')){if(-not(Get-Command $command -ErrorAction SilentlyContinue)){throw "Missing command: $command"}}
    & gh.exe auth status *> $null
    if($LASTEXITCODE -ne 0){throw 'GitHub CLI is not authenticated.'}

    Write-Host '=== Installing independent local SYSTEM guardian ===' -ForegroundColor Cyan
    Install-Guardian
    $service=Get-RunnerService
    & sc.exe failure $service.Name reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    Set-Service -Name $service.Name -StartupType Automatic
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $GuardianPath

    Write-Host '=== Verifying official GitHub runner ===' -ForegroundColor Cyan
    $runner=Wait-RunnerOnline -TimeoutSeconds 180

    Write-Host '=== Verifying Codex from trusted NOCTA worktree ===' -ForegroundColor Cyan
    $codex=Invoke-CodexSmoke

    $secretNames=@(& gh.exe secret list --repo $Repo --json name --jq '.[].name' 2>$null)
    $serverspaceSecrets=@('SERVERSPACE_API_KEY','SERVERSPACE_SERVER_ID','SERVERSPACE_API_BASE')
    $missingSecrets=@($serverspaceSecrets|Where-Object{$_ -notin $secretNames})

    Write-Host '=== Triggering current VPS command ===' -ForegroundColor Cyan
    & gh.exe workflow run nocta-vps-command.yml --repo $Repo | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Unable to trigger NOCTA VPS command workflow.'}
    try{& gh.exe workflow run nocta-external-guardian-v3.yml --repo $Repo|Out-Null}catch{}

    $guardianState=$null
    if(Test-Path (Join-Path $StateDir 'runner-guardian.json')){try{$guardianState=Get-Content (Join-Path $StateDir 'runner-guardian.json') -Raw|ConvertFrom-Json}catch{}}
    $report=[ordered]@{
        schema='nocta-local-autonomy/v1.2'
        status='PASS'
        completed_at=[DateTimeOffset]::UtcNow.ToString('o')
        runner=[ordered]@{id=$runner.id;name=$runner.name;status=$runner.status;busy=$runner.busy;labels=@($runner.labels|ForEach-Object{$_.name})}
        service=[ordered]@{name=$service.Name;status=$service.Status.ToString();start_type=$service.StartType.ToString()}
        local_guardian=[ordered]@{minute_task=$MinuteTask;startup_task=$StartupTask;script=$GuardianPath;state=$guardianState}
        codex=$codex
        serverspace_secrets_present=($missingSecrets.Count -eq 0)
        missing_serverspace_secret_names=$missingSecrets
        external_guardian_status='NONBLOCKING_PENDING_GITHUB_HOSTED_ACTIONS'
        log=$LogPath
    }
    Write-JsonNoBom -Path $ReportPath -Value $report
    $issueBody="## NOCTA local autonomy v1.2`n`n**Status:** ``PASS`` `n`n- Runner: ``$($runner.status)```n- Windows service: ``$($service.Status)```n- Codex: ``$($codex.response)```n- Local SYSTEM guardian: installed (every minute + startup)`n- Serverspace secrets present: ``$($missingSecrets.Count -eq 0)```n- External hosted guardian: ``PENDING`` (does not block local autonomy)`n"
    $tempIssue=Join-Path $env:TEMP 'nocta-autonomy-issue.md'
    [IO.File]::WriteAllText($tempIssue,$issueBody,$Utf8NoBom)
    & gh.exe issue edit $GuardianIssue --repo $Repo --body-file $tempIssue | Out-Null

    Write-Host ''
    Write-Host '=== NOCTA LOCAL AUTONOMY V1.2 PASS ===' -ForegroundColor Green
    Write-Host "Runner: $($runner.status); service: $($service.Status); Codex: $($codex.response)"
    Write-Host "Local guardian: $MinuteTask + $StartupTask"
    Write-Host "Serverspace secrets present: $($missingSecrets.Count -eq 0)"
    Write-Host "Report: $ReportPath"
    Write-Host 'RDP is no longer required for normal runner and Codex operation.' -ForegroundColor Yellow
}
catch {
    try{$service=Get-RunnerService;Set-Service -Name $service.Name -StartupType Automatic -ErrorAction SilentlyContinue;Start-Service -Name $service.Name -ErrorAction SilentlyContinue;powershell.exe -NoProfile -ExecutionPolicy Bypass -File $GuardianPath}catch{}
    $failure=[ordered]@{schema='nocta-local-autonomy/v1.2';status='FAIL';failed_at=[DateTimeOffset]::UtcNow.ToString('o');error=$_.Exception.Message;log=$LogPath;note='Runner and local guardian were left enabled where possible.'}
    Write-JsonNoBom -Path $ReportPath -Value $failure
    Write-Host ''
    Write-Host '=== NOCTA LOCAL AUTONOMY V1.2 FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally { try{Stop-Transcript|Out-Null}catch{} }
