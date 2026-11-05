<#
.SYNOPSIS
    Sunshine Headless起動ショートカットをデスクトップに作成する。
.DESCRIPTION
    Windows標準のWScript.Shell COMインターフェースをPowerShellから呼ぶ。
    VBSファイルは不要。ショートカットは本スクリプトと同じ場所の
    Launch-Sunshine-Headless.ps1を非表示で呼ぶ。
.PARAMETER ShortcutPath
    作成先の .lnk ファイル。省略するとユーザーのデスクトップへ作成する。
.PARAMETER ShowHelp
    詳細なヘルプを表示。-h / -help に対応。
.EXAMPLE
    .\Create-Sunshine-Shortcut.ps1
.EXAMPLE
    .\Create-Sunshine-Shortcut.ps1 -ShortcutPath 'D:\Sunshine Headless.lnk'
.EXAMPLE
    .\Create-Sunshine-Shortcut.ps1 -h
.NOTES
    Windows PowerShell 5.1。起動時にUACによる管理者権限の確認が必要。
#>
[CmdletBinding()]
param(
    [string]$ShortcutPath = '',
    [Alias('h', 'help')]
    [switch]$ShowHelp
)

#region HelpAndPreflight
if ($ShowHelp) {
    Get-Help -Name $PSCommandPath -Full
    return
}

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$sunshineExe = Join-Path -Path (Split-Path -Parent $scriptDirectory) -ChildPath 'Sunshine\sunshine.exe'
$launcherPs1 = Join-Path -Path $scriptDirectory -ChildPath 'Launch-Sunshine-Headless.ps1'
$powerShellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ([string]::IsNullOrWhiteSpace($ShortcutPath)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $ShortcutPath = Join-Path -Path $desktop -ChildPath 'Sunshine Headless.lnk'
}
foreach ($path in @($sunshineExe, $launcherPs1, $powerShellExe)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "必要なファイルが見つからぬ: $path"
    }
}
#endregion HelpAndPreflight

#region CreateShortcut
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut([IO.Path]::GetFullPath($ShortcutPath))
$link.TargetPath = $powerShellExe
$link.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcherPs1 + '"'
$link.WorkingDirectory = $scriptDirectory
$link.IconLocation = $sunshineExe + ',0'
$link.Description = 'Sunshine + Parsec VDD（必要なときだけ起動）'
$link.Save()
Write-Host "ショートカットを作成したぞ: $ShortcutPath"
#endregion CreateShortcut
