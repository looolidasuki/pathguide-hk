# Flutter / Android 環境搭建記錄

**日期：** 2026-09-22
**目的：** 為 M3（最小可見 Demo）準備可用的 Flutter + Android 構建環境。

---

## 1. 已實測通過的部分

`flutter doctor -v` 實測輸出（用户終端，非沙箱）：

| 項 | 結果 |
|---|---|
| Flutter | **3.47.5 stable**（`C:\...\Accessible Visual Guidance\.tools\flutter`） |
| Dart | 3.13.4 |
| Framework revision | `6a19cca564`（2026-09-17） |
| Windows | 11 專業版 64-bit，24H2，build 26100.4946 |
| 網絡資源 | ✅ **全部可用**（Gradle / pub / Flutter artifacts 都能下載） |
| Android SDK | 36.1.0，位於 `%LOCALAPPDATA%\Android\Sdk` |

**SDK 位置説明：** Flutter SDK 解壓在**倉庫內的 `.tools\flutter`**，不是常規位置。
原因是執行沙箱禁止寫入工作區以外的任何路徑（實測 `%LOCALAPPDATA%`、
`%USERPROFILE%`、`C:\Program Files` 全部拒絕訪問）。`.tools/` 已被 `.gitignore` 排除。
若想搬到常規位置，改 `.env.flutter.ps1` 裏的 `$flutterBin` 即可。

---

## 2. 三個已經踩過並修好的坑

### 坑 1：Flutter 狀態文件寫不進去，報錯指向錯誤方向

**症狀：**

```
Error: Flutter failed to write to a file at
  "C:\Users\user\AppData\Roaming\.flutter_tool_state".
The flutter tool cannot access the file or directory.
Please ensure that the SDK and/or project is installed in a location that has
read/write permissions for the current user.
```

**這個錯誤信息會把人引向「SDK 裝壞了」，實際不是。**

**根因（讀 Flutter 源碼確認，非猜測）：**

`packages/flutter_tools/lib/src/base/config.dart` 的 `_userHomePath()`：

```dart
final envKey = platform.isWindows ? 'APPDATA' : 'HOME';
return platform.environment[envKey] ?? '.';
```

Windows 上它**只認 `APPDATA`**。注意同一文件另一處的
`FileSystemUtils.homeDirPath` 用的是 `USERPROFILE`——兩個不是一回事，
只改 `USERPROFILE` 無效。而在 Windows 分支上沒有 XDG 那樣的回退，
所以 `APPDATA` 是唯一入口。

**修法：** `.env.flutter.ps1` 裏把 `APPDATA` 指向工作區內的 `.tools\appdata`。

### 坑 2：SDK 裝在 `%LOCALAPPDATA%` 導致解壓大面積失敗

**症狀：** `tar -xf` 報上百行
`Can't create '\\?\C:\Users\user\AppData\Local\flutter\packages\...': No such file or directory`。

**根因：** 沙箱拒絕在工作區外創建目錄，但 `tar` 把它報成「目錄不存在」。

**修法：** 解壓到工作區內的 `.tools\`。同樣內容，`tar` 12 秒完成、零錯誤。

### 坑 3：系統 JDK 是 24，Flutter 不支持

**症狀：** 系統 `java` 是 `C:\Program Files\Java\jdk-24`。Flutter/AGP 尚不支持 JDK 24。

**修法：** 用 Android Studio 自帶的 JBR（`C:\Program Files\Android\Android Studio\jbr`），
實測 `openjdk 21.0.10`，符合 Flutter 要求。**不需要額外裝 JDK。**

---

## 3. 尚未解決：兩個 `flutter doctor` 報項

### 3.1 `cmdline-tools component is missing` + `Android license status unknown`

**現狀：** `%LOCALAPPDATA%\Android\Sdk\cmdline-tools\` **存在但是空目錄**。
`licenses\android-sdk-license` 文件已存在（Android Studio 裝 SDK 時接受過），
但 Flutter 通過 `cmdline-tools` 檢查 license，所以報 unknown。

**修法：** 裝 command-line tools。

```powershell
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
$url = "https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip"
Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\cmdtools.zip"
Expand-Archive "$env:TEMP\cmdtools.zip" -DestinationPath "$env:TEMP\cmdtools" -Force
# 必須是 cmdline-tools\<version>\ 結構，Flutter 認這個層級
New-Item -ItemType Directory -Force -Path "$sdk\cmdline-tools\latest" | Out-Null
Move-Item "$env:TEMP\cmdtools\cmdline-tools\*" "$sdk\cmdline-tools\latest\" -Force
# 複製成 latest 之外的平級副本，sdkmanager 自己會再找一次
Copy-Item "$sdk\cmdline-tools\latest" "$sdk\cmdline-tools\19.0" -Recurse -Force
flutter doctor --android-licenses     # 一路 y
flutter doctor -v
```

`dl.google.com` 的 URL 隨版本變化。若 404，用瀏覽器打開
<https://developer.android.com/studio#command-line-tools-only> 取最新鏈接。

### 3.2 未檢測到 Android 真機

**現狀：** `Connected device` 列出的是 Windows / Chrome / Edge（桌面與網頁目標），
**沒有手機**。

**排查順序：**

```powershell
# 1) 物理連接是否被識別（這一步最説明問題）
adb devices -l
```

| `adb devices` 輸出 | 含義 | 下一步 |
|---|---|---|
| 空列表（只有標題行） | USB 層就沒連上 | 換數據線（很多線只能充電）、換 USB 口、確認手機彈窗已點「允許」 |
| `xxxx unauthorized` | 手機沒授權這台電腦 | 手機上點「允許 USB 調試」；不行就撤銷授權重插 |
| `xxxx device` | 正常 | Flutter 應該能看到了，重跑 `flutter doctor` |

**手機側設置（不同廠商路徑不同）：**

- 通用：設置 → 關於手機 → **連點「版本號」7 次** → 返回 → 系統 → 開發者選項 →
  打開「USB 調試」
- 小米/紅米：還要打開開發者選項裏的 **「USB 調試（安全設置）」**，
  並且 USB 用途選「傳輸文件」而不是「僅充電」
- 華為/榮耀：開發者選項裏打開「僅充電模式下允許 ADB 調試」
- OPPO/一加/realme：需要登錄賬號才能開 USB 調試

**關於 Windows 桌面目標：** `flutter doctor` 報 Visual Studio 缺
「Desktop development with C++」workload —— **本項目不需要**，我們只出 Android APK。
不要為它去裝幾個 GB 的組件。

---

## 4. 日常使用

```powershell
cd "C:\Users\user\PycharmProjects\Accessible Visual Guidance"
. .\.env.flutter.ps1
cd app
flutter test                      # 不需要手機
flutter devices                   # 看真機
flutter run -d <device-id>        # 真機調試
flutter build apk --release       # 出 APK
```

---

## 5. 執行沙箱的硬限制（重要，別再試）

**Dart 在本沙箱內無法啓動任何子進程。** 實測最小探針：

```
$ dart .tmp\dart_probe.dart
systemTemp OK: C:\Users\user\AppData\Local\Temp\dsh-JfaVRg
runSync git FAIL: ProcessException: 拒絕訪問。 (at ../../runtime/bin/process_win.cc:744)
runSync cmd FAIL: ProcessException: 拒絕訪問。
dart.exe : CreateFile failed 5 (拒絕訪問。)
```

後果：`flutter_tools` 啓動時就要跑 `git log` / `pub upgrade`，因此
**`flutter create`、`flutter test`、`flutter build` 在沙箱內全部不可用**——
`flutter.bat` 會陷入 "Unable to 'pub upgrade' flutter tool. Retrying…" 的循環
（實測刷出 135 個 `flutter_tools.snapshot.old*` 副本）。

這與之前 `pnpm`/`node` 拿不到管道輸出是同一條邊界（命名管道不可用），
不是配置問題。

**分工結論：** 代碼與測試由代理編寫，**編譯、`flutter test`、裝機必須由用户在普通終端執行**。

---

## 6. iOS 支持策略（2026-09-22 決策）

**需求：** 小米（Android）與 iPhone（iOS）都要能用。

### 6.1 必須澄清的技術邊界

Flutter 跨的是 **UI 與業務邏輯**，**不跨原生推理層**：

| 層 | 跨平台 | 説明 |
|---|---|---|
| `lib/` 下的 Dart（界面、畫框、HUD、閾值滑條、播報邏輯、狀態機、類別表） | ✅ 一份通用 | Flutter 真正跨的部分 |
| 原生推理（TFLite 推理、相機取幀、視頻解碼） | ❌ 各平台一份 | Android = Kotlin（`CameraX` + `Interpreter`）；iOS = Swift（`AVFoundation` + Core ML / TFLite C++） |

原因：實時推理要直接消費相機幀的內存緩衝並控制線程與 GPU 委託，兩端的 API 完全不同。
Flutter 不做這層翻譯。**原生代碼有多少行，就要寫幾份。**

因此「留好接口」的含義是：**Dart 側一次設計，原生側兩次實現**，
不是「一份代碼兩端跑」。

### 6.2 平台通道契約（防兩端漂移的關鍵）

接口約定的唯一事實源是 **`app/lib/vision/platform_contract.dart`**：
channels 名、方法名、請求/響應的全部字符串鍵都在那裏以常量聲明。

- Kotlin 與 Swift 實現**都必須**用同樣的字面量，不得各寫各的字符串——
  通道名或鍵名不一致時，表現為「調用靜默無結果」，兩端都不報錯。
- Dart 側對回包做**防禦式解析**（缺鍵、類型不對都返回空結果），
  避免某個平台實現的差異把 App 打崩。

### 6.3 當前執行順序

| 階段 | 平台 | 能做到哪一步 |
|---|---|---|
| 現在（Windows） | Android | 完整：Kotlin 實現 + 真機（Redmi Note 11T Pro / Android 14 / arm64）編譯、裝機、跑通 |
| 現在（Windows） | iOS | 生成 `ios/` 工程骨架併入庫；Dart 層零改動即可複用 |
| 之後（MacBook） | iOS | `pod install` + Xcode 編譯；按契約補 Swift 實現；真機/TestFlight |

**`ios/` 目錄必須一併入庫。** 它只是文本工程文件，生成一次即可，
在 MacBook 上不必重新 `flutter create`。

### 6.4 iOS 側待辦清單（MacBook 上做）

1. `cd app && flutter pub get && cd ios && pod install`（CocoaPods 必須先裝）
2. `ios/Runner/Info.plist` 加 **`NSCameraUsageDescription`**（相機權限）。
   **缺這一項會在打開相機的瞬間閃退**，不是報錯對話框。
3. 按 `platform_contract.dart` 實現 `VisionPlugin.swift`：
   - `AVCaptureSession` 取幀 → 旋轉到正立 → 縮放 → 寫入 `CVPixelBuffer`
   - TFLite 優先用 **Core ML delegate**；Android 側用 NNAPI / GPU delegate
   - 回包鍵名與 Kotlin 完全一致
4. `flutter_tts` 的粵語語音包：iOS 側 `yue-HK` 支持情況需實測，
   退路是 `zh-HK`，再不行改為真人錄音 + 本地音頻播放。

### 6.5 已知的 iOS 額外成本

- **Apple 開發者賬號**：真機調試需要免費 Apple ID 即可（證書 7 天有效期，需重複簽名）；
  上 TestFlight / App Store 需付費賬號（約 US$99/年）。
- **模型格式**：Android 用 TFLite 順暢；iOS 上 Core ML 是原生路徑，
  需要額外做一次 TFLite → Core ML 轉換（或用 TFLite C++ 直接集成）。
  這一步的成本要預留，別默認「TFLite 能直接搬到 iOS」。

