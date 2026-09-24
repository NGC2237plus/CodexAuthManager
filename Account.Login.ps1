# Adapters are scriptblocks so tests never start/stop real Codex processes.
function Get-CodexRunningProcesses([string]$AppPath) {
    $appDirectory=if($AppPath){[IO.Path]::GetDirectoryName($AppPath)}else{''}
    foreach($process in @(Get-Process -ErrorAction Stop)) {
        if($process.Id -eq $PID){continue}
        if($process.ProcessName -match '^codex$'){[pscustomobject]@{Id=$process.Id;Name=$process.ProcessName};continue}
        if($process.ProcessName -notmatch '^(ChatGPT|codex-code-mode-host|codex-computer-use-swift)$'){continue}
        try {$path=$process.Path} catch {throw '无法检查 Codex 进程，请检查权限后重试。'}
        if(-not $path){throw '无法检查 Codex 进程，请检查权限后重试。'}
        if(($appDirectory -and $path.StartsWith($appDirectory+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) -or $path -match 'OpenAI\.Codex_' -or $process.ProcessName -like 'codex-*') {
            [pscustomobject]@{Id=$process.Id;Name=$process.ProcessName}
        }
    }
}
function Start-CodexDesktop([string]$AppPath,[string]$Directory) {
    $info=[Diagnostics.ProcessStartInfo]::new($AppPath)
    $info.UseShellExecute=$false; $info.WorkingDirectory=[IO.Path]::GetDirectoryName($AppPath)
    $info.EnvironmentVariables['CODEX_HOME']=[IO.Path]::GetFullPath($Directory)
    $process=[Diagnostics.Process]::Start($info)
    if($null -eq $process){throw '无法启动 Codex。'}
    $process.Dispose()
}
function Assert-CodexExited([string]$AppPath,[scriptblock]$ProcessProbe) {
    if(@(& $ProcessProbe $AppPath).Count -gt 0){throw 'Codex 尚未完全退出，请手动退出后点击重新检查。'}
}
function Assert-FileCredentialMode([string]$Directory) {
    $config=Join-Path $Directory 'config.toml'
    if([IO.File]::Exists($config)){
        $text=[IO.File]::ReadAllText($config)
        if($text -match '(?m)^\s*["'']?cli_auth_credentials_store["'']?\s*=\s*["''](keyring|auto|ephemeral)["'']'){
            throw '当前配置使用系统凭据库或内存存储，不能通过删除 auth.json 开始登录。'
        }
    }
}
function Find-CodexDesktopPath([string]$SettingsPath) {
    if([IO.File]::Exists($SettingsPath)){
        try{$settings=[IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json; if([IO.File]::Exists($settings.CodexAppPath)){return [string]$settings.CodexAppPath}}catch{}
    }
    foreach($p in @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)){
        try{if($p.Path -and $p.MainModule.FileVersionInfo.ProductName -eq 'Codex'){return $p.Path}}catch{}
    }
    foreach($package in @(Get-AppxPackage -Name '*Codex*' -ErrorAction SilentlyContinue | Sort-Object Version -Descending)){
        $path=Join-Path $package.InstallLocation 'app\ChatGPT.exe';if([IO.File]::Exists($path)){return $path}
    }
    return ''
}
function Start-NewAccountLogin {
    param([string]$Directory,[string]$AppPath,[string]$Expected,[string]$SelectedName='',
          [scriptblock]$ProcessProbe={param($path) Get-CodexRunningProcesses $path},
          [scriptblock]$Launcher={param($path,$dir) Start-CodexDesktop $path $dir})
    Invoke-AccountLock $Directory {
        Assert-NoPendingLogin $Directory
        if(-not [IO.File]::Exists($AppPath) -or [IO.Path]::GetExtension($AppPath) -ine '.exe'){throw '请选择有效的 Codex 桌面程序。'}
        Assert-NoAccountLink $Directory
        Assert-FileCredentialMode $Directory
        Assert-CodexExited $AppPath $ProcessProbe
        Assert-CurrentFingerprint $Directory $Expected
        $identity=Get-AuthIdentity -Path (Join-Path $Directory 'auth.json')
        # Resolve named backup before publishing a pending login session.
        $savedName=''
        if($identity.Status -eq 'Known'){
            $saved=Save-CurrentAccountCore $Directory '' $SelectedName $Expected
            $savedName=$saved.Name
        }
        $session=New-AccountRecovery $Directory $Expected 'Login'
        $session.SavedName=$savedName; Write-LoginSession $Directory $session
        Assert-CodexExited $AppPath $ProcessProbe
        Assert-CurrentFingerprint $Directory $Expected
        $active=Join-Path $Directory 'auth.json'
        if($Expected -ne 'missing'){[IO.File]::Delete($active)}
        $session.State='Removed'; Write-LoginSession $Directory $session
        try { & $Launcher $AppPath $Directory | Out-Null }
        catch {
            if(-not [IO.File]::Exists($active) -and @(& $ProcessProbe $AppPath).Count -eq 0){
                Restore-LoginOriginalCore $Directory $session
                $session.State='Cancelled'; Write-LoginSession $Directory $session
                throw 'Codex 启动失败，已恢复原登录文件。'
            }
            $session.State='RestorePending'; Write-LoginSession $Directory $session
            throw 'Codex 启动结果无法确认，已保留恢复备份，请检查进程和当前登录。'
        }
        $session.State='Waiting'; Write-LoginSession $Directory $session
        return $session
    }
}
function Restore-LoginOriginalCore([string]$Directory,$Session) {
    $active=Join-Path $Directory 'auth.json';Assert-NoAccountLink $active
    if([IO.File]::Exists($active)){throw '已存在登录文件，恢复操作不会覆盖它。'}
    if($Session.OriginalFingerprint -eq 'missing'){return}
    $source=Join-Path $Directory ('account-manager-recovery\'+$Session.Id+'\auth.json');Assert-NoAccountLink $source
    $bytes=[IO.File]::ReadAllBytes($source)
    if((Get-BytesFingerprint $bytes) -cne $Session.OriginalFingerprint){throw '恢复备份校验失败，未修改当前登录。'}
    # CreateNew ensures even a late external login cannot be overwritten.
    $stream=[IO.File]::Open($active,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush()}finally{$stream.Dispose()}
}
function Stop-NewAccountLogin {
    param([string]$Directory,[string]$AppPath,[scriptblock]$ProcessProbe={param($path) Get-CodexRunningProcesses $path})
    Invoke-AccountLock $Directory {
        $session=Get-PendingLogin $Directory
        if($null -eq $session){return}
        Assert-CodexExited $AppPath $ProcessProbe
        $active=Join-Path $Directory 'auth.json';Assert-NoAccountLink $active
        $existing=Get-AccountFingerprint $active
        if($existing -eq 'missing'){Restore-LoginOriginalCore $Directory $session}
        # Preserve any existing credential, including a new/partially written one.
        $session.State='Cancelled';Write-LoginSession $Directory $session
        [pscustomobject]@{KeptExisting=($existing -ne 'missing');Restored=($existing -eq 'missing' -and $session.OriginalFingerprint -ne 'missing')}
    }
}
function Get-LoginObservation {
    param([string]$Directory,[string]$PreviousFingerprint='',
          [scriptblock]$CredentialReader={param($path) Get-AuthIdentity -Path $path})
    $session=Get-PendingLogin $Directory
    if($null -eq $session){return [pscustomobject]@{State='None';Fingerprint='';Identity=$null}}
    $identity=& $CredentialReader (Join-Path $Directory 'auth.json')
    $state='Waiting'
    if($session.State -eq 'Prepared' -and $identity.Fingerprint -ceq $session.OriginalFingerprint){$state='Interrupted'}
    elseif($identity.ValidCredential -and $identity.Status -eq 'Known' -and $identity.Fingerprint -ceq $PreviousFingerprint){$state='Ready'}
    elseif($identity.Status -in @('Unknown','Conflict','Invalid')){$state='Incomplete'}
    [pscustomobject]@{State=$state;Fingerprint=$identity.Fingerprint;Identity=$identity}
}
function Save-NewLoginAccount {
    param([string]$Directory,[string]$Name='',[string]$SelectedName='',[string]$Expected,[string]$PreferredEmail='')
    Invoke-AccountLock $Directory {
        $session=Get-PendingLogin $Directory
        if($null -eq $session){throw '登录流程记录不存在，请重新刷新。'}
        $identity=Get-AuthIdentity -Path (Join-Path $Directory 'auth.json')
        if($identity.Status -ne 'Known'){throw '新凭据身份尚未确定，请等待登录完成。'}
        $saved=Save-CurrentAccountCore $Directory $Name $SelectedName $Expected $PreferredEmail
        $session.State='Completed';$session.SavedName=$saved.Name;Write-LoginSession $Directory $session
        [void](Write-CompatibilityRecord $Directory $saved.Name)
        return $saved
    }
}
