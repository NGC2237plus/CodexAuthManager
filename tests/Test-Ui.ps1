param([string]$ScratchDirectory = $env:TEMP)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-auth-list.ps1')
. (Join-Path $root 'Ui.Data.ps1')
$script:Count=0
function Assert($Condition,$Message) { if (-not $Condition) { throw $Message }; $script:Count++ }
$w=[pscustomobject]@{used_percent=25;limit_window_seconds=18000;reset_at=1790161200}
$v=ConvertTo-QuotaView $w 'Codex'
Assert ($v.Remaining -eq 75 -and $v.Label -eq 'Codex · 5 小时') 'Quota conversion failed'
$unknown=ConvertTo-QuotaView ([pscustomobject]@{used_percent=$null;limit_window_seconds=604800}) 'Codex'
Assert ($unknown.Percent -eq '未返回额度') 'Null quota must remain unknown'
$exhausted=ConvertTo-QuotaView ([pscustomobject]@{used_percent=100;limit_window_seconds=2592000}) 'Codex'
Assert ($exhausted.Percent -eq '0% 剩余' -and $exhausted.Label -match '30 天' -and $exhausted.Color -eq '#D15353') 'Exhausted/monthly quota incorrect'
$usage=[pscustomobject]@{plan_type='plus';rate_limit=[pscustomobject]@{primary_window=$w;secondary_window=$null;limit_reached=$false};code_review_rate_limit=$null;additional_rate_limits=@()}
$summary=[pscustomobject]@{Ok=$true;OnlineName='online@example.test';Usage=$usage}
$row=ConvertTo-AccountRow $summary 'local-folder' $false
Assert ($row.LocalName -eq 'local-folder' -and $row.Email -eq 'online@example.test') 'Local identity overwritten'
Assert ($row.Quotas.Count -eq 1 -and $row.EmptyVisibility -eq 'Collapsed') 'Single-window rendering incorrect'
Assert (-not (@($row.PSObject.Properties.Name) -match 'token|AuthPath|Usage')) 'Backend data leaked to UI'
$usage.additional_rate_limits=@([pscustomobject]@{limit_name='Extra';rate_limit=[pscustomobject]@{primary_window=$w}})
$withExtra=ConvertTo-AccountRow $summary 'local-folder'
Assert ($withExtra.Quotas.Count -eq 2 -and $withExtra.Quotas[1].Label -match 'Extra') 'Additional quota missing'
$usage.rate_limit.limit_reached=$true
Assert ((ConvertTo-AccountRow $summary 'local-folder').Status -eq '额度已用尽') 'Limit status missing'
foreach ($code in @('401','403','429','Network/timeout error')) {
    $errorRow=ConvertTo-AccountRow ([pscustomobject]@{Ok=$false;Error=$code}) 'unchanged'
    Assert ($errorRow.DetailVisibility -eq 'Visible' -and $errorRow.Quotas.Count -eq 0 -and $errorRow.LocalName -eq 'unchanged') 'Failure state incorrect'
}
Assert ((ConvertTo-AccountRow ([pscustomobject]@{Ok=$false;Error='401'}) 'local').Status -eq '登录失效') '401 status incorrect'
$pending=New-AccountRow '当前登录' $true
Assert ($pending.IsCurrent -and $pending.Status -eq '等待查询') 'Initial current row incorrect'
$temp=Join-Path $ScratchDirectory ('codex-ui-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $temp 'my_auth\本地 名称') -Force | Out-Null
$entries=@(Get-AccountEntries $temp)
Assert ($entries.Count -eq 2 -and $entries[0].IsCurrent -and $entries[1].Name -eq '本地 名称') 'Entry discovery changed local names'
Assert (-not (Test-Path -LiteralPath (Join-Path $temp 'auth.json'))) 'Discovery wrote auth data'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$reader=[Xml.XmlReader]::Create((Join-Path $root 'MainWindow.xaml'))
try { $window=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
Assert ($null -ne $window.FindName('RefreshButton') -and $null -ne $window.FindName('AccountList')) 'WPF controls missing'
$window.Close()
Assert ((Get-FileHash -LiteralPath (Join-Path $root 'codex-auth-manager.bat')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $root 'backups\codex-auth-manager.before-wpf.bat')).Hash) 'Legacy manager changed'
Assert ((Get-FileHash -LiteralPath (Join-Path $root 'backups\codex-auth-manager.bat.backup-20260923-103219.bak')).Hash -eq 'B78C778661F2D92DB0B66B1DCDA761A0342C54615CB2227E584B798446D1BA2F') 'Original backup changed'
[pscustomobject]@{Checks=$script:Count;PowerShell=$PSVersionTable.PSVersion.ToString();Result='PASS'} | ConvertTo-Json -Compress
