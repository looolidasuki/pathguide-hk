# Flutter / Android 环境搭建记录

**日期：** 2026-09-22
**目的：** 为 M3（最小可见 Demo）准备可用的 Flutter + Android 构建环境。

---

## 1. 已实测通过的部分

`flutter doctor -v` 实测输出（用户终端，非沙箱）：

| 项 | 结果 |
|---|---|
| Flutter | **3.47.5 stable**（`C:\...\Accessible Visual Guidance\.tools\flutter`） |
| Dart | 3.13.4 |
| Framework revision | `6a19cca564`（2026-09-17） |
| Windows | 11 專業版 64-bit，24H2，build 26100.4946 |
| 网络资源 | ✅ **全部可用**（Gradle / pub / Flutter artifacts 都能下载） |
| Android SDK | 36.1.0，位于 `%LOCALAPPDATA%\Android\Sdk` |

**SDK 位置说明：** Flutter SDK 解压在**仓库内的 `.tools\flutter`**，不是常规位置。
原因是执行沙箱禁止写入工作区以外的任何路径（实测 `%LOCALAPPDATA%`、
`%USERPROFILE%`、`C:\Program Files` 全部拒绝访问）。`.tools/` 已被 `.gitignore` 排除。
若想搬到常规位置，改 `.env.flutter.ps1` 里的 `$flutterBin` 即可。

---

## 2. 三个已经踩过并修好的坑

### 坑 1：Flutter 状态文件写不进去，报错指向错误方向

**症状：**

```
Error: Flutter failed to write to a file at
  "C:\Users\user\AppData\Roaming\.flutter_tool_state".
The flutter tool cannot access the file or directory.
Please ensure that the SDK and/or project is installed in a location that has
read/write permissions for the current user.
```

**这个错误信息会把人引向「SDK 装坏了」，实际不是。**

**根因（读 Flutter 源码确认，非猜测）：**

`packages/flutter_tools/lib/src/base/config.dart` 的 `_userHomePath()`：

```dart
final envKey = platform.isWindows ? 'APPDATA' : 'HOME';
return platform.environment[envKey] ?? '.';
```

Windows 上它**只认 `APPDATA`**。注意同一文件另一处的
`FileSystemUtils.homeDirPath` 用的是 `USERPROFILE`——两个不是一回事，
只改 `USERPROFILE` 无效。而在 Windows 分支上没有 XDG 那样的回退，
所以 `APPDATA` 是唯一入口。

**修法：** `.env.flutter.ps1` 里把 `APPDATA` 指向工作区内的 `.tools\appdata`。

### 坑 2：SDK 装在 `%LOCALAPPDATA%` 导致解压大面积失败

**症状：** `tar -xf` 报上百行
`Can't create '\\?\C:\Users\user\AppData\Local\flutter\packages\...': No such file or directory`。

**根因：** 沙箱拒绝在工作区外创建目录，但 `tar` 把它报成「目录不存在」。

**修法：** 解压到工作区内的 `.tools\`。同样内容，`tar` 12 秒完成、零错误。

### 坑 3：系统 JDK 是 24，Flutter 不支持

**症状：** 系统 `java` 是 `C:\Program Files\Java\jdk-24`。Flutter/AGP 尚不支持 JDK 24。

**修法：** 用 Android Studio 自带的 JBR（`C:\Program Files\Android\Android Studio\jbr`），
实测 `openjdk 21.0.10`，符合 Flutter 要求。**不需要额外装 JDK。**

---

## 3. 尚未解决：两个 `flutter doctor` 报项

### 3.1 `cmdline-tools component is missing` + `Android license status unknown`

**现状：** `%LOCALAPPDATA%\Android\Sdk\cmdline-tools\` **存在但是空目录**。
`licenses\android-sdk-license` 文件已存在（Android Studio 装 SDK 时接受过），
但 Flutter 通过 `cmdline-tools` 检查 license，所以报 unknown。

**修法：** 装 command-line tools。

```powershell
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
$url = "https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip"
Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\cmdtools.zip"
Expand-Archive "$env:TEMP\cmdtools.zip" -DestinationPath "$env:TEMP\cmdtools" -Force
# 必须是 cmdline-tools\<version>\ 结构，Flutter 认这个层级
New-Item -ItemType Directory -Force -Path "$sdk\cmdline-tools\latest" | Out-Null
Move-Item "$env:TEMP\cmdtools\cmdline-tools\*" "$sdk\cmdline-tools\latest\" -Force
# 复制成 latest 之外的平级副本，sdkmanager 自己会再找一次
Copy-Item "$sdk\cmdline-tools\latest" "$sdk\cmdline-tools\19.0" -Recurse -Force
flutter doctor --android-licenses     # 一路 y
flutter doctor -v
```

`dl.google.com` 的 URL 随版本变化。若 404，用浏览器打开
<https://developer.android.com/studio#command-line-tools-only> 取最新链接。

### 3.2 未检测到 Android 真机

**现状：** `Connected device` 列出的是 Windows / Chrome / Edge（桌面与网页目标），
**没有手机**。

**排查顺序：**

```powershell
# 1) 物理连接是否被识别（这一步最说明问题）
adb devices -l
```

| `adb devices` 输出 | 含义 | 下一步 |
|---|---|---|
| 空列表（只有标题行） | USB 层就没连上 | 换数据线（很多线只能充电）、换 USB 口、确认手机弹窗已点「允许」 |
| `xxxx unauthorized` | 手机没授权这台电脑 | 手机上点「允许 USB 调试」；不行就撤销授权重插 |
| `xxxx device` | 正常 | Flutter 应该能看到了，重跑 `flutter doctor` |

**手机侧设置（不同厂商路径不同）：**

- 通用：设置 → 关于手机 → **连点「版本号」7 次** → 返回 → 系统 → 开发者选项 →
  打开「USB 调试」
- 小米/红米：还要打开开发者选项里的 **「USB 调试（安全设置）」**，
  并且 USB 用途选「传输文件」而不是「仅充电」
- 华为/荣耀：开发者选项里打开「仅充电模式下允许 ADB 调试」
- OPPO/一加/realme：需要登录账号才能开 USB 调试

**关于 Windows 桌面目标：** `flutter doctor` 报 Visual Studio 缺
「Desktop development with C++」workload —— **本项目不需要**，我们只出 Android APK。
不要为它去装几个 GB 的组件。

---

## 4. 日常使用

```powershell
cd "C:\Users\user\PycharmProjects\Accessible Visual Guidance"
. .\.env.flutter.ps1
cd app
flutter test                      # 不需要手机
flutter devices                   # 看真机
flutter run -d <device-id>        # 真机调试
flutter build apk --release       # 出 APK
```

---

## 5. 执行沙箱的硬限制（重要，别再试）

**Dart 在本沙箱内无法启动任何子进程。** 实测最小探针：

```
$ dart .tmp\dart_probe.dart
systemTemp OK: C:\Users\user\AppData\Local\Temp\dsh-JfaVRg
runSync git FAIL: ProcessException: 拒绝访问。 (at ../../runtime/bin/process_win.cc:744)
runSync cmd FAIL: ProcessException: 拒绝访问。
dart.exe : CreateFile failed 5 (拒绝访问。)
```

后果：`flutter_tools` 启动时就要跑 `git log` / `pub upgrade`，因此
**`flutter create`、`flutter test`、`flutter build` 在沙箱内全部不可用**——
`flutter.bat` 会陷入 "Unable to 'pub upgrade' flutter tool. Retrying…" 的循环
（实测刷出 135 个 `flutter_tools.snapshot.old*` 副本）。

这与之前 `pnpm`/`node` 拿不到管道输出是同一条边界（命名管道不可用），
不是配置问题。

**分工结论：** 代码与测试由代理编写，**编译、`flutter test`、装机必须由用户在普通终端执行**。

---

## 6. iOS 支持策略（2026-09-22 决策）

**需求：** 小米（Android）与 iPhone（iOS）都要能用。

### 6.1 必须澄清的技术边界

Flutter 跨的是 **UI 与业务逻辑**，**不跨原生推理层**：

| 层 | 跨平台 | 说明 |
|---|---|---|
| `lib/` 下的 Dart（界面、画框、HUD、阈值滑条、播报逻辑、状态机、类别表） | ✅ 一份通用 | Flutter 真正跨的部分 |
| 原生推理（TFLite 推理、相机取帧、视频解码） | ❌ 各平台一份 | Android = Kotlin（`CameraX` + `Interpreter`）；iOS = Swift（`AVFoundation` + Core ML / TFLite C++） |

原因：实时推理要直接消费相机帧的内存缓冲并控制线程与 GPU 委托，两端的 API 完全不同。
Flutter 不做这层翻译。**原生代码有多少行，就要写几份。**

因此「留好接口」的含义是：**Dart 侧一次设计，原生侧两次实现**，
不是「一份代码两端跑」。

### 6.2 平台通道契约（防两端漂移的关键）

接口约定的唯一事实源是 **`app/lib/vision/platform_contract.dart`**：
channels 名、方法名、请求/响应的全部字符串键都在那里以常量声明。

- Kotlin 与 Swift 实现**都必须**用同样的字面量，不得各写各的字符串——
  通道名或键名不一致时，表现为「调用静默无结果」，两端都不报错。
- Dart 侧对回包做**防御式解析**（缺键、类型不对都返回空结果），
  避免某个平台实现的差异把 App 打崩。

### 6.3 当前执行顺序

| 阶段 | 平台 | 能做到哪一步 |
|---|---|---|
| 现在（Windows） | Android | 完整：Kotlin 实现 + 真机（Redmi Note 11T Pro / Android 14 / arm64）编译、装机、跑通 |
| 现在（Windows） | iOS | 生成 `ios/` 工程骨架并入库；Dart 层零改动即可复用 |
| 之后（MacBook） | iOS | `pod install` + Xcode 编译；按契约补 Swift 实现；真机/TestFlight |

**`ios/` 目录必须一并入库。** 它只是文本工程文件，生成一次即可，
在 MacBook 上不必重新 `flutter create`。

### 6.4 iOS 侧待办清单（MacBook 上做）

1. `cd app && flutter pub get && cd ios && pod install`（CocoaPods 必须先装）
2. `ios/Runner/Info.plist` 加 **`NSCameraUsageDescription`**（相机权限）。
   **缺这一项会在打开相机的瞬间闪退**，不是报错对话框。
3. 按 `platform_contract.dart` 实现 `VisionPlugin.swift`：
   - `AVCaptureSession` 取帧 → 旋转到正立 → 缩放 → 写入 `CVPixelBuffer`
   - TFLite 优先用 **Core ML delegate**；Android 侧用 NNAPI / GPU delegate
   - 回包键名与 Kotlin 完全一致
4. `flutter_tts` 的粤语语音包：iOS 侧 `yue-HK` 支持情况需实测，
   退路是 `zh-HK`，再不行改为真人录音 + 本地音频播放。

### 6.5 已知的 iOS 额外成本

- **Apple 开发者账号**：真机调试需要免费 Apple ID 即可（证书 7 天有效期，需重复签名）；
  上 TestFlight / App Store 需付费账号（约 US$99/年）。
- **模型格式**：Android 用 TFLite 顺畅；iOS 上 Core ML 是原生路径，
  需要额外做一次 TFLite → Core ML 转换（或用 TFLite C++ 直接集成）。
  这一步的成本要预留，别默认「TFLite 能直接搬到 iOS」。

