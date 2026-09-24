. (Join-Path $PSScriptRoot 'Account.Identity.ps1')

function Invoke-AccountLock([string]$Directory,[scriptblock]$Action) {
    $key=Get-BytesFingerprint ([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Directory).TrimEnd('\','/').ToUpperInvariant()))
    $mutex=[Threading.Mutex]::new($false,('Local\CodexAuthManager-'+$key)); $locked=$false
    try {
        try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if(-not $locked){throw '另一个管理器正在操作账户，请稍后重试。'}
        & $Action
    } finally { if($locked){$mutex.ReleaseMutex()}; $mutex.Dispose() }
}
function Assert-CurrentFingerprint([string]$Directory,[string]$Expected) {
    $path=Join-Path $Directory 'auth.json'; Assert-NoAccountLink $path
    if(-not $Expected -or (Get-AccountFingerprint $path) -cne $Expected){throw '登录文件已经变化，请重新打开操作窗口。'}
}
function Write-CompatibilityRecord([string]$Directory,[string]$Name) {
    try {
        $path=Join-Path $Directory 'my_auth\.current_account.txt'; Assert-NoAccountLink $path
        Write-AccountAtomic $path ([Text.UTF8Encoding]::new($false).GetBytes($Name+[Environment]::NewLine))
        return $true
    } catch { return $false }
}
function ConvertTo-AutomaticAccountName([string]$Email) {
    $name=($Email -replace '[<>:"/\\|?*\x00-\x1f]','_').Trim().TrimEnd('.')
    if($name.Length -gt 95){$name=$name.Substring(0,95)}
    try { Assert-AccountName $name } catch { $name='账号-'+$name }
    return $name
}
function Save-CurrentAccountCore {
    param([string]$Directory,[string]$Name,[string]$SelectedName,[string]$Expected,[string]$PreferredEmail='')
    Assert-CurrentFingerprint $Directory $Expected
    $inventory=Get-AccountInventory $Directory; $identity=$inventory.Current.Identity
    if(-not $identity.ValidCredential){throw '当前凭据缺失或无效，不能保存为账号。'}
    $manual=-not [string]::IsNullOrWhiteSpace($Name)
    if($manual){ $destinationName=$Name.Trim() }
    elseif($inventory.Matches.Count -eq 1){ $destinationName=$inventory.Matches[0].Name }
    elseif($inventory.Matches.Count -gt 1){
        if($SelectedName -notin @($inventory.Matches | ForEach-Object {$_.Name})){throw '同一身份有多份备份，请选择要更新的一份。'}
        $destinationName=$SelectedName
    } else {
        $email=if($PreferredEmail){$PreferredEmail}else{$identity.Email}
        if(-not $email){throw '无法取得账号邮箱，请填写保存名称。'}
        $destinationName=ConvertTo-AutomaticAccountName $email
    }
    Assert-AccountName $destinationName
    $store=Join-Path $Directory 'my_auth'
    $path=Join-Path (Join-Path $store $destinationName) 'auth.json'
    Assert-NoAccountLink $path
    $old=Get-AuthIdentity -Path $path
    if($old.Fingerprint -ne 'missing' -and -not ($old.Status -eq 'Known' -and $identity.Status -eq 'Known' -and $old.Key -ceq $identity.Key)){
        if($manual -or $inventory.Matches.Count -gt 0){throw '同名备份属于其他账号或身份无法确认，请换一个名称。'}
        $suffix=if($identity.Key){$identity.Key.Substring(0,8)}else{$identity.Fingerprint.Substring(0,8)}
        $base=$destinationName+'-'+$suffix; $destinationName=$base; $n=2
        while($true){
            $path=Join-Path (Join-Path $store $destinationName) 'auth.json'; Assert-NoAccountLink $path
            $old=Get-AuthIdentity -Path $path
            if($old.Fingerprint -eq 'missing' -or ($old.Status -eq 'Known' -and $identity.Status -eq 'Known' -and $old.Key -ceq $identity.Key)){break}
            $destinationName=$base+'-'+$n; $n++
        }
    }
    $bytes=[IO.File]::ReadAllBytes($inventory.Current.AuthPath)
    if((Get-BytesFingerprint $bytes) -cne $Expected){throw '登录文件已经变化，请重新保存。'}
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    Assert-CurrentFingerprint $Directory $Expected
    if((Get-AccountFingerprint $path) -cne $old.Fingerprint){throw '备份文件已经变化，请重试。'}
    Write-AccountAtomic $path $bytes
    if((Get-AccountFingerprint $path) -cne $Expected){throw '备份校验失败，操作已停止。'}
    Assert-CurrentFingerprint $Directory $Expected
    [pscustomobject]@{Name=$destinationName;Path=$path;Fingerprint=$Expected;IdentityKey=$identity.Key}
}
function Save-CurrentAccount {
    param([string]$Directory,[string]$Name='',[string]$SelectedName='',[string]$Expected,[string]$PreferredEmail='')
    Invoke-AccountLock $Directory {
        Assert-NoPendingLogin $Directory
        Save-CurrentAccountCore $Directory $Name $SelectedName $Expected $PreferredEmail
    }
}
function New-AccountRecovery([string]$Directory,[string]$Expected,[string]$Purpose) {
    Assert-CurrentFingerprint $Directory $Expected
    $recoveryDir=Join-Path $Directory ('account-manager-recovery\'+[guid]::NewGuid().ToString('N'))
    Assert-NoAccountLink $recoveryDir
    [void][IO.Directory]::CreateDirectory($recoveryDir)
    if($Expected -ne 'missing'){
        $bytes=[IO.File]::ReadAllBytes((Join-Path $Directory 'auth.json'))
        if((Get-BytesFingerprint $bytes) -cne $Expected){throw '登录文件已经变化，请重试。'}
        Write-AccountAtomic (Join-Path $recoveryDir 'auth.json') $bytes
        if((Get-AccountFingerprint (Join-Path $recoveryDir 'auth.json')) -cne $Expected){throw '恢复备份校验失败。'}
    }
    $session=[pscustomobject]@{Version=1;Id=([IO.Path]::GetFileName($recoveryDir));Purpose=$Purpose;State='Prepared';OriginalFingerprint=$Expected;CreatedUtc=[DateTime]::UtcNow.ToString('o');SavedName='';IdentityStatus=(Get-AuthIdentity -Path (Join-Path $Directory 'auth.json')).Status}
    Write-LoginSession $Directory $session
    return $session
}
function Write-LoginSession([string]$Directory,$Session) {
    if($Session.Id -notmatch '^[a-f0-9]{32}$'){throw '恢复记录无效。'}
    $path=Join-Path $Directory ('account-manager-recovery\'+$Session.Id+'\session.json')
    Assert-NoAccountLink $path
    Write-AccountAtomic $path ([Text.UTF8Encoding]::new($false).GetBytes(($Session | ConvertTo-Json -Depth 4)))
}
function Get-PendingLogin([string]$Directory) {
    $root=Join-Path $Directory 'account-manager-recovery'; Assert-NoAccountLink $root
    if(-not [IO.Directory]::Exists($root)){return $null}
    $pending=@()
    foreach($folder in @(Get-ChildItem -LiteralPath $root -Directory)){
        $path=Join-Path $folder.FullName 'session.json'; Assert-NoAccountLink $path
        if(-not [IO.File]::Exists($path)){continue}
        try{$session=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop}catch{throw '恢复记录无法读取，请检查恢复目录。'}
        if($session.Id -cne $folder.Name -or $session.Version -ne 1){throw '恢复记录无效。'}
        if($session.Purpose -eq 'Login' -and $session.State -in @('Prepared','Removed','Waiting','Detected','RestorePending')){$pending+=$session}
    }
    if($pending.Count -gt 1){throw '存在多份未完成的登录记录，请先检查恢复目录。'}
    if($pending.Count -eq 1){return $pending[0]}
    return $null
}
function Assert-NoPendingLogin([string]$Directory) {
    if($null -ne (Get-PendingLogin $Directory)){throw '登录流程尚未结束，请先保存新账号或结束登录流程。'}
}
function Get-SwitchSnapshot([string]$Directory,[string]$TargetName) {
    Assert-AccountName $TargetName
    $path=Join-Path $Directory ('my_auth\'+$TargetName+'\auth.json'); Assert-NoAccountLink $path
    if(-not [IO.File]::Exists($path)){throw '目标账户没有认证文件。'}
    $active=Join-Path $Directory 'auth.json';Assert-NoAccountLink $active
    [pscustomobject]@{Active=Get-AccountFingerprint $active;Target=Get-AccountFingerprint $path}
}
function Invoke-AccountSwitch {
    param([string]$Directory,[string]$TargetName,[string]$BackupName='',$Expected,[string]$SelectedName='')
    Invoke-AccountLock $Directory {
        Assert-NoPendingLogin $Directory
        $snapshot=Get-SwitchSnapshot $Directory $TargetName
        if($null -eq $Expected -or $snapshot.Active -cne $Expected.Active -or $snapshot.Target -cne $Expected.Target){throw '登录文件已经变化，请重新打开切换窗口。'}
        $target=Join-Path $Directory ('my_auth\'+$TargetName+'\auth.json')
        $bytes=[IO.File]::ReadAllBytes($target); $identity=Get-AuthIdentity -Bytes $bytes
        if(-not $identity.ValidCredential -or $identity.Status -ne 'Known'){throw '目标凭据无效或身份无法确认，不能切换。'}
        if($identity.Fingerprint -cne $Expected.Target){throw '目标文件已经变化，请重新选择。'}
        if($snapshot.Active -ceq $snapshot.Target){return [pscustomobject]@{Changed=$false;RecordWritten=$true}}
        $current=Get-AuthIdentity -Path (Join-Path $Directory 'auth.json')
        if($current.Status -eq 'Known' -and $current.Key -ceq $identity.Key){return [pscustomobject]@{Changed=$false;RecordWritten=$true}}
        $recovery=New-AccountRecovery $Directory $Expected.Active 'Switch'
        if($current.Status -eq 'Known'){
            $saved=Save-CurrentAccountCore $Directory $BackupName $SelectedName $Expected.Active
            $recovery.SavedName=$saved.Name
        }
        $latest=Get-SwitchSnapshot $Directory $TargetName
        if($latest.Active -cne $Expected.Active -or $latest.Target -cne $Expected.Target){throw '登录文件已经变化，已停止切换。'}
        Write-AccountAtomic (Join-Path $Directory 'auth.json') $bytes
        $recovery.State='Completed'; Write-LoginSession $Directory $recovery
        $recordOk=Write-CompatibilityRecord $Directory $TargetName
        [pscustomobject]@{Changed=$true;RecordWritten=$recordOk}
    }
}
