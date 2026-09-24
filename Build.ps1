$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$automation = (& $windowsPowerShell -NoProfile -Command '[System.Management.Automation.PSObject].Assembly.Location' | Out-String).Trim()
if (-not (Test-Path -LiteralPath $automation -PathType Leaf)) { throw 'Windows PowerShell assembly not found.' }
& $compiler /nologo /target:winexe /platform:x64 /optimize+ (('/out:' + (Join-Path $PSScriptRoot 'CodexAuthManager.exe'))) (('/reference:' + $automation)) /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
