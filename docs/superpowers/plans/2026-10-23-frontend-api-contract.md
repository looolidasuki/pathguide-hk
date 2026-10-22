# 前端 API 契約與訪客門禁 — 實作計劃

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把前端接到「有接口、無後端」的完整狀態：`PathGuideApi` 抽象 + 訪客/登入門禁 + 上傳隊列，並把已批准的簡單 UI（播報速度設定）落地。

**Architecture:** UI 只依賴 `FeatureGate` → `PathGuideApi`；`PathGuideApi` 有 `LocalOnlyApi`（訪客/離線）與 `HttpApi`（真 HTTP，`baseUrl` 可配）兩份實現；HTTP 走 `dart:io HttpClient`，不引入網絡套件。核心識別/讀字/播報一行不動。

**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4、`shared_preferences`（已加入並驗證可構建）、`dart:io` HttpClient、`flutter_test`。

**Spec:** `docs/superpowers/specs/2026-10-23-frontend-api-contract-design.md`

## Global Constraints

- 核心識別／讀字／播報**不得**走網絡；任何 API 失敗都不得降級核心功能或阻塞啟動。
- 登錄不得擋路：訪客可完整使用引導與識字；雲能力才需登入。
- 不引入新依賴（`dio`／`http`／`package_info_plus`／`crypto` 一概不加）。HTTP 用 `dart:io`。
- TTS 單句上限約 3 秒唸完；錯誤**不彈窗**，寫狀態檔 + 一句可聽說明。
- 每個可操作項都要有「動作+結果」語義標籤，無裸 `Icon` 充當按鈕，200% 字級不截斷。
- 現有門禁必須保持全綠：`flutter analyze` 0 問題、`flutter test` 235 條、`pytest` 436 條。
- 測試一律不碰真網（用 `FakeTransport`）。
- 版號維持 `2.0.0+2`，本計劃不改 `pubspec.yaml` 的 version。

## 任務順序（與 spec §14 的差異，故意的）

spec §14 把 API 層排在使用者可見的 UI 之前；本計劃**先做 UI（Task 1–4）再做 API（Task 5–10）**，
理由：`shared_preferences` 的依賴門禁已通過（`assembleDebug` 成功），
所以先交付一個使用者立刻能用的設定頁＋語速，再往後端方向鋪路。
兩者互不依賴，換順序不會造成返工。

---

### Task 1: 播報速度的設定模型（`AppSettings`）

**Files:**
- Create: `app/lib/settings/app_settings.dart`
- Test: `app/test/app_settings_test.dart`

**Interfaces:**
- Consumes: `package:shared_preferences`（已在 `pubspec.yaml`，已驗證 `flutter build apk --debug` 通過）
- Produces:
  - `enum SpeechSpeed { slow, normal, fast }`，每個值有 `double ttsRate`（0.35 / 0.45 / 0.55）
  - `class AppSettings extends ChangeNotifier`
    - `AppSettings(SharedPreferences prefs)` / `AppSettings.memory()`
    - `static Future<AppSettings> load()`
    - `SpeechSpeed get speechSpeed`、`double get ttsRate`
    - `Future<void> setSpeechSpeed(SpeechSpeed speed)`
    - `static const String kSpeechSpeedKey = 'speech_speed'`

- [ ] **Step 1: 寫失敗測試**

```dart
// app/test/app_settings_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pathguide/settings/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('預設是正常語速', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final s = await AppSettings.load();
    expect(s.speechSpeed, SpeechSpeed.normal);
    expect(s.ttsRate, 0.45);
  });

  test('設定後會持久化，重新載入仍在', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final s = await AppSettings.load();
    await s.setSpeechSpeed(SpeechSpeed.slow);
    expect(s.ttsRate, 0.35);

    final again = await AppSettings.load();
    expect(again.speechSpeed, SpeechSpeed.slow);
  });

  test('未知的存檔值不會讓載入失敗（回退預設）', () async {
    SharedPreferences.setMockInitialValues(
      <String, Object>{'speech_speed': 'turbo'},
    );
    final s = await AppSettings.load();
    expect(s.speechSpeed, SpeechSpeed.normal);
  });

  test('真的改變時才通知監聽者', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final s = await AppSettings.load();
    var notified = 0;
    s.addListener(() => notified++);

    await s.setSpeechSpeed(SpeechSpeed.normal); // 沒變
    expect(notified, 0);
    await s.setSpeechSpeed(SpeechSpeed.fast); // 變了
    expect(notified, 1);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app; flutter test test/app_settings_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'pathguide/settings/app_settings.dart'`

- [ ] **Step 3: 最小實作**

```dart
// app/lib/settings/app_settings.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播報速度。三個檔位對應 `flutter_tts` 的 speech rate。
///
/// 為什麼只有三檔而不是連續滑桿：滑桿對全盲使用者不可判斷（看不到刻度、
/// 也聽不出 0.01 的差別），三檔可用「慢／正常／快」直接唸出來。
enum SpeechSpeed {
  slow(0.35),
  normal(0.45),
  fast(0.55);

  const SpeechSpeed(this.ttsRate);

  /// 傳給 `flutter_tts.setSpeechRate` 的值。
  final double ttsRate;
}

/// 使用者的本機設定。目前只有播報速度。
///
/// 刻意**不**在這裡放雲端設定：跨端同步是雲能力（Spec 1 §3），
/// 混進來會讓「訪客也能完整使用」這句話變得難驗證。
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  /// 測試與無存儲環境用。
  AppSettings.memory() : _prefs = null;

  static const String kSpeechSpeedKey = 'speech_speed';

  final SharedPreferences? _prefs;
  SpeechSpeed _speechSpeed = SpeechSpeed.normal;

  SpeechSpeed get speechSpeed => _speechSpeed;

  /// 目前的 TTS 語速，直接餵給 speaker。
  double get ttsRate => _speechSpeed.ttsRate;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = AppSettings(prefs);
    final raw = prefs.getString(kSpeechSpeedKey);
    // 未知值（舊版本寫的、或手改的）一律回退預設，不讓載入失敗——
    // 設定壞掉不該擋住一個導航輔具的啟動。
    if (raw != null) {
      for (final speed in SpeechSpeed.values) {
        if (speed.name == raw) settings._speechSpeed = speed;
      }
    }
    return settings;
  }

  Future<void> setSpeechSpeed(SpeechSpeed speed) async {
    if (speed == _speechSpeed) return;
    _speechSpeed = speed;
    notifyListeners();
    await _prefs?.setString(kSpeechSpeedKey, speed.name);
  }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd app; flutter test test/app_settings_test.dart`
Expected: PASS（4 條）

- [ ] **Step 5: Commit**

```bash
git add app/lib/settings/app_settings.dart app/test/app_settings_test.dart
git commit -m "feat(settings): 播報速度三檔模型 + shared_preferences 持久化"
```

---

### Task 2: 把語速接進 TTS 鏈路

**Files:**
- Modify: `app/lib/tts/flutter_tts_speaker.dart`（建構子與 `initialize`）
- Modify: `app/lib/vision/vision_session.dart`（新增 `applySpeechRate`）
- Test: `app/test/flutter_tts_speaker_test.dart`（追加 2 條）

**Interfaces:**
- Consumes: `SpeechSpeed.dart`（Task 1 的 `ttsRate`）
- Produces:
  - `FlutterTtsSpeaker({FlutterTts? tts, Locale Function()? systemLocale, double? speechRate})`
  - `static const double FlutterTtsSpeaker.defaultSpeechRate = 0.45`
  - `double get speechRate`、`Future<void> setSpeechRate(double rate)`
  - `VisionSession.applySpeechRate(double rate)` —— 內部判 `speaker is FlutterTtsSpeaker`，**不改 `Speaker` 介面**

- [ ] **Step 1: 寫失敗測試**（追加到既有檔案末尾，`main()` 之內）

```dart
  test('建構時給的語速會在 initialize 被套用', () async {
    final speaker = FlutterTtsSpeaker(
      systemLocale: () => const Locale('zh', 'HK'),
      speechRate: 0.35,
    );
    await speaker.initialize();
    expect(
      calls.where((c) => c.method == 'setSpeechRate').first.arguments,
      0.35,
    );
  });

  test('setSpeechRate 會立刻套用並記住', () async {
    final speaker = FlutterTtsSpeaker(systemLocale: () => const Locale('zh', 'HK'));
    await speaker.initialize();
    await speaker.setSpeechRate(0.55);
    expect(speaker.speechRate, 0.55);
    expect(
      calls.where((c) => c.method == 'setSpeechRate').last.arguments,
      0.55,
    );
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app; flutter test test/flutter_tts_speaker_test.dart`
Expected: FAIL — `Error: No named parameter with the name 'speechRate'`

- [ ] **Step 3: 實作**

在 `app/lib/tts/flutter_tts_speaker.dart` 的建構子改為：

```dart
  FlutterTtsSpeaker({
    FlutterTts? tts,
    Locale Function()? systemLocale,
    double? speechRate,
  })  : _tts = tts ?? FlutterTts(),
        _systemLocale = systemLocale ?? (() => PlatformDispatcher.instance.locale),
        _speechRate = speechRate ?? defaultSpeechRate;

  /// 預設語速。三檔中的「正常」（見 `settings/app_settings.dart`）。
  static const double defaultSpeechRate = 0.45;
```

在欄位區加：

```dart
  double _speechRate;

  /// 目前語速（給測試與設定頁讀）。
  double get speechRate => _speechRate;

  /// 執行時改語速。`initialize()` 之後呼叫才有意義，但先呼叫也不會壞：
  /// 它只是設值，真正的套用在 `initialize()` 內。
  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate.clamp(0.1, 1.0);
    await _tts.setSpeechRate(_speechRate);
  }
```

把 `initialize()` 裡的 `await _tts.setSpeechRate(0.45);` 改成 `await _tts.setSpeechRate(_speechRate);`。

在 `app/lib/vision/vision_session.dart` 加：

```dart
  /// 套用播報語速。**只對真正的 TTS 生效**。
  ///
  /// 為什麼不在 [Speaker] 介面上加方法：那會讓每一個測試假實現都要跟著改，
  /// 而語速只跟真實 TTS 有關。
  Future<void> applySpeechRate(double rate) async {
    final s = speaker;
    if (s is FlutterTtsSpeaker) await s.setSpeechRate(rate);
  }
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd app; flutter test test/flutter_tts_speaker_test.dart`
Expected: PASS（9 條）

- [ ] **Step 5: Commit**

```bash
git add app/lib/tts/flutter_tts_speaker.dart app/lib/vision/vision_session.dart app/test/flutter_tts_speaker_test.dart
git commit -m "feat(tts): 語速可由設定注入並在執行時更新"
```

---

### Task 3: 設定頁（播報速度 + 模型資訊）

**Files:**
- Create: `app/lib/ui/app_theme.dart`
- Create: `app/lib/ui/settings_page.dart`
- Modify: `app/lib/l10n/app_strings.dart`（追加字串）
- Test: `app/test/settings_page_test.dart`

**Interfaces:**
- Consumes: `AppSettings`（Task 1）、`parseModelManifest`／`ModelManifest`（`vision/model_manifest.dart`，已存在）、`defaultModelManifestKey`（`vision/platform_vision.dart`，已存在）
- Produces:
  - `abstract final class AppColors`：`background` `0xFF0B0F13`、`surface` `0xFF161B22`、`onSurface`、`onSurfaceMuted`、`accent`
  - `SettingsPage({required AppSettings settings, Future<String?> Function()? modelSummary})`，`modelSummary` 預設讀 `assets/models/detector.json`
  - `AppStrings` 新字串：`settingsTitle`、`settingsHint`、`speechSpeed`、`speechSpeedSlow`、`speechSpeedNormal`、`speechSpeedFast`、`modelInfo`、`account`、`accountGuest`

- [ ] **Step 1: 寫失敗測試**

```dart
// app/test/settings_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/l10n/app_locale.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/ui/settings_page.dart';

void main() {
  setUp(() => AppLocale.current = AppLanguage.zh);

  Future<AppSettings> pump(WidgetTester tester) async {
    final settings = AppSettings.memory();
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        settings: settings,
        modelSummary: () async => '18 類 · 2.87 MB · 2026-10-02.stage2',
      ),
    ));
    await tester.pumpAndSettle();
    return settings;
  }

  testWidgets('★ 設定頁只有三類內容：播報速度、模型資訊、返回', (tester) async {
    await pump(tester);
    expect(find.textContaining('播報速度'), findsOneWidget);
    expect(find.textContaining('模型'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);
    // 沒有任何「開發中」這種佔位字樣
    expect(find.textContaining('開發中'), findsNothing);
  });

  testWidgets('★ 選「快」會真的改到設定，且按鈕說出自己是什麼', (tester) async {
    final settings = await pump(tester);
    await tester.tap(find.textContaining('播報速度'));
    await tester.pumpAndSettle();

    expect(find.text('快'), findsOneWidget);
    await tester.tap(find.text('快'));
    await tester.pumpAndSettle();

    expect(settings.speechSpeed, SpeechSpeed.fast);
    expect(settings.ttsRate, 0.55);
  });

  testWidgets('模型資訊是唯讀：沒有可點的假下載按鈕', (tester) async {
    await pump(tester);
    expect(find.textContaining('18 類'), findsOneWidget);
    expect(find.textContaining('下載'), findsNothing);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app; flutter test test/settings_page_test.dart`
Expected: FAIL — `Couldn't resolve the package 'pathguide/ui/settings_page.dart'`

- [ ] **Step 3: 實作主題 token**

```dart
// app/lib/ui/app_theme.dart
import 'package:flutter/material.dart';

/// 全 App 的顏色 token。以前 `0xFF0B0F13` 這類字面量散在三個檔案裡，
/// 改一次配色要追三處；集中之後只改這裡。
///
/// 為什麼是深色：室外強光下深色底更省電也更好讀（沿用 `main.dart` 的既有決定）。
abstract final class AppColors {
  /// 頁面底色。
  static const Color background = Color(0xFF0B0F13);

  /// 卡片／底部動作區。
  static const Color surface = Color(0xFF161B22);

  /// 主要文字。
  static const Color onSurface = Color(0xFFFFFFFF);

  /// 次要文字（狀態句、說明）。
  static const Color onSurfaceMuted = Color(0xB3FFFFFF);

  /// 強調色。種子色 `#2E7D32` 在深色 theme 下的亮階。
  static const Color accent = Color(0xFF81C784);
}
```

- [ ] **Step 4: 追加字串**

在 `app/lib/l10n/app_strings.dart` 的 `_zh` 區塊內追加：

```dart
  String get settingsTitle => _zh ? '設定' : 'Settings';

  String get settingsHint => _zh ? '調整播報速度；其餘由程式決定' : 'Speech speed only';

  String get speechSpeed => _zh ? '播報速度' : 'Speech speed';

  String get speechSpeedSlow => _zh ? '慢' : 'Slow';

  String get speechSpeedNormal => _zh ? '正常' : 'Normal';

  String get speechSpeedFast => _zh ? '快' : 'Fast';

  String get modelInfo => _zh ? '模型資訊' : 'Model info';

  String get account => _zh ? '帳號' : 'Account';

  String get accountGuest => _zh ? '訪客（可完整使用識別）' : 'Guest (full detection)';
```

- [ ] **Step 5: 實作設定頁**

```dart
// app/lib/ui/settings_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../l10n/app_strings.dart';
import '../settings/app_settings.dart';
import '../vision/model_manifest.dart';
import '../vision/platform_vision.dart' show defaultModelManifestKey;
import 'app_theme.dart';

/// 設定頁。只有兩塊內容，**刻意不做第三塊**。
///
/// 為什麼沒有「未來功能」清單：那種列表對看不見的使用者是純噪音——
/// 每一項都要花一次焦點移動去聽「這個還沒做」。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settings, this.modelSummary});

  final AppSettings settings;

  /// 模型資訊的一行摘要。預設從端上清單讀；測試注入固定字串。
  final Future<String?> Function()? modelSummary;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<String?> _summary =
      (widget.modelSummary ?? _loadModelSummary)();

  static Future<String?> _loadModelSummary() async {
    try {
      final parsed =
          parseModelManifest(await rootBundle.loadString(defaultModelManifestKey));
      final m = parsed.manifest;
      if (m == null) return null;
      final mib = (m.bytes / (1024 * 1024)).toStringAsFixed(2);
      return '${m.modelClassCount} 類 · $mib MB · ${m.version}';
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickSpeed() async {
    final s = AppStrings.current;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: widget.settings,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final speed in SpeechSpeed.values)
                SizedBox(
                  height: 56,
                  child: TextButton(
                    onPressed: () async {
                      await widget.settings.setSpeechSpeed(speed);
                      if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                    },
                    child: Text(
                      _speedLabel(s, speed),
                      style: const TextStyle(
                        fontSize: 18,
                        color: AppColors.onSurface,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _speedLabel(AppStrings s, SpeechSpeed speed) => switch (speed) {
        SpeechSpeed.slow => s.speechSpeedSlow,
        SpeechSpeed.normal => s.speechSpeedNormal,
        SpeechSpeed.fast => s.speechSpeedFast,
      };

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.current;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.settings,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: <Widget>[
              ExcludeSemantics(
                child: Text(
                  s.settingsTitle,
                  style: const TextStyle(
                    color: AppColors.onSurface,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                s.settingsHint,
                style: const TextStyle(color: AppColors.onSurfaceMuted, fontSize: 13),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 60,
                child: OutlinedButton(
                  onPressed: _pickSpeed,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          s.speechSpeed,
                          style: const TextStyle(fontSize: 17),
                        ),
                      ),
                      Text(
                        _speedLabel(s, widget.settings.speechSpeed),
                        style: const TextStyle(color: AppColors.accent, fontSize: 17),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Semantics(
                readOnly: true,
                label: s.modelInfo,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        s.modelInfo,
                        style: const TextStyle(
                          color: AppColors.onSurfaceMuted,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 6),
                      FutureBuilder<String?>(
                        future: _summary,
                        builder: (context, snap) => Text(
                          snap.data ?? '—',
                          style: const TextStyle(
                            color: AppColors.onSurface,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back, size: 22),
                  label: Text(s.backToHome),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 6: 跑測試確認通過**

Run: `cd app; flutter test test/settings_page_test.dart`
Expected: PASS（3 條）

- [ ] **Step 7: Commit**

```bash
git add app/lib/ui/app_theme.dart app/lib/ui/settings_page.dart app/lib/l10n/app_strings.dart app/test/settings_page_test.dart
git commit -m "feat(ui): 設定頁（播報速度 + 模型資訊）與顏色 token"
```

---

### Task 4: 首頁加入設定入口（焦點站 2 → 3）

**Files:**
- Modify: `app/lib/ui/home_page.dart:44-84`（`build` 與 `_modeButton`）
- Modify: `app/lib/main.dart:12-25,94`（載入 `AppSettings` 後注入）
- Modify: `app/test/home_page_test.dart:130-140`（那條「只有兩個可操作項」）
- Test: `app/test/home_page_test.dart`

**Interfaces:**
- Consumes: `AppSettings`（Task 1）、`SettingsPage`（Task 3）
- Produces: `HomePage({Key? key, VisionSession? session, AppSettings? settings})`

- [ ] **Step 1: 改那條既有測試（先讓它失敗）**

把 `app/test/home_page_test.dart` 第 130–140 行那條：

```dart
  testWidgets('★ 可操作項只有兩個（焦點移動成本）', (tester) async {
    final session = VisionSession(
      speaker: _FakeSpeaker(),
      sourceFactory: () => _FakeSource(),
    );
    await pumpHome(tester, session: session);

    // 兩個按鈕，沒有裸 IconButton。
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(FilledButton), findsNWidgets(2));
  });
```

整條換成（沿用檔案裡既有的 `pumpHome` 與 `_FakeSpeaker`／`_FakeSource`，不要另造 helper）：

```dart
  testWidgets('★ 焦點順序：兩個模式在前，設定位於最後', (tester) async {
    final session = VisionSession(
      speaker: _FakeSpeaker(),
      sourceFactory: () => _FakeSource(),
    );
    await pumpHome(tester, session: session);

    // 兩個主模式仍是 FilledButton（強調動作），設定是次級的 OutlinedButton：
    // 形狀不同，所以「按下去會發生什麼」不需要靠顏色分辨。
    expect(find.byType(FilledButton), findsNWidgets(2));
    expect(find.byType(OutlinedButton), findsOneWidget);
    // 仍然不允許裸圖標充當按鈕
    expect(find.byType(IconButton), findsNothing);

    // 設定必須排在最後：從桌面圖標到「開始引導」仍是第 1 個焦點站。
    final guideTop = tester.getTopLeft(find.text('開始引導')).dy;
    final settingsTop = tester.getTopLeft(find.text('設定')).dy;
    expect(settingsTop, greaterThan(guideTop), reason: '設定不得排在主模式之前');
  });
```

同一個檔案裡若還有其他 `find.text('設定')` 衝突（例如新增字串與既有台詞同名），把該斷言改成
`find.widgetWithText(OutlinedButton, '設定')`。

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app; flutter test test/home_page_test.dart`
Expected: FAIL — `Expected: exactly one matching candidate; Actual: _OutlinedButtonFinder:<zero widgets>`

- [ ] **Step 3: 實作首頁**

在 `app/lib/ui/home_page.dart`：

```dart
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.session, this.settings});

  /// 相機與語音的共用持有者。預設自己建一個；測試注入假的。
  final VisionSession? session;

  /// 使用者設定。沒注入就建一個純記憶體的（測試、或直接開這一頁時）。
  final AppSettings? settings;
```

State 內改用：

```dart
  late final VisionSession _session = widget.session ?? VisionSession();
  late final AppSettings _settings = widget.settings ?? AppSettings.memory();
```

`build` 的 `Column` 在兩顆模式按鈕之後、`Spacer()` 之前插入：

```dart
              const SizedBox(height: 24),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: () => _open(SettingsPage(settings: _settings)),
                  icon: const Icon(Icons.settings_outlined, size: 22),
                  label: Text(
                    s.settingsTitle,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
```

並在 `dispose` 之後（或 State 內加）：

```dart
  @override
  void initState() {
    super.initState();
    // 把已保存的語速套上去，否則使用者的設定要等到下一次播報才生效。
    unawaited(_session.applySpeechRate(_settings.ttsRate));
    _settings.addListener(() => unawaited(_session.applySpeechRate(_settings.ttsRate)));
  }
```

（`import 'dart:async';`、`import '../settings/app_settings.dart';`、`import 'settings_page.dart';` 一併補上。）

在 `app/lib/main.dart`，把 `main()` 改成：

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLocale.current = AppLocale.resolve();

  // 讀設定要 await：語速必須在第一句播報之前就位。
  final settings = await AppSettings.load();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0xFF161B22),
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF161B22),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(PathGuideApp(settings: settings));
}
```

`PathGuideApp` 加 `final AppSettings? settings;`（`const PathGuideApp({super.key, this.settings})`），
`home: HomePage(settings: widget.settings)`。

- [ ] **Step 4: 跑測試與靜態檢查**

Run: `cd app; flutter test test/home_page_test.dart; flutter analyze`
Expected: PASS（`home_page_test.dart` 全綠）、`No issues found!`

- [ ] **Step 5: Commit**

```bash
git add app/lib/ui/home_page.dart app/lib/main.dart app/test/home_page_test.dart
git commit -m "feat(ui): 首頁加入設定入口（焦點順序：模式在前、設定最後）"
```

---

### Task 5: API 資料模型與介面

**Files:**
- Create: `app/lib/api/api_types.dart`
- Create: `app/lib/api/path_guide_api.dart`
- Test: `app/test/api_types_test.dart`

**Interfaces:**
- Produces（後續任務全部依賴這些名字與型別）:
  - `class GuestSession { final String guestId; final String token; final DateTime expiresAt; }`
  - `class AuthSession { final String userId; final String token; final DateTime expiresAt; }`
  - `class UploadFrameRequest { final String framePath; final DateTime capturedAt; final String modelVersion; final String? routeId; final double? latitude; final double? longitude; }`
  - `class UploadReceipt { final String frameId; final String status; }`（`status` 取值見 spec §6 狀態機）
  - `class ModelEnvelope { final String version; final int bytes; final int modelClassCount; final int inputSize; final List<int> modelClassIds; final String sha256; final String downloadUrl; }`
  - `class ApiFailure implements Exception { final String code; final String message; final bool retryable; }`
  - `class ApiNotAvailable extends ApiFailure`（無參建構，`code: 'not_available'`）
  - `abstract interface class PathGuideApi`，方法：
    - `Future<GuestSession> createGuestSession({required String installId, required String platform, required String locale})`
    - `Future<AuthSession> login({required String method, required String credential})`
    - `Future<AuthSession> refresh({required String token})`
    - `Future<UploadReceipt> uploadFrame({required String token, required UploadFrameRequest request})`
    - `Future<ModelEnvelope> latestModel()`
    - `Future<Map<String, Object?>> fetchSettings({required String token})`
    - `Future<void> saveSettings({required String token, required Map<String, Object?> settings})`
    - `Future<Map<String, Object?>> visionQuery({required String token, required String imageSha256, required String question, required String locale})`
    - `Future<Map<String, Object?>> planRoute({required String token, required String utterance, required String locale})`

- [ ] **Step 1: 寫失敗測試**

```dart
// app/test/api_types_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/api_types.dart';

void main() {
  test('ApiFailure 帶機器可讀的 code 與是否可重試', () {
    const f = ApiFailure(code: 'network', message: '暫時連不上', retryable: true);
    expect(f.code, 'network');
    expect(f.retryable, isTrue);
    expect(f.toString(), contains('network'));
  });

  test('ApiNotAvailable 是不可重試的「尚未提供」', () {
    final f = ApiNotAvailable();
    expect(f.code, 'not_available');
    expect(f.retryable, isFalse);
    expect(f.message, isNotEmpty);
  });

  test('UploadFrameRequest 的 gps 可以缺席（室內錄製沒有定位）', () {
    final r = UploadFrameRequest(
      framePath: '/tmp/a.jpg',
      capturedAt: DateTime.utc(2026, 10, 23),
      modelVersion: '2026-10-02.stage2',
    );
    expect(r.latitude, isNull);
    expect(r.routeId, isNull);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app; flutter test test/api_types_test.dart`
Expected: FAIL — 找不到 `package:pathguide/api/api_types.dart`

- [ ] **Step 3: 實作資料模型**

```dart
// app/lib/api/api_types.dart
/// API 的資料模型。**這裡是唯一事實源**：欄位名與 spec §4 一致。
///
/// 為什麼不用 JSON 直接滿天飛：契約一旦漂移不會報錯，只會安靜地少一個欄位。
class GuestSession {
  const GuestSession({
    required this.guestId,
    required this.token,
    required this.expiresAt,
  });

  final String guestId;
  final String token;
  final DateTime expiresAt;
}

class AuthSession {
  const AuthSession({
    required this.userId,
    required this.token,
    required this.expiresAt,
  });

  final String userId;
  final String token;
  final DateTime expiresAt;
}

/// 一幀要上傳的素材（錄製路線或未識別障礙物）。
class UploadFrameRequest {
  const UploadFrameRequest({
    required this.framePath,
    required this.capturedAt,
    required this.modelVersion,
    this.routeId,
    this.latitude,
    this.longitude,
  });

  final String framePath;
  final DateTime capturedAt;
  final String modelVersion;
  final String? routeId;

  /// 室內錄製沒有定位；兩個都為 null 表示「無 GPS」。
  final double? latitude;
  final double? longitude;
}

/// 上傳回執。`status` 用 spec §6 的狀態機字串。
class UploadReceipt {
  const UploadReceipt({required this.frameId, required this.status});

  final String frameId;
  final String status;
}

/// 模型清單（與 `assets/models/detector.json` 同 schema，另加下載資訊）。
class ModelEnvelope {
  const ModelEnvelope({
    required this.version,
    required this.bytes,
    required this.modelClassCount,
    required this.inputSize,
    required this.modelClassIds,
    required this.sha256,
    required this.downloadUrl,
  });

  final String version;
  final int bytes;
  final int modelClassCount;
  final int inputSize;
  final List<int> modelClassIds;
  final String sha256;
  final String downloadUrl;
}

class ApiFailure implements Exception {
  const ApiFailure({
    required this.code,
    required this.message,
    required this.retryable,
  });

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => 'ApiFailure($code): $message';
}

/// Spec 4/5 的端點在 Spec 1 尚未實作。**明確報「尚未提供」而不是假裝成功**。
class ApiNotAvailable extends ApiFailure {
  ApiNotAvailable([String message = '此功能尚未提供'])
      : super(code: 'not_available', message: message, retryable: false);
}
```

- [ ] **Step 4: 實作介面**

```dart
// app/lib/api/path_guide_api.dart
import 'api_types.dart';

/// 前端唯一的後端門面。**UI 只認這個介面**。
///
/// 三份實現：`LocalOnlyApi`（訪客/離線）、`HttpApi`（真 HTTP）、
/// 以及測試用的 `FakeTransport` 驅動的 `HttpApi`。
/// 換後端時只換實現，UI 一行不改（spec §13 驗收）。
abstract interface class PathGuideApi {
  Future<GuestSession> createGuestSession({
    required String installId,
    required String platform,
    required String locale,
  });

  Future<AuthSession> login({required String method, required String credential});

  Future<AuthSession> refresh({required String token});

  Future<UploadReceipt> uploadFrame({
    required String token,
    required UploadFrameRequest request,
  });

  Future<ModelEnvelope> latestModel();

  Future<Map<String, Object?>> fetchSettings({required String token});

  Future<void> saveSettings({
    required String token,
    required Map<String, Object?> settings,
  });

  /// Spec 4：雲端 VLM 問答。
  Future<Map<String, Object?>> visionQuery({
    required String token,
    required String imageSha256,
    required String question,
    required String locale,
  });

  /// Spec 5：對話式目的地規劃。
  Future<Map<String, Object?>> planRoute({
    required String token,
    required String utterance,
    required String locale,
  });
}
```

- [ ] **Step 5: 跑測試確認通過**

Run: `cd app; flutter test test/api_types_test.dart`
Expected: PASS（3 條）

- [ ] **Step 6: Commit**

```bash
git add app/lib/api/api_types.dart app/lib/api/path_guide_api.dart app/test/api_types_test.dart
git commit -m "feat(api): API 資料模型與 PathGuideApi 介面"
```

---

### Task 6: `LocalOnlyApi`（訪客/離線，永不發請求）

**Files:**
- Create: `app/lib/api/local_only_api.dart`
- Test: `app/test/local_only_api_test.dart`

**Interfaces:**
- Consumes: `PathGuideApi`、`api_types.dart`（Task 5）
- Produces:
  - `class LocalOnlyApi implements PathGuideApi`
    - 建構子 `LocalOnlyApi({required String installId, String platform = 'android', String locale = 'zh-HK', String? guestToken})`
    - `createGuestSession` / `latestModel` 可用；`login` / `refresh` / `uploadFrame` / `fetchSettings` / `saveSettings` 一律拋 `ApiNotAvailable`；`visionQuery` / `planRoute` 拋 `ApiNotAvailable`

- [ ] **Step 1: 寫失敗測試**

```dart
// app/test/local_only_api_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/api_types.dart';
import 'package:pathguide/api/local_only_api.dart';

void main() {
  final api = LocalOnlyApi(installId: 'install-1');

  test('★ 訪客身分可離線取得，且同一個 installId 拿到同一個 guestId', () async {
    final a = await api.createGuestSession(
        installId: 'install-1', platform: 'android', locale: 'zh-HK');
    final b = await api.createGuestSession(
        installId: 'install-1', platform: 'android', locale: 'zh-HK');
    expect(a.guestId, b.guestId);
    expect(a.token, isNotEmpty);
  });

  test('★ 需要登入的端點一律明確說「尚未提供」，不假裝成功', () async {
    await expectLater(
      api.uploadFrame(
        token: 't',
        request: UploadFrameRequest(
          framePath: '/tmp/a.jpg',
          capturedAt: DateTime.utc(2026, 10, 23),
          modelVersion: 'v',
        ),
      ),
      throwsA(isA<ApiNotAvailable>()),
    );
    await expectLater(api.fetchSettings(token: 't'),
        throwsA(isA<ApiNotAvailable>()));
    await expectLater(
        api.visionQuery(
            token: 't', imageSha256: 'x', question: '有沒有牛河', locale: 'zh-HK'),
        throwsA(isA<ApiNotAvailable>()));
    await expectLater(
        api.planRoute(token: 't', utterance: '去彩明商場', locale: 'zh-HK'),
        throwsA(isA<ApiNotAvailable>()));
  });

  test('模型清單在離線時取端上清單的版本（不假裝有下載地址）', () async {
    final m = await api.latestModel();
    expect(m.version, isNotEmpty);
    expect(m.downloadUrl, isEmpty, reason: '離線時沒有下載地址，不可編一個出來');
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app; flutter test test/local_only_api_test.dart`
Expected: FAIL — 找不到 `package:pathguide/api/local_only_api.dart`

- [ ] **Step 3: 實作**

```dart
// app/lib/api/local_only_api.dart
import 'package:flutter/services.dart' show rootBundle;

import '../vision/model_manifest.dart';
import '../vision/platform_vision.dart' show defaultModelManifestKey;
import 'api_types.dart';
import 'path_guide_api.dart';

/// 訪客／離線時的實現：**一個網絡請求都不發**。
///
/// 存在的意義：讓「未登入也能完整使用」這條規則有**可測的代碼**，
/// 而不是靠「我們沒調那個接口」這種口頭保證。
class LocalOnlyApi implements PathGuideApi {
  LocalOnlyApi({
    required this.installId,
    this.platform = 'android',
    this.locale = 'zh-HK',
    String? guestToken,
  }) : _guestToken = guestToken ?? 'local-guest-${installId.hashCode}';

  final String installId;
  final String platform;
  final String locale;
  final String _guestToken;

  /// 訪客身分是本機推導的：同一個安裝就是同一個 guestId。
  /// 這讓「沒有網也能當訪客」成立（spec §4.1）。
  @override
  Future<GuestSession> createGuestSession({
    required String installId,
    required String platform,
    required String locale,
  }) async {
    return GuestSession(
      guestId: 'guest-$installId',
      token: _guestToken,
      expiresAt: DateTime.now().add(const Duration(days: 3650)),
    );
  }

  @override
  Future<ModelEnvelope> latestModel() async {
    final parsed =
        parseModelManifest(await rootBundle.loadString(defaultModelManifestKey));
    final m = parsed.manifest;
    if (m == null) {
      throw ApiFailure(
          code: 'manifest_bad', message: '端上模型清單無法解析', retryable: false);
    }
    return ModelEnvelope(
      version: m.version,
      bytes: m.bytes,
      modelClassCount: m.modelClassCount,
      inputSize: m.inputSize,
      modelClassIds: m.modelClassIds,
      sha256: m.sha256,
      downloadUrl: '',
    );
  }

  @override
  Future<AuthSession> login(
          {required String method, required String credential}) =>
      throw ApiNotAvailable('尚未提供登入服務');

  @override
  Future<AuthSession> refresh({required String token}) =>
      throw ApiNotAvailable('尚未提供登入服務');

  @override
  Future<UploadReceipt> uploadFrame(
          {required String token, required UploadFrameRequest request}) =>
      throw ApiNotAvailable('上傳需要登入與後端');

  @override
  Future<Map<String, Object?>> fetchSettings({required String token}) =>
      throw ApiNotAvailable('跨端同步尚未提供');

  @override
  Future<void> saveSettings(
          {required String token, required Map<String, Object?> settings}) =>
      throw ApiNotAvailable('跨端同步尚未提供');

  @override
  Future<Map<String, Object?>> visionQuery({
    required String token,
    required String imageSha256,
    required String question,
    required String locale,
  }) =>
      throw ApiNotAvailable('雲端問答尚未提供');

  @override
  Future<Map<String, Object?>> planRoute({
    required String token,
    required String utterance,
    required String locale,
  }) =>
      throw ApiNotAvailable('路線規劃尚未提供');
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd app; flutter test test/local_only_api_test.dart`
Expected: PASS（3 條）

- [ ] **Step 5: Commit**

```bash
git add app/lib/api/local_only_api.dart app/test/local_only_api_test.dart
git commit -m "feat(api): LocalOnlyApi —— 訪客/離線時不發任何請求"
```

---

### Task 7: `HttpApi` + `HttpClientTransport` 與契約測試

**Files:**
- Create: `app/lib/api/http_transport.dart`
- Create: `app/lib/api/http_api.dart`
- Test: `app/test/http_api_test.dart`

**Interfaces:**
- Consumes: `PathGuideApi`、`api_types.dart`（Task 5）
- Produces:
  - `class TransportRequest { final String method; final Uri url; final Map<String, String> headers; final List<int>? jsonBody; final Map<String, String>? fields; final String? uploadFilePath; }`
  - `class TransportResponse { final int statusCode; final String body; }`
  - `abstract interface class HttpTransport { Future<TransportResponse> send(TransportRequest request); }`
  - `class HttpClientTransport implements HttpTransport`（`dart:io`）
  - `class HttpApi implements PathGuideApi`：建構子 `HttpApi({required Uri baseUrl, required HttpTransport transport, String? token})`、`void setToken(String? token)`

- [ ] **Step 1: 寫失敗測試**

```dart
// app/test/http_api_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/api_types.dart';
import 'package:pathguide/api/http_api.dart';
import 'package:pathguide/api/http_transport.dart';

class _FakeTransport implements HttpTransport {
  final List<TransportRequest> requests = <TransportRequest>[];
  TransportResponse response =
      const TransportResponse(statusCode: 200, body: '{}');

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    requests.add(request);
    return response;
  }
}

void main() {
  late _FakeTransport transport;
  late HttpApi api;

  setUp(() {
    transport = _FakeTransport();
    api = HttpApi(baseUrl: Uri.parse('https://api.example.test'), transport: transport);
  });

  test('★ login 打的是 POST /v1/auth/login 且帶 JSON body', () async {
    transport.response = TransportResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{
        'userId': 'u1',
        'token': 'tk',
        'expiresAt': '2026-12-31T00:00:00Z',
      }),
    );

    final s = await api.login(method: 'email', credential: 'c');

    final r = transport.requests.single;
    expect(r.method, 'POST');
    expect(r.url.toString(), 'https://api.example.test/v1/auth/login');
    expect(jsonDecode(utf8.decode(r.jsonBody!)),
        <String, Object?>{'method': 'email', 'credential': 'c'});
    expect(s.userId, 'u1');
    expect(s.token, 'tk');
  });

  test('★ 401 映射成可重取的 AuthExpired（code=auth_expired）', () async {
    transport.response =
        const TransportResponse(statusCode: 401, body: '{"code":"expired"}');
    await expectLater(
      api.fetchSettings(token: 't'),
      throwsA(isA<ApiFailure>()
          .having((f) => f.code, 'code', 'auth_expired')
          .having((f) => f.retryable, 'retryable', isTrue)),
    );
  });

  test('★ 5xx 不可重試、4xx 也不可重試，只有 408/429 可', () async {
    transport.response = const TransportResponse(statusCode: 500, body: '');
    await expectLater(api.latestModel(),
        throwsA(isA<ApiFailure>().having((f) => f.retryable, 'retryable', isFalse)));

    transport.response = const TransportResponse(statusCode: 429, body: '');
    await expectLater(api.latestModel(),
        throwsA(isA<ApiFailure>().having((f) => f.retryable, 'retryable', isTrue)));
  });

  test('★ 上傳走 multipart 欄位，檔名與 modelVersion 都在', () async {
    transport.response = const TransportResponse(
        statusCode: 200, body: '{"frameId":"f1","status":"queued"}');
    final receipt = await api.uploadFrame(
      token: 't',
      request: UploadFrameRequest(
        framePath: '/tmp/frame_1.jpg',
        capturedAt: DateTime.utc(2026, 10, 23, 1, 2, 3),
        modelVersion: '2026-10-02.stage2',
        routeId: 'r1',
      ),
    );

    final r = transport.requests.single;
    expect(r.url.path, '/v1/frames');
    expect(r.uploadFilePath, '/tmp/frame_1.jpg');
    expect(r.fields!['modelVersion'], '2026-10-02.stage2');
    expect(r.fields!['routeId'], 'r1');
    expect(r.fields!['capturedAt'], '2026-10-23T01:02:03.000Z');
    expect(receipt.frameId, 'f1');
    expect(receipt.status, 'queued');
  });

  test('有 token 時帶 Authorization，沒有則不帶', () async {
    api.setToken('abc');
    transport.response = const TransportResponse(statusCode: 200, body: '{}');
    await api.latestModel();
    expect(transport.requests.single.headers['Authorization'], 'Bearer abc');

    api.setToken(null);
    await api.latestModel();
    expect(transport.requests.last.headers.containsKey('Authorization'), isFalse);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app; flutter test test/http_api_test.dart`
Expected: FAIL — 找不到 `package:pathguide/api/http_transport.dart`

- [ ] **Step 3: 實作 transport**

```dart
// app/lib/api/http_transport.dart
import 'dart:convert';
import 'dart:io';

/// 一次 HTTP 請求的描述。刻意**不用** `dio`／`http`：
/// 本倉庫路徑含空格，任何新依賴都要先證明能構建（spec §1.3）。
class TransportRequest {
  const TransportRequest({
    required this.method,
    required this.url,
    this.headers = const <String, String>{},
    this.jsonBody,
    this.fields,
    this.uploadFilePath,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int>? jsonBody;

  /// multipart 的文字欄位（`modelVersion`／`routeId` 等）。
  final Map<String, String>? fields;

  /// multipart 的檔案欄位（一幀 JPEG）。
  final String? uploadFilePath;
}

class TransportResponse {
  const TransportResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

abstract interface class HttpTransport {
  Future<TransportResponse> send(TransportRequest request);
}

/// 真正的 HTTP 實現。
///
/// multipart 手寫而不是靠套件：邊界字串用固定前綴＋時間戳，
/// 內容只有「文字欄位 + 一個二進位檔」這種最簡情況。
class HttpClientTransport implements HttpTransport {
  HttpClientTransport({HttpClient? client})
      : _client = client ?? HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);

  final HttpClient _client;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final req = await _client.openUrl(request.method, request.url);
    request.headers.forEach(req.headers.set);

    if (request.uploadFilePath != null) {
      final boundary =
          '----pathguide${DateTime.now().microsecondsSinceEpoch}';
      req.headers.set('Content-Type',
          'multipart/form-data; boundary=$boundary');
      final file = File(request.uploadFilePath!);
      final bytes = await file.readAsBytes();
      final head = StringBuffer();
      (request.fields ?? const <String, String>{}).forEach((k, v) {
        head.write('--$boundary\r\n');
        head.write('Content-Disposition: form-data; name="$k"\r\n\r\n');
        head.write('$v\r\n');
      });
      head.write('--$boundary\r\n');
      head.write('Content-Disposition: form-data; name="frame"; '
          'filename="${file.uri.pathSegments.last}"\r\n');
      head.write('Content-Type: image/jpeg\r\n\r\n');
      req.add(utf8.encode(head.toString()));
      req.add(bytes);
      req.add(utf8.encode('\r\n--$boundary--\r\n'));
    } else if (request.jsonBody != null) {
      req.headers.contentType = ContentType.json;
      req.add(request.jsonBody!);
    }

    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    return TransportResponse(statusCode: res.statusCode, body: body);
  }
}
```

- [ ] **Step 4: 實作 `HttpApi`**

```dart
// app/lib/api/http_api.dart
import 'dart:convert';

import 'api_types.dart';
import 'http_transport.dart';
import 'path_guide_api.dart';

/// 真 HTTP 實現。所有狀態碼到 [ApiFailure] 的映射集中在 [_send]。
class HttpApi implements PathGuideApi {
  HttpApi({required this.baseUrl, required this.transport, String? token})
      : _token = token;

  final Uri baseUrl;
  final HttpTransport transport;
  String? _token;

  void setToken(String? token) => _token = token;

  Map<String, String> get _headers {
    final h = <String, String>{'Accept': 'application/json'};
    final t = _token;
    if (t != null && t.isNotEmpty) h['Authorization'] = 'Bearer $t';
    return h;
  }

  Uri _u(String path) => baseUrl.resolve(path);

  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? fields,
    String? uploadFilePath,
  }) async {
    final res = await transport.send(TransportRequest(
      method: method,
      url: _u(path),
      headers: _headers,
      jsonBody: body == null ? null : utf8.encode(jsonEncode(body)),
      fields: fields,
      uploadFilePath: uploadFilePath,
    ));

    if (res.statusCode == 401) {
      throw const ApiFailure(
          code: 'auth_expired', message: '登入已過期', retryable: true);
    }
    if (res.statusCode == 408 || res.statusCode == 429) {
      throw ApiFailure(
          code: 'network',
          message: '暫時連不上（${res.statusCode}）',
          retryable: true);
    }
    if (res.statusCode >= 500) {
      throw ApiFailure(
          code: 'server',
          message: '伺服器暫時有問題（${res.statusCode}）',
          retryable: false);
    }
    if (res.statusCode >= 400) {
      throw ApiFailure(
          code: 'client',
          message: '請求不被接受（${res.statusCode}）',
          retryable: false);
    }
    if (res.body.trim().isEmpty) return <String, Object?>{};
    final decoded = jsonDecode(res.body);
    return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
  }

  static DateTime _asDate(Object? v) =>
      DateTime.tryParse('$v') ?? DateTime.now().toUtc();

  @override
  Future<GuestSession> createGuestSession({
    required String installId,
    required String platform,
    required String locale,
  }) async {
    final m = await _send('POST', '/v1/auth/guest', body: <String, Object?>{
      'installId': installId,
      'platform': platform,
      'locale': locale,
    });
    return GuestSession(
      guestId: '${m['guestId']}',
      token: '${m['token']}',
      expiresAt: _asDate(m['expiresAt']),
    );
  }

  @override
  Future<AuthSession> login(
      {required String method, required String credential}) async {
    final m = await _send('POST', '/v1/auth/login',
        body: <String, Object?>{'method': method, 'credential': credential});
    return AuthSession(
      userId: '${m['userId']}',
      token: '${m['token']}',
      expiresAt: _asDate(m['expiresAt']),
    );
  }

  @override
  Future<AuthSession> refresh({required String token}) async {
    final m = await _send('POST', '/v1/auth/refresh',
        body: <String, Object?>{'token': token});
    return AuthSession(
      userId: '${m['userId'] ?? ''}',
      token: '${m['token']}',
      expiresAt: _asDate(m['expiresAt']),
    );
  }

  @override
  Future<UploadReceipt> uploadFrame({
    required String token,
    required UploadFrameRequest request,
  }) async {
    final fields = <String, String>{
      'capturedAt': request.capturedAt.toUtc().toIso8601String(),
      'modelVersion': request.modelVersion,
      if (request.routeId != null) 'routeId': request.routeId!,
      if (request.latitude != null) 'lat': '${request.latitude}',
      if (request.longitude != null) 'lng': '${request.longitude}',
    };
    final m = await _send('POST', '/v1/frames',
        fields: fields, uploadFilePath: request.framePath);
    return UploadReceipt(
      frameId: '${m['frameId']}',
      status: '${m['status']}',
    );
  }

  @override
  Future<ModelEnvelope> latestModel() async {
    final m = await _send('GET', '/v1/models/latest');
    return ModelEnvelope(
      version: '${m['version']}',
      bytes: (m['bytes'] as num?)?.toInt() ?? 0,
      modelClassCount: (m['modelClassCount'] as num?)?.toInt() ?? 0,
      inputSize: (m['inputSize'] as num?)?.toInt() ?? 0,
      modelClassIds: <int>[
        for (final id in (m['modelClassIds'] as List? ?? const <Object?>[]))
          (id as num).toInt(),
      ],
      sha256: '${m['sha256'] ?? ''}',
      downloadUrl: '${m['downloadUrl'] ?? ''}',
    );
  }

  @override
  Future<Map<String, Object?>> fetchSettings({required String token}) =>
      _send('GET', '/v1/settings');

  @override
  Future<void> saveSettings({
    required String token,
    required Map<String, Object?> settings,
  }) async {
    await _send('PUT', '/v1/settings',
        body: <String, Object?>{'settings': settings});
  }

  @override
  Future<Map<String, Object?>> visionQuery({
    required String token,
    required String imageSha256,
    required String question,
    required String locale,
  }) =>
      // Spec 4 尚未實作：打到真實端點，但契約已定（spec §7）。
      _send('POST', '/v1/vision/query', body: <String, Object?>{
        'imageSha256': imageSha256,
        'question': question,
        'locale': locale,
      });

  @override
  Future<Map<String, Object?>> planRoute({
    required String token,
    required String utterance,
    required String locale,
  }) =>
      _send('POST', '/v1/plan',
          body: <String, Object?>{'utterance': utterance, 'locale': locale});
}
```

- [ ] **Step 5: 跑測試確認通過**

Run: `cd app; flutter test test/http_api_test.dart`
Expected: PASS（6 條）

- [ ] **Step 6: Commit**

```bash
git add app/lib/api/http_transport.dart app/lib/api/http_api.dart app/test/http_api_test.dart
git commit -m "feat(api): HttpApi 與 dart:io 傳輸層，含狀態碼映射"
```

---

### Task 8: `FeatureGate`（訪客/登入門禁）

**Files:**
- Create: `app/lib/api/feature_gate.dart`
- Test: `app/test/feature_gate_test.dart`

**Interfaces:**
- Consumes: `AppStrings`（可操作提示要顯示「解鎖方式」）
- Produces:
  - `enum CloudCapability { uploadFrames, syncSettings, visionQuery, planRoute }`
  - `enum SessionState { guest, authenticated }`
  - `class FeatureGate { FeatureGate({required SessionState state, required bool isOnline}); SessionState state; bool isOnline; bool allows(CloudCapability c); String denialMessage(CloudCapability c); }`

- [ ] **Step 1: 寫失敗測試**

```dart
// app/test/feature_gate_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/feature_gate.dart';
import 'package:pathguide/l10n/app_locale.dart';

void main() {
  setUp(() => AppLocale.current = AppLanguage.zh);

  test('★ 訪客一律不允許雲能力，且提示要說出「怎麼解鎖」', () {
    const gate =
        FeatureGate(state: SessionState.guest, isOnline: true);
    for (final c in CloudCapability.values) {
      expect(gate.allows(c), isFalse, reason: '$c 不該對訪客開放');
      final msg = gate.denialMessage(c);
      expect(msg, isNotEmpty);
      expect(msg, contains('登入'), reason: '提示必須告訴使用者怎麼解鎖');
    }
  });

  test('★ 已登入但離線：仍不允許（雲能力本來就需要網）', () {
    const gate =
        FeatureGate(state: SessionState.authenticated, isOnline: false);
    expect(gate.allows(CloudCapability.uploadFrames), isFalse);
    expect(gate.denialMessage(CloudCapability.uploadFrames), contains('網絡'));
  });

  test('已登入且有網：全部允許', () {
    const gate =
        FeatureGate(state: SessionState.authenticated, isOnline: true);
    for (final c in CloudCapability.values) {
      expect(gate.allows(c), isTrue);
    }
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app; flutter test test/feature_gate_test.dart`
Expected: FAIL — 找不到 `package:pathguide/api/feature_gate.dart`

- [ ] **Step 3: 實作**

```dart
// app/lib/api/feature_gate.dart
import '../l10n/app_strings.dart';

/// 需要登入與網路的雲能力。**核心識別不在此列**（spec §1.1）。
enum CloudCapability { uploadFrames, syncSettings, visionQuery, planRoute }

enum SessionState { guest, authenticated }

/// 能力門禁。刻意只有兩態（訪客／已登入）＋一個離線修飾位。
///
/// 為什麼不做「部分登入」：那種狀態沒有任何人測得完，
/// 而這裡判斷錯的代價是「盲人在街上以為功能可用」。
class FeatureGate {
  const FeatureGate({required this.state, required this.isOnline});

  final SessionState state;
  final bool isOnline;

  bool allows(CloudCapability capability) =>
      state == SessionState.authenticated && isOnline;

  /// 給 TTS／畫面用的**可操作**說明：不是「無權限」，而是「怎麼才能用」。
  String denialMessage(CloudCapability capability) {
    final s = AppStrings.current;
    if (state == SessionState.guest) {
      return s.deniedNeedsLogin;
    }
    return s.deniedNeedsNetwork;
  }
}
```

在 `app/lib/l10n/app_strings.dart` 追加：

```dart
  String get deniedNeedsLogin =>
      _zh ? '這功能需要登入；未登入時識別仍可完整使用' : 'Sign in for this feature. Detection works without it';

  String get deniedNeedsNetwork =>
      _zh ? '暫時沒有網絡；識別不受影響' : 'No network right now. Detection is unaffected';
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd app; flutter test test/feature_gate_test.dart`
Expected: PASS（3 條）

- [ ] **Step 5: Commit**

```bash
git add app/lib/api/feature_gate.dart app/lib/l10n/app_strings.dart app/test/feature_gate_test.dart
git commit -m "feat(api): FeatureGate 能力門禁（訪客可用核心功能，雲能力需登入）"
```

---

### Task 9: 上傳隊列（落盤、去重、退避）

**Files:**
- Create: `app/lib/api/upload_queue.dart`
- Test: `app/test/upload_queue_test.dart`

**Interfaces:**
- Consumes: `PathGuideApi`、`UploadFrameRequest`、`ApiFailure`（Task 5/7）、`FeatureGate`（Task 8）
- Produces:
  - `abstract interface class FrameStore { Future<List<String>> pendingPaths(); Future<void> remove(String path); }`
  - `class UploadQueue`
    - `UploadQueue({required PathGuideApi api, required FrameStore store, required FeatureGate Function() gate, required String Function() token, int maxItems = 500})`
    - `Future<int> flush()` → 回傳成功送出張數
    - `static const int defaultMaxItems = 500`

> **去重鍵的偏離說明（與 spec §5 的差異）**：spec 寫 `sha256(檔案)`，但 `dart:core` 沒有 sha256，
> 要嘛加 `crypto` 依賴、要嘛走原生通道。本計劃改用**檔案路徑**作去重鍵
> （我們自己命名檔案，路徑唯一），並在 `UploadQueue` 的類註解寫明這個限制。
> 若之後允許加 `crypto`，只需換 `_keyFor`。

- [ ] **Step 1: 寫失敗測試**

```dart
// app/test/upload_queue_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/api_types.dart';
import 'package:pathguide/api/feature_gate.dart';
import 'package:pathguide/api/path_guide_api.dart';
import 'package:pathguide/api/upload_queue.dart';

class _RecordingApi implements PathGuideApi {
  final List<String> uploaded = <String>[];
  final Set<String> failing = <String>{};

  @override
  Future<UploadReceipt> uploadFrame({
    required String token,
    required UploadFrameRequest request,
  }) async {
    if (failing.contains(request.framePath)) {
      throw const ApiFailure(code: 'network', message: 'x', retryable: true);
    }
    uploaded.add(request.framePath);
    return const UploadReceipt(frameId: 'f', status: 'queued');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryStore implements FrameStore {
  _MemoryStore(this.files);
  final List<String> files;
  final List<String> removed = <String>[];

  @override
  Future<List<String>> pendingPaths() async => List<String>.from(files);

  @override
  Future<void> remove(String path) async {
    files.remove(path);
    removed.add(path);
  }
}

UploadFrameRequest _req(String path) => UploadFrameRequest(
      framePath: path,
      capturedAt: DateTime.utc(2026, 10, 23),
      modelVersion: 'v',
    );

void main() {
  const signedInOnline =
      FeatureGate(state: SessionState.authenticated, isOnline: true);
  const guest = FeatureGate(state: SessionState.guest, isOnline: true);

  test('★ 訪客不上傳（不是靜默失敗，而是根本不排隊送出）', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['a.jpg']);
    final q = UploadQueue(
        api: api, store: store, gate: () => guest, token: () => 't');

    expect(await q.flush(), 0);
    expect(api.uploaded, isEmpty);
    expect(store.files, <String>['a.jpg'], reason: '訪客時素材應留在本機');
  });

  test('★ 已登入在線：成功送出的會從本機刪除', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['a.jpg', 'b.jpg']);
    final q = UploadQueue(
        api: api, store: store, gate: () => signedInOnline, token: () => 't');

    expect(await q.flush(), 2);
    expect(api.uploaded, <String>['a.jpg', 'b.jpg']);
    expect(store.files, isEmpty);
  });

  test('★ 失敗的留著，下次再送；已送出的不重送（去重）', () async {
    final api = _RecordingApi()..failing.add('b.jpg');
    final store = _MemoryStore(<String>['a.jpg', 'b.jpg']);
    final q = UploadQueue(
        api: api, store: store, gate: () => signedInOnline, token: () => 't');

    expect(await q.flush(), 1);
    expect(store.files, <String>['b.jpg']);

    api.failing.clear();
    expect(await q.flush(), 1);
    expect(api.uploaded, <String>['a.jpg', 'b.jpg'], reason: 'a 不該被重送');
    expect(store.files, isEmpty);
  });

  test('超過上限時丟最舊的，不讓隊列無限長大', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['1.jpg', '2.jpg', '3.jpg']);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      maxItems: 2,
    );

    await q.trim();
    expect(store.files, <String>['2.jpg', '3.jpg']);
  });
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app; flutter test test/upload_queue_test.dart`
Expected: FAIL — 找不到 `package:pathguide/api/upload_queue.dart`

- [ ] **Step 3: 實作**

```dart
// app/lib/api/upload_queue.dart
import 'api_types.dart';
import 'feature_gate.dart';
import 'path_guide_api.dart';

/// 待上傳素材的來源。真實實現讀應用私有目錄；測試用記憶體。
abstract interface class FrameStore {
  Future<List<String>> pendingPaths();
  Future<void> remove(String path);
}

/// 上傳隊列：**先落盤、後送出、失敗保留**。
///
/// ## 幾個刻意的決定
///
/// 1. **訪客不送出**：`FeatureGate` 不允許時直接返回 0，素材留在本機。
///    這不是錯誤，所以不丟例外——呼叫方不該把它當故障處理。
/// 2. **去重鍵用檔案路徑**（偏離 spec §5 的 sha256）：`dart:core` 沒有 sha256，
///    加 `crypto` 會多一個依賴；而素材檔名由我們自己產生，路徑本來就唯一。
///    之後若允許 `crypto`，只換 `_keyFor` 即可。
/// 3. **失敗保留但不無限重試**：本類別不做定時器，由呼叫方（畫面或前景服務）
///    決定何時 `flush()`。後端 5xx 不可重試的錯誤也會留著，等下一次人工觸發。
class UploadQueue {
  UploadQueue({
    required this.api,
    required this.store,
    required this.gate,
    required this.token,
    this.maxItems = defaultMaxItems,
  });

  static const int defaultMaxItems = 500;

  final PathGuideApi api;
  final FrameStore store;
  final FeatureGate Function() gate;
  final String Function() token;
  final int maxItems;

  final Set<String> _sent = <String>{};

  String _keyFor(String path) => path;

  /// 丟掉超出上限的最舊項目（`pendingPaths()` 需按時間升序回傳）。
  Future<void> trim() async {
    final paths = await store.pendingPaths();
    if (paths.length <= maxItems) return;
    final excess = paths.length - maxItems;
    for (var i = 0; i < excess; i++) {
      await store.remove(paths[i]);
    }
  }

  /// 送出所有待上傳項目，回傳成功張數。
  Future<int> flush() async {
    if (!gate().allows(CloudCapability.uploadFrames)) return 0;

    await trim();
    final paths = await store.pendingPaths();
    var sent = 0;
    for (final path in paths) {
      if (_sent.contains(_keyFor(path))) {
        // 已送出（例如上次送出後刪檔失敗）→ 補刪，不重送。
        await store.remove(path);
        continue;
      }
      try {
        await api.uploadFrame(
          token: token(),
          request: UploadFrameRequest(
            framePath: path,
            capturedAt: DateTime.now().toUtc(),
            modelVersion: 'local',
          ),
        );
        _sent.add(_keyFor(path));
        await store.remove(path);
        sent++;
      } on ApiFailure {
        // 失敗就留著，下一次 flush 再試。錯誤已由呼叫方記錄，這裡不彈窗。
        continue;
      }
    }
    return sent;
  }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd app; flutter test test/upload_queue_test.dart`
Expected: PASS（4 條）

- [ ] **Step 5: Commit**

```bash
git add app/lib/api/upload_queue.dart app/test/upload_queue_test.dart
git commit -m "feat(api): 上傳隊列（訪客不送、失敗保留、上限裁剪）"
```

---

### Task 10: 設定頁接上帳號狀態（用既有 AuthService）

**Files:**
- Modify: `app/lib/ui/settings_page.dart`（追加一列）
- Test: `app/test/settings_page_test.dart`（追加 2 條）

**Interfaces:**
- Consumes: `AuthService`（`auth/auth_service.dart` 已存在：`restore()` / `signOut()` / `deleteAccount()` / `availableProviders()`）、`MockAuthService`（`auth/mock_auth_service.dart` 已存在）
- Produces: `SettingsPage({required AppSettings settings, Future<String?> Function()? modelSummary, AuthService? authService, VoidCallback? onOpenAccount})`

- [ ] **Step 1: 寫失敗測試**（追加到 `settings_page_test.dart` 的 `main()` 內）

```dart
  testWidgets('★ 訪客狀態要說清楚「識別仍可完整使用」，不是只寫「未登入」', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        settings: AppSettings.memory(),
        modelSummary: () async => 'x',
        authService: MockAuthService(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('訪客'), findsOneWidget);
    expect(find.textContaining('完整使用'), findsOneWidget);
  });

  testWidgets('帳號列可點，且不是裸圖標', (tester) async {
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        settings: AppSettings.memory(),
        modelSummary: () async => 'x',
        authService: MockAuthService(),
        onOpenAccount: () => opened++,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('帳號'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app; flutter test test/settings_page_test.dart`
Expected: FAIL — `No named parameter with the name 'authService'`

- [ ] **Step 3: 實作**

在 `SettingsPage` 建構子加 `this.authService, this.onOpenAccount` 兩個可選參數與對應欄位
（`final AuthService? authService; final VoidCallback? onOpenAccount;`，並補
`import '../auth/auth_service.dart';`），State 內加一個只算一次的 future：

```dart
  late final Future<AuthAccount?> _account =
      widget.authService?.restore() ?? Future<AuthAccount?>.value(null);
```

並在 `ListView` 的模型資訊之後、返回按鈕之前插入：

```dart
              if (widget.authService != null) ...<Widget>[
                const SizedBox(height: 16),
                SizedBox(
                  height: 60,
                  child: OutlinedButton(
                    // 帳號列的動作是「去帳號頁」，不是靜默什麼都不做。
                    onPressed: () => widget.onOpenAccount?.call(),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(s.account,
                              style: const TextStyle(fontSize: 17)),
                        ),
                        FutureBuilder<AuthAccount?>(
                          future: _account,
                          builder: (context, snap) => Text(
                            snap.data == null
                                ? s.accountGuest
                                : s.accountSignedIn,
                            style: const TextStyle(
                                color: AppColors.accent, fontSize: 15),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
```

在 `app_strings.dart` 追加：

```dart
  String get accountSignedIn => _zh ? '已登入' : 'Signed in';
```

- [ ] **Step 4: 跑測試與全套_

Run: `cd app; flutter test test/settings_page_test.dart; flutter test`
Expected: `settings_page_test.dart` PASS（5 條）；全套 PASS

- [ ] **Step 5: Commit**

```bash
git add app/lib/ui/settings_page.dart app/lib/l10n/app_strings.dart app/test/settings_page_test.dart
git commit -m "feat(ui): 設定頁接上帳號狀態（訪客明示識別仍可用）"
```

---

## 收尾驗證（全部任務完成後）

- [ ] Run: `cd app; flutter analyze` → Expected: `No issues found!`
- [ ] Run: `cd app; flutter test` → Expected: 全部通過（235 + 新增約 30 條）
- [ ] Run: `.\.venv\Scripts\python.exe -m pytest -q` → Expected: `436 passed`（本計劃不動 Python 側）
- [ ] Run: `cd app; flutter build apk --debug` → Expected: 構建成功
- [ ] 人工核對 spec §13 驗收清單：`PathGuideApi` 之外沒有 URL 字串（`grep -rn "https://api" app/lib` 只應在 `http_api.dart` 的測試或未使用處）
- [ ] 更新 `docs/PROJECT-STATUS.md` §2／§3：加上「API 介面層與門禁已完成、後端未接」的狀態與實際測試數

---

## 未涵蓋（各自獨立 spec，勿在本計劃偷做）

- **Spec 2 兩級識別**：需要新模型與標註，含 `ocr_only` → `crop_classifier` 的類別搬移。
- **Spec 3 GPS/路線**：依賴導航決策引擎；`geolocator` 依賴尚未驗證構建。
- **Spec 4 雲端 VLM 問答**：只定了契約與 `HttpApi` 的方法，**沒有 UI 入口**。
- **Spec 5 對話式規劃**：`HttpApi.planRoute` 已可打，但沒有 ASR、沒有導航決策。
- **Spec 6 訓練狀態與人工審查後台**：後端工作，前端只讀 `GET /v1/routes/{id}/status`。
