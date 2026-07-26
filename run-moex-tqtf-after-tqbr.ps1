#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Python = 'C:\Python312\python.exe'
$Repo = 'C:\Nocta\collector\ProjectX'
$SegmentsRoot = 'C:\Nocta\data\segments'
$Prior = Join-Path $SegmentsRoot 'shares-tqbr'
$Output = Join-Path $SegmentsRoot 'shares-tqtf'
$StateDir = 'C:\Nocta\state'
$LogDir = 'C:\Nocta\logs\collector'

New-Item -ItemType Directory -Force -Path $StateDir, $LogDir | Out-Null
$LogPath = Join-Path $LogDir ("shares-tqtf-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $LogPath -Force | Out-Null

try {
    if (-not (Test-Path $Python)) { throw "Python not found: $Python" }
    if (-not (Test-Path (Join-Path $Repo '.git'))) { throw "Collector repository not found: $Repo" }

    Write-Host '=== PRECHECK: TQBR ===' -ForegroundColor Cyan
    $priorManifestPath = Join-Path $Prior 'metadata\dataset_manifest.json'
    $priorValidationPath = Join-Path $Prior 'state\latest_validation.json'
    if (-not (Test-Path $priorManifestPath)) { throw 'TQBR manifest is missing' }
    if (-not (Test-Path $priorValidationPath)) { throw 'TQBR validation is missing' }

    $priorManifest = Get-Content $priorManifestPath -Raw | ConvertFrom-Json
    $priorValidation = Get-Content $priorValidationPath -Raw | ConvertFrom-Json
    if ($priorManifest.status -ne 'PASS') { throw "TQBR manifest status is $($priorManifest.status)" }
    if ($priorValidation.status -ne 'PASS') { throw "TQBR validation status is $($priorValidation.status)" }
    if ([int]$priorManifest.instrument_count -le 0) { throw 'TQBR instrument count is empty' }
    if ([int]$priorManifest.candle_count -le 0) { throw 'TQBR candle count is empty' }
    if (@($priorManifest.trading_dates).Count -ne 2) { throw 'TQBR does not contain exactly two trading dates' }

    Write-Host ("TQBR PASS: {0} instruments, {1} candles, dates {2}" -f $priorManifest.instrument_count, $priorManifest.candle_count, (@($priorManifest.trading_dates) -join ', ')) -ForegroundColor Green

    Write-Host '=== COLLECT: TQTF ===' -ForegroundColor Cyan
    if (Test-Path $Output) { Remove-Item -Recurse -Force $Output }
    Set-Location $Repo
    $env:PYTHONPATH = $Repo

    & $Python -u tools\moex_v6_segment.py `
        --segment-id shares-tqtf `
        --scope stock/shares `
        --board TQTF `
        --partition-count 1 `
        --partition-index 0 `
        --output $Output `
        --config config\moex_operational_v6.json `
        --heartbeat-seconds 20
    if ($LASTEXITCODE -ne 0) { throw "TQTF collection failed with exit code $LASTEXITCODE" }

    Write-Host '=== VALIDATE: TQTF ===' -ForegroundColor Cyan
    & $Python -u tools\moex_v6_validate.py --output $Output
    if ($LASTEXITCODE -ne 0) { throw "TQTF validation failed with exit code $LASTEXITCODE" }

    $manifestPath = Join-Path $Output 'metadata\dataset_manifest.json'
    $validationPath = Join-Path $Output 'state\latest_validation.json'
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $validation = Get-Content $validationPath -Raw | ConvertFrom-Json
    if ($manifest.status -ne 'PASS' -or $validation.status -ne 'PASS') { throw 'TQTF result is not PASS' }

    $bytes = (Get-ChildItem $Output -File -Recurse | Measure-Object Length -Sum).Sum
    $report = [ordered]@{
        status = 'PASS'
        segment_id = 'shares-tqtf'
        generated_at = (Get-Date).ToString('o')
        instrument_count = [int]$manifest.instrument_count
        candle_count = [int]$manifest.candle_count
        trading_dates = @($manifest.trading_dates)
        validated_files = [int]$validation.validated_files
        failures = @($validation.failures)
        bytes = [int64]$bytes
        mib = [math]::Round($bytes / 1MB, 2)
        prior_tqbr = [ordered]@{
            instrument_count = [int]$priorManifest.instrument_count
            candle_count = [int]$priorManifest.candle_count
            trading_dates = @($priorManifest.trading_dates)
        }
        log = $LogPath
    }
    $reportPath = Join-Path $StateDir 'shares-tqtf-run-report.json'
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== TQTF SEGMENT PASS ===' -ForegroundColor Green
    $report.GetEnumerator() | Format-Table -AutoSize
    Write-Host "Report: $reportPath"
    Write-Host "Log:    $LogPath"
}
catch {
    $failure = [ordered]@{
        status = 'FAIL'
        segment_id = 'shares-tqtf'
        failed_at = (Get-Date).ToString('o')
        error = $_.Exception.Message
        log = $LogPath
    }
    $failure | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $StateDir 'shares-tqtf-run-report.json') -Encoding UTF8
    Write-Host ''
    Write-Host '=== TQTF SEGMENT FAIL ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
