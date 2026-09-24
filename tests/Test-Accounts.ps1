param([string]$ScratchDirectory=$env:TEMP)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Account.Switch.ps1')
. (Join-Path $root 'Account.Login.ps1')
$script:Checks=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:Checks++}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Assert $failed $Message}
function New-Jwt($Payload){
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 6 -Compress))
    return 'e30.'+[Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')+'.synthetic'
}
function New-AuthBytes([string]$Account,[string]$User,[string]$Email,[int]$Revision=1){
    $claims=@{email=$Email;name='Fixture';revision=$Revision;'https://api.openai.com/auth'=@{chatgpt_account_id=$Account;chatgpt_user_id=$User}}
    $jwt=New-Jwt $claims
    return [Text.Encoding]::UTF8.GetBytes((@{tokens=@{account_id=$Account;id_token=$jwt;access_token=$jwt;refresh_token=('synthetic-'+$Revision)}} | ConvertTo-Json -Compress))
}
$fixtureRoot=Join-Path $ScratchDirectory ('codex-accounts-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$script:A=New-AuthBytes 'account-A' 'user-A' 'a@example.test'
$script:A2=New-AuthBytes 'account-A' 'user-A' 'a@example.test' 2
$script:B=New-AuthBytes 'account-B' 'user-B' 'b@example.test'
function Put([string]$Path,[byte[]]$Bytes){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllBytes($Path,$Bytes)}
function New-Fixture([string]$Name){
    $dir=Join-Path $fixtureRoot $Name
    Put (Join-Path $dir 'auth.json') $script:A
    Put (Join-Path $dir 'my_auth\原有别名\auth.json') $script:A2
    Put (Join-Path $dir 'my_auth\目标账户\auth.json') $script:B
    [IO.File]::WriteAllText((Join-Path $dir 'my_auth\.current_account.txt'),'目标账户')
    return $dir
}
function Expected([string]$Directory){Get-AccountFingerprint (Join-Path $Directory 'auth.json')}
$none={param($path) @()};$running={param($path) [pscustomobject]@{Id=123;Name='synthetic'}};$launch={param($path,$dir)}
$app=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$dir=New-Fixture 'identity'
$inventory=Get-AccountInventory $dir
Assert ($inventory.Matches.Count -eq 1 -and $inventory.Others.Count -eq 1) 'Identity dedup failed across token rotations'
Assert ($inventory.Current.Name -eq '原有别名') 'Legacy record was trusted'
Assert ((Get-AuthIdentity -Bytes $A).Key -ceq (Get-AuthIdentity -Bytes $A2).Key) 'Token rotation changed identity'
Assert ((Get-AuthIdentity -Bytes (New-AuthBytes 'account-A' 'other-user' 'a@example.test')).Key -cne $inventory.Current.Identity.Key) 'Different workspace member merged'
Assert ((Get-AuthIdentity -Bytes (New-AuthBytes 'other-account' 'user-A' 'a@example.test')).Key -cne $inventory.Current.Identity.Key) 'Different workspace merged'
$bad=[Text.Encoding]::UTF8.GetString($A) | ConvertFrom-Json
$bad.tokens.account_id='wrong'
Assert ((Get-AuthIdentity -Bytes ([Text.Encoding]::UTF8.GetBytes(($bad | ConvertTo-Json -Compress)))).Status -eq 'Conflict') 'Conflicting account accepted'
$bad=[Text.Encoding]::UTF8.GetString($A) | ConvertFrom-Json
$bad.tokens.access_token=New-Jwt @{'https://api.openai.com/auth'=@{chatgpt_account_id='account-A';chatgpt_user_id='other'}}
Assert ((Get-AuthIdentity -Bytes ([Text.Encoding]::UTF8.GetBytes(($bad | ConvertTo-Json -Compress)))).Status -eq 'Conflict') 'Conflicting token users accepted'
$unknown=[Text.Encoding]::UTF8.GetBytes('{"tokens":{"access_token":"opaque"}}')
Assert ((Get-AuthIdentity -Bytes $unknown).Status -eq 'Unknown') 'Opaque credential identity guessed'
$bHash=Get-AccountFingerprint (Join-Path $dir 'my_auth\目标账户\auth.json')
$saved=Save-CurrentAccount -Directory $dir -Expected (Expected $dir)
Assert ($saved.Name -eq '原有别名') 'Existing alias not preserved'
Assert ((Get-AccountFingerprint $saved.Path) -ceq (Expected $dir)) 'Saved bytes differ from active'
Assert ((Get-AccountFingerprint (Join-Path $dir 'my_auth\目标账户\auth.json')) -ceq $bHash) 'Wrong account overwritten by legacy record'
Reject {Save-CurrentAccount $dir '目标账户' '' (Expected $dir)} 'Different identity collision allowed'
$saved=Save-CurrentAccount $dir '另存名称' '' (Expected $dir)
Assert ([IO.File]::Exists($saved.Path) -and [IO.Directory]::Exists((Join-Path $dir 'my_auth\原有别名'))) 'Save-as renamed old folder'
Reject {Save-CurrentAccount -Directory $dir -Expected (Expected $dir)} 'Ambiguous identity silently selected'
$saved=Save-CurrentAccount -Directory $dir -SelectedName '原有别名' -Expected (Expected $dir)
Assert ($saved.Name -eq '原有别名') 'Explicit same-identity selection failed'
$dir=New-Fixture 'default-name';Put (Join-Path $dir 'auth.json') (New-AuthBytes 'C' 'C' 'c@example.test')
$saved=Save-CurrentAccount -Directory $dir -Expected (Expected $dir)
Assert ($saved.Name -eq 'c@example.test') 'Email default missing'
$dir=New-Fixture 'name-collision';Put (Join-Path $dir 'auth.json') (New-AuthBytes 'C' 'C' '目标账户')
$saved=Save-CurrentAccount -Directory $dir -Expected (Expected $dir)
Assert ($saved.Name -like '目标账户-*') 'Automatic collision not disambiguated'
$dir=New-Fixture 'missing-email';Put (Join-Path $dir 'auth.json') (New-AuthBytes 'C' 'C' '')
Reject {Save-CurrentAccount -Directory $dir -Expected (Expected $dir)} 'Missing email silently named'
$saved=Save-CurrentAccount $dir '手动名字' '' (Expected $dir)
Assert ($saved.Name -eq '手动名字') 'Explicit name with missing email failed'
foreach($badName in @('..','../outside','a\b','CON','nul.txt','trailing.')){Reject {Assert-AccountName $badName} 'Unsafe name accepted'}
$dir=New-Fixture 'stale-save';$before=Expected $dir;Put (Join-Path $dir 'auth.json') $B
Reject {Save-CurrentAccount -Directory $dir -Expected $before} 'Stale save accepted'
$dir=New-Fixture 'switch';$snapshot=Get-SwitchSnapshot $dir '目标账户'
[IO.File]::WriteAllText((Join-Path $dir 'my_auth\.current_account.txt'),'another-wrong-record')
$result=Invoke-AccountSwitch -Directory $dir -TargetName '目标账户' -Expected $snapshot
Assert ($result.Changed -and (Expected $dir) -ceq $snapshot.Target) 'Identity switch failed'
Assert ((Get-AccountFingerprint (Join-Path $dir 'my_auth\原有别名\auth.json')) -ceq $snapshot.Active) 'Switch backup belonged to wrong account'
$dir=New-Fixture 'record-failure';$snapshot=Get-SwitchSnapshot $dir '目标账户'
$script:RealAtomic=${function:Write-AccountAtomic}
function Write-AccountAtomic([string]$Path,[byte[]]$Bytes){if([IO.Path]::GetFileName($Path) -eq '.current_account.txt'){throw 'fixture failure'};& $script:RealAtomic $Path $Bytes}
$result=Invoke-AccountSwitch -Directory $dir -TargetName '目标账户' -Expected $snapshot
Assert ($result.Changed -and -not $result.RecordWritten -and (Expected $dir) -ceq $snapshot.Target) 'Compatibility record failure rolled back switch'
Set-Item Function:Write-AccountAtomic $script:RealAtomic
$dir=New-Fixture 'same-identity-switch';$before=Expected $dir
$result=Invoke-AccountSwitch -Directory $dir -TargetName '原有别名' -Expected (Get-SwitchSnapshot $dir '原有别名')
Assert (-not $result.Changed -and (Expected $dir) -ceq $before) 'Same identity switch regressed refreshed tokens'
$dir=New-Fixture 'online-email';Put (Join-Path $dir 'auth.json') (New-AuthBytes 'C' 'C' '')
$saved=Save-CurrentAccount -Directory $dir -Expected (Expected $dir) -PreferredEmail 'verified@example.test'
Assert ($saved.Name -eq 'verified@example.test') 'Verified online email was not used'
$dir=New-Fixture 'running';$before=Expected $dir
Reject {Start-NewAccountLogin $dir $app $before '' $running $launch} 'Live process did not block login reset'
Assert ((Expected $dir) -ceq $before -and -not [IO.Directory]::Exists((Join-Path $dir 'account-manager-recovery'))) 'Blocked login wrote recovery/active'
foreach($mode in @('keyring','auto','ephemeral')){
    [IO.File]::WriteAllText((Join-Path $dir 'config.toml'),('cli_auth_credentials_store = "'+$mode+'"'))
    Reject {Start-NewAccountLogin $dir $app $before '' $none $launch} 'Unsupported store reset allowed'
}
$dir=New-Fixture 'missing-launcher';$before=Expected $dir
Reject {Start-NewAccountLogin $dir (Join-Path $dir 'missing.exe') $before '' $none $launch} 'Missing launcher accepted'
Assert ((Expected $dir) -ceq $before) 'Launcher validation removed auth'
$dir=New-Fixture 'login';$before=Expected $dir
$session=Start-NewAccountLogin $dir $app $before '' $none $launch
Assert ((Expected $dir) -eq 'missing' -and $session.State -eq 'Waiting') 'Login did not remove active auth'
Assert ((Get-AccountFingerprint (Join-Path $dir ('account-manager-recovery\'+$session.Id+'\auth.json'))) -ceq $before) 'Recovery copy differs'
Assert ((Get-AccountFingerprint (Join-Path $dir 'my_auth\原有别名\auth.json')) -ceq $before) 'Login backup identity wrong'
Assert ((Get-PendingLogin $dir).Id -eq $session.Id) 'Restart could not discover pending login'
Reject {Start-NewAccountLogin $dir $app 'missing' '' $none $launch} 'Concurrent login allowed'
Reject {Invoke-AccountSwitch -Directory $dir -TargetName '目标账户' -Expected (Get-SwitchSnapshot $dir '目标账户')} 'Switch during login allowed'
[IO.File]::WriteAllText((Join-Path $dir 'auth.json'),'{"tokens":')
Assert ((Get-LoginObservation $dir).State -eq 'Incomplete') 'Partial JSON accepted as login'
Put (Join-Path $dir 'auth.json') $B
$observation=Get-LoginObservation $dir
Assert ($observation.State -eq 'Waiting') 'First read prematurely accepted'
Assert ((Get-LoginObservation $dir $observation.Fingerprint).State -eq 'Ready') 'Stable new credential not accepted'
$saved=Save-NewLoginAccount -Directory $dir -Expected (Expected $dir)
Assert ($saved.Name -eq '目标账户' -and $null -eq (Get-PendingLogin $dir)) 'Login save did not finish session'
$dir=New-Fixture 'launch-fail';$before=Expected $dir
Reject {Start-NewAccountLogin $dir $app $before '' $none {param($p,$d) throw 'synthetic launch failure'}} 'Launch failure unreported'
Assert ((Expected $dir) -ceq $before -and $null -eq (Get-PendingLogin $dir)) 'Launch failure did not restore auth'
$dir=New-Fixture 'cancel';$before=Expected $dir
$session=Start-NewAccountLogin $dir $app $before '' $none $launch
Reject {Stop-NewAccountLogin $dir $app $running} 'Restore while running allowed'
$result=Stop-NewAccountLogin $dir $app $none
Assert ($result.Restored -and (Expected $dir) -ceq $before) 'Cancel did not restore old login'
$dir=New-Fixture 'preserve-new';$before=Expected $dir
$session=Start-NewAccountLogin $dir $app $before '' $none $launch
Put (Join-Path $dir 'auth.json') $B;$newHash=Expected $dir
$result=Stop-NewAccountLogin $dir $app $none
Assert ($result.KeptExisting -and (Expected $dir) -ceq $newHash) 'Cancel overwrote new credential'
$dir=New-Fixture 'unknown-login';Put (Join-Path $dir 'auth.json') $unknown;$before=Expected $dir
$session=Start-NewAccountLogin $dir $app $before '' $none $launch
Assert ($session.IdentityStatus -eq 'Unknown' -and $session.SavedName -eq '' -and (Get-AccountInventory $dir).Saved.Count -eq 2) 'Unknown identity assigned to a saved account'
$result=Stop-NewAccountLogin $dir $app $none
Assert ((Expected $dir) -ceq $before) 'Unknown credential was not recoverable'
$dir=New-Fixture 'backup-fail';$before=Expected $dir
function Write-AccountAtomic([string]$Path,[byte[]]$Bytes){if($Path -like '*my_auth*'){throw 'synthetic backup failure'};& $script:RealAtomic $Path $Bytes}
Reject {Start-NewAccountLogin $dir $app $before '' $none $launch} 'Backup failure ignored'
Assert ((Expected $dir) -ceq $before) 'Backup failure removed auth'
Set-Item Function:Write-AccountAtomic $script:RealAtomic
$dir=New-Fixture 'racing-process';$before=Expected $dir;$script:ProbeCount=0
$racing={param($p) $script:ProbeCount++;if($script:ProbeCount -gt 1){[pscustomobject]@{Id=123}}}
Reject {Start-NewAccountLogin $dir $app $before '' $racing $launch} 'Late process start ignored'
Assert ((Expected $dir) -ceq $before) 'Late process start removed auth'
Assert ((Get-LoginObservation $dir $before).State -eq 'Interrupted') 'Interrupted preparation not recognized'
[void](Stop-NewAccountLogin $dir $app $none)
$dir=New-Fixture 'empty-login';[IO.File]::Delete((Join-Path $dir 'auth.json'))
$session=Start-NewAccountLogin $dir $app 'missing' '' $none $launch
[void](Stop-NewAccountLogin $dir $app $none)
Assert ((Expected $dir) -eq 'missing') 'No-auth cancellation created credential'
$dir=New-Fixture 'corrupt-recovery';$before=Expected $dir
$session=Start-NewAccountLogin $dir $app $before '' $none $launch
Put (Join-Path $dir ('account-manager-recovery\'+$session.Id+'\auth.json')) $B
Reject {Stop-NewAccountLogin $dir $app $none} 'Corrupted recovery accepted'
Assert ((Expected $dir) -eq 'missing' -and $null -ne (Get-PendingLogin $dir)) 'Corrupted recovery lost pending state'
$dir=New-Fixture 'late-login-write';$before=Expected $dir
$session=Start-NewAccountLogin $dir $app $before '' $none $launch
$writer={param($path) Put (Join-Path $dir 'auth.json') $script:B; @()}
$result=Stop-NewAccountLogin $dir $app $writer
Assert ($result.KeptExisting -and (Expected $dir) -ceq (Get-BytesFingerprint $B)) 'Late external login was overwritten'
$dir=New-Fixture 'auth-race';$before=Expected $dir;$script:ProbeCount=0
$writer={param($path) $script:ProbeCount++;if($script:ProbeCount -gt 1){Put (Join-Path $dir 'auth.json') $script:B};@()}
Reject {Start-NewAccountLogin $dir $app $before '' $writer $launch} 'Changed credential during preparation accepted'
Assert ((Expected $dir) -ceq (Get-BytesFingerprint $B)) 'Preparation removed changed credential'
[void](Stop-NewAccountLogin $dir $app $none)
Assert (-not ((Get-AuthIdentity -Bytes $A).PSObject.Properties.Name -match 'token')) 'Identity model contains tokens'
[pscustomobject]@{Result='PASS';Checks=$script:Checks;FixtureDirectory=$fixtureRoot} | ConvertTo-Json -Compress
