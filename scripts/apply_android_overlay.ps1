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
    [string]$SourceRef = 'v1.12.1+31-android-sync.3'
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
    'app/test/android_back_test.dart'
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
