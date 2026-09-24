# Windows PowerShell 5.1 / STA. Queries run in the background; switches are explicit.
param(
    [string]$CodexDir = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$Demo,
    [switch]$SmokeTest,
    [string]$ReportPath = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Launch with powershell.exe -STA.' }
. (Join-Path $PSScriptRoot 'codex-auth-list.ps1') -CodexDir $CodexDir
. (Join-Path $PSScriptRoot 'Ui.Data.ps1')
. (Join-Path $PSScriptRoot 'Account.Switch.ps1')
. (Join-Path $PSScriptRoot 'Account.Login.ps1')
$script:AppRoot = $PSScriptRoot
$script:DataRoot = $CodexDir
$script:IsDemo = [bool]$Demo
$script:IsSmoke = [bool]$SmokeTest
$script:ReportFile = $ReportPath
$script:Worker = $null
$script:Async = $null
$script:Finished = $false
$script:UiFault = $false
$script:Generation = 0
$script:PendingLogin=$null
$script:LoginReady=$false
$script:LoginPreviousFingerprint=''
$script:ReadyFingerprint=''
$script:SettingsPath=Join-Path $PSScriptRoot 'settings.json'
$script:CodexAppPath=if($Demo){''}else{Find-CodexDesktopPath $script:SettingsPath}
$script:Rows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$reader = [Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'MainWindow.xaml'))
try { $script:Window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
$script:Controls = @{}
foreach ($name in @('RefreshButton','LegacyButton','CurrentEmail','CurrentPanel','SaveState','LoginButton','SaveButton','LoginBanner','LoginStatus','OpenLoginButton','CancelLoginButton','SavedCount','ErrorCount','RefreshTime','AccountList','AccountScroll','OverallProgress','StatusText')) {
    $script:Controls[$name] = $script:Window.FindName($name)
}
$script:Controls.AccountList.ItemsSource = $script:Rows
$script:Controls.AccountList.Tag = [double]350
$script:Controls.AccountList.Add_SizeChanged({
    $width = $script:Controls.AccountList.ActualWidth
    $columns = [Math]::Max(2, [Math]::Floor($width / 300))
    $script:Controls.AccountList.Tag = [double][Math]::Floor($width / $columns)
})
if ($Demo) { $script:Window.Title = 'Codex 账户管理 · 演示'; $script:Controls.LegacyButton.IsEnabled = $false }

$script:WorkerCode = {
    param($AppRoot, $Entries, $Queue, $DemoMode)
    $ErrorActionPreference = 'Stop'
    try {
        . (Join-Path $AppRoot 'codex-auth-list.ps1')
        . (Join-Path $AppRoot 'Ui.Data.ps1')
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $cache = @{}
        for ($i=0; $i -lt $Entries.Count; $i++) {
            $entry = $Entries[$i]
            if ($DemoMode) {
                Start-Sleep -Milliseconds 180
                if ($i -eq 3) { $summary = [pscustomobject]@{Ok=$false;Error='HTTP 401'} }
                else {
                    $used = @(18,42,100,0,8)[$i % 5]
                    $usage = [pscustomobject]@{
                        plan_type='plus'; code_review_rate_limit=$null; additional_rate_limits=@()
                        rate_limit=[pscustomobject]@{
                            limit_reached=($used -eq 100)
                            primary_window=[pscustomobject]@{used_percent=$used;limit_window_seconds=18000;reset_at=1790161200}
                            secondary_window=[pscustomobject]@{used_percent=($used / 2);limit_window_seconds=604800;reset_at=1790679600}
                        }
                    }
                    $summary = [pscustomobject]@{Ok=$true;OnlineName=('account{0}@example.com' -f ($i+1));Usage=$usage}
                }
            } else {
                $summary = Get-CodexOnlineSummary -AuthPath $entry.AuthPath -Cache $cache -Timeout 12
            }
            $row = ConvertTo-AccountRow -Summary $summary -Name $entry.Name -IsCurrent $entry.IsCurrent
            $row.SourceFingerprint=[string]$entry.Identity.Fingerprint
            if($summary.Ok){$row.VerifiedEmail=ConvertTo-CodexDisplayText (Get-CodexField $summary.Usage 'email')}
            if (-not $summary.Ok -and $entry.Identity.Email) { $row.Email=$entry.Identity.Email + '（本地凭据）' }
            $Queue.Enqueue([pscustomobject]@{Kind='row';Index=$i;Row=$row;Ok=[bool]$summary.Ok})
        }
    } catch {
        # Do not send exception details or secret-bearing records to the UI.
        $Queue.Enqueue([pscustomobject]@{Kind='fatal'})
    }
}

function Start-AccountRefresh {
    if ($null -ne $script:Worker) { return }
    $script:Generation++
    $script:Finished = $false
    $script:UiFault = $false
    $script:Completed = 0
    $script:Failures = 0
    $script:Controls.RefreshButton.IsEnabled = $false
    $script:Controls.AccountList.IsEnabled = $false
    $script:Controls.LoginButton.IsEnabled = $false
    $script:Controls.SaveButton.IsEnabled = $false
    $script:Controls.RefreshButton.Content = '正在刷新…'
    $script:Controls.ErrorCount.Text = '—'
    $script:Controls.OverallProgress.Value = 0
    $script:Controls.StatusText.Text = '正在查询账户，结果将逐个显示…'
    try {
        if ($script:IsDemo) {
            $script:Entries = @(
                [pscustomobject]@{Name='当前登录';IsCurrent=$true;AuthPath=''},
                [pscustomobject]@{Name='工作账户';IsCurrent=$false;AuthPath=''},
                [pscustomobject]@{Name='个人账户';IsCurrent=$false;AuthPath=''},
                [pscustomobject]@{Name='备用账户';IsCurrent=$false;AuthPath=''},
                [pscustomobject]@{Name='长名称账户 · 开发与研究';IsCurrent=$false;AuthPath=''}
            )
            $script:Controls.SaveState.Text = '已保存为：演示当前账户 · 已隐藏 1 份同身份备份'
            $script:Controls.SavedCount.Text = '5'
        } else {
            $script:Inventory=Get-AccountInventory $script:DataRoot
            $script:Entries=@($script:Inventory.Current) + @($script:Inventory.Others)
            $script:Controls.SavedCount.Text=[string]$script:Inventory.Saved.Count
            $script:Controls.SaveState.Text=if($script:Inventory.Current.Identity.Status -eq 'Missing'){'尚未登录'}elseif($script:Inventory.Current.Identity.Status -ne 'Known'){'身份无法确定 · 不自动归属已有备份'}elseif($script:Inventory.Matches.Count -eq 0){'尚未保存'}elseif($script:Inventory.Matches.Count -eq 1){'已保存为：'+$script:Inventory.Matches[0].Name}else{'已保存 '+$script:Inventory.Matches.Count+' 份同身份备份（已隐藏）'}
        }
        $script:Rows.Clear()
        foreach ($entry in $script:Entries) {
            $row=New-AccountRow $entry.Name $entry.IsCurrent
            if($entry.IsCurrent){$script:Controls.CurrentPanel.DataContext=$row}else{$script:Rows.Add($row)}
        }
        $script:Queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        $script:Worker = [PowerShell]::Create()
        [void]$script:Worker.AddScript($script:WorkerCode.ToString()).AddArgument($script:AppRoot).AddArgument($script:Entries).AddArgument($script:Queue).AddArgument($script:IsDemo)
        $script:Async = $script:Worker.BeginInvoke()
        $script:Timer.Start()
    } catch {
        if ($null -ne $script:Worker) { $script:Worker.Dispose(); $script:Worker=$null }
        $script:UiFault = $true
        $script:Controls.RefreshButton.IsEnabled = $true
        $script:Controls.AccountList.IsEnabled = $true
        Update-ActionButtons
        $script:Controls.RefreshButton.Content = '重新刷新'
        $script:Controls.StatusText.Text = '无法读取本地账户目录，请检查文件权限后重试。'
        if ($script:IsSmoke) { Write-SmokeReport; $script:Window.Close() }
    }
}

function Write-SmokeReport {
    if (-not $script:ReportFile) { return }
    function Get-ProgressState($Visual) {
        if ($Visual -is [Windows.Controls.ProgressBar]) {
            $indicator=$Visual.Template.FindName('PART_Indicator',$Visual)
            [pscustomobject]@{Value=$Visual.Value;Width=$Visual.ActualWidth;FillWidth=$indicator.ActualWidth;ContextType=$(if($null -ne $Visual.DataContext){$Visual.DataContext.GetType().FullName}else{''})}
        }
        for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Visual);$i++) {
            Get-ProgressState ([Windows.Media.VisualTreeHelper]::GetChild($Visual,$i))
        }
    }
    $script:Window.UpdateLayout()
    $positions = @(
        for ($i=0; $i -lt $script:Rows.Count; $i++) {
            $container = $script:Controls.AccountList.ItemContainerGenerator.ContainerFromIndex($i)
            $point = $container.TranslatePoint([Windows.Point]::new(0,0),$script:Controls.AccountList)
            [pscustomobject]@{X=$point.X;Y=$point.Y;Width=$container.ActualWidth;Height=$container.ActualHeight}
        }
    )
    $report = [pscustomobject]@{
        Success=($script:Finished -and -not $script:UiFault)
        Demo=$script:IsDemo; Rows=$script:Rows.Count; Completed=$script:Completed
        Failures=$script:Failures; RefreshEnabled=$script:Controls.RefreshButton.IsEnabled
        WindowWidth=$script:Window.ActualWidth; WindowHeight=$script:Window.ActualHeight
        Generation=$script:Generation
        QuotaRows=@($script:Rows | Where-Object { $_.Quotas.Count -gt 0 }).Count
        PendingRows=@($script:Rows | Where-Object { $_.Status -eq '等待查询' }).Count
        ProgressBars=@(Get-ProgressState $script:Window)
        ScrollHeight=$script:Controls.AccountScroll.ScrollableHeight
        CardPositions=$positions
        CurrentInList=@($script:Rows | Where-Object IsCurrent).Count
        CurrentAtTop=[bool]$script:Controls.CurrentPanel.DataContext.IsCurrent
        HeaderActions=@('LoginButton','SaveButton','RefreshButton') | ForEach-Object {$script:Controls[$_].Content}
    }
    $layouts = @()
    foreach ($testWidth in @(980,1180,1500)) {
        $script:Window.Width = $testWidth
        $script:Window.UpdateLayout()
        $first = $script:Controls.AccountList.ItemContainerGenerator.ContainerFromIndex(0)
        $columns = 0
        $overflow = $false
        for ($i=0; $i -lt $script:Rows.Count; $i++) {
            $container = $script:Controls.AccountList.ItemContainerGenerator.ContainerFromIndex($i)
            $point = $container.TranslatePoint([Windows.Point]::new(0,0),$script:Controls.AccountList)
            if ($point.Y -eq 0) { $columns++ }
            if ($point.X + $container.ActualWidth -gt $script:Controls.AccountList.ActualWidth + 1) { $overflow=$true }
        }
        $layouts += [pscustomobject]@{WindowWidth=$testWidth;Columns=$columns;CardWidth=$first.ActualWidth;Overflow=$overflow}
    }
    $report | Add-Member -NotePropertyName ResponsiveLayouts -NotePropertyValue $layouts
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ReportFile -Encoding UTF8
}

$script:Timer = [Windows.Threading.DispatcherTimer]::new()
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:Timer.Add_Tick({
    try {
        # Capture completion before draining: a late enqueue must be read on
        # this tick or the next, never lost between draining and disposal.
        $workerDone = $script:Async.IsCompleted
        $item = $null
        while ($script:Queue.TryDequeue([ref]$item)) {
            if ($item.Kind -eq 'row') {
                if($item.Row.IsCurrent){$script:Controls.CurrentPanel.DataContext=$item.Row}
                else{$script:Rows[$item.Index-1] = $item.Row}
                $script:Completed++
                if (-not $item.Ok) { $script:Failures++ }
                $script:Controls.OverallProgress.Value = 100 * $script:Completed / [Math]::Max(1,$script:Entries.Count)
                $script:Controls.StatusText.Text = '正在更新 {0} / {1} 个条目…' -f $script:Completed,$script:Entries.Count
            } else { $script:UiFault=$true }
            $item=$null
        }
        if ($workerDone) {
            try { [void]$script:Worker.EndInvoke($script:Async) } catch { $script:UiFault=$true }
            if ($script:Worker.HadErrors) { $script:UiFault=$true }
            $script:Worker.Dispose(); $script:Worker=$null; $script:Async=$null
            $script:Timer.Stop()
            $script:Finished=$true
            $script:Controls.RefreshButton.IsEnabled=$true
            $script:Controls.AccountList.IsEnabled=$true
            Update-ActionButtons
            $script:Controls.RefreshButton.Content='刷新全部'
            $script:Controls.ErrorCount.Text=[string]$script:Failures
            $script:Controls.RefreshTime.Text='更新于 ' + (Get-Date -Format 'HH:mm:ss')
            if ($script:UiFault) { $script:Controls.StatusText.Text='部分查询未能完成，请重新刷新。' }
            else { $script:Controls.StatusText.Text='更新完成 · {0} 个条目，{1} 个查询异常' -f $script:Completed,$script:Failures }
            if ($script:IsSmoke) { Write-SmokeReport; $script:Window.Close() }
        }
    } catch {
        $script:UiFault=$true
        $script:Timer.Stop()
        $script:Controls.StatusText.Text='界面更新失败，请关闭后重新打开。'
        if ($script:IsSmoke) { Write-SmokeReport; $script:Window.Close() }
    }
})
. (Join-Path $script:AppRoot 'Ui.Actions.ps1')
$script:Controls.AccountList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
    param($sender,$eventArgs)
    if ($eventArgs.OriginalSource -is [Windows.Controls.Button] -and $eventArgs.OriginalSource.Name -eq 'SwitchButton') {
        $eventArgs.Handled = $true
        Show-AccountAction -Mode Switch -Row $eventArgs.OriginalSource.DataContext
    }
})
$script:Controls.RefreshButton.Add_Click({ Start-AccountRefresh })
$script:Controls.AccountScroll.Add_PreviewMouseWheel({
    param($sender,$eventArgs)
    $sender.ScrollToVerticalOffset($sender.VerticalOffset - $eventArgs.Delta)
    $eventArgs.Handled=$true
})
$script:Controls.LegacyButton.Add_Click({
    try {
        # User-requested interactive legacy manager. No selection is automated.
        Start-Process -FilePath (Join-Path $script:AppRoot 'codex-auth-manager.bat') -WorkingDirectory $script:AppRoot -ErrorAction Stop
    } catch { [void][Windows.MessageBox]::Show($script:Window,'无法打开原版管理器，请到程序目录双击 codex-auth-manager.bat。','打开失败') }
})
$script:Window.Add_ContentRendered({ Start-AccountRefresh; $script:LoginTimer.Start() })
$script:Window.Add_Closed({ $script:Timer.Stop(); $script:LoginTimer.Stop() })
try { [void]$script:Window.ShowDialog() }
finally {
    $script:Timer.Stop()
    if ($null -ne $script:Worker) { $script:Worker.Stop(); $script:Worker.Dispose(); $script:Worker=$null }
}
if ($script:IsSmoke -and (-not $script:Finished -or $script:UiFault)) { exit 1 }
