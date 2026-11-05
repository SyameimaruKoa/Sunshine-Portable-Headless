@echo off
chcp 932 >nul
rem Saved in Shift-JIS (CP932). Help is at the bottom of this file (:HELP).
setlocal EnableExtensions DisableDelayedExpansion

set "BASE=%~dp0"
set "PSBIN=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "CORE=%BASE%Start-Sunshine-ParsecVDD-v2.ps1"
set "WRAPPER=%BASE%Launch-Sunshine-Headless.ps1"
set "SUNSHINE=%BASE%..\sunshine.exe"
set "SHORTCUT=%BASE%Create-Sunshine-Shortcut.ps1"

if /I "%~1"=="-h" goto :HELP
if /I "%~1"=="--help" goto :HELP
if /I "%~1"=="--shortcut" goto :SHORTCUT
if /I "%~1"=="--debug" goto :DEBUG
if not "%~1"=="" goto :INVALID

call :CHECK
if errorlevel 1 exit /b 2

rem START detaches PowerShell; CMD returns immediately, so no batch Ctrl+C prompt.
start "" /D "%BASE%" "%PSBIN%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%WRAPPER%"
if errorlevel 1 (
    echo [ERROR] PowerShell を起動できなかったのじゃ。
    pause
    exit /b 1
)
exit /b 0

:DEBUG
call :CHECK
if errorlevel 1 exit /b 2
rem A separate PowerShell console for troubleshooting; CMD still exits immediately.
start "" /D "%BASE%" "%PSBIN%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CORE%"
if errorlevel 1 (
    echo [ERROR] PowerShell を起動できなかったのじゃ。
    pause
    exit /b 1
)
exit /b 0

:SHORTCUT
call :CHECK
if errorlevel 1 exit /b 2
if not exist "%SHORTCUT%" (
    echo [ERROR] Create-Sunshine-Shortcut.ps1 が見つからないのじゃ。
    pause
    exit /b 2
)
"%PSBIN%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SHORTCUT%"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%

:CHECK
if not exist "%PSBIN%" (
    echo [ERROR] Windows PowerShell が見つからないのじゃ。
    pause
    exit /b 2
)
if not exist "%SUNSHINE%" (
    echo [ERROR] sunshine.exe が見つからないのじゃ。
    echo Sunshine-Portable-Headless と同じ階層に Sunshine フォルダーを置くのじゃ。
    pause
    exit /b 2
)
if not exist "%CORE%" (
    echo [ERROR] Start-Sunshine-ParsecVDD-v2.ps1 が見つからないのじゃ。
    pause
    exit /b 2
)
if not exist "%WRAPPER%" (
    echo [ERROR] Launch-Sunshine-Headless.ps1 が見つからないのじゃ。
    pause
    exit /b 2
)
exit /b 0

:INVALID
echo [ERROR] 未対応の引数: %~1
echo.
goto :HELP_ERROR

:HELP
echo.
echo Sunshine + Parsec VDD ポータブル起動
echo.
echo 使用方法:
echo     Sunshine-Headless.cmd              通常起動（ウィンドウ非表示）
echo     Sunshine-Headless.cmd --debug      別のPowerShell画面で起動
echo     Sunshine-Headless.cmd --shortcut   デスクトップにショートカット作成
echo     Sunshine-Headless.cmd -h          ヘルプ表示
echo     Sunshine-Headless.cmd --help      ヘルプ表示
echo.
echo 配置: Sunshine\sunshine.exe と Sunshine-Portable-Headless\本CMD一式を
echo       同じ親フォルダーへ配置するのじゃ。
echo       Parsec Virtual Display Adapter は事前にインストールすること。
echo.
echo 起動時に管理者権限のUAC確認が表示される。
echo Sunshineをトレイメニューから通常終了すると仮想モニターも削除する。
echo CMDは起動後すぐに閉じるので、バッチ終了の確認は表示されない。
exit /b 0

:HELP_ERROR
echo ヘルプを表示するには -h または --help を指定するのじゃ。
exit /b 2
