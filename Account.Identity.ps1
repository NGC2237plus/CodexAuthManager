# Local identity metadata only; decoding a JWT is not signature verification.
function Get-AuthValue($Object, [string]$Name) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}
function Get-BytesFingerprint([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','') } finally { $sha.Dispose() }
}
function ConvertFrom-AuthJwt([string]$Token) {
    $parts=$Token.Split('.')
    if ($parts.Length -ne 3) { throw 'Invalid JWT' }
    $body=$parts[1].Replace('-','+').Replace('_','/')
    $body=$body.PadRight($body.Length + (4-$body.Length%4)%4,'=')
    return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($body)) | ConvertFrom-Json -ErrorAction Stop)
}
function Get-AuthIdentity {
    param([string]$Path, [byte[]]$Bytes)
    $result=[pscustomobject]@{Status='Missing';Key='';Email='';DisplayName='';Fingerprint='missing';ValidCredential=$false}
    if ($null -eq $Bytes) {
        if (-not [IO.File]::Exists($Path)) { return $result }
        try { $Bytes=[IO.File]::ReadAllBytes($Path) } catch { $result.Status='Unreadable';return $result }
    }
    $result.Fingerprint=Get-BytesFingerprint $Bytes
    $result.Status='Invalid'
    try {
        $auth=[Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xfeff) | ConvertFrom-Json -ErrorAction Stop
        $tokens=Get-AuthValue $auth 'tokens'
        $access=Get-AuthValue $tokens 'access_token'
        $result.ValidCredential=($access -is [string] -and -not [string]::IsNullOrWhiteSpace($access))
        if (-not $result.ValidCredential) { return $result }
        $accounts=@(); $users=@(); $invalidToken=$false
        $storedAccount=[string](Get-AuthValue $tokens 'account_id')
        if ($storedAccount) { $accounts+=$storedAccount }
        foreach ($field in @('id_token','access_token')) {
            $token=[string](Get-AuthValue $tokens $field)
            if (-not $token) { continue }
            try { $claims=ConvertFrom-AuthJwt $token } catch { $invalidToken=$true;continue }
            $scope=Get-AuthValue $claims 'https://api.openai.com/auth'
            $account=[string](Get-AuthValue $scope 'chatgpt_account_id')
            $user=[string](Get-AuthValue $scope 'chatgpt_user_id')
            if ($account) { $accounts+=$account }
            if ($user) { $users+=$user }
            $profile=Get-AuthValue $claims 'https://api.openai.com/profile'
            if (-not $result.Email) { $result.Email=[string](Get-AuthValue $claims 'email') }
            if (-not $result.Email) { $result.Email=[string](Get-AuthValue $profile 'email') }
            if (-not $result.DisplayName) { $result.DisplayName=[string](Get-AuthValue $claims 'name') }
            if (-not $result.DisplayName) { $result.DisplayName=[string](Get-AuthValue $profile 'name') }
        }
        $result.Email=($result.Email -replace '[\x00-\x1f\x7f-\x9f]',' ').Trim()
        $result.DisplayName=($result.DisplayName -replace '[\x00-\x1f\x7f-\x9f]',' ').Trim()
        $uniqueAccounts=@($accounts | Select-Object -Unique)
        $uniqueUsers=@($users | Select-Object -Unique)
        $result.Status='Unknown'
        if ($uniqueAccounts.Count -gt 1 -or $uniqueUsers.Count -gt 1) { $result.Status='Conflict' }
        elseif (-not $invalidToken -and $uniqueAccounts.Count -eq 1 -and $uniqueUsers.Count -eq 1) {
            $keyText=@($uniqueAccounts[0],$uniqueUsers[0]) | ConvertTo-Json -Compress
            $result.Key=Get-BytesFingerprint ([Text.Encoding]::UTF8.GetBytes($keyText))
            $result.Status='Known'
        }
    } catch { $result.Status='Invalid' }
    return $result
}
function Get-AccountInventory([string]$Directory) {
    $active=Get-AuthIdentity -Path (Join-Path $Directory 'auth.json')
    $saved=@(); $matches=@(); $others=@()
    $store=Join-Path $Directory 'my_auth'
    if ([IO.Directory]::Exists($store)) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $store -Directory -ErrorAction Stop | Sort-Object Name)) {
            $path=Join-Path $folder.FullName 'auth.json'
            $identity=Get-AuthIdentity -Path $path
            $entry=[pscustomobject]@{Name=$folder.Name;IsCurrent=$false;AuthPath=$path;Identity=$identity}
            $saved+=$entry
            if ($active.Status -eq 'Known' -and $identity.Status -eq 'Known' -and $active.Key -ceq $identity.Key) { $matches+=$entry }
            else { $others+=$entry }
        }
    }
    $name=if($matches.Count -eq 1){$matches[0].Name}elseif($active.Email){$active.Email}else{'当前登录'}
    $current=[pscustomobject]@{Name=$name;IsCurrent=$true;AuthPath=(Join-Path $Directory 'auth.json');Identity=$active}
    [pscustomobject]@{Current=$current;Saved=$saved;Matches=$matches;Others=$others}
}
