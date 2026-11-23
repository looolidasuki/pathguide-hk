#!/usr/bin/env pwsh
<#
.SYNOPSIS
  把本倉庫的 Android 專屬工作，冪等地疊加到「上游同步後」的 App 上。

.DESCRIPTION
  本倉庫的規矩：App 基線永遠跟上游（actiondarr/pathguide）走，我方只保留
  上游**明確沒有**的 Android 工作。每次同步上游，下面這些東西會被覆蓋或消失：

    新增檔（上游沒有）
      MenuPlugin.kt            菜單 OCR + 菜單語音查詢（ML Kit 中文）
      PathGuideTileService.kt   快速設定磁貼
      ic_qs_tile.xml            磁貼圖示
      file_paths.xml            FileProvider 路徑白名單
      values*/strings.xml       四語系 app_name / tile_label
      menu_platform_test.dart   菜單平台支援契約測試

    需要改上游檔案（多處編輯）
      MainActivity.kt           註冊菜單插件 + 轉發 onActivityResult
      AndroidManifest.xml       label 走 @string/app_name；磁貼 service；FileProvider
      build.gradle.kts          ML Kit text-recognition-chinese
      menu_reader.dart          supported 納入 Android
      menu_page.dart            第三方語音廠商名按平台（iOS=Apple / Android=Google）；不支援理由分讀字／菜單
      menu_ui_test.dart         廠商名映射測試
      MenuPlugin.kt             includeGeneral → 回傳 readingLines（上游 1.12 通用讀字）

    route_memory 的 Windows 相容（修程式、不跳測試；POSIX 上是 no-op）
      encrypted_route_store / route_learning_store：.lock 用路徑末段判斷、孤兒清理按平台分隔符比對

  冪等規則（可重複執行）：
    - 新增檔已存在           → 跳過（不覆蓋手改內容）
    - 「已套用」marker 存在   → 跳過
    - 錨點找不到             → 記為錯誤（上游改了那段程式，需人工確認）

  行尾自動跟隨目標檔案（CRLF / LF 都可以），不必手動統一。

.PARAMETER Check
  只檢查不修改：全部就緒 exit 0，有缺 exit 1（可當提交前／CI 門禁）。

.PARAMETER SourceRef
  新增檔從哪個 git 版本還原。預設是本倉庫最後一次同步的 tag。
  刻意用 git 而不是把內容寫死：新增檔只有一份事實源。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\apply_android_overlay.ps1 -Check
  powershell -ExecutionPolicy Bypass -File scripts\apply_android_overlay.ps1
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [string]$SourceRef = 'v1.12.1+31-android-sync.7'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$utf8 = New-Object System.Text.UTF8Encoding($false)
$LF = "`n"

$script:changed = 0
$script:skipped = 0
$script:errors = New-Object System.Collections.ArrayList

function Add-Err([string]$msg) { [void]$script:errors.Add($msg) }

# 把用 LF 拼好的多行字串，轉成目標檔案的實際行尾。
function Match-Eol([string]$text, [string]$s) {
    if ($text.Contains("`r`n")) { return ($s -replace "`r`n", "`n") -replace "`n", "`r`n" }
    return $s -replace "`r`n", "`n"
}

# ---------------------------------------------------------------- 新增檔還原
function Restore-OverlayFile([string]$rel) {
    $full = Join-Path $repo $rel
    if (Test-Path $full) { $script:skipped++; return }
    if ($Check) { $script:changed++; Write-Host "PENDING  restore  $rel"; return }
    $text = (& git show "${SourceRef}:$rel" 2>$null) -join $LF
    if ([string]::IsNullOrWhiteSpace($text)) {
        Add-Err "無法從 $SourceRef 還原 $rel（該 ref 沒有這個檔？）"
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
    [System.IO.File]::WriteAllText($full, $text + $LF, $utf8)
    $script:changed++
    Write-Host "RESTORED $rel（來自 $SourceRef）"
}

# ---------------------------------------------------------------- 單處補丁
# marker 必須是「新狀態」的字串（不能等於 anchor，否則套用後會被誤判為未套用）
function Patch-Overlay(
    [string]$rel,
    [string]$name,
    [string]$marker,
    [string]$anchor,
    [string]$replacement
) {
    $full = Join-Path $repo $rel
    if (-not (Test-Path $full)) { Add-Err "缺少檔案：$rel（$name）"; return }
    $text = [System.IO.File]::ReadAllText($full)

    $m = Match-Eol $text $marker
    if ($text.Contains($m)) { $script:skipped++; return }

    $a = Match-Eol $text $anchor
    $r = Match-Eol $text $replacement
    if (-not $text.Contains($a)) {
        Add-Err "錨點找不到：$name（$rel）。上游可能改了這段程式，請人工確認。"
        return
    }
    if ($Check) { $script:changed++; Write-Host "PENDING  patch    $name（$rel）"; return }
    [System.IO.File]::WriteAllText($full, $text.Replace($a, $r), $utf8)
    $script:changed++
    Write-Host "PATCHED  $name（$rel）"
}

# ================================================================ 1. 新增檔
$overlayFiles = @(
    'app/android/app/src/main/kotlin/hk/pathguide/pathguide/MenuPlugin.kt',
    'app/android/app/src/main/kotlin/hk/pathguide/pathguide/PathGuideTileService.kt',
    'app/android/app/src/main/res/drawable/ic_qs_tile.xml',
    'app/android/app/src/main/res/xml/file_paths.xml',
    'app/android/app/src/main/res/values/strings.xml',
    'app/android/app/src/main/res/values-zh-rCN/strings.xml',
    'app/android/app/src/main/res/values-zh-rHK/strings.xml',
    'app/android/app/src/main/res/values-zh-rTW/strings.xml',
    'app/test/menu_platform_test.dart',
    'app/test/android_back_test.dart',
    'app/android/app/src/main/kotlin/hk/pathguide/pathguide/CameraPreprocess.kt',
    'app/android/app/src/main/kotlin/hk/pathguide/pathguide/RouteCameraPlugin.kt',
    'app/android/app/src/main/kotlin/hk/pathguide/pathguide/RouteLandmarkPlugin.kt',
    'app/android/app/src/test/kotlin/hk/pathguide/pathguide/CameraPreprocessTest.kt',
    'app/assets/models/route_landmark_embedder.json',
    'app/assets/models/route_landmark_embedder.tflite',
    'app/lib/route_memory/route_camera_preview.dart',
    'app/lib/route_memory/route_platform_profile.dart',
    'app/test/route_android_profile_test.dart',
    'app/lib/tts/speech_latency.dart',
    'app/test/speech_latency_test.dart',
    'app/test/daily_detection_threshold_test.dart',
    'app/android/app/src/test/resources/camera_preprocess/cases.txt',
    'app/android/app/src/test/resources/camera_preprocess/down_r0.expected_f32le',
    'app/android/app/src/test/resources/camera_preprocess/down_r0.raw_rgb',
    'app/android/app/src/test/resources/camera_preprocess/down_r180.expected_f32le',
    'app/android/app/src/test/resources/camera_preprocess/down_r180.raw_rgb',
    'app/android/app/src/test/resources/camera_preprocess/down_r90.expected_f32le',
    'app/android/app/src/test/resources/camera_preprocess/down_r90.raw_rgb',
    'app/android/app/src/test/resources/camera_preprocess/up_r270.expected_f32le',
    'app/android/app/src/test/resources/camera_preprocess/up_r270.raw_rgb'
)
foreach ($f in $overlayFiles) { Restore-OverlayFile $f }

# ================================================================ 2. MainActivity
$mainAk = 'app/android/app/src/main/kotlin/hk/pathguide/pathguide/MainActivity.kt'
Patch-Overlay $mainAk 'MainActivity: import Intent' `
    'import android.content.Intent' `
    'import android.os.Bundle' `
    ('import android.content.Intent' + $LF + 'import android.os.Bundle')

Patch-Overlay $mainAk 'MainActivity: menuPlugin 欄位' `
    'private val menuPlugin by lazy { MenuPlugin(this) }' `
    'class MainActivity : FlutterActivity() {' `
    (@(
        'class MainActivity : FlutterActivity() {',
        '',
        '    /**',
        '     * 菜單插件需要 Activity 才能開系統相機／相簿，並接收回來的結果，',
        '     * 所以在這裡持有實例，由 [onActivityResult] 轉發。',
        '     */',
        '    private val menuPlugin by lazy { MenuPlugin(this) }'
    ) -join $LF)

Patch-Overlay $mainAk 'MainActivity: 註冊 menuPlugin' `
    'flutterEngine.plugins.add(menuPlugin)' `
    '        flutterEngine.plugins.add(SpeechInputPlugin())' `
    ('        flutterEngine.plugins.add(SpeechInputPlugin())' + $LF + '        flutterEngine.plugins.add(menuPlugin)')

Patch-Overlay $mainAk 'MainActivity: onActivityResult 轉發' `
    'if (!menuPlugin.onActivityResult(requestCode, resultCode, data)) {' `
    '    override fun onCreate(' `
    (@(
        '    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {',
        '        // 先問菜單插件（它只認自己的 requestCode），其餘照舊交回 Flutter。',
        '        if (!menuPlugin.onActivityResult(requestCode, resultCode, data)) {',
        '            super.onActivityResult(requestCode, resultCode, data)',
        '        }',
        '    }',
        '',
        '    override fun onCreate('
    ) -join $LF)

# ================================================================ 3. AndroidManifest
$manifest = 'app/android/app/src/main/AndroidManifest.xml'
Patch-Overlay $manifest 'manifest: label 走資源' `
    'android:label="@string/app_name"' `
    'android:label="領路通"' `
    'android:label="@string/app_name"'

$serviceBlock = @(
    '        <!-- 快速設定磁貼：全盲使用者唯一「兩秒內可達、不必回主頁」的啟動路徑。',
    '             下面三個屬性任何一個寫錯，磁貼都會靜默消失且系統不報錯。 -->',
    '        <service',
    '            android:name=".PathGuideTileService"',
    '            android:exported="true"',
    '            android:icon="@drawable/ic_qs_tile"',
    '            android:label="@string/tile_label"',
    '            android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">',
    '            <intent-filter>',
    '                <action android:name="android.service.quicksettings.action.QS_TILE" />',
    '            </intent-filter>',
    '        </service>',
    '        <!-- 菜單拍照用的暫存檔分享（系統相機寫入 cacheDir，讀完即刪） -->',
    '        <provider',
    '            android:name="androidx.core.content.FileProvider"',
    '            android:authorities="${applicationId}.fileprovider"',
    '            android:exported="false"',
    '            android:grantUriPermissions="true">',
    '            <meta-data',
    '                android:name="android.support.FILE_PROVIDER_PATHS"',
    '                android:resource="@xml/file_paths" />',
    '        </provider>',
    '        <meta-data',
    '            android:name="flutterEmbedding"'
) -join $LF
Patch-Overlay $manifest 'manifest: 磁貼 service + FileProvider' `
    '.PathGuideTileService' `
    ('        <meta-data' + $LF + '            android:name="flutterEmbedding"') `
    $serviceBlock

# ================================================================ 4. Gradle
$gradle = 'app/android/app/build.gradle.kts'
$mlkit = @(
    '    implementation("com.google.ai.edge.litert:litert:2.2.0")',
    '',
    '    // 菜單 OCR（Android）：ML Kit 中文文字辨識，模型隨 AAR 打包，離線可用。',
    '    // 為什麼是中文版而不是通用拉丁版：餐牌絕大多數是中文，而中文辨識器同時支援拉丁字元。',
    '    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")'
) -join $LF
Patch-Overlay $gradle 'gradle: ML Kit 中文辨識' `
    'text-recognition-chinese:16.0.1' `
    '    implementation("com.google.ai.edge.litert:litert:2.2.0")' `
    $mlkit

# ================================================================ 5. menu_reader
$reader = 'app/lib/menu/menu_reader.dart'
Patch-Overlay $reader 'menu_reader: supported 納入 Android' `
    'TargetPlatform.android);' `
    '  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;' `
    (@(
        '  // Android 有原生實作（MenuPlugin.kt，ML Kit 中文辨識）。',
        '  // Android 版目前是單頁、走系統相機／相簿，ML Kit 不提供逐行置信度。',
        '  bool get supported =>',
        '      !kIsWeb &&',
        '      (defaultTargetPlatform == TargetPlatform.iOS ||',
        '          defaultTargetPlatform == TargetPlatform.android);'
    ) -join $LF)

Patch-Overlay $reader 'menu_reader: 不支援時說明' `
    '菜單閱讀目前支援 iPhone 與 Android。' `
    "if (!supported) throw const MenuFailure('菜單閱讀目前先支援 iPhone。');" `
    "if (!supported) throw const MenuFailure('菜單閱讀目前支援 iPhone 與 Android。');"

# ================================================================ 6. menu_page
$page = 'app/lib/menu/menu_page.dart'
Patch-Overlay $page 'menu_page: 引入 foundation' `
    "import 'package:flutter/foundation.dart' show defaultTargetPlatform;" `
    "import 'package:flutter/material.dart';" `
    ("import 'package:flutter/foundation.dart' show defaultTargetPlatform;" + $LF + "import 'package:flutter/material.dart';")

$vendorFn = @(
    '',
    '/// 線上語音是哪一家（**廠商名**，讓句子自然接上「的線上語音服務」）。',
    '///',
    '/// 隱私說明必須點對名字：iOS 走 Apple 的語音服務，Android 走 Google 的。',
    '///',
    '/// 抽成頂層函數是為了可測：widget 測試若臨時改 debugDefaultTargetPlatformOverride，',
    '/// 必須在測試體內復位（flutter_test 會在測試體尾檢查），很容易漏；',
    '/// 純函數版本可以三個分支直接斷言。',
    '@visibleForTesting',
    'String onlineVoiceVendorFor(TargetPlatform platform) => switch (platform) {',
    "  TargetPlatform.iOS => 'Apple',",
    "  TargetPlatform.android => 'Google',",
    "  _ => '系統',",
    '};'
) -join $LF
Patch-Overlay $page 'menu_page: 廠商名純函數' `
    'String onlineVoiceVendorFor(TargetPlatform platform)' `
    "import 'menu_reader.dart';" `
    ("import 'menu_reader.dart';" + $LF + $vendorFn)

Patch-Overlay $page 'menu_page: 標題用廠商名' `
    '_onlineVoiceVendor()} 線上語音搜尋？' `
    "          title: const AppText('使用 Apple 線上語音搜尋？')," `
    "          title: AppText('使用 `$("${_onlineVoiceVendor()}") 線上語音搜尋？'),"

Patch-Overlay $page 'menu_page: 內容用廠商名' `
    '_onlineVoiceVendor()} 的線上語音服務處理' `
    "            '這部手機未提供離線粵語辨識。選擇繼續後，這次錄音可能由 Apple 的線上語音服務處理，需要網絡。菜單照片不會傳送到該服務。你亦可取消，直接輸入菜式。'," `
    "            '這部手機未提供離線粵語辨識。選擇繼續後，這次錄音可能由 `$("${_onlineVoiceVendor()}") 的線上語音服務處理，需要網絡。菜單照片不會傳送到該服務。你亦可取消，直接輸入菜式。',"

Patch-Overlay $page 'menu_page: 內容移除 const' `
    '          content: AppText(' `
    ('          content: const AppText(' + $LF + "            '這部手機未提供離線粵語辨識") `
    ('          content: AppText(' + $LF + "            '這部手機未提供離線粵語辨識")

# 上游 1.12.1+31 起此處按 widget.generalReading 分「讀字／菜單」兩句（仍只講 iPhone）。
$unsupportedAnchor = @(
    '              AppText(',
    '                widget.generalReading',
    "                    ? '閱讀文字支援 iOS 16 或以上的 iPhone。'",
    "                    : '本輪菜單閱讀先支援 iPhone，繁體中文辨識需要 iOS 16 或以上。',",
    '              ),'
) -join $LF
Patch-Overlay $page 'menu_page: 不支援時的理由' `
    'AppText(_unsupportedReason(widget.generalReading))' `
    $unsupportedAnchor `
    '              AppText(_unsupportedReason(widget.generalReading)),'

$helpers = @(
    '  /// 線上語音廠商名的內部入口。',
    '  static String _onlineVoiceVendor() => onlineVoiceVendorFor(defaultTargetPlatform);',
    '',
    '  /// 這個平台不支援菜單／讀字時，要說出為什麼與在哪些平台可用。',
    '  static String _unsupportedReason(bool generalReading) =>',
    '      switch (defaultTargetPlatform) {',
    '    TargetPlatform.iOS => generalReading',
    "        ? '閱讀文字支援 iOS 16 或以上的 iPhone。'",
    "        : '菜單閱讀在 iPhone 需要 iOS 16 或以上。',",
    "    TargetPlatform.android => '這部 Android 裝置未提供可用的文字辨識服務。',",
    "    _ => '文字及菜單閱讀目前支援 iPhone 與 Android。',",
    '  };',
    ''
) -join $LF
Patch-Overlay $page 'menu_page: 兩個 helper' `
    'static String _unsupportedReason(' `
    '  void _search() {' `
    ($helpers + '  void _search() {')

# ================================================================ 7. menu_ui_test
$uiTest = 'app/test/menu_ui_test.dart'
Patch-Overlay $uiTest 'menu_ui_test: 引入 foundation' `
    'show TargetPlatform, defaultTargetPlatform;' `
    "import 'package:flutter/rendering.dart';" `
    ("import 'package:flutter/foundation.dart'" + $LF + "    show TargetPlatform, defaultTargetPlatform;" + $LF + "import 'package:flutter/rendering.dart';")

Patch-Overlay $uiTest 'menu_ui_test: 用當前平台廠商名斷言' `
    'final vendor = onlineVoiceVendorFor(defaultTargetPlatform);' `
    "    expect(find.text('使用 Apple 線上語音搜尋？'), findsOneWidget);" `
    (@(
        '    // 斷言用當前平台的廠商名：臨時改 debugDefaultTargetPlatformOverride',
        '    // 必須在測試體內復位，漏了會被 flutter_test 的 invariant 檢查抓到。',
        '    final vendor = onlineVoiceVendorFor(defaultTargetPlatform);',
        "    expect(find.text('使用 `$vendor 線上語音搜尋？'), findsOneWidget);"
    ) -join $LF)

$vendorTest = @(
    "  test('★ 線上語音的廠商名：iOS=Apple、Android=Google、其餘=系統', () {",
    '    // 隱私說明必須點對第三方服務：寫錯等於在錄音用途上騙人。',
    "    expect(onlineVoiceVendorFor(TargetPlatform.iOS), 'Apple');",
    "    expect(onlineVoiceVendorFor(TargetPlatform.android), 'Google');",
    "    expect(onlineVoiceVendorFor(TargetPlatform.linux), '系統');",
    '  });',
    '',
    'void main() {'
) -join $LF
Patch-Overlay $uiTest 'menu_ui_test: 廠商名三分支測試' `
    '線上語音的廠商名：iOS=Apple' `
    ('void main() {' + $LF) `
    $vendorTest
# ================================================================ 8. route_memory 的 Windows 相容
#
# 都是「上游在 macOS／POSIX 看不到、Windows 上必炸」的類型；修程式，不跳測試。
# 改動在 POSIX（Android／iOS）上都是 no-op。
#
# (a) 鎖檔判斷用 `f.path.endsWith('/.lock')`，但 Windows 的 path 用反斜線，
#     於是鎖檔被當成「已有資料但沒有金鑰」→ 每次開檔都 keyUnavailable。
#     encrypted_route_store（1.8.0 起）與 route_learning_store（1.12 新增）各有一處。
#
# (b) 孤兒清理用 '/' 拼出「要保留的路徑」，再和 Directory.list 的路徑比對；
#     Windows 列出的是反斜線路徑 → 要保留的紀錄與 .lock 全被當孤兒刪除。
#     （2026-11-22 查證：之前 Windows 上跳過的 8 條測試，真正原因是這個，
#      不是「Windows 無法刪除已打開的 .lock」；修好後全部可在 Windows 通過，跳過已撤銷。）
$storeFile = 'app/lib/route_memory/encrypted_route_store.dart'
Patch-Overlay $storeFile 'route_store: .lock 用路徑末段判斷' `
    "name != '.lock'" `
    "          if (f is File && !f.path.endsWith('/.lock')) {" `
    (@(
        '          // ★ 用路徑的**最後一段**判斷，不要比對 ''/.lock''：',
        '          //   Windows 的 File.path 用反斜線，''...\.lock''.endsWith(''/.lock'') 恆為 false，',
        '          //   於是鎖檔會被當成「已有資料但沒有金鑰」，每次開檔都丟 keyUnavailable。',
        '          //   這個 bug 只在非 POSIX 平台出現，Android／iOS 都看不到。',
        '          final name = f.uri.pathSegments.isEmpty',
        '              ? ""',
        '              : f.uri.pathSegments.last;',
        '          if (f is File && name != ''.lock'') {'
    ) -join $LF)

$learningFile = 'app/lib/route_memory/route_learning_store.dart'
Patch-Overlay $learningFile 'learning_store: .lock 用路徑末段判斷' `
    "e.uri.pathSegments.where((s) => s.isNotEmpty).last != '.lock'" `
    "          if (await directory.list().any((e) => !e.path.endsWith('/.lock'))) {" `
    (@(
        '          // ★ 用路徑的**最後一段**判斷，不要比對 ''/.lock''（同 encrypted_route_store）：',
        '          //   Windows 的 path 用反斜線，鎖檔會被誤判成「有資料但沒有金鑰」。',
        '          if (await directory.list().any((e) =>',
        '              e.uri.pathSegments.where((s) => s.isNotEmpty).last != ''.lock'')) {'
    ) -join $LF)

$orphanAnchor = @(
    '    await for (final f in directory.list(recursive: true, followLinks: false)) {',
    '      if (f is File && !keep.contains(f.path)) await f.delete();'
) -join $LF
$orphanFix = @(
    '    // ★ keep 用 ''/'' 拼路徑，但 Windows 的 Directory.list 回傳反斜線路徑；',
    '    //   直接比對會把要保留的紀錄與 .lock 都當孤兒刪掉。POSIX（Android／iOS）上這是 no-op。',
    '    final keepNative = {',
    '      for (final k in keep) k.replaceAll(''/'', Platform.pathSeparator),',
    '    };',
    '    await for (final f in directory.list(recursive: true, followLinks: false)) {',
    '      if (f is File && !keepNative.contains(f.path)) await f.delete();'
) -join $LF
Patch-Overlay $storeFile 'route_store: 孤兒清理按平台分隔符比對' `
    'final keepNative = {' $orphanAnchor $orphanFix
Patch-Overlay $learningFile 'learning_store: 孤兒清理按平台分隔符比對' `
    'final keepNative = {' $orphanAnchor $orphanFix

# ================================================================ 9. 2026-11-22 真機崩潰修正
#
# (a) VisionPlugin：推理中 release → interpreter.close() → SIGSEGV；推理與釋放互斥。
# (b) menu_page：Android 相機返回時回前景途中的 hidden 被當成離開 → 取消辨識，
#     MenuPlugin 重複回覆而崩潰；回前景途中的 hidden 不再走「離開」分支。
#     （MenuPlugin.kt 的「只回覆當前請求」守衛隨新增檔由 SourceRef 還原。）
# 錨點自動含足夠上下文以保證唯一；marker 取舊檔不存在的最長新行。

Patch-Overlay 'app/android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt' 'VisionPlugin: 真機修正 1' `
    '* 離開辨識頁時 `release` 會先停相機再 [close]，但 `cameraExecutor.shutdown()`' `
    (@(
    '    val isBusy: Boolean get() = busy',
    '',
    '    /**'
) -join $LF) `
    (@(
    '    val isBusy: Boolean get() = busy',
    '',
    '    /**',
    '     * 推理與釋放互斥。',
    '     *',
    '     * 離開辨識頁時 `release` 會先停相機再 [close]，但 `cameraExecutor.shutdown()`',
    '     * **不會等正在跑的那一幀**（每幀約 0.5 秒）。若此時直接 `interpreter.close()`，',
    '     * 後台線程上的 `interpreter.run()` 會讀到已釋放的原生記憶體 → SIGSEGV',
    '     * （2026-11-22 真機實測：辨識中按返回 3/3 崩潰）。',
    '     *',
    '     * 做法：[close] 只在沒有推理時立即釋放；否則標記 [closed]，',
    '     * 由那一幀結束時負責釋放。不在主線程上等推理完成，避免卡頓。',
    '     */',
    '    private val lifecycleLock = Any()',
    '    private var closed = false',
    '',
    '    /**'
) -join $LF)

Patch-Overlay 'app/android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt' 'VisionPlugin: 真機修正 2' `
    'if (!busy) runCatching { interpreter.close() }' `
    (@(
    '    fun close() {',
    '        runCatching { interpreter.close() }'
) -join $LF) `
    (@(
    '    fun close() {',
    '        synchronized(lifecycleLock) {',
    '            if (closed) return',
    '            closed = true',
    '            if (!busy) runCatching { interpreter.close() }',
    '        }'
) -join $LF)

Patch-Overlay 'app/android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt' 'VisionPlugin: 真機修正 3' `
    'if (closed || busy) return emptyList()' `
    (@(
    '    ): List<Detection> {',
    '        if (busy) return emptyList()',
    '        busy = true'
) -join $LF) `
    (@(
    '    ): List<Detection> {',
    '        synchronized(lifecycleLock) {',
    '            if (closed || busy) return emptyList()',
    '            busy = true',
    '        }'
) -join $LF)

Patch-Overlay 'app/android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt' 'VisionPlugin: 真機修正 4' `
    'if (closed) runCatching { interpreter.close() }' `
    (@(
    '        } finally {',
    '            busy = false'
) -join $LF) `
    (@(
    '        } finally {',
    '            synchronized(lifecycleLock) {',
    '                busy = false',
    '                // 推理途中被 close()：由最後一幀負責釋放原生資源。',
    '                if (closed) runCatching { interpreter.close() }',
    '            }'
) -join $LF)

Patch-Overlay 'app/lib/menu/menu_page.dart' 'menu_page: 真機修正 1' `
    'AppLifecycleState? _lastLifecycle;' `
    '  bool _speaking = false, _outputBusy = false, _foreground = true;' `
    (@(
    '  bool _speaking = false, _outputBusy = false, _foreground = true;',
    '  AppLifecycleState? _lastLifecycle;'
) -join $LF)

Patch-Overlay 'app/lib/menu/menu_page.dart' 'menu_page: 真機修正 2' `
    '// Flutter 回前景時會依序經過 paused → hidden → inactive → resumed。' `
    '  void didChangeAppLifecycleState(AppLifecycleState state) {' `
    (@(
    '  void didChangeAppLifecycleState(AppLifecycleState state) {',
    '    // Flutter 回前景時會依序經過 paused → hidden → inactive → resumed。',
    '    // 這個 hidden 是「正在回來」而不是「正在離開」。Android 系統相機返回時，',
    '    // 原生端在 Flutter 回前景前已開始辨識（狀態不再是 acquiring），',
    '    // 若把它當成離開而取消或清空待讀結果，辨識結果會被丟棄（2026-11-22 真機實測）。',
    '    final returning =',
    '        state == AppLifecycleState.hidden &&',
    '        _lastLifecycle == AppLifecycleState.paused;',
    '    _lastLifecycle = state;'
) -join $LF)

Patch-Overlay 'app/lib/menu/menu_page.dart' 'menu_page: 真機修正 3' `
    'state == AppLifecycleState.hidden)) {' `
    (@(
    '      // An iOS permission sheet uses inactive. Keep its eventual response until resumed.',
    '      if (state == AppLifecycleState.paused ||',
    '          state == AppLifecycleState.detached ||',
    '          state == AppLifecycleState.hidden) {'
) -join $LF) `
    (@(
    '      // An iOS permission sheet uses inactive. Keep its eventual response until resumed.',
    '      if (!returning &&',
    '          (state == AppLifecycleState.paused ||',
    '              state == AppLifecycleState.detached ||',
    '              state == AppLifecycleState.hidden)) {'
) -join $LF)

Patch-Overlay 'app/test/support/fake_menu.dart' 'fake_menu: 真機修正 1' `
    '/// 原生端（onActivityResult）在 Flutter 回前景**之前**就開始辨識的時序。' `
    '  bool notifyRecognizing = true;' `
    (@(
    '  bool notifyRecognizing = true;',
    '',
    '  /// 設定後，`onRecognizing` 要等它完成才觸發：模擬 Android 系統相機返回時',
    '  /// 原生端（onActivityResult）在 Flutter 回前景**之前**就開始辨識的時序。',
    '  Future<void>? recognizingGate;'
) -join $LF)

Patch-Overlay 'app/test/support/fake_menu.dart' 'fake_menu: 真機修正 2' `
    'if (recognizingGate != null) await recognizingGate;' `
    '    if (readError != null) throw readError!;' `
    (@(
    '    if (readError != null) throw readError!;',
    '    if (recognizingGate != null) await recognizingGate;'
) -join $LF)

Patch-Overlay 'app/test/menu_ui_test.dart' 'menu_ui_test: 真機修正 1' `
    '''Android camera return: recognizing starts before resume and is not cancelled'',' `
    (@(
    '      expect(find.byKey(const ValueKey(''voice-menu-search'')), findsOneWidget);',
    '      await tester.pumpWidget(const SizedBox());',
    '    },',
    '  );'
) -join $LF) `
    (@(
    '      expect(find.byKey(const ValueKey(''voice-menu-search'')), findsOneWidget);',
    '      await tester.pumpWidget(const SizedBox());',
    '    },',
    '  );',
    '  testWidgets(',
    '    ''Android camera return: recognizing starts before resume and is not cancelled'',',
    '    (tester) async {',
    '      // 2026-11-22 真機：Android 在 Flutter 回前景前就回調 onActivityResult 並開始辨識；',
    '      // 回前景途中的 hidden 若被當成「離開」，會取消辨識並令原生端重複回覆而崩潰。',
    '      final gate = Completer<void>();',
    '      final wait = Completer<MenuDocument?>();',
    '      final reader = FakeMenuReader()',
    '        ..recognizingGate = gate.future',
    '        ..readFuture = wait.future;',
    '      final speaker = MenuTestSpeaker();',
    '      await open(tester, reader, speaker);',
    '      await tester.tap(find.byKey(const ValueKey(''capture-menu'')));',
    '      await tester.pump();',
    '      final before = reader.cancels;',
    '      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);',
    '      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);',
    '      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);',
    '      await tester.pump();',
    '      gate.complete();',
    '      await tester.pump();',
    '      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);',
    '      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);',
    '      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);',
    '      wait.complete(sampleMenu());',
    '      await tester.pumpAndSettle();',
    '      expect(reader.cancels, before);',
    '      expect(find.byKey(const ValueKey(''voice-menu-search'')), findsOneWidget);',
    '      await tester.pumpWidget(const SizedBox());',
    '    },',
    '  );'
) -join $LF)

# ================================================================ 10. 2026-11-22 Android 系統返回鍵
#
# AppShell 以狀態切頁、未接住系統返回 → 任何任務頁按返回都直接離開 App（TalkBack 受影響）。
# PopScope：只有首頁交還系統；其他頁與左上角返回箭頭做同一件事。測試見 test/android_back_test.dart（新增檔）。
# 以整塊替換（返回邏輯方法、整個 build()），避免逐行縮排差異造成誤判。

Patch-Overlay 'app/lib/ui/app_shell.dart' 'app_shell: 系統返回邏輯' `
    'void _systemBack() {' `
    (@(
    '  void _openAccount() => setState(() => _accountVisible = true);',
    '',
    '  Widget _page() =>'
) -join $LF) `
    (@(
    '  void _openAccount() => setState(() => _accountVisible = true);',
    '',
    '  bool get _overlayVisible =>',
    '      _accountVisible ||',
    '      _menuVisible ||',
    '      _graphVisible ||',
    '      _depthVisible ||',
    '      _routeMemoryVisible;',
    '',
    '  /// 只有首頁（且沒有開著的覆蓋頁）才把系統返回交還系統、離開 App。',
    '  bool get _atRoot => _section == AppSection.home && !_overlayVisible;',
    '',
    '  /// Android 系統返回／返回手勢：與頁面左上角返回箭頭做同一件事。',
    '  ///',
    '  /// 各頁以狀態切換、不在 Navigator 路由棧上，未接住時系統返回會直接離開 App',
    '  /// （2026-11-22 真機實測；TalkBack 使用者常用返回手勢）。覆蓋頁先關，',
    '  /// 再按頁面層級退一層；戶外導航進行中仍經 [_select] 先確認是否結束。',
    '  void _systemBack() {',
    '    if (_routeMemoryVisible) {',
    '      setState(() => _routeMemoryVisible = false);',
    '    } else if (_depthVisible) {',
    '      setState(() => _depthVisible = false);',
    '    } else if (_graphVisible) {',
    '      setState(() => _graphVisible = false);',
    '    } else if (_menuVisible) {',
    '      setState(() => _menuVisible = false);',
    '    } else if (_accountVisible) {',
    '      setState(() => _accountVisible = false);',
    '    } else {',
    '      final parent = switch (_section) {',
    '        AppSection.home => null,',
    '        AppSection.explore => AppSection.home,',
    '        AppSection.navigation => AppSection.home,',
    '        AppSection.outdoor => AppSection.navigation,',
    '        AppSection.settings => AppSection.home,',
    '        AppSection.developer => AppSection.settings,',
    '        AppSection.visionDiagnostics => AppSection.developer,',
    '      };',
    '      if (parent != null) _select(parent);',
    '    }',
    '  }',
    '',
    '  Widget _page() =>'
) -join $LF)

Patch-Overlay 'app/lib/ui/app_shell.dart' 'app_shell: build 包 PopScope' `
    'onPopInvokedWithResult: (didPop, _) {' `
    (@(
    '  @override',
    '  Widget build(BuildContext context) {',
    '    return Scaffold(',
    '      // Dispose the outgoing camera immediately. An AnimatedSwitcher would',
    '      // keep it alive (and potentially speaking) during its exit animation.',
    '      body: KeyedSubtree(',
    '        key: ValueKey(',
    '          _routeMemoryVisible',
    '              ? ''route-memory-mock''',
    '              : _depthVisible',
    '              ? ''depth''',
    '              : _graphVisible',
    '              ? ''graph-replay''',
    '              : _menuVisible',
    '              ? ''menu''',
    '              : _accountVisible',
    '              ? ''account''',
    '              : _section,',
    '        ),',
    '        child: _routeMemoryVisible',
    '            ? RouteMemoryMockPage(',
    '                controller: _routeMemory,',
    '                settings: widget.settings,',
    '                onBack: () => setState(() => _routeMemoryVisible = false),',
    '              )',
    '            : _depthVisible',
    '            ? DepthPage(',
    '                settings: widget.settings,',
    '                onBack: () => setState(() => _depthVisible = false),',
    '              )',
    '            : _graphVisible',
    '            ? GraphReplayPage(',
    '                settings: widget.settings,',
    '                onBack: () => setState(() => _graphVisible = false),',
    '              )',
    '            : _menuVisible',
    '            ? MenuPage(',
    '                generalReading: true,',
    '                settings: widget.settings,',
    '                onBack: () => setState(() => _menuVisible = false),',
    '              )',
    '            : _accountVisible',
    '            ? AccountPage(onBack: () => setState(() => _accountVisible = false))',
    '            : _page(),',
    '      ),',
    '    );',
    '  }'
) -join $LF) `
    (@(
    '  @override',
    '  Widget build(BuildContext context) {',
    '    return PopScope(',
    '      canPop: _atRoot,',
    '      onPopInvokedWithResult: (didPop, _) {',
    '        if (!didPop) _systemBack();',
    '      },',
    '      child: Scaffold(',
    '        // Dispose the outgoing camera immediately. An AnimatedSwitcher would',
    '        // keep it alive (and potentially speaking) during its exit animation.',
    '        body: KeyedSubtree(',
    '          key: ValueKey(',
    '            _routeMemoryVisible',
    '                ? ''route-memory-mock''',
    '                : _depthVisible',
    '                ? ''depth''',
    '                : _graphVisible',
    '                ? ''graph-replay''',
    '                : _menuVisible',
    '                ? ''menu''',
    '                : _accountVisible',
    '                ? ''account''',
    '                : _section,',
    '          ),',
    '          child: _routeMemoryVisible',
    '              ? RouteMemoryMockPage(',
    '                  controller: _routeMemory,',
    '                  settings: widget.settings,',
    '                  onBack: () => setState(() => _routeMemoryVisible = false),',
    '                )',
    '              : _depthVisible',
    '              ? DepthPage(',
    '                  settings: widget.settings,',
    '                  onBack: () => setState(() => _depthVisible = false),',
    '                )',
    '              : _graphVisible',
    '              ? GraphReplayPage(',
    '                  settings: widget.settings,',
    '                  onBack: () => setState(() => _graphVisible = false),',
    '                )',
    '              : _menuVisible',
    '              ? MenuPage(',
    '                  generalReading: true,',
    '                  settings: widget.settings,',
    '                  onBack: () => setState(() => _menuVisible = false),',
    '                )',
    '              : _accountVisible',
    '              ? AccountPage(',
    '                  onBack: () => setState(() => _accountVisible = false),',
    '                )',
    '              : _page(),',
    '        ),',
    '      ),',
    '    );',
    '  }'
) -join $LF)

# ================================================================ 11. 2026-11-23 Android 錄路與檢測前處理
#
# (a) 錄路（FR3）：RouteCameraPlugin／RouteLandmarkPlugin（新增檔）與 Dart 平台配置
#     route_platform_profile.dart（新增檔）；共享 Dart 的 iOS 寫死值改按平台取。
# (b) 檢測前處理：CameraPreprocess（新增檔，JVM 對照測試）取代最近一點取樣＋限幅 YUV。
# 補丁自動產生（相近改動合併成整塊）；每段以自身替換文字作「已套用」標記，一對一不互相遮蔽。

Patch-Overlay 'app/android/app/build.gradle.kts' 'build.gradle.kts: 錄路／前處理 1' `
    (@(
    '    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")',
    '',
    '    // 原生純邏輯的 JVM 單元測試（例：CameraPreprocessTest 與離線 OpenCV 逐像素對照）。',
    '    testImplementation("junit:junit:4.13.2")'
) -join $LF) `
    '    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")' `
    (@(
    '    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")',
    '',
    '    // 原生純邏輯的 JVM 單元測試（例：CameraPreprocessTest 與離線 OpenCV 逐像素對照）。',
    '    testImplementation("junit:junit:4.13.2")'
) -join $LF)

Patch-Overlay 'app/android/app/src/main/kotlin/hk/pathguide/pathguide/MainActivity.kt' 'MainActivity.kt: 錄路／前處理 1' `
    (@(
    '        flutterEngine.plugins.add(menuPlugin)',
    '        // 室內錄路（Android）：相機關鍵幀與路標特徵，對應 iOS 的 RouteCamera／RouteLandmark。',
    '        flutterEngine.plugins.add(RouteCameraPlugin(this))',
    '        flutterEngine.plugins.add(RouteLandmarkPlugin(this))'
) -join $LF) `
    '        flutterEngine.plugins.add(menuPlugin)' `
    (@(
    '        flutterEngine.plugins.add(menuPlugin)',
    '        // 室內錄路（Android）：相機關鍵幀與路標特徵，對應 iOS 的 RouteCamera／RouteLandmark。',
    '        flutterEngine.plugins.add(RouteCameraPlugin(this))',
    '        flutterEngine.plugins.add(RouteLandmarkPlugin(this))'
) -join $LF)

Patch-Overlay 'app/android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt' 'VisionPlugin.kt: 錄路／前處理 1' `
    (@(
    '            // 两者不一致正是「色度取错、画面变灰」那类缺陷的来源。',
    '            lastFrameFormat = "YUV420 $fmt uvPlane=${uPlane.rowStride}/${uPlane.pixelStride} uvCopy=$cw " +',
    '                "fullRange=${YoloDetector.CAMERA_FULL_RANGE} ${det.lumaRange} " +',
    '                "pre=%.1fms infer=%.1fms".format(det.lastPreprocessMs, det.lastInferenceMs)',
    '            // 每 30 幀記一次，供 adb logcat 讀取前處理／推理耗時與 Y 範圍（全範圍佐證）。',
    '            if (analyzedFrames % 30 == 0L) Log.i(TAG, "幀格式 $lastFrameFormat")'
) -join $LF) `
    (@(
    '            // 两者不一致正是「色度取错、画面变灰」那类缺陷的来源。',
    '            lastFrameFormat = "YUV420 $fmt uvPlane=${uPlane.rowStride}/${uPlane.pixelStride} uvCopy=$cw"'
) -join $LF) `
    (@(
    '            // 两者不一致正是「色度取错、画面变灰」那类缺陷的来源。',
    '            lastFrameFormat = "YUV420 $fmt uvPlane=${uPlane.rowStride}/${uPlane.pixelStride} uvCopy=$cw " +',
    '                "fullRange=${YoloDetector.CAMERA_FULL_RANGE} ${det.lumaRange} " +',
    '                "pre=%.1fms infer=%.1fms".format(det.lastPreprocessMs, det.lastInferenceMs)',
    '            // 每 30 幀記一次，供 adb logcat 讀取前處理／推理耗時與 Y 範圍（全範圍佐證）。',
    '            if (analyzedFrames % 30 == 0L) Log.i(TAG, "幀格式 $lastFrameFormat")'
) -join $LF)

Patch-Overlay 'app/android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt' 'VisionPlugin.kt: 錄路／前處理 2' `
    (@(
    '        const val PAD = 114',
    '',
    '        /**',
    '         * 相機 YUV_420_888 視為 JFIF 全範圍 BT.601（Android 相機慣例）。',
    '         * 真機以 [lumaRange]（Y 的實際最小／最大值）佐證：限幅範圍資料不會低於 16 或高於 235。',
    '         */',
    '        const val CAMERA_FULL_RANGE = true',
    '',
    '        /**'
) -join $LF) `
    (@(
    '        const val PAD = 114',
    '',
    '        /**'
) -join $LF) `
    (@(
    '        const val PAD = 114',
    '',
    '        /**',
    '         * 相機 YUV_420_888 視為 JFIF 全範圍 BT.601（Android 相機慣例）。',
    '         * 真機以 [lumaRange]（Y 的實際最小／最大值）佐證：限幅範圍資料不會低於 16 或高於 235。',
    '         */',
    '        const val CAMERA_FULL_RANGE = true',
    '',
    '        /**'
) -join $LF)

Patch-Overlay 'app/android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt' 'VisionPlugin.kt: 錄路／前處理 3' `
    (@(
    '    @Volatile var lastInferenceMs: Double = 0.0',
    '        private set',
    '',
    '    /** 前處理（YUV→RGB＋letterbox）耗時，與推理時間分開記。 */',
    '    @Volatile var lastPreprocessMs: Double = 0.0',
    '        private set',
    '',
    '    /** 最近一幀 Y 平面的實際範圍，用來佐證相機是全範圍 YUV。 */',
    '    @Volatile var lumaRange: String = ""',
    '        private set',
    '',
    '    // 只在推理線程使用（detectYuv 已以 busy 互斥）。',
    '    private var rgbScratch: FloatArray? = null',
    '    private val inputArray: FloatArray by lazy { FloatArray(inputSize * inputSize * 3) }'
) -join $LF) `
    (@(
    '    @Volatile var lastInferenceMs: Double = 0.0',
    '        private set'
) -join $LF) `
    (@(
    '    @Volatile var lastInferenceMs: Double = 0.0',
    '        private set',
    '',
    '    /** 前處理（YUV→RGB＋letterbox）耗時，與推理時間分開記。 */',
    '    @Volatile var lastPreprocessMs: Double = 0.0',
    '        private set',
    '',
    '    /** 最近一幀 Y 平面的實際範圍，用來佐證相機是全範圍 YUV。 */',
    '    @Volatile var lumaRange: String = ""',
    '        private set',
    '',
    '    // 只在推理線程使用（detectYuv 已以 busy 互斥）。',
    '    private var rgbScratch: FloatArray? = null',
    '    private val inputArray: FloatArray by lazy { FloatArray(inputSize * inputSize * 3) }'
) -join $LF)

Patch-Overlay 'app/android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt' 'VisionPlugin.kt: 錄路／前處理 4' `
    (@(
    '        try {',
    '            // ★ 前處理與離線評估／iOS 逐項對齊（見 CameraPreprocess 與其 JVM 對照測試）：',
    '            //   全範圍 BT.601 YUV→RGB、四捨五入（.5 取偶）尺寸、半像素雙線性、114 填充。',
    '            //   舊版「最近一點 + 限幅範圍公式」不報錯，只會令輸入偏離訓練分佈。',
    '            check(uvWidth == (frameWidth + 1) / 2) { "uvWidth=$uvWidth frame=$frameWidth" }',
    '            val tPre = System.nanoTime()',
    '            var yMin = 255',
    '            var yMax = 0',
    '            for (i in 0 until frameWidth * frameHeight) {',
    '                val value = y[i].toInt() and 0xFF',
    '                if (value < yMin) yMin = value',
    '                if (value > yMax) yMax = value',
    '            }',
    '            lumaRange = "Y[$yMin,$yMax]"',
    '            val rgbSize = frameWidth * frameHeight * 3',
    '            val rgb = rgbScratch?.takeIf { it.size == rgbSize } ?: FloatArray(rgbSize).also { rgbScratch = it }',
    '            CameraPreprocess.yuvToRgb(y, u, v, frameWidth, frameHeight, CAMERA_FULL_RANGE, rgb)',
    '            val geometry = CameraPreprocess.letterbox(',
    '                rgb, frameWidth, frameHeight, rotationDegrees, inputSize, channelsFirstInput, inputArray,',
    '            )',
    '            inputBuffer.rewind()',
    '            inputFloats.clear()',
    '            inputFloats.put(inputArray)',
    '            inputFloats.rewind()',
    '            inputBuffer.rewind()',
    '            lastPreprocessMs = (System.nanoTime() - tPre) / 1_000_000.0',
    '            val srcW = geometry.uprightWidth',
    '            val srcH = geometry.uprightHeight',
    '            val newW = geometry.scaledWidth',
    '            val newH = geometry.scaledHeight',
    '            val padX = geometry.padX',
    '            val padY = geometry.padY'
) -join $LF) `
    (@(
    '        try {',
    '            val rot = ((rotationDegrees % 360) + 360) % 360',
    '            val swap = rot == 90 || rot == 270',
    '            val srcW = if (swap) frameHeight else frameWidth',
    '            val srcH = if (swap) frameWidth else frameHeight',
    '',
    '            val scale = min(inputSize.toFloat() / srcW, inputSize.toFloat() / srcH)',
    '            val newW = (srcW * scale).toInt().coerceAtLeast(1)',
    '            val newH = (srcH * scale).toInt().coerceAtLeast(1)',
    '            val padX = (inputSize - newW) / 2',
    '            val padY = (inputSize - newH) / 2',
    '',
    '            inputBuffer.rewind()',
    '            // ★ 先用 letterbox 填充色铺满整个输入，再写入真实像素。',
    '            //',
    '            // 训练时 Ultralytics 用 114/255 ≈ 0.447 的灰边填充；如果这里留 0（黑边），',
    '            // 填充区域与训练分布不一致，会拉低置信度。这一点与「灰度输入」是同一类',
    '            // 问题：预处理必须和训练时逐项对齐，差一项都不报错，只是分数变低。',
    '            // 用 FloatBuffer 视图顺序写入，避免手动算字节偏移。',
    '            // 顺序是「先填满填充色，再逐行覆盖真实像素」——填充色与真实内容',
    '            // 都需要写入，所以分两趟：先整幅填 PAD，再把真实区域覆盖回去。',
    '            val padValue = PAD / 255f',
    '            inputFloats.clear()',
    '            val totalPixels = inputSize * inputSize',
    '            var filled = 0',
    '            while (filled < totalPixels) {',
    '                inputFloats.put(padValue).put(padValue).put(padValue)',
    '                filled++',
    '            }',
    '            // 现在把真实内容覆盖到 [padY, padY+newH) x [padX, padX+newW) 区域。',
    '            // 用绝对下标定位（视图没有 position 语义上的字节偏移问题）。',
    '            for (dy in 0 until newH) {',
    '                val rowBase = (padY + dy) * inputSize + padX',
    '                for (dx in 0 until newW) {',
    '                    val pixel = rowBase + dx',
    '                    val idx = if (channelsFirstInput) pixel else pixel * 3',
    '                    val channelStep = if (channelsFirstInput) totalPixels else 1',
    '                    val (r, g, b) = sampleRgb(',
    '                        y, u, v, frameWidth, frameHeight, uvWidth,',
    '                        rot, dx, dy, newW, newH,',
    '                    )',
    '                    inputFloats.put(idx, r)',
    '                    inputFloats.put(idx + channelStep, g)',
    '                    inputFloats.put(idx + 2 * channelStep, b)',
    '                }',
    '            }',
    '            inputFloats.rewind()',
    '            inputBuffer.rewind()'
) -join $LF) `
    (@(
    '        try {',
    '            // ★ 前處理與離線評估／iOS 逐項對齊（見 CameraPreprocess 與其 JVM 對照測試）：',
    '            //   全範圍 BT.601 YUV→RGB、四捨五入（.5 取偶）尺寸、半像素雙線性、114 填充。',
    '            //   舊版「最近一點 + 限幅範圍公式」不報錯，只會令輸入偏離訓練分佈。',
    '            check(uvWidth == (frameWidth + 1) / 2) { "uvWidth=$uvWidth frame=$frameWidth" }',
    '            val tPre = System.nanoTime()',
    '            var yMin = 255',
    '            var yMax = 0',
    '            for (i in 0 until frameWidth * frameHeight) {',
    '                val value = y[i].toInt() and 0xFF',
    '                if (value < yMin) yMin = value',
    '                if (value > yMax) yMax = value',
    '            }',
    '            lumaRange = "Y[$yMin,$yMax]"',
    '            val rgbSize = frameWidth * frameHeight * 3',
    '            val rgb = rgbScratch?.takeIf { it.size == rgbSize } ?: FloatArray(rgbSize).also { rgbScratch = it }',
    '            CameraPreprocess.yuvToRgb(y, u, v, frameWidth, frameHeight, CAMERA_FULL_RANGE, rgb)',
    '            val geometry = CameraPreprocess.letterbox(',
    '                rgb, frameWidth, frameHeight, rotationDegrees, inputSize, channelsFirstInput, inputArray,',
    '            )',
    '            inputBuffer.rewind()',
    '            inputFloats.clear()',
    '            inputFloats.put(inputArray)',
    '            inputFloats.rewind()',
    '            inputBuffer.rewind()',
    '            lastPreprocessMs = (System.nanoTime() - tPre) / 1_000_000.0',
    '            val srcW = geometry.uprightWidth',
    '            val srcH = geometry.uprightHeight',
    '            val newW = geometry.scaledWidth',
    '            val newH = geometry.scaledHeight',
    '            val padX = geometry.padX',
    '            val padY = geometry.padY'
) -join $LF)

Patch-Overlay 'app/android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt' 'VisionPlugin.kt: 錄路／前處理 5' `
    (@(
    '',
    '    // 舊 sampleRgb（最近一點取樣＋限幅範圍 YUV）已由 CameraPreprocess 取代，見其 JVM 對照測試。'
) -join $LF) `
    (@(
    '',
    '    /**',
    '     * 取 (dx, dy) 处的 RGB（已归一化到 [0,1]），**只计算不写缓冲**。',
    '     *',
    '     * 之所以只返回数值、由调用方顺序写入：写缓冲的位置管理一旦出错就会',
    '     * 越写越偏且不报错（真机出现过「前 1631 个锚点正常、之后全是垃圾」）。',
    '     * 把「算」和「写」分开，写入点只有一处且是顺序的。',
    '     *',
    '     * 映射链：letterbox 图 -> 正立帧（撤缩放）-> 原始帧（逆旋转）-> YUV 采样 -> RGB。',
    '     *',
    '     * **逆旋转的方向与公式见下面 `when` 里的推导。**',
    '     */',
    '    private fun sampleRgb(',
    '        y: ByteArray,',
    '        u: ByteArray,',
    '        v: ByteArray,',
    '        frameWidth: Int,',
    '        frameHeight: Int,',
    '        uvWidth: Int,',
    '        rotationDegrees: Int,',
    '        dx: Int,',
    '        dy: Int,',
    '        newW: Int,',
    '        newH: Int,',
    '    ): Triple<Float, Float, Float> {',
    '        val outW = frameWidthOrRotated(frameWidth, frameHeight, rotationDegrees)',
    '        val outH = frameHeightOrRotated(frameWidth, frameHeight, rotationDegrees)',
    '        val ux = dx * outW / newW',
    '        val uy = dy * outH / newH',
    '',
    '        // ★ 逆旋转：由「正立图坐标 (ux, uy)」反查「原始帧坐标 (sx, sy)」。',
    '        //',
    '        // Android 里 `rotationDegrees` 的语义是「把原始帧**顺时针**转这么多度才正立」。',
    '        // 顺时针 90 度的**正向**映射是 `destX = SRC_H - 1 - srcY`、`destY = srcX`',
    '        // （注意第二项是 `srcX`，**不是** `SRC_W - 1 - srcX`；后者会多一次镜像）。',
    '        // 反解即：`srcY = SRC_H - 1 - destX`、`srcX = destY`。',
    '        //',
    '        // 这里曾经错得离谱：90 分支写成 `Pair(outH-1-uy, frameWidth-1-ux)`，',
    '        // 两个分量都不对。用 numpy 逐点核对（原始帧 1280x720、rotation=90）：',
    '        // 该写法 **9216 个采样点全部取错源像素（100%）**，正确写法 0 个错。',
    '        // 270 分支写成 `Pair(uy, ux)`（纯转置 = 镜像，缺一次翻转），同样 100% 错。',
    '        // 0 与 180 原本就对，未改动。',
    '        //',
    '        // 为什么特别难发现：`sy` 会算到 [560,1279]，而原始帧只有 720 行，',
    '        // 被下面的 `coerceIn` 夹到 719 —— 于是正立图里约 78% 的区域',
    '        // **全都取的是原始帧的最后一行**，模型看到的基本上是一条糊掉的横线。',
    '        // 而输入诊断（min/max/越界计数）看不出任何异常，因为读到的仍是合法 Y 值。',
    '        // 正确写法下索引天然落在范围内，`coerceIn` 只是防御，不应触发。',
    '        val (sx, sy) = when (rotationDegrees) {',
    '            90 -> Pair(uy, frameHeight - 1 - ux)',
    '            180 -> Pair(frameWidth - 1 - ux, frameHeight - 1 - uy)',
    '            270 -> Pair(frameWidth - 1 - uy, ux)',
    '            else -> Pair(ux, uy)',
    '        }',
    '        val cx = sx.coerceIn(0, frameWidth - 1)',
    '        val cy = sy.coerceIn(0, frameHeight - 1)',
    '',
    '        val yVal = y[cy * frameWidth + cx].toInt() and 0xFF',
    '        // ★ UV 下标必须按**紧凑副本**的布局算，不能用原始平面的 rowStride/pixelStride。',
    '        //',
    '        // `copyPlane` 返回的是紧凑数组 `out[y * width + x]`，UV 的 width 就是',
    '        // `(frameWidth + 1) / 2`、pixelStride 已展开为 1。这里曾经写成',
    '        // `(cy/2) * uvRowStride + (cx/2) * uvPixelStride`，用的是**原始平面**的步长：',
    '        // 真机常见的 NV21 布局是 rowStride≈frameWidth、pixelStride=2，于是下标被放大',
    '        // 约 2 倍 —— 上半幅画面取到**错误的色度**，下半幅直接越界，',
    '        // 被下面的 `in u.indices` 兜成 128（中性色 = 灰度）。',
    '        //',
    '        // 表现和「喂灰度图」一模一样：模型仍能跑、分数普遍偏低、颜色线索全丢',
    '        // （本项目实测灰度输入把最高分从 0.62~0.82 压到 0.04~0.55），',
    '        // 而且不报任何错。按紧凑宽度算则恒有 uvIndex ∈ [0, uvWidth*ch)，',
    '        // 无论设备给出什么步长都正确。',
    '        val uvIndex = (cy / 2) * uvWidth + (cx / 2)',
    '        val uVal = if (uvIndex in u.indices) u[uvIndex].toInt() and 0xFF else 128',
    '        val vVal = if (uvIndex in v.indices) v[uvIndex].toInt() and 0xFF else 128',
    '',
    '        // 标准 BT.601 YUV -> RGB，输出归一化到 [0,1]。',
    '        // 模型输入是 float32，每个像素 3 个 float；写成 byte 会让字节数差 4 倍。',
    '        val yf = yVal - 16',
    '        val uf = uVal - 128',
    '        val vf = vVal - 128',
    '        val r = (1.164f * yf + 1.596f * vf).coerceIn(0f, 255f) / 255f',
    '        val g = (1.164f * yf - 0.392f * uf - 0.813f * vf).coerceIn(0f, 255f) / 255f',
    '        val b = (1.164f * yf + 2.017f * uf).coerceIn(0f, 255f) / 255f',
    '        return Triple(r, g, b)',
    '    }',
    '',
    '    private fun frameWidthOrRotated(w: Int, h: Int, rot: Int): Int =',
    '        if (rot == 90 || rot == 270) h else w',
    '',
    '    private fun frameHeightOrRotated(w: Int, h: Int, rot: Int): Int =',
    '        if (rot == 90 || rot == 270) w else h'
) -join $LF) `
    (@(
    '',
    '    // 舊 sampleRgb（最近一點取樣＋限幅範圍 YUV）已由 CameraPreprocess 取代，見其 JVM 對照測試。'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/recorded_route_controller.dart' 'recorded_route_controller.dart: 錄路／前處理 1' `
    (@(
    'import ''route_learning_store.dart'';',
    'import ''route_platform_profile.dart'';'
) -join $LF) `
    'import ''route_learning_store.dart'';' `
    (@(
    'import ''route_learning_store.dart'';',
    'import ''route_platform_profile.dart'';'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/recorded_route_controller.dart' 'recorded_route_controller.dart: 錄路／前處理 2' `
    (@(
    '          if (!_current(op) || !_running) return false;',
    '          if (distances.single < RoutePlatform.feature.duplicateDistance) {'
) -join $LF) `
    (@(
    '          if (!_current(op) || !_running) return false;',
    '          if (distances.single < 2) {'
) -join $LF) `
    (@(
    '          if (!_current(op) || !_running) return false;',
    '          if (distances.single < RoutePlatform.feature.duplicateDistance) {'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_capture_page.dart' 'route_capture_page.dart: 錄路／前處理 1' `
    (@(
    'import ''route_observation_source.dart'';',
    'import ''route_camera_preview.dart'';'
) -join $LF) `
    'import ''route_observation_source.dart'';' `
    (@(
    'import ''route_observation_source.dart'';',
    'import ''route_camera_preview.dart'';'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_capture_page.dart' 'route_capture_page.dart: 錄路／前處理 2' `
    (@(
    '                                widget.previewBuilder?.call(context) ??',
    '                                routeCameraPreview(),'
) -join $LF) `
    (@(
    '                                widget.previewBuilder?.call(context) ??',
    '                                const UiKitView(',
    '                                  viewType: ''hk.pathguide/route_camera/preview'',',
    '                                ),'
) -join $LF) `
    (@(
    '                                widget.previewBuilder?.call(context) ??',
    '                                routeCameraPreview(),'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_journey_page.dart' 'route_journey_page.dart: 錄路／前處理 1' `
    (@(
    'import ''route_package.dart'';',
    'import ''route_camera_preview.dart'';'
) -join $LF) `
    'import ''route_package.dart'';' `
    (@(
    'import ''route_package.dart'';',
    'import ''route_camera_preview.dart'';'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_journey_page.dart' 'route_journey_page.dart: 錄路／前處理 2' `
    (@(
    '                          widget.previewBuilder?.call(context) ??',
    '                          routeCameraPreview(),'
) -join $LF) `
    (@(
    '                          widget.previewBuilder?.call(context) ??',
    '                          const UiKitView(',
    '                            viewType: ''hk.pathguide/route_camera/preview'',',
    '                          ),'
) -join $LF) `
    (@(
    '                          widget.previewBuilder?.call(context) ??',
    '                          routeCameraPreview(),'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_landmark_client.dart' 'route_landmark_client.dart: 錄路／前處理 1' `
    (@(
    'import ''route_localizer.dart'';',
    'import ''route_platform_profile.dart'';'
) -join $LF) `
    'import ''route_localizer.dart'';' `
    (@(
    'import ''route_localizer.dart'';',
    'import ''route_platform_profile.dart'';'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_landmark_client.dart' 'route_landmark_client.dart: 錄路／前處理 2' `
    (@(
    '        v[''manualFloorConfirmationRequired''] != true ||',
    '        !RoutePlatform.feature.ocrRevisions.contains(v[''ocrRevision''])) {'
) -join $LF) `
    (@(
    '        v[''manualFloorConfirmationRequired''] != true ||',
    '        ![2, 3].contains(v[''ocrRevision''])) {'
) -join $LF) `
    (@(
    '        v[''manualFloorConfirmationRequired''] != true ||',
    '        !RoutePlatform.feature.ocrRevisions.contains(v[''ocrRevision''])) {'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_localizer.dart' 'route_localizer.dart: 錄路／前處理 1' `
    (@(
    'import ''route_package.dart'' show RouteDocument;',
    'import ''route_platform_profile.dart'';'
) -join $LF) `
    'import ''route_package.dart'' show RouteDocument;' `
    (@(
    'import ''route_package.dart'' show RouteDocument;',
    'import ''route_platform_profile.dart'';'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_localizer.dart' 'route_localizer.dart: 錄路／前處理 2' `
    (@(
    '  }',
    '  // Per-platform descriptor profile (iOS Vision feature print, Android',
    '  // MobileNetV3-small embedder); see RouteFeatureProfile.',
    '  static String get featureRevision => RoutePlatform.feature.featureRevision;',
    '  static String get preprocessRevision =>',
    '      RoutePlatform.feature.preprocessRevision;',
    '  static double get maxDistance => RoutePlatform.feature.maxDistance;',
    '  static double get minGap => RoutePlatform.feature.minGap;',
    '  static const validity = Duration(seconds: 5);'
) -join $LF) `
    (@(
    '  }',
    '  static const featureRevision = ''vision-featureprint-v1'',',
    '      preprocessRevision = ''upright-jpeg-v1'';',
    '  static const maxDistance = 8.0, minGap = 2.0, validity = Duration(seconds: 5);'
) -join $LF) `
    (@(
    '  }',
    '  // Per-platform descriptor profile (iOS Vision feature print, Android',
    '  // MobileNetV3-small embedder); see RouteFeatureProfile.',
    '  static String get featureRevision => RoutePlatform.feature.featureRevision;',
    '  static String get preprocessRevision =>',
    '      RoutePlatform.feature.preprocessRevision;',
    '  static double get maxDistance => RoutePlatform.feature.maxDistance;',
    '  static double get minGap => RoutePlatform.feature.minGap;',
    '  static const validity = Duration(seconds: 5);'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_media.dart' 'route_media.dart: 錄路／前處理 1' `
    (@(
    'import ''route_package.dart'' show RouteDocument, RouteProblem, RouteStoreFailure;',
    'import ''route_platform_profile.dart'';'
) -join $LF) `
    'import ''route_package.dart'' show RouteDocument, RouteProblem, RouteStoreFailure;' `
    (@(
    'import ''route_package.dart'' show RouteDocument, RouteProblem, RouteStoreFailure;',
    'import ''route_platform_profile.dart'';'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_media.dart' 'route_media.dart: 錄路／前處理 2' `
    (@(
    '        observation[''routeId''] != routeId ||',
    '        RouteCameraProfile.bySource(observation[''source'']) == null ||',
    '        observation[''profile''] != RouteCameraProfile.profile ||',
    '        observation[''walkingValidated''] != false ||',
    '        observation[''mirrored''] != false ||',
    '        observation[''clockMapping''] !=',
    '            RouteCameraProfile.bySource(observation[''source''])!.clockMapping ||'
) -join $LF) `
    (@(
    '        observation[''routeId''] != routeId ||',
    '        observation[''source''] != ''avfoundation-back-wide'' ||',
    '        observation[''profile''] != ''route-camera-engineering-v1'' ||',
    '        observation[''walkingValidated''] != false ||',
    '        observation[''mirrored''] != false ||',
    '        observation[''clockMapping''] != ''coremedia-host'' ||'
) -join $LF) `
    (@(
    '        observation[''routeId''] != routeId ||',
    '        RouteCameraProfile.bySource(observation[''source'']) == null ||',
    '        observation[''profile''] != RouteCameraProfile.profile ||',
    '        observation[''walkingValidated''] != false ||',
    '        observation[''mirrored''] != false ||',
    '        observation[''clockMapping''] !=',
    '            RouteCameraProfile.bySource(observation[''source''])!.clockMapping ||'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_media.dart' 'route_media.dart: 錄路／前處理 3' `
    (@(
    '    if (observation[''captureClockId''] !=',
    '            RouteCameraProfile.bySource(observation[''source''])!',
    '                .clockId(observation[''clockEpoch''] as String) ||'
) -join $LF) `
    (@(
    '    if (observation[''captureClockId''] !=',
    '            ''avcapture-session-${observation[''clockEpoch'']}'' ||'
) -join $LF) `
    (@(
    '    if (observation[''captureClockId''] !=',
    '            RouteCameraProfile.bySource(observation[''source''])!',
    '                .clockId(observation[''clockEpoch''] as String) ||'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_observation_source.dart' 'route_observation_source.dart: 錄路／前處理 1' `
    (@(
    'import ''package:crypto/crypto.dart'';',
    'import ''package:flutter/services.dart'';',
    '',
    'import ''route_platform_profile.dart'';'
) -join $LF) `
    (@(
    'import ''package:crypto/crypto.dart'';',
    'import ''package:flutter/foundation.dart'';',
    'import ''package:flutter/services.dart'';'
) -join $LF) `
    (@(
    'import ''package:crypto/crypto.dart'';',
    'import ''package:flutter/services.dart'';',
    '',
    'import ''route_platform_profile.dart'';'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_observation_source.dart' 'route_observation_source.dart: 錄路／前處理 2' `
    (@(
    '  RouteObservationSource({bool? supported})',
    '    : supported = supported ?? RoutePlatform.captureSupported;'
) -join $LF) `
    (@(
    '  RouteObservationSource({bool? supported})',
    '    : supported =',
    '          supported ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);'
) -join $LF) `
    (@(
    '  RouteObservationSource({bool? supported})',
    '    : supported = supported ?? RoutePlatform.captureSupported;'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_observation_source.dart' 'route_observation_source.dart: 錄路／前處理 3' `
    (@(
    '        h[''startRequestId''] != current.startRequest ||',
    '        h[''source''] != RoutePlatform.camera.source ||',
    '        h[''profile''] != RouteCameraProfile.profile ||',
    '        h[''clockMapping''] != RoutePlatform.camera.clockMapping ||'
) -join $LF) `
    (@(
    '        h[''startRequestId''] != current.startRequest ||',
    '        h[''source''] != ''avfoundation-back-wide'' ||',
    '        h[''profile''] != ''route-camera-engineering-v1'' ||',
    '        h[''clockMapping''] != ''coremedia-host'' ||'
) -join $LF) `
    (@(
    '        h[''startRequestId''] != current.startRequest ||',
    '        h[''source''] != RoutePlatform.camera.source ||',
    '        h[''profile''] != RouteCameraProfile.profile ||',
    '        h[''clockMapping''] != RoutePlatform.camera.clockMapping ||'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_observation_source.dart' 'route_observation_source.dart: 錄路／前處理 4' `
    (@(
    '        epoch.isEmpty ||',
    '        clock != RoutePlatform.camera.clockId(epoch) ||'
) -join $LF) `
    (@(
    '        epoch.isEmpty ||',
    '        clock != ''avcapture-session-$epoch'' ||'
) -join $LF) `
    (@(
    '        epoch.isEmpty ||',
    '        clock != RoutePlatform.camera.clockId(epoch) ||'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_package.dart' 'route_package.dart: 錄路／前處理 1' `
    (@(
    'import ''route_media.dart'';',
    'import ''route_platform_profile.dart'';'
) -join $LF) `
    'import ''route_media.dart'';' `
    (@(
    'import ''route_media.dart'';',
    'import ''route_platform_profile.dart'';'
) -join $LF)

Patch-Overlay 'app/lib/route_memory/route_package.dart' 'route_package.dart: 錄路／前處理 2' `
    (@(
    '      RegExp(r''^[A-Za-z0-9_-]{1,80}$'').hasMatch(id);',
    '  bool get compatible =>',
    '      compatibleRevisions(source, featureRevision, preprocessRevision);',
    '',
    '  /// Captured routes replay only with this platform''s landmark descriptor',
    '  /// (iOS Vision feature print, Android MobileNetV3-small embedder); features',
    '  /// from another profile are not comparable. See RouteFeatureProfile.',
    '  static bool compatibleRevisions(',
    '    RouteContentSource source,',
    '    String featureRevision,',
    '    String preprocessRevision,',
    '  ) => source == RouteContentSource.synthetic',
    '      ? featureRevision == ''p0-synthetic-v1'' &&',
    '            preprocessRevision == ''none-synthetic''',
    '      : featureRevision == RoutePlatform.feature.featureRevision &&',
    '            preprocessRevision == RoutePlatform.feature.preprocessRevision;'
) -join $LF) `
    (@(
    '      RegExp(r''^[A-Za-z0-9_-]{1,80}$'').hasMatch(id);',
    '  bool get compatible => source == RouteContentSource.synthetic',
    '      ? featureRevision == ''p0-synthetic-v1'' &&',
    '            preprocessRevision == ''none-synthetic''',
    '      : featureRevision == ''vision-featureprint-v1'' &&',
    '            preprocessRevision == ''upright-jpeg-v1'';'
) -join $LF) `
    (@(
    '      RegExp(r''^[A-Za-z0-9_-]{1,80}$'').hasMatch(id);',
    '  bool get compatible =>',
    '      compatibleRevisions(source, featureRevision, preprocessRevision);',
    '',
    '  /// Captured routes replay only with this platform''s landmark descriptor',
    '  /// (iOS Vision feature print, Android MobileNetV3-small embedder); features',
    '  /// from another profile are not comparable. See RouteFeatureProfile.',
    '  static bool compatibleRevisions(',
    '    RouteContentSource source,',
    '    String featureRevision,',
    '    String preprocessRevision,',
    '  ) => source == RouteContentSource.synthetic',
    '      ? featureRevision == ''p0-synthetic-v1'' &&',
    '            preprocessRevision == ''none-synthetic''',
    '      : featureRevision == RoutePlatform.feature.featureRevision &&',
    '            preprocessRevision == RoutePlatform.feature.preprocessRevision;'
) -join $LF)

Patch-Overlay 'app/pubspec.yaml' 'pubspec.yaml: 錄路／前處理 1' `
    (@(
    '    - assets/models/detector-hk9.json',
    '    # Android 路標特徵（MobileNetV3-small 嵌入，來源與雜湊見清單）。iOS 用 Apple Vision，不讀此檔。',
    '    - assets/models/route_landmark_embedder.tflite',
    '    - assets/models/route_landmark_embedder.json'
) -join $LF) `
    '    - assets/models/detector-hk9.json' `
    (@(
    '    - assets/models/detector-hk9.json',
    '    # Android 路標特徵（MobileNetV3-small 嵌入，來源與雜湊見清單）。iOS 用 Apple Vision，不讀此檔。',
    '    - assets/models/route_landmark_embedder.tflite',
    '    - assets/models/route_landmark_embedder.json'
) -join $LF)

# ================================================================ 12. 2026-11-23 日常辨識畫框門檻＝播報門檻
#
# 日常模式畫框門檻改為播報門檻（舊版 0.30 畫、0.70 說，出現不出聲的低分框）；
# 開發者診斷頁保留獨立的畫框門檻。測試見 ios_demo_test。
# 補丁由 scripts/gen_overlay_section.py 產生並驗證逐字重現。

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 日常辨識畫框門檻＝播報門檻 1' `
    '}) => developerControls ? developerThreshold : speakThreshold;' `
    'import ''../vision/model_manifest.dart'';' `
    (@(
    'import ''../vision/model_manifest.dart'';',
    '',
    '/// 日常辨識只顯示會被播報的框：畫框與播報用同一門檻。',
    '///',
    '/// 2026-11-23 真機：日常模式固定 0.30 畫框、0.70 播報，空白暗畫面出現',
    '/// 「樓梯 0.47」全屏框卻不出聲。看得見的測試者會把這些當成誤認，而依賴',
    '/// 讀屏的使用者聽不到，畫面與語音資訊不一致。開發者診斷頁保留兩個獨立門檻。',
    '@visibleForTesting',
    'double detectionDisplayThreshold({',
    '  required bool developerControls,',
    '  required double developerThreshold,',
    '  required double speakThreshold,',
    '}) => developerControls ? developerThreshold : speakThreshold;'
) -join $LF)

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 日常辨識畫框門檻＝播報門檻 2' `
    (@(
    '',
    '  /// 開發者診斷頁的「畫框」門檻（可與播報門檻分開調，供比較）。',
    '  double _threshold = 0.30;',
    '',
    '  /// 實際推給檢測來源的門檻；見 [detectionDisplayThreshold]。',
    '  double get _drawThreshold => detectionDisplayThreshold(',
    '    developerControls: widget.developerControls,',
    '    developerThreshold: _threshold,',
    '    speakThreshold: widget.settings.speakThreshold,',
    '  );'
) -join $LF) `
    (@(
    '',
    '  double _threshold = 0.30;'
) -join $LF) `
    (@(
    '',
    '  /// 開發者診斷頁的「畫框」門檻（可與播報門檻分開調，供比較）。',
    '  double _threshold = 0.30;',
    '',
    '  /// 實際推給檢測來源的門檻；見 [detectionDisplayThreshold]。',
    '  double get _drawThreshold => detectionDisplayThreshold(',
    '    developerControls: widget.developerControls,',
    '    developerThreshold: _threshold,',
    '    speakThreshold: widget.settings.speakThreshold,',
    '  );'
) -join $LF)

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 日常辨識畫框門檻＝播報門檻 3' `
    (@(
    '          rotationDegrees: 90,',
    '          threshold: _drawThreshold,'
) -join $LF) `
    (@(
    '          rotationDegrees: 90,',
    '          threshold: _threshold,'
) -join $LF) `
    (@(
    '          rotationDegrees: 90,',
    '          threshold: _drawThreshold,'
) -join $LF)

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 日常辨識畫框門檻＝播報門檻 4' `
    (@(
    '      // 原生相機啟動後才推送閾值；模擬來源同樣由來源負責過濾。',
    '      source.threshold = _drawThreshold;'
) -join $LF) `
    (@(
    '      // 原生相機啟動後才推送閾值；模擬來源同樣由來源負責過濾。',
    '      source.threshold = _threshold;'
) -join $LF) `
    (@(
    '      // 原生相機啟動後才推送閾值；模擬來源同樣由來源負責過濾。',
    '      source.threshold = _drawThreshold;'
) -join $LF)

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 日常辨識畫框門檻＝播報門檻 5' `
    (@(
    '                    ? Colors.redAccent',
    '                    : (_diagnostics!.frameMaxScore >= _drawThreshold'
) -join $LF) `
    (@(
    '                    ? Colors.redAccent',
    '                    : (_diagnostics!.frameMaxScore >= _threshold'
) -join $LF) `
    (@(
    '                    ? Colors.redAccent',
    '                    : (_diagnostics!.frameMaxScore >= _drawThreshold'
) -join $LF)

Patch-Overlay 'app/test/ios_demo_test.dart' 'ios_demo_test.dart: 2026-11-23 日常辨識畫框門檻＝播報門檻 1' `
    (@(
    '  final visionCalls = <String>[];',
    '  final thresholdPushes = <double>[];'
) -join $LF) `
    '  final visionCalls = <String>[];' `
    (@(
    '  final visionCalls = <String>[];',
    '  final thresholdPushes = <double>[];'
) -join $LF)

Patch-Overlay 'app/test/ios_demo_test.dart' 'ios_demo_test.dart: 2026-11-23 日常辨識畫框門檻＝播報門檻 2' `
    (@(
    '    visionCalls.clear();',
    '    thresholdPushes.clear();'
) -join $LF) `
    '    visionCalls.clear();' `
    (@(
    '    visionCalls.clear();',
    '    thresholdPushes.clear();'
) -join $LF)

Patch-Overlay 'app/test/ios_demo_test.dart' 'ios_demo_test.dart: 2026-11-23 日常辨識畫框門檻＝播報門檻 3' `
    (@(
    '        visionCalls.add(call.method);',
    '        if (call.method == ''setThreshold'') {',
    '          thresholdPushes.add(',
    '            ((call.arguments as Map)[''threshold''] as num).toDouble(),',
    '          );',
    '        }'
) -join $LF) `
    '        visionCalls.add(call.method);' `
    (@(
    '        visionCalls.add(call.method);',
    '        if (call.method == ''setThreshold'') {',
    '          thresholdPushes.add(',
    '            ((call.arguments as Map)[''threshold''] as num).toDouble(),',
    '          );',
    '        }'
) -join $LF)

Patch-Overlay 'app/test/ios_demo_test.dart' 'ios_demo_test.dart: 2026-11-23 日常辨識畫框門檻＝播報門檻 4' `
    (@(
    '    expect(find.text(''自動播報''), findsOneWidget);',
    '    await close(tester);',
    '  });',
    '',
    '  testWidgets(''daily recognition draws only boxes it will announce'', (',
    '    tester,',
    '  ) async {',
    '    // 2026-11-23 真機：日常模式曾以 0.30 畫框、0.70 播報，空白暗畫面出現',
    '    // 不出聲的「樓梯 0.47」全屏框。日常模式的畫框門檻必須等於播報門檻。',
    '    final settings = AppSettings.memory();',
    '    await settings.setSpeakThreshold(0.65);',
    '    await start(tester, initialSection: AppSection.explore, settings: settings);',
    '    expect(thresholdPushes, isNotEmpty);',
    '    expect(thresholdPushes.last, closeTo(0.65, 1e-9));',
    '    await close(tester);',
    '  });',
    '',
    '  test(''developer diagnostics keep an independent drawing threshold'', () {',
    '    expect(',
    '      detectionDisplayThreshold(',
    '        developerControls: true,',
    '        developerThreshold: 0.30,',
    '        speakThreshold: 0.70,',
    '      ),',
    '      0.30,',
    '    );',
    '    expect(',
    '      detectionDisplayThreshold(',
    '        developerControls: false,',
    '        developerThreshold: 0.30,',
    '        speakThreshold: 0.70,',
    '      ),',
    '      0.70,',
    '    );'
) -join $LF) `
    (@(
    '    expect(find.text(''自動播報''), findsOneWidget);',
    '    await close(tester);'
) -join $LF) `
    (@(
    '    expect(find.text(''自動播報''), findsOneWidget);',
    '    await close(tester);',
    '  });',
    '',
    '  testWidgets(''daily recognition draws only boxes it will announce'', (',
    '    tester,',
    '  ) async {',
    '    // 2026-11-23 真機：日常模式曾以 0.30 畫框、0.70 播報，空白暗畫面出現',
    '    // 不出聲的「樓梯 0.47」全屏框。日常模式的畫框門檻必須等於播報門檻。',
    '    final settings = AppSettings.memory();',
    '    await settings.setSpeakThreshold(0.65);',
    '    await start(tester, initialSection: AppSection.explore, settings: settings);',
    '    expect(thresholdPushes, isNotEmpty);',
    '    expect(thresholdPushes.last, closeTo(0.65, 1e-9));',
    '    await close(tester);',
    '  });',
    '',
    '  test(''developer diagnostics keep an independent drawing threshold'', () {',
    '    expect(',
    '      detectionDisplayThreshold(',
    '        developerControls: true,',
    '        developerThreshold: 0.30,',
    '        speakThreshold: 0.70,',
    '      ),',
    '      0.30,',
    '    );',
    '    expect(',
    '      detectionDisplayThreshold(',
    '        developerControls: false,',
    '        developerThreshold: 0.30,',
    '        speakThreshold: 0.70,',
    '      ),',
    '      0.70,',
    '    );'
) -join $LF)

# ================================================================ 13. 2026-11-23 Android 播報延遲量度
#
# 日常辨識接入 SpeechLatencyProbe（新增檔），記原生處理＋Dart＋TTS 開始的延遲。
# 補丁由 scripts/gen_overlay_section.py 產生並驗證逐字重現。

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 Android 播報延遲量度 1' `
    (@(
    'import ''../vision/model_manifest.dart'';',
    'import ''../tts/speech_latency.dart'';'
) -join $LF) `
    'import ''../vision/model_manifest.dart'';' `
    (@(
    'import ''../vision/model_manifest.dart'';',
    'import ''../tts/speech_latency.dart'';'
) -join $LF)

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 Android 播報延遲量度 2' `
    (@(
    '  late final FlutterTtsSpeaker _speaker;',
    '',
    '  /// 畫面→開始發聲的工程量度（App 語音路線），見 [SpeechLatencyProbe]。',
    '  final _latency = SpeechLatencyProbe();'
) -join $LF) `
    '  late final FlutterTtsSpeaker _speaker;' `
    (@(
    '  late final FlutterTtsSpeaker _speaker;',
    '',
    '  /// 畫面→開始發聲的工程量度（App 語音路線），見 [SpeechLatencyProbe]。',
    '  final _latency = SpeechLatencyProbe();'
) -join $LF)

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 Android 播報延遲量度 3' `
    (@(
    '      onPlaybackEvent: (event) {',
    '        if (event == TtsPlaybackEvent.started &&',
    '            _voice.owner == SpeechChannel.environment) {',
    '          _latency.started();',
    '        }'
) -join $LF) `
    '      onPlaybackEvent: (event) {' `
    (@(
    '      onPlaybackEvent: (event) {',
    '        if (event == TtsPlaybackEvent.started &&',
    '            _voice.owner == SpeechChannel.environment) {',
    '          _latency.started();',
    '        }'
) -join $LF)

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 Android 播報延遲量度 4' `
    (@(
    '  void _stopSpeech() {',
    '    _latency.cancel();'
) -join $LF) `
    '  void _stopSpeech() {' `
    (@(
    '  void _stopSpeech() {',
    '    _latency.cancel();'
) -join $LF)

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 Android 播報延遲量度 5' `
    '_latency.submitted(receivedAt: now, nativeMs: frame.inferenceMs);' `
    '        _announcer.onFrame(frame.detections) != null) {' `
    (@(
    '        _announcer.onFrame(frame.detections) != null) {',
    '      // 讀屏路線沒有 TTS 開始回呼，不計入延遲量度。',
    '      if (!_screenReader) {',
    '        _latency.submitted(receivedAt: now, nativeMs: frame.inferenceMs);',
    '      }'
) -join $LF)

# ================================================================ 14. 2026-11-23 日常辨識行人門檻 0.80
#
# 依獨立 Open Images 評估，日常模式行人須達 0.80（與播報門檻取較高者），畫框、播報、摘要共用。
# 測試見 daily_detection_threshold_test（新增檔）。
# 補丁由 scripts/gen_overlay_section.py 產生並驗證逐字重現。

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 日常辨識行人門檻 0.80 1' `
    (@(
    'import ''dart:async'';',
    'import ''dart:math'' as math;'
) -join $LF) `
    'import ''dart:async'';' `
    (@(
    'import ''dart:async'';',
    'import ''dart:math'' as math;'
) -join $LF)

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 日常辨識行人門檻 0.80 2' `
    (@(
    '}) => developerControls ? developerThreshold : speakThreshold;',
    '',
    '/// 日常模式的逐類最低分數（以項目類別 id 為鍵），與播報門檻取較高者。',
    '///',
    '/// 2026-11-23 獨立 Open Images test 評估（verification/android-oid-test-eval-20261123.json）：',
    '/// 行人在 0.70 的精確率 0.77，0.80 為 0.87；全類誤認 82 → 39，召回 0.220 → 0.177。',
    '/// 其他可評類別在 0.70 已足夠（垃圾桶 1.00、單車 0.92）；門及未評類別維持播報門檻。',
    'const Map<int, double> kDailyClassMinScore = <int, double>{6: 0.80};',
    '',
    '/// 日常模式只保留達到逐類門檻的偵測；畫框、播報及文字摘要共用同一結果。',
    '/// 開發者診斷頁原樣輸出，以便比較。',
    '@visibleForTesting',
    'List<Detection> dailyDetections(',
    '  List<Detection> detections, {',
    '  required bool developerControls,',
    '  required double speakThreshold,',
    '}) {',
    '  if (developerControls) return detections;',
    '  return [',
    '    for (final d in detections)',
    '      if (d.score >= math.max(speakThreshold, kDailyClassMinScore[d.id] ?? 0))',
    '        d,',
    '  ];',
    '}'
) -join $LF) `
    '}) => developerControls ? developerThreshold : speakThreshold;' `
    (@(
    '}) => developerControls ? developerThreshold : speakThreshold;',
    '',
    '/// 日常模式的逐類最低分數（以項目類別 id 為鍵），與播報門檻取較高者。',
    '///',
    '/// 2026-11-23 獨立 Open Images test 評估（verification/android-oid-test-eval-20261123.json）：',
    '/// 行人在 0.70 的精確率 0.77，0.80 為 0.87；全類誤認 82 → 39，召回 0.220 → 0.177。',
    '/// 其他可評類別在 0.70 已足夠（垃圾桶 1.00、單車 0.92）；門及未評類別維持播報門檻。',
    'const Map<int, double> kDailyClassMinScore = <int, double>{6: 0.80};',
    '',
    '/// 日常模式只保留達到逐類門檻的偵測；畫框、播報及文字摘要共用同一結果。',
    '/// 開發者診斷頁原樣輸出，以便比較。',
    '@visibleForTesting',
    'List<Detection> dailyDetections(',
    '  List<Detection> detections, {',
    '  required bool developerControls,',
    '  required double speakThreshold,',
    '}) {',
    '  if (developerControls) return detections;',
    '  return [',
    '    for (final d in detections)',
    '      if (d.score >= math.max(speakThreshold, kDailyClassMinScore[d.id] ?? 0))',
    '        d,',
    '  ];',
    '}'
) -join $LF)

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 日常辨識行人門檻 0.80 3' `
    (@(
    '        _pendingStatusAnnouncement == null;',
    '    final detections = dailyDetections(',
    '      frame.detections,',
    '      developerControls: widget.developerControls,',
    '      speakThreshold: widget.settings.speakThreshold,',
    '    );',
    '    if (_announcer.enabled &&',
    '        !_announcer.isSpeaking &&',
    '        _announcer.onFrame(detections) != null) {'
) -join $LF) `
    (@(
    '        _pendingStatusAnnouncement == null;',
    '    if (_announcer.enabled &&',
    '        !_announcer.isSpeaking &&',
    '        _announcer.onFrame(frame.detections) != null) {'
) -join $LF) `
    (@(
    '        _pendingStatusAnnouncement == null;',
    '    final detections = dailyDetections(',
    '      frame.detections,',
    '      developerControls: widget.developerControls,',
    '      speakThreshold: widget.settings.speakThreshold,',
    '    );',
    '    if (_announcer.enabled &&',
    '        !_announcer.isSpeaking &&',
    '        _announcer.onFrame(detections) != null) {'
) -join $LF)

Patch-Overlay 'app/lib/ui/demo_page.dart' 'demo_page.dart: 2026-11-23 日常辨識行人門檻 0.80 4' `
    (@(
    '    setState(() {',
    '      _detections = detections;',
    '      _readback = resultSummary(',
    '        detections,'
) -join $LF) `
    (@(
    '    setState(() {',
    '      _detections = frame.detections;',
    '      _readback = resultSummary(',
    '        frame.detections,'
) -join $LF) `
    (@(
    '    setState(() {',
    '      _detections = detections;',
    '      _readback = resultSummary(',
    '        detections,'
) -join $LF)

# ================================================================ 結果
Write-Host ''
if ($script:errors.Count -gt 0) {
    Write-Host "有 $($script:errors.Count) 個問題需要人工處理：" -ForegroundColor Red
    foreach ($e in $script:errors) { Write-Host "  - $e" -ForegroundColor Red }
    exit 1
}
if ($Check) {
    if ($script:changed -eq 0) {
        Write-Host "OVERLAY OK：全部已就緒（$($script:skipped) 項已存在）。" -ForegroundColor Green
        exit 0
    }
    Write-Host "OVERLAY 未完成：$($script:changed) 項待套用，$($script:skipped) 項已存在。" -ForegroundColor Yellow
    exit 1
}
Write-Host "OVERLAY DONE：套用 $($script:changed) 項，跳過 $($script:skipped) 項。" -ForegroundColor Green
Write-Host '下一步：從無空格盤符跑 flutter analyze / test / build apk（見 docs/FRONTEND-DESIGN.zh-HK.md）。'
