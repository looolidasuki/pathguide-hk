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
      menu_page.dart            第三方語音廠商名按平台（iOS=Apple / Android=Google）
      menu_ui_test.dart         廠商名映射測試

    平台守衛（上游 4 個路線記憶測試依賴 iOS Keychain，非 macOS 必然失敗）
      captured_route_store_test / encrypted_route_store_test /
      route_journey_page_test / route_record_replay_test

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
    [string]$SourceRef = 'v1.8.0+15-android-sync.1'
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
    'app/test/menu_platform_test.dart'
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

Patch-Overlay $page 'menu_page: 不支援時的理由' `
    'AppText(_unsupportedReason())' `
    "              const AppText('本輪菜單閱讀先支援 iPhone，繁體中文辨識需要 iOS 16 或以上。')," `
    '              AppText(_unsupportedReason()),'

$helpers = @(
    '  /// 線上語音廠商名的內部入口。',
    '  static String _onlineVoiceVendor() => onlineVoiceVendorFor(defaultTargetPlatform);',
    '',
    '  /// 這個平台不支援菜單閱讀時，要說出為什麼與在哪些平台可用。',
    '  static String _unsupportedReason() => switch (defaultTargetPlatform) {',
    "    TargetPlatform.iOS => '菜單閱讀在 iPhone 需要 iOS 16 或以上。',",
    "    TargetPlatform.android => '這部 Android 裝置未提供可用的文字辨識服務。',",
    "    _ => '菜單閱讀目前支援 iPhone 與 Android。',",
    '  };',
    ''
) -join $LF
Patch-Overlay $page 'menu_page: 兩個 helper' `
    'static String _unsupportedReason()' `
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
# 兩件事，都是「上游在 macOS／POSIX 看不到、Windows 上必炸」的類型：
#
# (a) `_key()` 用 `f.path.endsWith('/.lock')` 判斷鎖檔，但 Windows 的 File.path 用反斜線，
#     於是鎖檔被當成「已有資料但沒有金鑰」→ 每次開檔都 RouteStoreFailure(keyUnavailable)。
#     這是**真 bug**（POSIX 掩蓋了它），所以修程式，不跳測試。
#
# (b) 有幾條測試刻意在 store 仍持有 .lock 時刪檔／模擬崩潰。POSIX 允許刪除已打開的檔案，
#     Windows 回 PathAccessException(errno 32)。那是平台語義差異、不是產品缺陷，
#     所以只在 Windows 跳過那幾條，並寫明真正的原因（不要用假理由蓋掉真 bug）。
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

$winHelper = @(
    '// Windows 允許「刪除已打開的檔案」嗎？不可以（POSIX 可以）。',
    '// 下面這些測試刻意在 store 仍持有 `.lock` 時刪檔／模擬崩潰，',
    '// 在 Windows 上必然得到 PathAccessException(errno 32) → RouteStoreFailure(io)。',
    '// Android/iOS 是 POSIX，行為正確；所以只在 Windows 跳過，並寫明真正的原因，',
    '// 不要用「需要 Keychain」之類的假理由（會蓋掉真 bug）。',
    'const _winLockSkip =',
    "    'Windows 無法刪除已打開的 .lock（POSIX 允許；Android/iOS 不受影響）';",
    '',
    'void destructiveTest(String name, Future<void> Function() body) =>',
    '    test(name, body, skip: Platform.isWindows ? _winLockSkip : null);',
    '',
    '// testWidgets 的 skip 只收 bool，帶不上原因字串；真正的原因寫在 _winLockSkip 的註解裡。',
    'void destructiveWidgetTest(String name, WidgetTesterCallback body) =>',
    '    testWidgets(name, body, skip: Platform.isWindows);',
    '',
    'void main() {'
) -join $LF

$captured = 'app/test/captured_route_store_test.dart'
Patch-Overlay $captured 'captured_store_test: Windows 鎖語義 helper' `
    'void destructiveTest(String name' `
    ('void main() {' + $LF) `
    $winHelper

Patch-Overlay $captured 'captured_store_test: 包裝 for 迴圈的兩條' `
    'destructiveTest(''$cancel cancels media waiting' `
    '    test(''$cancel cancels media waiting before catalog publication'', () async {' `
    '    destructiveTest(''$cancel cancels media waiting before catalog publication'', () async {'

Patch-Overlay $captured 'captured_store_test: 包裝 crash 那條' `
    'destructiveTest(''a crash after media write' `
    'test(''a crash after media write preserves old pointer; explicit cleanup removes orphans'',' `
    'destructiveTest(''a crash after media write preserves old pointer; explicit cleanup removes orphans'','

Patch-Overlay $captured 'captured_store_test: 包裝 tampered 那條' `
    'destructiveTest(''tampered image blocks latest version' `
    'test(''tampered image blocks latest version; explicit rollback recovers and delete removes all media'',' `
    'destructiveTest(''tampered image blocks latest version; explicit rollback recovers and delete removes all media'','

$encrypted = 'app/test/encrypted_route_store_test.dart'
Patch-Overlay $encrypted 'encrypted_store_test: Windows 鎖語義 helper' `
    'void destructiveTest(String name' `
    ('void main() {' + $LF) `
    $winHelper

Patch-Overlay $encrypted 'encrypted_store_test: 包裝 corrupt active 那條' `
    ('destructiveTest(' + $LF + '    ''corrupt active version preserved') `
    ('test(' + $LF + '    ''corrupt active version preserved; explicit verified older rollback works'',') `
    ('destructiveTest(' + $LF + '    ''corrupt active version preserved; explicit verified older rollback works'',')

Patch-Overlay $encrypted 'encrypted_store_test: 包裝 failure before catalog 那條' `
    'destructiveTest(''failure before catalog switch' `
    'test(''failure before catalog switch leaves stable active version and orphan ignored'', () async {' `
    'destructiveTest(''failure before catalog switch leaves stable active version and orphan ignored'', () async {'

Patch-Overlay $encrypted 'encrypted_store_test: 包裝 route namespace 那條' `
    ('destructiveTest(' + $LF + '    ''route namespace and key') `
    ('test(' + $LF + '    ''route namespace and key do not touch photo queue or another library'',') `
    ('destructiveTest(' + $LF + '    ''route namespace and key do not touch photo queue or another library'',')

Patch-Overlay $encrypted 'encrypted_store_test: 包裝 explicit pruning 那條' `
    'destructiveTest(''explicit pruning retains active' `
    '  test(''explicit pruning retains active, verified fallback and draft, with monotonic versions'', () async {' `
    '  destructiveTest(''explicit pruning retains active, verified fallback and draft, with monotonic versions'', () async {'

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
