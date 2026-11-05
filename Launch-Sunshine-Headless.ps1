<#
.SYNOPSIS
    コンソールを表示したままSunshine + Parsec VDDを起動し、ログを残す。
.DESCRIPTION
    同じフォルダーの既存 Start-Sunshine-ParsecVDD-v2.ps1 を管理者権限で呼び出す。
    SunshineとVDDの制御ロジックは変更しない。スクリプト自体は
    Sunshine終了まで待機し、終了後は通常どおり自動終了する。
.PARAMETER ShowHelp
    詳細なヘルプを表示する。-h / -help に対応する。
.EXAMPLE
    .\Launch-Sunshine-Headless.ps1
.EXAMPLE
    .\Launch-Sunshine-Headless.ps1 -h
.NOTES
    Windows PowerShell 5.1、UTF-8 BOM。ログは Sunshine-Headless.log。
#>
[CmdletBinding()]
param(
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
$controllerPath = Join-Path -Path $scriptDirectory -ChildPath 'Start-Sunshine-ParsecVDD-v2.ps1'
$logPath = Join-Path -Path $scriptDirectory -ChildPath 'Sunshine-Headless.log'
$transcriptStarted = $false
#endregion HelpAndPreflight

#region RunAndLog
try {
    if (-not (Test-Path -LiteralPath $controllerPath -PathType Leaf)) {
        throw "制御スクリプトが見つからぬ: $controllerPath"
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $powerShellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        Start-Process -FilePath $powerShellExe -ArgumentList $arguments -Verb RunAs -ErrorAction Stop | Out-Null
        return
    }

    Start-Transcript -LiteralPath $logPath -Append -ErrorAction Stop | Out-Null
    $transcriptStarted = $true
    & $controllerPath
}
catch {
    $errorText = "Sunshine起動に失敗したのじゃ: $($_ | Out-String)"
    if ($transcriptStarted) {
        Write-Host $errorText
    }
    else {
        $errorText | Out-File -LiteralPath $logPath -Encoding utf8 -Append
    }
    exit 1
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    }
}
#endregion RunAndLog
