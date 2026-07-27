#requires -Version 5.1

param(
    [switch]$Loop
)

$ErrorActionPreference = 'Stop'
$Python = 'C:\Python312\python.exe'
$Controller = 'C:\Nocta\control\agent\nocta_vps_controller_v2.py'

if (-not (Test-Path $Python)) { throw "Python is missing: $Python" }
if (-not (Test-Path $Controller)) { throw "Controller is missing: $Controller" }

$arguments = @($Controller)
if ($Loop) { $arguments += '--loop' }

& $Python @arguments
exit $LASTEXITCODE
