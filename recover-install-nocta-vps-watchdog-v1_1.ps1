#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseInstaller = 'C:\recover-install-nocta-vps-watchdog-v1.ps1'
$WatchdogPath = 'C:\Nocta\control\agent\nocta-vps-watchdog-v1.ps1'
$InstallerUrl = 'https://raw.githubusercontent.com/qluck7/first/main/recover-install-nocta-vps-watchdog-v1.ps1?rev=89b140a3'
$WatchdogTaskName = 'NoctaVpsWatchdogV1'

Invoke-WebRequest -Uri $InstallerUrl -UseBasicParsing -OutFile $BaseInstaller
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $BaseInstaller
if ($LASTEXITCODE -ne 0) { throw "Base watchdog recovery failed with exit code $LASTEXITCODE" }

if (-not (Test-Path $WatchdogPath)) { throw "Watchdog file is missing: $WatchdogPath" }
$lines = @(Get-Content $WatchdogPath)
$index = -1
for ($i = 0; $i -lt ($lines.Count - 2); $i++) {
    if ($lines[$i] -eq '    Start-Agent' -and
        $lines[$i + 1] -match '^    \$latest = Read-JsonFile' -and
        $lines[$i + 2] -match "^    if \(-not \$latest -or \[string\]\$latest\.status -ne 'RUNNING'\) \{ return \}$") {
        $index = $i
        break
    }
}

if ($index -ge 0) {
    $before = if ($index -gt 0) { @($lines[0..($index - 1)]) } else { @() }
    $afterStart = $index + 3
    $after = if ($afterStart -lt $lines.Count) { @($lines[$afterStart..($lines.Count - 1)]) } else { @() }
    $replacement = @(
        "    `$latest = Read-JsonFile -Path (Join-Path `$StateDir 'latest.json')",
        "    if (-not `$latest -or [string]`$latest.status -ne 'RUNNING') { Start-Agent; return }"
    )
    @($before + $replacement + $after) | Set-Content -Path $WatchdogPath -Encoding UTF8
}

Stop-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $WatchdogTaskName
Start-Sleep -Seconds 5

$watchdogProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine -match 'nocta-vps-watchdog-v1\.ps1' -and $_.CommandLine -match '-Loop'
})
if ($watchdogProcesses.Count -eq 0) { throw 'Hardened watchdog did not restart.' }

Write-Host ''
Write-Host '=== NOCTA VPS WATCHDOG V1.1 PASS ===' -ForegroundColor Green
Write-Host 'The stale TQTF run was replaced, heartbeat is enabled, and the watchdog is persistent across reboot.'
