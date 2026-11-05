# Sunshine + Parsec VDD Portable Launcher

**Windowsでポータブル版Sunshineを使うときだけ起動し、Parsec VDDの仮想モニターを生成・維持・削除するランチャー。**

サービス登録、VBS、ParsecDisplayアプリの常駐は不要。Sunshineはログイン中ユーザーの管理者権限で起動する（起動時UAC確認）。

## 動作

1. ランチャーがPowerShellを独立プロセスとして起動し、CMDはすぐ終了する。
2. ランチャーを管理者権限に昇格し、Parsec VDDを起動する。ドライバー制御で画面を追加し、Windowsが仮想画面を認識したことを確認する（失敗時は最大3回再試行）。
3. 管理者権限でポータブル版 `sunshine.exe` を起動する。Sunshine稼働中も仮想画面と維持信号を監視し、切断時には再生成を試みる。
4. Sunshineを正常終了すると、仮想モニターを削除する。PowerShellも終了する。

**Ctrl+Cや「バッチ ジョブを終了しますか？」は通常の起動・終了では不要。** Sunshineのトレイアイコンから終了すること。

## 必要環境

- Windows 10/11 x64、Windows PowerShell 5.1
- ポータブル版 [Sunshine](https://github.com/LizardByte/Sunshine/releases)（`sunshine.exe` を直接起動する方式）
- [Parsec Virtual Display Driver](https://github.com/nomi-san/parsec-vdd) が **setup.exeでインストール済み**、デバイスマネージャーの `Parsec Virtual Display Adapter` が正常
- **Windowsにサインインしたセッション**（ログイン画面からの完全無人起動には非対応）

**ParsecDisplay GUI、VDDのCLI、Sunshineサービスの導入は不要**。本ランチャーはParsec VDDのドライバーに直接IOCTLを送る。

## インストール

本リポジトリを `Sunshine` フォルダーと同じ階層に置く。**Sunshine本体とランチャーは別フォルダー**でよい。

```text
親フォルダー/
    Sunshine/
        sunshine.exe                       (別途用意)
        config/
            sunshine.conf
    Sunshine-Portable-Headless/
        Sunshine-Headless.cmd
        Launch-Sunshine-Headless.ps1
        Create-Sunshine-Shortcut.ps1
        Start-Sunshine-ParsecVDD-v2.ps1
        Set-Sunshine-AutoDisplay.ps1
        Set-Sunshine-DpiScaling.ps1
        HeadlessSettings.json
```

パスはランチャーの場所から `..\Sunshine\sunshine.exe` として解決する。設定ファイルはSunshine本体側の `config\sunshine.conf` に作成・更新される。

**`apps.json`、MPO、Game DVR、電源プランには触れない。** `sunshine.conf` では表示関連の3項目のみ自動追従用に設定する。 `sunshine-vdd` のサービス用インストーラーとは別実装。

### ワンクリック起動

**`Sunshine-Headless.cmd` をダブルクリック**する。UACが表示されるので許可する。CMDは即終了し、SunshineとParsec仮想モニターは利用中だけ稼働する。

### デスクトップショートカット（任意）

一度だけ `Sunshine-Headless.cmd --shortcut` を実行する。作られた「Sunshine Headless」のショートカットは**PowerShellに直接リンクする**ため、起動時にCMDやVBSを経由しない。管理者権限への昇格はPowerShellランチャーが行う。

> インストール先を移動した場合は、ショートカットを作り直すこと。

## 終了

Sunshineのトレイアイコンから通常終了する。制御スクリプトが終了を検知し、`finally` でVDDの仮想モニターを削除する。**VDDのドライバー本体はインストールされたまま**。

Parsec VDDは維持信号が約1秒停止すると仮想モニターを削除する。稼働中は3秒周期で画面を確認し、維持信号の異常または画面の連続消失時に再生成する。再生成後のSunshineキャプチャ復帰は環境依存なので、必要ならMoonlightを再接続する。

## コマンドとヘルプ

```bat
Sunshine-Headless.cmd
Sunshine-Headless.cmd --debug
Sunshine-Headless.cmd --shortcut
Sunshine-Headless.cmd -h
Sunshine-Headless.cmd --help
```

`--debug` は独立したPowerShellウィンドウで起動し、エラーを表示する。必要なら管理者権限のPowerShellを追加起動する。バッチ自体は待機しない。PS1単体にも `-h` があり、コメントベースの `Get-Help` に対応する。

通常起動時のログは `Sunshine-Headless.log`。コンソール非表示で失敗したらまずログを確認する。

## Sunshineの画面設定

### Moonlightの解像度・FPSに自動追従

ランチャーはSunshine起動前に `Set-Sunshine-AutoDisplay.ps1` を実行し、`config/sunshine.conf` 内の表示関連3項目のみを設定する。

```ini
dd_configuration_option = ensure_only_display
dd_resolution_option = auto
dd_refresh_rate_option = auto
```

- **解像度**：Moonlightで要求した解像度に変更する。
- **リフレッシュレート**：Moonlightで要求したFPSに変更する（ドライバーが対応する表示モードのみ）。
- **拡大率（WindowsのDPIスケール）**：`HeadlessSettings.json` の `dpiScaling` で `keep`（Windows設定を維持）または `100`（Parsec VDD仮想モニターのみ100%に固定）を選択する。Sunshine本体にはDPI拡大率の自動制御機能はない。
- Moonlight側の **Optimize game settings（ゲーム設定を最適化）** を有効にする。解像度の自動変更に必要。

### 拡大率100%固定（任意）

`HeadlessSettings.json` の値だけを変更する。通常は既定の `keep` を使用する。

```json
{
    "dpiScaling": "100"
}
```

- `"keep"`：Windowsの拡大率を変更しない（既定）。Sunshine側の解像度・FPSへの自動追従は有効。
- `"100"`：**Parsec VDDの仮想画面だけ**を100%に変更する。Sunshine起動前および稼働中（3秒間隔）に確認し、解像度変更後も100%に戻す。追加サービスは不要。
- 仮想画面は `PSCCDD0` IDまたは `ParsecVDA` 名で識別する。識別できない場合は物理モニターを変更せず、警告を記録する。
- 100%固定にはWindowsの非公開API（`DisplayConfigGetDeviceInfo(-3)`、`DisplayConfigSetDeviceInfo(-4)`）を利用する。Windowsの更新によって動作しなくなる可能性があり、その場合もSunshineの配信は継続する。
- `keep` に切り替えても、過去にWindowsが保存したDPI設定を自動的に元に戻すわけではない。

参考実装：[lihas/windows-DPI-scaling-sample](https://github.com/lihas/windows-DPI-scaling-sample) / [imniko/SetDPI](https://github.com/imniko/SetDPI)。

`output_name` にモニターGUIDを設定した場合は `ensure_only_display` を使用する。未設定の場合は、物理モニターを誤って無効化しないよう `ensure_active` に切り替える。Headless運用のため、次項の手順で**Parsec仮想モニターのGUID**を設定すること。

既存設定のほかの項目は変更しない。設定を変更する必要がある場合のみ書き込み、最初の変更時に `sunshine.conf.bak` を作成する。カスタム設定ファイル使用時は `-ConfigPath` を指定する。

仮想モニターを生成した状態でSunshineのログ（`Currently available display devices`）を確認し、**Parsec仮想モニターの `device_id`** を配信対象に設定する。PnPアダプターIDの `ROOT\DISPLAY\...` と、SunshineのモニターGUIDは異なるので混同しないこと。

ノートPCの蓋を閉じてもスリープしないよう電源設定を確認する。蓋を閉じて内蔵ディスプレイが切断されても、Parsec VDDの画面が有効なら配信可能な構成となる。

## 制約と注意

- Sunshineがすでに起動中なら、PS1が二重起動を拒否する。起動にはUAC承認が必要。
- 仮想モニターの生成・寿命管理は `Start-Sunshine-ParsecVDD-v2.ps1` が担当する。ParsecDisplay公式実装に合わせ、IOCTL完了確認とキャンセル待ち、および削除時のインデックス配置を修正した。設定ファイルの編集処理は `Set-Sunshine-AutoDisplay.ps1` に分離している。
- ポータブルSunshineのGame Capture / WGC方式はそのまま利用できるが、描画・配信の成否は環境とSunshine設定に依存する。
- **通常動作中はPowerShellのプロセスが1つ残る**（仮想モニター維持のため）。Sunshineが終了すればこのプロセスも終了する。バックグラウンドサービスとしての常時稼働はしない。
- ParsecDisplay GUIや`vdd add` CLIとの同時制御は想定していない。同じVDDを複数の管理プログラムが制御すると生成・削除が競合する可能性がある。
- ドライバーが不安定な環境では、Parsec公式の [VDD Advanced Configuration](https://support.parsec.app/hc/en-us/articles/32361359271444-VDD-Advanced-Configuration) にある親GPUの選択も確認する。Windows 10/11環境によってはVDD 0.45系に互換性問題があり、[parsec-vdd](https://github.com/nomi-san/parsec-vdd#picking-a-driver) は0.41を安定版として紹介している。
- Windows実機での起動・Headless配信は未検証。静的検査だけでは実際の画面再認識まで保証できない。

## ファイル形式

- `*.ps1`：UTF-8 **BOM付き**、CRLF
- `*.cmd`：Shift-JIS（CP932）、CRLF（先頭で `chcp 932`）
- `README.md`：UTF-8

## 出典・謝辞

- [nomi-san/parsec-vdd](https://github.com/nomi-san/parsec-vdd) - Parsec VDD IOCTLとAPI情報（MITライセンス）
- [Roei-Bracha/sunshine-vdd](https://github.com/Roei-Bracha/sunshine-vdd) - Sunshine連携の参考資料。本リポジトリはサービス再起動型の導入処理を使用しない。
- [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) - 配信ホスト本体。本リポジトリにはバイナリを含めない。
