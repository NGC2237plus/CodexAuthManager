# Read-only account display for codex-auth-manager.bat (Windows PowerShell 5.1+).
# Credentials are sent only to the fixed official usage endpoint. No refresh,
# auth-file writes, account renaming, or changes to the current-account record.
param(
    [string]$CodexDir = (Join-Path $env:USERPROFILE '.codex'),
    [string]$AuthStore = '',
    [ValidateRange(1, 60)][int]$TimeoutSeconds = 12
)

function Get-CodexField {
    param($Object, [string]$Name)
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function ConvertTo-CodexDisplayText {
    param($Value)
    # Remote names must not inject terminal control sequences or extra lines.
    return ([string]$Value -replace '[\x00-\x1f\x7f-\x9f]', ' ').Trim()
}

function Invoke-CodexUsageRequest {
    param([string]$AccessToken, [string]$AccountId, [int]$Timeout)
    $headers = @{ Authorization = 'Bearer ' + $AccessToken }
    if ($AccountId) { $headers['ChatGPT-Account-ID'] = $AccountId }
    # Never follow redirects with credentials or accept a configurable upstream.
    Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage' `
        -Method Get -Headers $headers -MaximumRedirection 0 `
        -TimeoutSec $Timeout -ErrorAction Stop
}

function Get-CodexQueryError {
    param($ErrorRecord)
    $status = 0
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { }
    switch ($status) {
        401 { return 'Login expired or invalid (HTTP 401). Sign in with Codex and save again.' }
        403 { return 'Access denied (HTTP 403); check account access or network.' }
        429 { return 'Too many queries (HTTP 429); try again later.' }
    }
    if ($status -ge 300 -and $status -lt 400) { return 'Redirect refused; credentials were not forwarded.' }
    if ($status -ge 500) { return ('Service unavailable (HTTP {0}); try again later.' -f $status) }
    if ($status -gt 0) { return ('Query failed (HTTP {0}).' -f $status) }
    return 'Network/timeout error; check the connection or proxy and try again.'
}

function Get-CodexOnlineSummary {
    param([string]$AuthPath, [hashtable]$Cache, [int]$Timeout = 12)
    if (-not (Test-Path -LiteralPath $AuthPath -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Error = 'No auth.json found.' }
    }
    try {
        $auth = Get-Content -LiteralPath $AuthPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = 'auth.json cannot be read or is not valid JSON.' }
    }
    $tokens = Get-CodexField $auth 'tokens'
    $accessToken = [string](Get-CodexField $tokens 'access_token')
    $accountId = [string](Get-CodexField $tokens 'account_id')
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        return [pscustomobject]@{ Ok = $false; Error = 'No ChatGPT access token; subscription quota is unavailable for this entry.' }
    }
    # Only deduplicate identical credentials during this listing; no disk cache.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $key = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($accountId + "`n" + $accessToken)))
    } finally { $sha.Dispose() }
    if ($null -ne $Cache -and $Cache.ContainsKey($key)) { return $Cache[$key] }
    try {
        $usage = Invoke-CodexUsageRequest -AccessToken $accessToken -AccountId $accountId -Timeout $Timeout
        if ($null -eq $usage -or $usage -is [string] -or $null -eq $usage.PSObject.Properties['rate_limit']) {
            $result = [pscustomobject]@{ Ok = $false; Error = 'Unexpected usage response; quota is unavailable.' }
        } else {
            # The email/name comes from the network response, never local JWT claims.
            $onlineName = ConvertTo-CodexDisplayText (Get-CodexField $usage 'email')
            if (-not $onlineName) { $onlineName = ConvertTo-CodexDisplayText (Get-CodexField $usage 'name') }
            if (-not $onlineName) { $onlineName = '(not returned by server)' }
            $result = [pscustomobject]@{ Ok = $true; OnlineName = $onlineName; Usage = $usage }
        }
    } catch {
        # Never print the exception/response body, headers, tokens or auth JSON.
        $result = [pscustomobject]@{ Ok = $false; Error = (Get-CodexQueryError $_) }
    }
    if ($null -ne $Cache) { $Cache[$key] = $result }
    return $result
}

function Format-CodexQuotaWindow {
    param($Window, [string]$FallbackName)
    if ($null -eq $Window) { return $null }
    $windowName = $FallbackName
    $seconds = 0.0
    $rawSeconds = Get-CodexField $Window 'limit_window_seconds'
    if ($null -ne $rawSeconds -and [double]::TryParse([string]$rawSeconds, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -and $seconds -gt 0) {
        if ($seconds % 86400 -eq 0) { $windowName = ('{0}d' -f ($seconds / 86400)) }
        elseif ($seconds % 3600 -eq 0) { $windowName = ('{0}h' -f ($seconds / 3600)) }
        else { $windowName = ('{0:0.#}m' -f ($seconds / 60)) }
    }
    $remaining = 'unavailable'
    $used = 0.0
    $rawUsed = Get-CodexField $Window 'used_percent'
    if ($null -ne $rawUsed -and [double]::TryParse([string]$rawUsed, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$used) -and -not [double]::IsNaN($used) -and -not [double]::IsInfinity($used)) {
        $remaining = ('{0:0.#}% remaining' -f [Math]::Max(0, [Math]::Min(100, 100 - $used)))
    }
    $reset = 'unknown'
    try {
        $rawReset = Get-CodexField $Window 'reset_at'
        if ($null -ne $rawReset -and [double]$rawReset -gt 0) {
            $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01', [DateTimeKind]::Utc)
            $reset = $epoch.AddSeconds([double]$rawReset).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        }
    } catch { }
    return ('{0}: {1}; resets {2}' -f $windowName, $remaining, $reset)
}

function Get-CodexQuotaLines {
    param($Limit, [string]$Label)
    if ($null -eq $Limit) { return }
    $primary = Format-CodexQuotaWindow (Get-CodexField $Limit 'primary_window') 'primary'
    $secondary = Format-CodexQuotaWindow (Get-CodexField $Limit 'secondary_window') 'secondary'
    foreach ($line in @($primary, $secondary)) {
        if ($line) { '{0} {1}' -f $Label, $line }
    }
    if (-not $primary -and -not $secondary) { '{0}: quota windows unavailable' -f $Label }
}

function Show-CodexAccountSummary {
    param([string]$Label, $Summary)
    Write-Output $Label
    if (-not $Summary.Ok) {
        Write-Output ('    Online account / quota: {0}' -f $Summary.Error)
        return
    }
    Write-Output ('    Online account: {0}' -f $Summary.OnlineName)
    $plan = ConvertTo-CodexDisplayText (Get-CodexField $Summary.Usage 'plan_type')
    if ($plan) { Write-Output ('    Plan: {0}' -f $plan) }
    $limit = Get-CodexField $Summary.Usage 'rate_limit'
    if ($null -eq $limit) { Write-Output '    Codex quota: unavailable' }
    else {
        Get-CodexQuotaLines $limit 'Codex' | ForEach-Object { Write-Output ('    ' + $_) }
        if ((Get-CodexField $limit 'limit_reached') -eq $true) { Write-Output '    Codex usage limit reached.' }
    }
    Get-CodexQuotaLines (Get-CodexField $Summary.Usage 'code_review_rate_limit') 'Code review' | ForEach-Object { Write-Output ('    ' + $_) }
    foreach ($additional in @(Get-CodexField $Summary.Usage 'additional_rate_limits')) {
        if ($null -eq $additional) { continue }
        $labelText = ConvertTo-CodexDisplayText (Get-CodexField $additional 'limit_name')
        if (-not $labelText) { $labelText = ConvertTo-CodexDisplayText (Get-CodexField $additional 'metered_feature') }
        if (-not $labelText) { $labelText = 'Additional quota' }
        Get-CodexQuotaLines (Get-CodexField $additional 'rate_limit') $labelText | ForEach-Object { Write-Output ('    ' + $_) }
    }
}

function Show-CodexOnlineAccounts {
    param([string]$Directory, [string]$Store, [int]$Timeout = 12)
    $cache = @{}
    Write-Output 'Fetching online account names and quotas (read-only)...'
    Write-Output 'Reset times use the local time zone. Local account names are unchanged.'
    Write-Output ''
    $summary = Get-CodexOnlineSummary -AuthPath (Join-Path $Directory 'auth.json') -Cache $cache -Timeout $Timeout
    Show-CodexAccountSummary -Label 'Current auth.json:' -Summary $summary
    Write-Output ''
    Write-Output 'Saved account folders:'
    if (-not (Test-Path -LiteralPath $Store -PathType Container)) { Write-Output '  (none)'; return }
    $folders = @(Get-ChildItem -LiteralPath $Store -Directory -ErrorAction Stop)
    $number = 0
    foreach ($folder in $folders) {
        $number++
        # Output the local name before making a potentially slow request.
        Write-Output ('  {0}. {1}' -f $number, (ConvertTo-CodexDisplayText $folder.Name))
        $summary = Get-CodexOnlineSummary -AuthPath (Join-Path $folder.FullName 'auth.json') -Cache $cache -Timeout $Timeout
        Show-CodexAccountSummary -Label '' -Summary $summary | Where-Object { $_ -ne '' }
    }
    if ($number -eq 0) { Write-Output '  (none)' }
}

# Dot-sourcing loads functions for tests without querying any accounts.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if (-not $AuthStore) { $AuthStore = Join-Path $CodexDir 'my_auth' }
        Show-CodexOnlineAccounts -Directory $CodexDir -Store $AuthStore -Timeout $TimeoutSeconds
    } catch {
        Write-Output 'Online listing failed. The original local account list is still available.'
        exit 1
    }
}
