<#
.SYNOPSIS
    Parsec VDD の仮想モニターと Sunshine ポータブル版を一緒に起動する。
.DESCRIPTION
    Windows のログイン中ユーザーとして Parsec VDD の仮想ディスプレイを1台追加し、
    VDDの維持信号を送信しながら Sunshine を起動する。
    Sunshine が終了したら仮想ディスプレイを削除し、補助プロセスを残さない。
    Sunshine の既存設定やサービス、電源プラン等は変更しない。
.PARAMETER SunshineExe
    実行する sunshine.exe。既定はランチャーの親フォルダーにある sunshine.exe。
.PARAMETER ConfigPath
    既存の sunshine.conf を明示的に指定する場合に使用する。
    省略した場合は Sunshine 本来の設定場所を使用する。
.PARAMETER StartupDelaySeconds
    仮想モニターの作成後、Sunshine 起動までに待機する秒数。既定は 2 秒。
.PARAMETER ShowHelp
    使用方法を表示する。-h / -Help に対応。
.EXAMPLE
    .\Start-Sunshine-ParsecVDD.ps1
.EXAMPLE
    .\Start-Sunshine-ParsecVDD.ps1 -ConfigPath 'C:\Users\User\AppData\Local\Sunshine\config\sunshine.conf'
.EXAMPLE
    .\Start-Sunshine-ParsecVDD.ps1 -h
.NOTES
    Windows PowerShell 5.1 / Windows 11 x64 / Parsec VDD 0.45 を想定。
    仮想モニターを毎回削除するため、最初の一度だけSunshine側で
    Parsec仮想ディスプレイの device_id を設定する必要がある。
    Windows実機での動作試験は未実施。
#>
[CmdletBinding()]
param(
    [string]$SunshineExe = '',
    [string]$ConfigPath = '',
    [ValidateRange(0, 30)]
    [int]$StartupDelaySeconds = 2,
    [Alias('h', 'help')]
    [switch]$ShowHelp
)

#region HelpAndPreflight
if ($ShowHelp) {
    Get-Help -Name $PSCommandPath -Full
    return
}

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SunshineExe)) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
        throw 'スクリプトの保存先フォルダーを取得できぬ。-File で実行するのじゃ。'
    }
    $SunshineExe = Join-Path -Path (Split-Path -Parent $scriptDirectory) -ChildPath 'sunshine.exe'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $powerShellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -StartupDelaySeconds ' + $StartupDelaySeconds
    if (-not [string]::IsNullOrWhiteSpace($SunshineExe)) {
        $arguments += ' -SunshineExe "' + $SunshineExe + '"'
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $arguments += ' -ConfigPath "' + $ConfigPath + '"'
    }
    Write-Host 'SunshineとVDDを管理者権限で起動し直すのじゃ。'
    $elevated = Start-Process -FilePath $powerShellExe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    exit $elevated.ExitCode
}
if (-not [Environment]::Is64BitProcess) {
    throw '64ビットの Windows PowerShell で実行する必要があるのじゃ。'
}
$SunshineExe = [IO.Path]::GetFullPath($SunshineExe)
if (-not (Test-Path -LiteralPath $SunshineExe -PathType Leaf)) {
    throw "Sunshine本体が見つからぬ: $SunshineExe"
}
if ($ConfigPath -and -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "指定した設定ファイルが見つからぬ: $ConfigPath"
}
if (Get-Process -Name 'sunshine' -ErrorAction SilentlyContinue) {
    throw 'Sunshineが既に起動しておる。二重起動を避けるため終了してから実行するのじゃ。'
}

$adapter = Get-PnpDevice -Class Display -ErrorAction Stop |
    Where-Object {
        ($_.FriendlyName -eq 'Parsec Virtual Display Adapter' -or $_.InstanceId -like 'ROOT\PARSEC\VDA*') -and
        $_.Status -eq 'OK'
    }
if (-not $adapter) {
    throw '正常な Parsec Virtual Display Adapter が見つからぬ。'
}
#endregion HelpAndPreflight

#region VddInterop
# 公式 nomi-san/parsec-vdd の core/parsec-vdd.h のIOCTL実装をもとにした
# PowerShellから直接利用するための小さなC#ラッパー。
$interopSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

public static class PortableParsecVdd
{
    private const uint DIGCF_PRESENT = 0x2;
    private const uint DIGCF_DEVICEINTERFACE = 0x10;
    private const uint IOCTL_ADD = 0x0022e004;
    private const uint IOCTL_REMOVE = 0x0022a008;
    private const uint IOCTL_UPDATE = 0x0022a00c;
    private const int ERROR_IO_PENDING = 997;
    private static readonly Guid InterfaceGuid = new Guid("00b41627-04c4-429e-a26e-0265cf50c8fa");
    private static readonly object IoLock = new object();
    private static IntPtr device = IntPtr.Zero;
    private static Thread pingThread;
    private static volatile bool keepRunning;
    private static int displayIndex = -1;
    private static volatile string pingError;

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVICE_INTERFACE_DATA
    {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeOverlapped
    {
        public IntPtr Internal;
        public IntPtr InternalHigh;
        public uint Offset;
        public uint OffsetHigh;
        public IntPtr EventHandle;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid guid, IntPtr enumerator,
        IntPtr parent, uint flags);
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(IntPtr info, IntPtr deviceInfo,
        ref Guid guid, uint index, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", EntryPoint = "SetupDiGetDeviceInterfaceDetailW", SetLastError = true)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr info,
        ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, uint size,
        out uint required, IntPtr deviceInfo);
    [DllImport("setupapi.dll")]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr info);
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string name, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(IntPtr handle, uint code, IntPtr input, uint inputSize,
        IntPtr output, uint outputSize, IntPtr transferred, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetOverlappedResultEx(IntPtr handle, IntPtr overlapped,
        out uint transferred, uint milliseconds, bool alertable);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CancelIoEx(IntPtr handle, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetOverlappedResult(IntPtr handle, IntPtr overlapped,
        out uint transferred, bool wait);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateEvent(IntPtr attributes, bool manualReset,
        bool initialState, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DisplayDevice
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", EntryPoint = "EnumDisplayDevicesW", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplayDevices(string deviceName, uint index,
        ref DisplayDevice device, uint flags);

    public static bool IsDisplayActive()
    {
        for (uint i = 0; i < 64; i++)
        {
            DisplayDevice adapter = new DisplayDevice();
            adapter.cb = Marshal.SizeOf(typeof(DisplayDevice));
            if (!EnumDisplayDevices(null, i, ref adapter, 0))
                break;
            for (uint j = 0; j < 32; j++)
            {
                DisplayDevice monitor = new DisplayDevice();
                monitor.cb = Marshal.SizeOf(typeof(DisplayDevice));
                if (!EnumDisplayDevices(adapter.DeviceName, j, ref monitor, 1))
                    break;
                bool isParsec = (!String.IsNullOrEmpty(monitor.DeviceID) &&
                    monitor.DeviceID.IndexOf("PSCCDD0", StringComparison.OrdinalIgnoreCase) >= 0) ||
                    String.Equals(monitor.DeviceString, "ParsecVDA", StringComparison.OrdinalIgnoreCase);
                if (isParsec && (monitor.StateFlags & 1) != 0 && (adapter.StateFlags & 1) != 0)
                    return true;
            }
        }
        return false;
    }

    private static IntPtr OpenDevice()
    {
        Guid guid = InterfaceGuid;
        IntPtr info = SetupDiGetClassDevs(ref guid, IntPtr.Zero, IntPtr.Zero,
            DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (info == new IntPtr(-1))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "VDDを列挙できない");
        }
        try
        {
            SP_DEVICE_INTERFACE_DATA data = new SP_DEVICE_INTERFACE_DATA();
            data.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
            if (!SetupDiEnumDeviceInterfaces(info, IntPtr.Zero, ref guid, 0, ref data))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "VDDインターフェースが存在しない");
            }
            uint required;
            SetupDiGetDeviceInterfaceDetail(info, ref data, IntPtr.Zero, 0,
                out required, IntPtr.Zero);
            if (required < 8)
            {
                throw new InvalidOperationException("デバイスパスのサイズが取得できない");
            }
            IntPtr detail = Marshal.AllocHGlobal((int)required);
            try
            {
                Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                if (!SetupDiGetDeviceInterfaceDetail(info, ref data, detail, required,
                    out required, IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "VDDデバイスパス取得に失敗");
                }
                string path = Marshal.PtrToStringUni(IntPtr.Add(detail, 4));
                IntPtr handle = CreateFile(path, 0xC0000000, 3,
                    IntPtr.Zero, 3, 0x60000080, IntPtr.Zero);
                if (handle == new IntPtr(-1) || handle == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "VDDデバイスを開けない");
                }
                return handle;
            }
            finally
            {
                Marshal.FreeHGlobal(detail);
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(info);
        }
    }

    private static uint Ioctl(uint code, byte[] data)
    {
        lock (IoLock)
        {
            IntPtr input = Marshal.AllocHGlobal(32);
            IntPtr output = Marshal.AllocHGlobal(4);
            IntPtr evt = IntPtr.Zero;
            IntPtr ovPtr = IntPtr.Zero;
            try
            {
                for (int i = 0; i < 32; i++)
                {
                    Marshal.WriteByte(input, i, 0);
                }
                if (data != null)
                {
                    Marshal.Copy(data, 0, input, Math.Min(data.Length, 32));
                }
                Marshal.WriteInt32(output, 0);
                evt = CreateEvent(IntPtr.Zero, true, false, null);
                if (evt == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Event生成に失敗");
                }
                NativeOverlapped overlapped = new NativeOverlapped();
                overlapped.EventHandle = evt;
                ovPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(NativeOverlapped)));
                Marshal.StructureToPtr(overlapped, ovPtr, false);
                // ParsecDisplayと同じく、同期戻り値ではなくOVERLAPPEDの完了結果を確認する。
                DeviceIoControl(device, code, input, 32,
                    output, 4, IntPtr.Zero, ovPtr);
                uint transferred;
                uint timeout = code == IOCTL_ADD ? 5000u : 1000u;
                if (!GetOverlappedResultEx(device, ovPtr, out transferred, timeout, false))
                {
                    int error = Marshal.GetLastWin32Error();
                    // 未完了のI/Oが解放済みメモリへ書き込まないよう完了まで待つ。
                    CancelIoEx(device, ovPtr);
                    uint cancelledBytes;
                    GetOverlappedResult(device, ovPtr, out cancelledBytes, true);
                    throw new Win32Exception(error, "VDD IOCTL応答待ちに失敗");
                }
                return unchecked((uint)Marshal.ReadInt32(output));
            }
            finally
            {
                if (evt != IntPtr.Zero)
                {
                    CloseHandle(evt);
                }
                if (ovPtr != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(ovPtr);
                }
                Marshal.FreeHGlobal(input);
                Marshal.FreeHGlobal(output);
            }
        }
    }

    public static int Start()
    {
        if (device != IntPtr.Zero)
        {
            throw new InvalidOperationException("VDDはすでに起動中");
        }
        device = OpenDevice();
        try
        {
            // ParsecDisplayの接続順序と同じく、ADD前にUPDATEでセッションを初期化する。
            Ioctl(IOCTL_UPDATE, null);
            uint index = Ioctl(IOCTL_ADD, null);
            if (index > 15)
            {
                throw new InvalidOperationException("仮想ディスプレイの生成が失敗: " + index);
            }
            displayIndex = (int)index;
            Ioctl(IOCTL_UPDATE, null);
            keepRunning = true;
            pingError = null;
            pingThread = new Thread(PingLoop);
            pingThread.IsBackground = true;
            pingThread.Name = "Parsec VDD keepalive";
            pingThread.Start();
            return displayIndex;
        }
        catch
        {
            Stop();
            throw;
        }
    }

    private static void PingLoop()
    {
        while (keepRunning)
        {
            try
            {
                Ioctl(IOCTL_UPDATE, null);
            }
            catch (Exception ex)
            {
                pingError = ex.ToString();
                keepRunning = false;
                break;
            }
            Thread.Sleep(50);
        }
    }

    public static string GetPingError()
    {
        return pingError;
    }

    public static void Stop()
    {
        keepRunning = false;
        if (pingThread != null)
        {
            if (!pingThread.Join(12000))
                throw new InvalidOperationException("VDD維持スレッドが終了しないためデバイスを閉じられない");
            pingThread = null;
        }
        if (device != IntPtr.Zero)
        {
            try
            {
                if (displayIndex >= 0)
                {
                    byte[] indexBytes = new byte[2];
                    indexBytes[1] = (byte)displayIndex;
                    Ioctl(IOCTL_REMOVE, indexBytes);
                    Ioctl(IOCTL_UPDATE, null);
                }
            }
            finally
            {
                CloseHandle(device);
                device = IntPtr.Zero;
                displayIndex = -1;
            }
        }
    }
}
'@
#endregion VddInterop

#region SunshineLifecycle
$vddStarted = $false
function Start-VerifiedVdd {
    param([ValidateRange(1, 10)][int]$Attempts = 3)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $index = [PortableParsecVdd]::Start()
            $script:vddStarted = $true
            $ready = $false
            for ($probe = 0; $probe -lt 20; $probe++) {
                if ([PortableParsecVdd]::GetPingError()) {
                    throw "VDD維持信号に失敗: $([PortableParsecVdd]::GetPingError())"
                }
                if ([PortableParsecVdd]::IsDisplayActive()) {
                    $ready = $true
                    break
                }
                Start-Sleep -Milliseconds 500
            }
            if (-not $ready) {
                throw '仮想モニターが10秒以内にWindowsのアクティブな画面として認識されなかった'
            }
            Write-Host "Parsec仮想ディスプレイの認識を確認したぞ。Index=$index"
            return
        }
        catch {
            Write-Warning "Parsec VDDの初期化に失敗 ($attempt/$Attempts): $_"
            if ($script:vddStarted) {
                try {
                    [PortableParsecVdd]::Stop()
                }
                catch {
                    Write-Warning "VDDの後処理に失敗: $_"
                }
                finally {
                    $script:vddStarted = $false
                }
            }
            if ($attempt -eq $Attempts) {
                throw
            }
            Start-Sleep -Seconds 2
        }
    }
}
try {
    Add-Type -TypeDefinition $interopSource -Language CSharp -ReferencedAssemblies @('System.dll')
    Start-VerifiedVdd
    $displaySettingsScript = Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -ChildPath 'Set-Sunshine-AutoDisplay.ps1'
    if (-not (Test-Path -LiteralPath $displaySettingsScript -PathType Leaf)) {
        throw "Sunshineの画面設定スクリプトが見つからぬ: $displaySettingsScript"
    }
    & $displaySettingsScript -SunshineExe $SunshineExe -ConfigPath $ConfigPath

    # Read scaling policy once. keep never calls the undocumented DPI APIs.
    $headlessSettings = Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -ChildPath 'HeadlessSettings.json'
    $dpiMode = 'keep'
    if (Test-Path -LiteralPath $headlessSettings -PathType Leaf) {
        $options = Get-Content -LiteralPath $headlessSettings -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $options.dpiScaling) {
            $dpiMode = [string]$options.dpiScaling
        }
    }
    if ($dpiMode -cnotin @('keep', '100')) {
        throw "dpiScalingはkeepまたは100を指定するのじゃ: $dpiMode"
    }
    if ($dpiMode -eq '100') {
        $dpiScript = Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -ChildPath 'Set-Sunshine-DpiScaling.ps1'
        if (-not (Test-Path -LiteralPath $dpiScript -PathType Leaf)) {
            throw "拡大率制御スクリプトが見つからぬ: $dpiScript"
        }
    }

    if ($StartupDelaySeconds -gt 0) {
        Start-Sleep -Seconds $StartupDelaySeconds
    }

    $launchOptions = @{
        FilePath = $SunshineExe
        WorkingDirectory = (Split-Path -Parent $SunshineExe)
        PassThru = $true
        NoNewWindow = $true
    }
    if ($ConfigPath) {
        $launchOptions['ArgumentList'] = ('"' + [IO.Path]::GetFullPath($ConfigPath) + '"')
    }

    # Apply to the virtual monitor before starting Sunshine.
    $lastDpiResult = ''
    if ($dpiMode -eq '100') {
        try {
            $lastDpiResult = [string](& $dpiScript -Mode '100')
            if ($lastDpiResult -eq 'not-found') {
                Write-Warning 'Parsec仮想ディスプレイがまだ有効になっていない。Sunshine起動後に再確認する。'
            }
            elseif ($lastDpiResult -eq 'changed-to-100') {
                Write-Host 'Parsec仮想ディスプレイの拡大率を100%にしたぞ。'
            }
        }
        catch {
            Write-Warning "拡大率100%への切り替えに失敗: $_"
        }
    }

    Write-Host "Sunshineを起動するのじゃ: $SunshineExe"
    $sunshine = Start-Process @launchOptions
    try {
        # Sunshine稼働中もVDDの監視を継続する。DPI設定がkeepでも復旧する。
        $missingChecks = 0
        while (-not $sunshine.WaitForExit(3000)) {
            $pingError = [PortableParsecVdd]::GetPingError()
            if ([PortableParsecVdd]::IsDisplayActive()) {
                $missingChecks = 0
            }
            else {
                $missingChecks++
            }
            if ($pingError -or $missingChecks -ge 2) {
                Write-Warning "Parsec VDDの切断を検知。PingError=$pingError MissingChecks=$missingChecks"
                if ($vddStarted) {
                    try {
                        [PortableParsecVdd]::Stop()
                    }
                    catch {
                        Write-Warning "VDD終了処理に失敗: $_"
                    }
                    $vddStarted = $false
                }
                try {
                    Start-VerifiedVdd
                    Write-Warning 'Parsec仮想ディスプレイを再生成した。Sunshineの画面再認識が必要な場合は再接続するのじゃ。'
                }
                catch {
                    Write-Warning "Parsec仮想ディスプレイの再生成に失敗: $_"
                }
                $missingChecks = 0
            }
            if ($dpiMode -eq '100') {
                try {
                    $dpiResult = [string](& $dpiScript -Mode '100')
                    if ($dpiResult -eq 'changed-to-100') {
                        Write-Host 'Parsec仮想ディスプレイの拡大率を100%に再設定したぞ。'
                    }
                    elseif ($dpiResult -eq 'not-found' -and $lastDpiResult -ne 'not-found') {
                        Write-Warning 'Parsec仮想ディスプレイが見つからぬ。次回再確認する。'
                    }
                    $lastDpiResult = $dpiResult
                }
                catch {
                    $message = [string]$_
                    if ($lastDpiResult -ne $message) {
                        Write-Warning "拡大率100%の維持に失敗: $message"
                    }
                    $lastDpiResult = $message
                }
            }
        }
        $sunshine.Refresh()
        Write-Host "Sunshine終了コード: $($sunshine.ExitCode)"
        if ([PortableParsecVdd]::GetPingError()) {
            Write-Warning "VDD維持信号の処理中にエラーが発生: $([PortableParsecVdd]::GetPingError())"
        }
    }
    finally {
        $sunshine.Dispose()
    }
}
finally {
    if ($vddStarted) {
        Write-Host 'Parsec仮想ディスプレイを削除するのじゃ。'
        try {
            [PortableParsecVdd]::Stop()
        }
        catch {
            Write-Warning "VDD終了時の後処理に失敗: $_"
        }
    }
}
#endregion SunshineLifecycle
