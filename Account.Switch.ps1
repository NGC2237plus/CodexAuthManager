# Local file switching only. No network calls, token refresh or process termination.
function Assert-AccountName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 120 -or
        $Name -match '[<>:"/\\|?*\x00-\x1f]' -or $Name.EndsWith('.') -or $Name.EndsWith(' ') -or
        $Name -match '^(\.|\.\.|CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') {
        throw '账户名称无效：请使用普通文件夹名称，不含路径、保留名称或末尾空格。'
    }
}

function Assert-NoAccountLink([string]$Path) {
    $check = [IO.Path]::GetFullPath($Path)
    while ($check) {
        if (Test-Path -LiteralPath $check) {
            if ((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw '账户路径包含链接或重定向目录，已停止切换。'
            }
        }
        $check = [IO.Path]::GetDirectoryName($check)
    }
}

function Get-AccountFingerprint([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return 'missing' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Write-AccountAtomic([string]$Path, [byte[]]$Bytes) {
    $temp = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.auth-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp,$Path) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}


. (Join-Path $PSScriptRoot 'Account.Store.ps1')
