param([string]$ReportPath = (Join-Path $env:TEMP ('codex-wpf-smoke-' + [guid]::NewGuid().ToString('N') + '.json')))
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$process=Start-Process -FilePath (Join-Path $root 'CodexAuthManager.exe') -ArgumentList ('-Demo -SmokeTest -ReportPath "' + $ReportPath + '"') -WindowStyle Hidden -PassThru
if (-not $process.WaitForExit(30000)) { throw 'UI smoke timed out.' }
if ($process.ExitCode -ne 0) { throw 'UI process failed.' }
$report=Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if (-not $report.Success -or $report.PendingRows -ne 0 -or -not $report.RefreshEnabled) { throw 'UI lifecycle verification failed.' }
$cards=@($report.CardPositions)
if ($cards.Count -ne 4 -or $cards[0].Y -ne $cards[1].Y -or $cards[1].X -le $cards[0].X -or $cards[0].Width -lt 290) { throw 'Multi-column card layout failed.' }
if ($report.CurrentInList -ne 0 -or -not $report.CurrentAtTop -or $report.HeaderActions.Count -ne 3) { throw 'Current identity/header actions layout failed.' }
$layouts=@($report.ResponsiveLayouts)
if($layouts.Count -ne 3 -or $layouts[0].Columns -ne 2 -or $layouts[1].Columns -ne 3 -or $layouts[2].Columns -ne 4 -or @($layouts | Where-Object {$_.Overflow -or $_.CardWidth -lt 290}).Count -gt 0) { throw 'Responsive card layout failed.' }
$bars=@($report.ProgressBars | Where-Object ContextType -eq 'LocalCodex.QuotaView')
$expected=@(82,91,58,79,0,50,92,96)
if($bars.Count -ne $expected.Count) { throw 'Quota bar count mismatch.' }
for($i=0;$i -lt $bars.Count;$i++) {
    if($bars[$i].Value -ne $expected[$i] -or [Math]::Abs($bars[$i].FillWidth - $bars[$i].Width*$expected[$i]/100) -gt 1) { throw 'Quota bar value/width mismatch.' }
}
[pscustomobject]@{Result='PASS';QuotaBarsVerified=$bars.Count;ReportPath=$ReportPath} | ConvertTo-Json -Compress
