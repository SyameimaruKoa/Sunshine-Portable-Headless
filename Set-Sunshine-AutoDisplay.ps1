<#
.SYNOPSIS
    Sunshineの解像度とリフレッシュレートのクライアント追従を有効にする。
.DESCRIPTION
    ポータブル版Sunshineの設定ファイル内で、表示関連の3項目のみを変更する。
    Windowsのディスプレイ拡大率は変更しない。
.PARAMETER SunshineExe
    ポータブル版sunshine.exeのパス。既定はランチャーの親フォルダー。
.PARAMETER ConfigPath
    Sunshineが実際に使用する設定ファイルを指定する場合のパス。
.PARAMETER ShowHelp
    ヘルプを表示する。-h / -help を使用できる。
.EXAMPLE
    .\Set-Sunshine-AutoDisplay.ps1
.EXAMPLE
    .\Set-Sunshine-AutoDisplay.ps1 -ConfigPath 'D:\Sunshine\config\sunshine.conf'
.EXAMPLE
    .\Set-Sunshine-AutoDisplay.ps1 -h
#>
[CmdletBinding()]
param(
    [string]$SunshineExe = '',
    [string]$ConfigPath = '',
    [Alias('h', 'help')]
    [switch]$ShowHelp
)

#region HelpAndPaths
if ($ShowHelp) {
    Get-Help -Name $PSCommandPath -Full
    return
}
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SunshineExe)) {
    $SunshineExe = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'sunshine.exe'
}
if (-not (Test-Path -LiteralPath $SunshineExe -PathType Leaf)) {
    throw "sunshine.exe が見つからぬ: $SunshineExe"
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path (Split-Path -Parent ([IO.Path]::GetFullPath($SunshineExe))) -ChildPath 'config\sunshine.conf'
}
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$directory = Split-Path -Parent $ConfigPath
if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
#endregion HelpAndPaths

#region UpdateDisplayOptions
$exists = Test-Path -LiteralPath $ConfigPath -PathType Leaf
$bytes = if ($exists) { [IO.File]::ReadAllBytes($ConfigPath) } else { [byte[]]@() }
if ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 254 -and $bytes[1] -eq 255))) {
    throw 'sunshine.conf がUTF-16形式じゃ。元の文字コードを保つため変更せぬ。'
}
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
$encoding = [System.Text.UTF8Encoding]::new($hasBom, $true)
$offset = if ($hasBom) { 3 } else { 0 }
$content = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
$updated = $content
$newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
$hasTarget = [regex]::IsMatch($content, '(?mi)^\s*output_name\s*=\s*\{[0-9a-f\-]{36}\}\s*$')
$configurationMode = if ($hasTarget) { 'ensure_only_display' } else { 'ensure_active' }
if (-not $hasTarget) {
    Write-Warning 'output_nameにモニターGUIDが未設定のため、物理画面を無効化しないモードを使用する。'
}
$displayOptions = [ordered]@{
    dd_configuration_option = $configurationMode
    dd_resolution_option = 'auto'
    dd_refresh_rate_option = 'auto'
}
foreach ($entry in $displayOptions.GetEnumerator()) {
    $key = $entry.Key
    $value = $entry.Value
    $pattern = '(?mi)^(?<indent>[ \t]*)' + [regex]::Escape($key) + '(?<equal>[ \t]*=[ \t]*)[^\r\n]*'
    if ([regex]::IsMatch($updated, $pattern)) {
        $replacement = [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            $m.Groups['indent'].Value + $key + $m.Groups['equal'].Value + $value
        }
        $updated = [regex]::Replace($updated, $pattern, $replacement)
    }
    else {
        if ($updated.Length -gt 0 -and -not $updated.EndsWith("`n")) {
            $updated += $newline
        }
        $updated += "$key = $value$newline"
    }
}
if ($updated -cne $content) {
    if ($exists) {
        $backupPath = "$ConfigPath.bak"
        if (-not (Test-Path -LiteralPath $backupPath)) {
            [IO.File]::Copy($ConfigPath, $backupPath)
        }
    }
    $temporaryPath = "$ConfigPath.tmp.$PID"
    try {
        [IO.File]::WriteAllText($temporaryPath, $updated, $encoding)
        if ($exists) {
            # Windows PowerShell 5.1 may reject a null replacement backup path.
            # A unique temporary backup keeps the persistent .bak untouched.
            $replacementBackupPath = "$ConfigPath.replace-backup.$([Guid]::NewGuid().ToString('N'))"
            [IO.File]::Replace($temporaryPath, $ConfigPath, $replacementBackupPath)
            if (Test-Path -LiteralPath $replacementBackupPath -PathType Leaf) {
                Remove-Item -LiteralPath $replacementBackupPath -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            [IO.File]::Move($temporaryPath, $ConfigPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
    Write-Host "Sunshineの解像度・リフレッシュレート自動追従を設定したぞ: $ConfigPath"
}
#endregion UpdateDisplayOptions
