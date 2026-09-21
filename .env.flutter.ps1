# 用法：在本目录执行  . .\.env.flutter.ps1
#
# 作用：把 Flutter / Android / Gradle / pub 的全部写路径重定向到工作区内。
#
# 为什么需要：Flutter 工具链默认往用户目录写状态，而这些位置在受限沙箱下
# 一律被拒绝，报出来的错却是「flutter tool cannot access the file」——
# 看起来像 SDK 装坏了，其实是沙箱。**具体位置（读 Flutter 源码确认，非猜测）：**
#
#   %APPDATA%\.flutter_tool_state   <- 来自 config.dart 的 _userHomePath()：
#                                      Windows 上只认 APPDATA，不是 USERPROFILE
#   %LOCALAPPDATA%\Pub\Cache        <- pub 包缓存，用 PUB_CACHE 覆盖
#   %USERPROFILE%\.gradle           <- Gradle 缓存，用 GRADLE_USER_HOME 覆盖
#
# 本文件**可以安全提交**——它不含任何密钥。

$ErrorActionPreference = "Stop"

$repoRoot = $PSScriptRoot

# ---- Flutter SDK ----
$flutterBin = Join-Path $repoRoot ".tools\flutter\bin"
if (-not (Test-Path (Join-Path $flutterBin "flutter.bat"))) {
    Write-Host "未找到 Flutter SDK：$flutterBin\flutter.bat" -ForegroundColor Red
    Write-Host "见 docs/superpowers/plans/ 里的 M3 说明；SDK 解压到 .tools\flutter 即可。" -ForegroundColor Yellow
    return
}
$env:Path = "$flutterBin;$env:Path"

# ---- Android SDK ----
if (-not $env:ANDROID_HOME) {
    $env:ANDROID_HOME = Join-Path $env:LOCALAPPDATA "Android\Sdk"
}
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME

# ---- JDK ----
# 系统装的是 JDK 24，Flutter/AGP 尚不支持；用 Android Studio 自带的 JBR（21）。
$jbr = "C:\Program Files\Android\Android Studio\jbr"
if (Test-Path (Join-Path $jbr "bin\java.exe")) {
    $env:JAVA_HOME = $jbr
} elseif (-not $env:JAVA_HOME) {
    Write-Host "警告：未找到 Android Studio 自带 JDK，且 JAVA_HOME 未设置。" -ForegroundColor Yellow
}

# ---- 缓存重定向（受限沙箱必需）----
$env:APPDATA          = Join-Path $repoRoot ".tools\appdata"
$env:PUB_CACHE        = Join-Path $repoRoot ".tools\pub-cache"
$env:GRADLE_USER_HOME = Join-Path $repoRoot ".tools\gradle"
$env:FLUTTER_SUPPRESS_ANALYTICS = "true"
New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:PUB_CACHE, $env:GRADLE_USER_HOME | Out-Null

Write-Host "Flutter 环境已就绪" -ForegroundColor Green
Write-Host "  flutter         : $flutterBin\flutter.bat"
Write-Host "  ANDROID_HOME    : $env:ANDROID_HOME"
Write-Host "  JAVA_HOME       : $env:JAVA_HOME"
Write-Host "  APPDATA         : $env:APPDATA"
Write-Host "  PUB_CACHE       : $env:PUB_CACHE"
Write-Host "  GRADLE_USER_HOME: $env:GRADLE_USER_HOME"
Write-Host ""
Write-Host "常用命令：" -ForegroundColor Cyan
Write-Host "  cd app"
Write-Host "  flutter doctor -v                  # 工具链自检"
Write-Host "  flutter test                       # Dart 单元测试（不需要手机）"
Write-Host "  flutter devices                    # 看真机是否连上"
Write-Host "  flutter run -d <device-id>         # 真机调试"
Write-Host "  flutter build apk --release        # 出 APK"
