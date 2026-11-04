param([string]$ReportPath=(Join-Path $env:TEMP ('codex-wpf-smoke-single-'+[guid]::NewGuid().ToString('N')+'.json')))
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+(Join-Path $root 'CodexAuthManager.ps1')+'" -Demo -SmokeTest -RefreshSmokeTest -ReportPath "'+$ReportPath+'"'
$process=Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
if(-not $process.WaitForExit(30000)){throw 'Single refresh smoke timed out.'}
if($process.ExitCode -ne 0){throw 'Single refresh smoke process failed.'}
$report=Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if(-not $report.Success -or $report.SingleRefreshChecks -lt 50 -or $report.Generation -ne 6){throw 'Single refresh scenarios failed.'}
[pscustomobject]@{Result='PASS';Checks=$report.SingleRefreshChecks;ReportPath=$ReportPath} | ConvertTo-Json -Compress
