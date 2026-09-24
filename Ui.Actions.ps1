function Get-ActionErrorText($ErrorRecord) {
    $message=$ErrorRecord.Exception.Message
    if($message -match '^(当前|账号|账户|另一个|登录|同一|同名|无法取得|备份|恢复|存在多份|目标|Codex|请选择|新凭据|已存在)') { return $message }
    return '操作未完成，请检查文件权限、程序路径和文件占用。恢复副本会保留，不会打印认证内容。'
}
function Update-ActionButtons {
    $idle=$null -eq $script:Worker
    $pending=$null -ne $script:PendingLogin
    $script:Controls.LoginButton.IsEnabled=$idle -and -not $pending
    $script:Controls.AccountList.IsEnabled=$idle -and -not $pending
    $hasAuth=$script:IsDemo -or ($script:Inventory -and $script:Inventory.Current.Identity.ValidCredential)
    $script:Controls.SaveButton.IsEnabled=$idle -and $hasAuth -and (-not $pending -or $script:LoginReady)
    $script:Controls.LegacyButton.IsEnabled=-not $script:IsDemo -and -not $pending
}
function Show-AccountAction {
    param([ValidateSet('Save','Switch','Login')][string]$Mode,$Row)
    if($null -ne $script:Worker){return}
    if($Mode -ne 'Save' -and $null -ne $script:PendingLogin){return}
    try {
        $inventory=if($script:IsDemo){$null}else{Get-AccountInventory $script:DataRoot}
        $expected=if($script:IsDemo){'demo'}else{$inventory.Current.Identity.Fingerprint}
        $preferredEmail=''
        if($script:Controls.CurrentPanel.DataContext.SourceFingerprint -ceq $expected){$preferredEmail=$script:Controls.CurrentPanel.DataContext.VerifiedEmail}
        $snapshot=if($Mode -eq 'Switch' -and -not $script:IsDemo){Get-SwitchSnapshot $script:DataRoot $Row.LocalName}else{$null}
        $reader=[Xml.XmlReader]::Create((Join-Path $script:AppRoot 'AccountActionWindow.xaml'))
        try{$dialog=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}
        $dialog.Owner=$script:Window
        $heading=$dialog.FindName('Heading');$nameBox=$dialog.FindName('NameInput')
        $matches=$dialog.FindName('MatchChoice');$confirm=$dialog.FindName('ConfirmAction')
        $errorText=$dialog.FindName('ActionError');$appBox=$dialog.FindName('AppPath')
        $state=@{Result=$null}
        $identityText=if($script:IsDemo){'当前身份：account1@example.com（演示）'}elseif($inventory.Current.Identity.Email){'当前身份：'+$inventory.Current.Identity.Email}else{'当前身份：'+$inventory.Current.Identity.Status}
        $dialog.FindName('IdentityText').Text=$identityText
        if(-not $script:IsDemo -and $inventory.Matches.Count -gt 1){
            $dialog.FindName('MatchPanel').Visibility='Visible'
            foreach($entry in $inventory.Matches){[void]$matches.Items.Add($entry.Name)}
        }
        switch($Mode){
            Save {
                $heading.Text='保存当前账号';$confirm.Content='保存'
                $dialog.FindName('Hint').Text='名称留空时，优先更新此身份已有的备份；没有备份则使用邮箱。填写新名称可另存一份。同名但不同身份不会被覆盖。'
            }
            Switch {
                $heading.Text='切换 Codex 账号';$confirm.Content='备份并切换'
                $dialog.FindName('TargetText').Text='切换到：'+$Row.LocalName+' · '+$Row.Email
                $dialog.FindName('Hint').Text='先按当前凭据身份保存备份，再切换目标。备份名称留空可沿用已有名称。身份无法确定时只保留独立恢复副本。已运行的 Codex 客户端可能需要重启。'
            }
            Login {
                $heading.Text='登录新账号';$confirm.Content='检查退出并开始'
                $dialog.FindName('NamePanel').Visibility='Collapsed'
                $dialog.FindName('AppPanel').Visibility='Visible';$appBox.Text=$script:CodexAppPath
                $dialog.FindName('Hint').Text='请先手动完全退出 Codex。确认后会检查进程，备份当前凭据，移除活动 auth.json，再打开 Codex。请在官方界面登录，然后返回这里点击右上角“保存当前账号”。'
            }
        }
        if(-not $script:IsDemo -and $inventory.Matches.Count -eq 1){$dialog.FindName('TargetText').Text+='  当前备份：'+$inventory.Matches[0].Name}
        $dialog.Title=$heading.Text
        if($script:IsDemo){$dialog.Title+=' · 演示';$dialog.FindName('Hint').Text='演示模式：使用虚构账号，不读取或修改真实认证文件，也不启动或退出 Codex。'}
        $dialog.FindName('BrowseApp').Add_Click({
            $picker=[Microsoft.Win32.OpenFileDialog]::new();$picker.Filter='Codex 程序 (*.exe)|*.exe';$picker.Title='选择 Codex 桌面程序'
            if($picker.ShowDialog($dialog)){$appBox.Text=$picker.FileName}
        })
        $confirm.Add_Click({
            try {
                if($script:IsDemo){$state.Result=[pscustomobject]@{Demo=$true;Name='演示账号'}}
                else {
                    $selected=[string]$matches.SelectedItem
                    switch($Mode){
                        Save {
                            if($null -ne (Get-PendingLogin $script:DataRoot)){
                                $state.Result=Save-NewLoginAccount $script:DataRoot $nameBox.Text $selected $expected $preferredEmail
                            }else{$state.Result=Save-CurrentAccount $script:DataRoot $nameBox.Text $selected $expected $preferredEmail}
                        }
                        Switch {$state.Result=Invoke-AccountSwitch -Directory $script:DataRoot -TargetName $Row.LocalName -BackupName $nameBox.Text -SelectedName $selected -Expected $snapshot}
                        Login {
                            if(-not [IO.File]::Exists($appBox.Text)){throw '请选择有效的 Codex 桌面程序。'}
                            $script:CodexAppPath=$appBox.Text
                            $settings=[pscustomobject]@{CodexAppPath=$script:CodexAppPath}
                            Write-AccountAtomic $script:SettingsPath ([Text.UTF8Encoding]::new($false).GetBytes(($settings | ConvertTo-Json)))
                            $state.Result=Start-NewAccountLogin -Directory $script:DataRoot -AppPath $script:CodexAppPath -Expected $expected -SelectedName $selected
                        }
                    }
                }
                $dialog.DialogResult=$true
            } catch {
                $errorText.Text=Get-ActionErrorText $_
                if($Mode -eq 'Login'){$confirm.Content='重新检查并继续'}
            }
        })
        if($dialog.ShowDialog() -eq $true){
            if($Mode -eq 'Login'){
                $script:PendingLogin=$state.Result;$script:LoginReady=$false;$script:LoginPreviousFingerprint='';$script:ReadyFingerprint=''
                if($script:IsDemo){$script:DemoLoginTicks=0}
                $script:Controls.LoginBanner.Visibility='Visible';$script:Controls.LoginStatus.Text='等待登录 · 请在 Codex 中完成登录，再返回保存账号。'
            } elseif($Mode -eq 'Save') {
                $script:PendingLogin=$null;$script:LoginReady=$false;$script:Controls.LoginBanner.Visibility='Collapsed'
            }
            Update-ActionButtons
            Start-AccountRefresh
        }
    } catch {[void][Windows.MessageBox]::Show($script:Window,(Get-ActionErrorText $_),'账号操作')}
}
$script:Controls.LoginButton.Add_Click({Show-AccountAction -Mode Login})
$script:Controls.SaveButton.Add_Click({Show-AccountAction -Mode Save})
$script:Controls.OpenLoginButton.Add_Click({
    try{
        if($script:IsDemo){$script:Controls.LoginStatus.Text='演示：请点击“保存当前账号”完成流程。';return}
        if(-not [IO.File]::Exists($script:CodexAppPath)){
            $picker=[Microsoft.Win32.OpenFileDialog]::new();$picker.Filter='Codex 程序 (*.exe)|*.exe';$picker.Title='重新选择 Codex 桌面程序'
            if(-not $picker.ShowDialog($script:Window)){return}
            $script:CodexAppPath=$picker.FileName
            Write-AccountAtomic $script:SettingsPath ([Text.UTF8Encoding]::new($false).GetBytes((@{CodexAppPath=$script:CodexAppPath} | ConvertTo-Json)))
        }
        if(@(Get-CodexRunningProcesses $script:CodexAppPath).Count -eq 0){Start-CodexDesktop $script:CodexAppPath $script:DataRoot}
        else{$script:Controls.LoginStatus.Text='Codex 已在运行，请切换到其窗口完成登录。'}
    }catch{$script:Controls.LoginStatus.Text=Get-ActionErrorText $_}
})
$script:Controls.CancelLoginButton.Add_Click({
    $answer=[Windows.MessageBox]::Show($script:Window,'请先完全退出 Codex。结束流程时，若没有活动认证文件则恢复原登录；若已有文件则保留它，不自动覆盖。','结束登录流程',[Windows.MessageBoxButton]::OKCancel)
    if($answer -ne [Windows.MessageBoxResult]::OK){return}
    try {
        if(-not $script:IsDemo){[void](Stop-NewAccountLogin $script:DataRoot $script:CodexAppPath)}
        $script:PendingLogin=$null;$script:LoginReady=$false;$script:Controls.LoginBanner.Visibility='Collapsed';Update-ActionButtons;Start-AccountRefresh
    }catch{$script:Controls.LoginStatus.Text=Get-ActionErrorText $_}
})
$script:LoginTimer=[Windows.Threading.DispatcherTimer]::new()
$script:LoginTimer.Interval=[TimeSpan]::FromSeconds(1)
$script:LoginTimer.Add_Tick({
    try{
        if($script:IsDemo){
            if($null -ne $script:PendingLogin){
                $script:DemoLoginTicks++
                if($script:DemoLoginTicks -ge 2){$script:LoginReady=$true;$script:Controls.LoginStatus.Text='演示：已检测到登录凭据，请点击右上角“保存当前账号”。';Update-ActionButtons}
            }
            return
        }
        $script:PendingLogin=Get-PendingLogin $script:DataRoot
        if($null -eq $script:PendingLogin){$script:Controls.LoginBanner.Visibility='Collapsed';$script:LoginReady=$false;Update-ActionButtons;return}
        $script:Controls.LoginBanner.Visibility='Visible'
        $observation=Get-LoginObservation $script:DataRoot $script:LoginPreviousFingerprint
        $script:LoginPreviousFingerprint=$observation.Fingerprint
        $script:LoginReady=$observation.State -eq 'Ready'
        $script:Controls.LoginStatus.Text=switch($observation.State){
            Ready {'已检测到新凭据：'+$observation.Identity.Email+'。请点击右上角“保存当前账号”。'}
            Interrupted {'上次登录准备被中断，原凭据仍在。请点击“结束 / 恢复”，然后重新开始。'}
            Incomplete {'认证文件正在写入，或身份尚无法确认；请完成官方登录后等待。'}
            default {'等待登录 · 请在 Codex 中完成登录。可关闭管理器，稍后重新打开继续。'}
        }
        Update-ActionButtons
        if($script:LoginReady -and $script:ReadyFingerprint -cne $observation.Fingerprint -and $null -eq $script:Worker){
            $script:ReadyFingerprint=$observation.Fingerprint;Start-AccountRefresh
        }
    }catch{
        $script:PendingLogin=@{Blocked=$true};$script:LoginReady=$false
        $script:Controls.LoginBanner.Visibility='Visible';$script:Controls.LoginStatus.Text=Get-ActionErrorText $_;Update-ActionButtons
    }
})
