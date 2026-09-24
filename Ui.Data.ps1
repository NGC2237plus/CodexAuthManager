# Presentation-only objects. Never return tokens, raw auth JSON or HTTP bodies.
. (Join-Path $PSScriptRoot 'Account.Identity.ps1')
if (-not ('LocalCodex.QuotaView' -as [type])) {
    Add-Type -TypeDefinition @'
namespace LocalCodex {
    public sealed class QuotaView {
        public string Label { get; set; }
        public double Remaining { get; set; }
        public string Percent { get; set; }
        public string Color { get; set; }
        public string Reset { get; set; }
    }
}
'@
}

function New-AccountRow {
    param([string]$Name, [bool]$IsCurrent = $false)
    [pscustomobject]@{
        LocalName = $Name; IsCurrent = $IsCurrent
        SwitchVisibility = $(if ($IsCurrent) { 'Collapsed' } else { 'Visible' })
        CurrentVisibility = $(if ($IsCurrent) { 'Visible' } else { 'Collapsed' })
        Kind = $(if ($IsCurrent) { '当前认证文件' } else { '本地保存的账户' })
        Email = '等待联网查询'; Plan = ''; Status = '等待查询'
        VerifiedEmail = ''; SourceFingerprint = ''
        StatusColor = '#64748B'; Message = ''; Quotas = @()
        EmptyVisibility = 'Visible'; DetailVisibility = 'Collapsed'
        CardColor = $(if ($IsCurrent) { '#EFF8F6' } else { '#FFFFFF' })
        BorderColor = $(if ($IsCurrent) { '#A7D9CA' } else { '#E3E8EF' })
    }
}

function ConvertTo-QuotaView {
    param($Window, [string]$Label)
    if ($null -eq $Window) { return }
    $rawSeconds = Get-CodexField $Window 'limit_window_seconds'
    $seconds = 0.0
    $duration = '额度窗口'
    if ($null -ne $rawSeconds -and [double]::TryParse([string]$rawSeconds,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$seconds) -and $seconds -gt 0 -and -not [double]::IsInfinity($seconds)) {
        if ([double]$seconds % 86400 -eq 0) { $duration = ('{0} 天' -f ([double]$seconds / 86400)) }
        elseif ([double]$seconds % 3600 -eq 0) { $duration = ('{0} 小时' -f ([double]$seconds / 3600)) }
        else { $duration = ('{0:0.#} 分钟' -f ([double]$seconds / 60)) }
    }
    $used = Get-CodexField $Window 'used_percent'
    $value = 0.0
    $number = 0.0
    $hasValue = $null -ne $used -and [double]::TryParse([string]$used,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -and -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
    $percent = '未返回额度'
    $color = '#CBD5E1'
    if ($hasValue) {
        $value = [Math]::Max(0,[Math]::Min(100,100-$number))
        $percent = '{0:0.#}% 剩余' -f $value
        $color = if ($value -le 10) { '#D15353' } elseif ($value -le 25) { '#C58B27' } else { '#16866B' }
    }
    $reset = '重置时间未返回'
    try {
        $stamp = Get-CodexField $Window 'reset_at'
        if ($null -ne $stamp -and [double]$stamp -gt 0) {
            $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01',[DateTimeKind]::Utc)
            $reset = $epoch.AddSeconds([double]$stamp).ToLocalTime().ToString('MM-dd HH:mm') + ' 重置'
        }
    } catch { }
    [LocalCodex.QuotaView]@{ Label = ($Label + ' · ' + $duration); Remaining = $value; Percent = $percent; Color = $color; Reset = $reset }
}

function ConvertTo-AccountRow {
    param($Summary, [string]$Name, [bool]$IsCurrent = $false)
    $row = New-AccountRow $Name $IsCurrent
    if (-not $Summary.Ok) {
        $row.Email = '联网信息暂不可用'
        $row.Status = '查询失败'; $row.StatusColor = '#C58B27'
        switch -Regex ($Summary.Error) {
            '401' { $row.Status='登录失效'; $row.StatusColor='#D15353'; $row.Message='请通过右上角登录新账号，完成登录后保存。'; break }
            '403' { $row.Message='访问被拒绝（403），请检查账户权限或网络。'; break }
            '429' { $row.Message='请求较频繁（429），请稍后刷新。'; break }
            'No auth.json' { $row.Status='没有凭据'; $row.Message='该目录中没有 auth.json。'; break }
            'not valid JSON' { $row.Status='文件异常'; $row.Message='认证文件无法读取或格式不正确。'; break }
            'No ChatGPT' { $row.Status='不支持查询'; $row.Message='此凭据没有 ChatGPT 登录令牌，无法获取订阅额度。'; break }
            'Unexpected' { $row.Message='用量接口格式发生变化，暂时无法显示额度。'; break }
            default { $row.Message='网络或服务暂不可用，请检查连接后刷新。' }
        }
        $row.DetailVisibility = 'Visible'
        return $row
    }
    $row.Email = $Summary.OnlineName
    $row.Plan = ConvertTo-CodexDisplayText (Get-CodexField $Summary.Usage 'plan_type')
    $row.Status = '已更新'; $row.StatusColor = '#16866B'
    $windows = New-Object 'System.Collections.Generic.List[object]'
    $main = Get-CodexField $Summary.Usage 'rate_limit'
    foreach ($field in @('primary_window','secondary_window')) {
        $view = ConvertTo-QuotaView (Get-CodexField $main $field) 'Codex'
        if ($null -ne $view) { $windows.Add($view) }
    }
    $review = Get-CodexField $Summary.Usage 'code_review_rate_limit'
    foreach ($field in @('primary_window','secondary_window')) {
        $view = ConvertTo-QuotaView (Get-CodexField $review $field) '代码审查'
        if ($null -ne $view) { $windows.Add($view) }
    }
    foreach ($extra in @(Get-CodexField $Summary.Usage 'additional_rate_limits')) {
        if ($null -eq $extra) { continue }
        $label = ConvertTo-CodexDisplayText (Get-CodexField $extra 'limit_name')
        if (-not $label) { $label = ConvertTo-CodexDisplayText (Get-CodexField $extra 'metered_feature') }
        if (-not $label) { $label = '附加额度' }
        foreach ($field in @('primary_window','secondary_window')) {
            $view = ConvertTo-QuotaView (Get-CodexField (Get-CodexField $extra 'rate_limit') $field) $label
            if ($null -ne $view) { $windows.Add($view) }
        }
    }
    $row.Quotas = @($windows.ToArray())
    if ($windows.Count -gt 0) { $row.EmptyVisibility = 'Collapsed' }
    else { $row.Message='服务端未返回额度窗口。'; $row.DetailVisibility='Visible' }
    if ((Get-CodexField $main 'limit_reached') -eq $true) {
        $row.Status='额度已用尽'; $row.StatusColor='#D15353'
    }
    return $row
}

function Get-AccountEntries {
    param([string]$Directory)
    $inventory=Get-AccountInventory $Directory
    $inventory.Current
    $inventory.Others
}
