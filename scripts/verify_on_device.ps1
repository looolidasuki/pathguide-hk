# 真机自动验证：装包 → 授权 → 启动 → 截图 → 抓日志
#
# 目的：把「真机验证」变成一条命令，而不是让人在手机与终端之间来回当搬运工。
# 截图与日志都会落到 artifacts/device/，由我（或你）直接读图确认。
#
# 用法（必须先把手机用 USB 连上、并允许 USB 调试）：
#   cd "C:\Users\user\PycharmProjects\Accessible Visual Guidance"
#   . .\.env.flutter.ps1
#   .\scripts\verify_on_device.ps1
#
# 可选参数：
#   -ApkPath     指定 APK（默认用 debug 构建产物）
#   -Shots       截图张数（默认 3）
#   -IntervalSec 截图间隔秒数（默认 6）

[CmdletBinding()]
param(
    [string]$ApkPath = "app\build\app\outputs\flutter-apk\app-debug.apk",
    [int]$Shots = 3,
    [int]$IntervalSec = 6
)

# adb 会把「daemon not running」之类的提示写到 stderr。
# 在 $ErrorActionPreference='Stop' 下，那会被 PowerShell 当成致命错误直接中断脚本，
# 所以我们不用 Stop，改为每一步都显式检查，并且在调用 adb 时把两个流都收下来。
$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Fail($msg) { Write-Host ""; Write-Host "失败：$msg" -ForegroundColor Red; exit 1 }
function Info($msg) { Write-Host $msg }

# 调用 adb 并返回**纯文本**。
#
# 为什么不能直接 `& $adb ... 2>&1 | Out-String`：adb 会把「daemon not running」
# 这类提示写进 stderr，PowerShell 把它包成 ErrorRecord，序列化出来会附上
# “At line:NN char:NN … CategoryInfo …” 一大段装饰文字，既污染解析也看不懂。
# 这里把 ErrorRecord 还原成它原本的那一行消息。
function Invoke-Adb {
    param([string[]]$CmdArgs, [switch]$NoSerial)
    # 必须**显式累加**成数组：`$full = if (...) { $CmdArgs } else { ... }` 在只有
    # 一个元素时会把数组拆成 String，而 `& $adb @full` 对 String 的 splat 并不等于
    # 「原样传一个参数」——实测只传出首字符，adb 报 "unknown command d"。
    $full = @()
    if (-not $NoSerial) { $full += @("-s", $serial) }
    $full += $CmdArgs
    $out = & $adb @full 2>&1
    ($out | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_.Exception.Message
        } else {
            [string]$_
        }
    }) -join "`n"
}

# ---------------------------------------------------------------- 定位 adb
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME }
       elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT }
       else { Join-Path $env:LOCALAPPDATA "Android\Sdk" }
$adb = Join-Path $sdk "platform-tools\adb.exe"
if (-not (Test-Path $adb)) { Fail "找不到 adb：$adb（先执行 . .\.env.flutter.ps1）" }

# ---------------------------------------------------------------- 检查设备
# 首次调用会顺带启动 adb server，它的提示信息走 stderr——一并收下再解析。
$serial = ""
$devicesRaw = Invoke-Adb -CmdArgs @("devices") -NoSerial
$devices = @()
$devicesRaw -split "`r?`n" | Select-Object -Skip 1 | ForEach-Object {
    $line = $_.Trim()
    if ($line -match '^(\S+)\s+device$') { $devices += $Matches[1] }
}
if ($devices.Count -eq 0) {
    Fail @"
没有检测到已授权的设备。

请检查：
  1. 手机用 USB 线连上电脑；
  2. 开发者选项里打开「USB 调试」；
  3. 手机上弹出「允许 USB 调试吗？」时点允许（小米还需打开「USB 安装」，
     否则安装会报 INSTALL_FAILED_USER_RESTRICTED）。

排查命令：adb devices
（adb 原始输出：
$devicesRaw
）
"@
}
if ($devices.Count -gt 1) { Fail "检测到多台设备（$($devices -join ', ')），请只留一台。" }
$serial = $devices[0]
Info "设备：$serial"

$model = (Invoke-Adb -CmdArgs @("shell", "getprop", "ro.product.model")).Trim()
$release = (Invoke-Adb -CmdArgs @("shell", "getprop", "ro.build.version.release")).Trim()
$abi = (Invoke-Adb -CmdArgs @("shell", "getprop", "ro.product.cpu.abi")).Trim()
Info "型号：$model  Android $release  ABI $abi"

# ---------------------------------------------------------------- 检查 APK
if (-not (Test-Path $ApkPath)) { Fail "APK 不存在：$ApkPath（先跑 flutter build apk --debug）" }
$apkItem = Get-Item $ApkPath
Info ("APK ：{0}  {1:N0} 字节  构建于 {2}" -f $apkItem.Name, $apkItem.Length,
      $apkItem.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))

$newestSource = Get-ChildItem -Recurse -File `
    app\lib, app\android\app\src\main\kotlin `
    -Include *.dart, *.kt |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newestSource -and $newestSource.LastWriteTime -gt $apkItem.LastWriteTime) {
    Fail ("APK 比源码旧（最新源码 {0} 于 {1}），先重新构建，否则验证的是旧代码。" -f
          $newestSource.Name, $newestSource.LastWriteTime.ToString("HH:mm:ss"))
}
Info "APK 比源码新，验证的就是当前代码。"

$pkg = "hk.pathguide.pathguide"
$activity = "$pkg/.MainActivity"
$outDir = Join-Path $repo "artifacts\device"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ------------------------------------------------------- 屏幕必须亮着（否则一定「没有检测」）
#
# 灭屏时 CameraX **不会出帧**，于是 HUD 上是 analyzed=0、det=0、
# 截图全黑。这看起来和「代码坏了」一模一样，实测为此白查过一轮。
# 所以先自动唤醒；唤醒不了（有锁屏密码）就明确报出来，而不是让人去猜。
function Get-ScreenState() {
    $p = Invoke-Adb -CmdArgs @("shell", "dumpsys", "power")
    $w = if ($p -match "mWakefulness=(\w+)") { $Matches[1] } else { "unknown" }
    $on = if ($p -match "mScreenOn=(true|false)") { $Matches[1] } else { "?" }
    return @{ Wakefulness = $w; ScreenOn = $on }
}
Info ""
Info "== 屏幕状态 =="
$st = Get-ScreenState
Info "  唤醒状态：$($st.Wakefulness)   屏幕亮：$($st.ScreenOn)"
if ($st.Wakefulness -in @("Dozing", "Asleep")) {
    Info "  屏幕休眠中，发送唤醒键…"
    Invoke-Adb -CmdArgs @("shell", "input", "keyevent", "KEYCODE_WAKEUP") | Out-Null
    Start-Sleep -Seconds 2
    $st = Get-ScreenState
    Info "  唤醒后：$($st.Wakefulness)   屏幕亮：$($st.ScreenOn)"
    if ($st.Wakefulness -in @("Dozing", "Asleep")) {
        Fail @"
手机屏幕无法自动唤醒（可能设了锁屏密码）。

灭屏状态下 CameraX 不出帧，验证结果必然是 analyzed=0、det=0、截图全黑——
和「代码坏了」长得一样，所以这里直接拦住。

请手动点亮并解锁手机，然后重跑本脚本。
"@
    }
}

# ---------------------------------------------------------------- 安装
Info ""
Info "== 安装 =="
$installOut = Invoke-Adb -CmdArgs @("install", "-r", $ApkPath)
if ($installOut -match "INSTALL_FAILED_USER_RESTRICTED") {
    Fail @"
安装被小米 ROM 拒绝（INSTALL_FAILED_USER_RESTRICTED）。
请在「开发者选项」里打开 **USB 安装**（或「通过 USB 安装应用」），然后重跑。
"@
}
if ($installOut -notmatch "Success") { Fail "安装失败：`n$installOut" }
Info "安装成功"

# ---------------------------------------------------------------- 授权
# 先直接授权，免去首次启动的权限对话框——否则自动化会卡在弹窗上。
Info ""
Info "== 授权相机 =="
Invoke-Adb -CmdArgs @("shell", "pm", "grant", $pkg, "android.permission.CAMERA") | Out-Null
$pkgDump = Invoke-Adb -CmdArgs @("shell", "dumpsys", "package", $pkg)
$granted = $pkgDump -match "android.permission.CAMERA: granted=true"
Info ("相机权限：" + $(if ($granted) { "已授予" } else { "未授予（启动后可能停在权限对话框）" }))

# ---------------------------------------------------------------- 启动
Info ""
Info "== 启动 =="
Invoke-Adb -CmdArgs @("logcat", "-c") | Out-Null
Invoke-Adb -CmdArgs @("shell", "am", "force-stop", $pkg) | Out-Null
Start-Sleep -Seconds 1
$startOut = Invoke-Adb -CmdArgs @("shell", "am", "start", "-n", $activity)
if ($startOut -match "Error|Exception") { Info "启动命令有输出：$($startOut.Trim())" }

# 模型要落盘（约 10 MB）再加载，相机也要起预览，给足时间。
Info "等待 15 秒让相机与模型就绪…"
Start-Sleep -Seconds 15

# ---------------------------------------------------------------- 截图
Info ""
Info "== 截图 =="
for ($i = 1; $i -le $Shots; $i++) {
    $remote = "/sdcard/pg_shot_$i.png"
    $local = Join-Path $outDir ("shot_{0}_{1}.png" -f $i, (Get-Date -Format "HHmmss"))
    Invoke-Adb -CmdArgs @("shell", "screencap", "-p", $remote) | Out-Null
    Invoke-Adb -CmdArgs @("pull", $remote, $local) | Out-Null
    Invoke-Adb -CmdArgs @("shell", "rm", "-f", $remote) | Out-Null
    if (Test-Path $local) { Info ("  第 {0} 张：{1}" -f $i, $local) }
    else { Info ("  第 {0} 张：截图失败" -f $i) }
    if ($i -lt $Shots) { Start-Sleep -Seconds $IntervalSec }
}

# ---------------------------------------------------------------- 日志
Info ""
Info "== 原生日志 =="
$logFile = Join-Path $outDir ("logcat_{0}.txt" -f (Get-Date -Format "HHmmss"))
$raw = Invoke-Adb -CmdArgs @("logcat", "-d", "-s",
    "PathGuideVision:V", "flutter:V", "AndroidRuntime:E", "*:S")
$raw | Out-File -Encoding utf8 $logFile

$ready = Select-String -Path $logFile -Pattern "模型就绪" -ErrorAction SilentlyContinue
if ($ready) {
    Info "模型加载日志："
    $ready | ForEach-Object { Info ("  " + $_.Line.Trim()) }
} else {
    Info "没抓到「模型就绪」日志——模型可能没加载成功，请看日志文件。"
}

# HUD 状态行（Dart 侧每秒打一行，见 demo_page.dart 的 _logHud）。
# 这是**无需看屏幕**就能判断整条链路是否打通的关键证据。
$hud = Select-String -Path $logFile -Pattern "HUD fps=" -ErrorAction SilentlyContinue
if ($hud) {
    Info ""
    Info ("HUD 状态行（共 {0} 条，显示最后 3 条）：" -f $hud.Count)
    $hud | Select-Object -Last 3 | ForEach-Object {
        $line = $_.Line
        if ($line -match "HUD fps=.*") { Info ("  " + $Matches[0]) }
    }
    # 收到 HUD 行但原生分析帧为 0 —— 这是最容易误判的一种情况，直接说清原因。
    $last = $hud[-1].Line
    if ($last -match "analyzed=0") {
        $st2 = Get-ScreenState
        Info ""
        Info "注意：Dart 收到了诊断，但原生分析帧数为 0（相机没有出帧）。"
        Info "      当前屏幕：唤醒=$($st2.Wakefulness) 亮屏=$($st2.ScreenOn)"
        Info "      若亮屏仍为 0，常见原因：相机被其他 App 占用、权限被系统回收、或设备进入省电限制。"
    }
} else {
    Info ""
    Info "没抓到 HUD 状态行——说明 Dart 侧一帧都没收到（EventChannel 或相机分析回路没跑起来）。"
}

$crashes = Select-String -Path $logFile -Pattern "FATAL EXCEPTION|AndroidRuntime" -ErrorAction SilentlyContinue
if ($crashes) { Info "日志里有崩溃记录，务必查看。" }

Write-Host ""
Write-Host "完成。产物在：$outDir" -ForegroundColor Green
Write-Host "截图与日志已就位，可以直接读图确认 HUD 上的 transposed / geo / 框数。"

