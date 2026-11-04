# Loaded only by -Demo -SmokeTest -RefreshSmokeTest; uses the real dispatcher and
# routed buttons with synthetic responses, never real credentials or HTTP calls.
$script:RefreshPhase=0
$script:RefreshChecks=0
function Assert-Refresh($Condition,[string]$Message){
    if(-not $Condition){throw $Message};$script:RefreshChecks++
}
function Find-RefreshButton($Visual){
    if($Visual -is [Windows.Controls.Button] -and $Visual.Name -eq 'RefreshAccountButton'){return $Visual}
    for($j=0;$j -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Visual);$j++){
        $result=Find-RefreshButton ([Windows.Media.VisualTreeHelper]::GetChild($Visual,$j))
        if($null -ne $result){return $result}
    }
    return $null
}
function Invoke-RefreshSmokeStep {
    Assert-Refresh (-not $script:UiFault) 'Refresh worker failed'
    if($script:RefreshPhase -gt 0 -and $script:RefreshPhase -lt 5){
        $all=@($script:Controls.CurrentPanel.DataContext)+@($script:Rows)
        Assert-Refresh ($script:Completed -eq 1 -and $script:RefreshEntries.Count -eq 1) 'Single click queried multiple entries'
        for($j=0;$j -lt $all.Count;$j++){
            if($j -eq $script:TestTarget){
                Assert-Refresh (-not [object]::ReferenceEquals($all[$j],$script:BeforeRows[$j])) 'Target row was not replaced'
                Assert-Refresh ($all[$j].RefreshText -eq '刷新' -and $all[$j].UpdatedText -ne '尚未刷新') 'Target refresh state not cleared'
            }else{Assert-Refresh ([object]::ReferenceEquals($all[$j],$script:BeforeRows[$j])) 'Unrelated account was replaced'}
        }
        Assert-Refresh ($script:Failures -eq 1 -and $script:Controls.ErrorCount.Text -eq '1') 'Global failure count incorrect'
        if($script:TestTarget -eq 4){Assert-Refresh ($script:Rows[3].Quotas[0].Remaining -eq 92) 'Result applied to wrong card'}
        if($script:TestTarget -eq 3){Assert-Refresh ($script:Rows[2].Status -eq '登录失效') 'Failed refresh result missing'}
        if($script:TestTarget -eq 1){Assert-Refresh (-not $script:Rows[0].QueryFailed) 'Recovered error still counted'}
        Assert-Refresh ($script:Controls.RefreshCurrentButton.IsEnabled -and $script:Controls.AccountList.IsEnabled) 'Buttons not restored'
    }
    if($script:RefreshPhase -eq 5){
        Assert-Refresh ($script:Completed -eq 5 -and $script:RefreshEntries.Count -eq 5 -and $script:Failures -eq 1) 'Full refresh after single refresh failed'
        return $false
    }
    if($script:RefreshPhase -eq 4){
        $script:RefreshPhase++
        $script:Controls.RefreshButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        return $true
    }
    $script:TestTarget=@(4,3,0,1)[$script:RefreshPhase]
    if($script:TestTarget -eq 1){
        $failed=$script:Rows[0].PSObject.Copy();$failed.QueryFailed=$true;$failed.Status='查询失败';$script:Rows[0]=$failed
    }
    $script:BeforeRows=@($script:Controls.CurrentPanel.DataContext)+@($script:Rows)
    $script:Window.UpdateLayout()
    $button=if($script:TestTarget -eq 0){$script:Controls.RefreshCurrentButton}else{
        Find-RefreshButton ($script:Controls.AccountList.ItemContainerGenerator.ContainerFromIndex($script:TestTarget-1))
    }
    Assert-Refresh ($null -ne $button) 'Per-account refresh button missing'
    $generation=$script:Generation
    $script:RefreshPhase++
    $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-Refresh ($null -ne $script:Worker -and $script:RefreshEntries.Count -eq 1 -and $script:RefreshEntries[0].Index -eq $script:TestTarget) 'Button did not select correct account'
    $busyRow=if($script:TestTarget -eq 0){$script:Controls.CurrentPanel.DataContext}else{$script:Rows[$script:TestTarget-1]}
    Assert-Refresh ($busyRow.RefreshText -eq '刷新中…') 'Busy label missing'
    Start-AccountRefresh -EntryIndex 0
    Assert-Refresh ($script:Generation -eq $generation+1) 'Duplicate click started another worker'
    return $true
}
