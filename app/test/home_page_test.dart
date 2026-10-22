import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pathguide/l10n/app_locale.dart';
import 'package:pathguide/l10n/app_strings.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/ui/demo_page.dart';
import 'package:pathguide/ui/home_page.dart';
import 'package:pathguide/ui/read_text_page.dart';
import 'package:pathguide/vision/detection.dart';
import 'package:pathguide/vision/vision_session.dart';
import 'package:pathguide/vision/vision_source.dart';

/// 主界面與兩個模式的導覽。
///
/// ## 為什麼要測這張畫面
///
/// 分成兩個模式是一個**有代價的決定**：多一層導覽、多一次焦點移動，
/// 而全盲使用者每多一站就多一次迷路的機會。所以「分成兩個」必須真的
/// 換到東西——這裡把換到的東西釘住：
///
/// 1. 兩個模式**互斥**（讀字模式不能有障礙物播報在搶語音）
/// 2. 讀不到字要**出聲**（否則使用者分不出「沒字」與「壞了」）
/// 3. 相機**跨模式存活**（切模式不必等 1–2 秒重啟）
class _FakeSpeaker implements Speaker {
  final List<String> spoken = <String>[];
  int stops = 0;

  @override
  Future<String?> initialize() async => null;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stops++;

  @override
  Future<List<String>> languages() async => const <String>[];
}

class _FakeSource implements VisionSource {
  final StreamController<VisionFrame> _c =
      StreamController<VisionFrame>.broadcast();

  int initialized = 0; // 每次 initialize 都記，用來驗證「不重啟」
  int disposed = 0;

  @override
  String get displayName => 'Fake';

  @override
  Size get frameSize => const Size(1280, 720);

  @override
  int get rotationDegrees => 90;

  @override
  double threshold = 0.3;

  @override
  Stream<VisionFrame> get frames => _c.stream;

  @override
  Future<VisionSourceStatus> initialize() async {
    initialized++;
    return const VisionSourceStatus(ok: true, message: 'fake ready');
  }

  @override
  Future<VisionDiagnostics?> diagnostics() async => null;

  @override
  Future<void> dispose() async {
    disposed++;
    if (!_c.isClosed) await _c.close();
  }

  void emit(List<Detection> detections) {
    if (_c.isClosed) return;
    _c.add(VisionFrame(
      detections: detections,
      inferenceMs: 100,
      frameWidth: 1280,
      frameHeight: 720,
    ));
  }
}

Future<void> pumpHome(
  WidgetTester tester, {
  required VisionSession session,
}) async {
  await tester.pumpWidget(MaterialApp(home: HomePage(session: session)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    AppLocale.current = AppLanguage.zh;
  });

  /// 把字級調到 200%，並把畫布縮成一部 360×640 dp 的手機。
  ///
  /// 兩個都要：只看 200%、畫布還是預設的 800×600 時，en 的長句在 800 dp
  /// 寬下不會折行，那條測試就抓不到「固定高度把第二行切掉」。
  /// 真正的觸發條件是「窄機 + 大字」。
  void scaleTo200(WidgetTester tester, AppLanguage language) {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(1080, 1920); // 360×640 dp
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    AppLocale.current = language;
  }

  group('主界面', () {
    testWidgets('★ 只有兩個模式可選，且標籤就是結果', (tester) async {
      final session = VisionSession(
        speaker: _FakeSpeaker(),
        sourceFactory: () => _FakeSource(),
      );
      await pumpHome(tester, session: session);

      expect(find.text('開始引導'), findsOneWidget);
      expect(find.text('讀字'), findsOneWidget);
      // 標籤是動作（「開始引導」「讀字」），不是「模式一」「選項 A」。
      expect(find.text('模式一'), findsNothing);
      expect(find.text('選項'), findsNothing);
    });

    testWidgets('★ 每個模式都帶一句說明（不必再滑一次去讀）', (tester) async {
      final session = VisionSession(
        speaker: _FakeSpeaker(),
        sourceFactory: () => _FakeSource(),
      );
      await pumpHome(tester, session: session);

      expect(find.textContaining('偵測前方障礙物'), findsOneWidget);
      expect(find.textContaining('讀招牌'), findsOneWidget);
    });

    testWidgets('★ 焦點順序：兩個模式在前，設定位於最後', (tester) async {
      // 焦點順序只存在於語意樹裡，所以要先開語意再泵。
      final handle = tester.ensureSemantics();
      // 必須在測試body內收掉：addTearDown 的回呼在
      // flutter_test 的 _endOfTestVerifications 之後才跑，
      // 那時 handle 還開著就會被判成漏掉的 SemanticsHandle。
      try {
        final s = AppStrings.of(AppLanguage.zh);
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

        final guide = find.widgetWithText(FilledButton, s.modeGuidance);
        final read = find.widgetWithText(FilledButton, s.modeReadText);
        final settings = find.widgetWithText(OutlinedButton, s.settingsTitle);
        expect(guide, findsOneWidget);
        expect(read, findsOneWidget);
        expect(settings, findsOneWidget);

        // (1) 位置：設定必須在**兩顆**模式按鈕之後。
        //
        // 舊寫法只比第一顆（settingsTop > 開始引導的 top），所以把設定
        // 插進兩顆模式**中間**也會通過——那正是最該擋住的回歸。
        final guideBottom = tester.getBottomLeft(guide).dy;
        final readBottom = tester.getBottomLeft(read).dy;
        final settingsTop = tester.getTopLeft(settings).dy;
        expect(settingsTop, greaterThan(guideBottom), reason: '設定不得排在「開始引導」之前');
        expect(settingsTop, greaterThan(readBottom), reason: '設定不得排在「讀字」之前');

        // (2) 焦點／語意順序：位置對不等於焦點站對。
        //
        // TalkBack 爬的是**語意樹**，不是看 y 座標；只有語意樹的順序才是
        // 使用者實際走的順序。用 flutter_test 的
        // simulatedAccessibilityTraversal() 把樹走一遍，取三個按鈕節點
        // 的順序（這就是「焦點移動成本」那條需求的真實量測）。
        final buttonLabels = tester.semantics
            .simulatedAccessibilityTraversal()
            .where((node) => node.flagsCollection.isButton)
            .map((node) => node.label)
            .toList();

        expect(buttonLabels, hasLength(3), reason: '首頁只有三個可操作項');
        expect(buttonLabels[0], contains(s.modeGuidance), reason: '第 1 站必須是「開始引導」');
        expect(buttonLabels[1], contains(s.modeReadText), reason: '第 2 站必須是「讀字」');
        expect(buttonLabels[2], contains(s.settingsTitle), reason: '設定必須是最後一站');

        // (3) 「標籤 + 第二行說明」必須落在**同一個**節點裡，
        //     螢幕閱讀器才會一次唸完，不必再多滑一次。
        //     只唸「設定」等於唸了一個沒有結果提示的名詞。
        expect(buttonLabels[0], contains(s.modeGuidanceHint));
        expect(buttonLabels[2], contains(s.settingsHint),
            reason: '設定鈕要說出裡面有什麼（只調整語音速度…）');
      } finally {
        // dispose() 不可呼叫兩次（會讓 outstanding handle 計數變成負數並觸發
        // assert），所以這裡是唯一的收尾點，不再保留 addTearDown。
        handle.dispose();
      }
    });

    testWidgets('點「讀字」進入讀字畫面，並有返回出口', (tester) async {
      final session = VisionSession(
        speaker: _FakeSpeaker(),
        sourceFactory: () => _FakeSource(),
      );
      await pumpHome(tester, session: session);

      await tester.tap(find.text('讀字'));
      await tester.pumpAndSettle();

      expect(find.byType(ReadTextPage), findsOneWidget);
      // 一定要有出口——沒有出口的頁面等於把使用者關起來。
      expect(find.text('返回'), findsOneWidget);

      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byType(ReadTextPage), findsNothing);
    });
  });

  // 200% 字級是**這張畫面**的硬性約束（不是設定頁專屬）：
  // 首頁是每位使用者一定會看到、而且唯一能離開的一頁。
  //
  // 固定高度（以前的 `SizedBox(height: 72)` / `SizedBox(height: 48)`）在
  // 200% 字級下會讓標籤或說明折行後往外溢，Flutter 在測試裡把
  // RenderFlex overflow 當成**例外**，所以「這條測試綠」就等於
  // 「首頁沒有被裁掉」。zh / en 各跑一次：en 的句子長得多，是真正會爆的
  // 那一邊。
  group('★ 200% 字級不截斷', () {
    for (final language in AppLanguage.values) {
      testWidgets('200% 字級（${language.name}）：首頁三個入口都不截斷',
          (tester) async {
        scaleTo200(tester, language);

        final session = VisionSession(
          speaker: _FakeSpeaker(),
          sourceFactory: () => _FakeSource(),
        );
        await pumpHome(tester, session: session);
        final s = AppStrings.of(language);

        final guide = find.widgetWithText(FilledButton, s.modeGuidance);
        final read = find.widgetWithText(FilledButton, s.modeReadText);
        final settings = find.widgetWithText(OutlinedButton, s.settingsTitle);
        expect(guide, findsOneWidget);
        expect(read, findsOneWidget);
        expect(settings, findsOneWidget);

        // 100% 字級下的下限是 72 / 72 / 48：200% 只能長大，不能變矮。
        expect(tester.getSize(guide).height, greaterThan(72.0),
            reason: '200% 下「${s.modeGuidance}」要長高，不能被 72 切掉');
        expect(tester.getSize(read).height, greaterThan(72.0),
            reason: '200% 下「${s.modeReadText}」要長高，不能被 72 切掉');
        expect(tester.getSize(settings).height, greaterThan(48.0),
            reason: '200% 下「${s.settingsTitle}」要長高，不能被 48 切掉');
      });
    }
  });

  group('兩個模式互斥', () {
    testWidgets('★ 讀字模式不建立障礙物播報（否則會搶語音）', (tester) async {
      final speaker = _FakeSpeaker();
      final source = _FakeSource();
      final session = VisionSession(
        speaker: speaker,
        sourceFactory: () => source,
      );
      await tester.pumpWidget(MaterialApp(
        home: ReadTextPage(session: session),
      ));
      await tester.pumpAndSettle();

      // 就算有障礙物進來，讀字模式也不該播報它們。
      // 這是「分成兩個模式」最主要換到的東西。
      _FakeSource();
      session.announcer.enabled = false; // 讀字模式不使用 announcer
      source.emit(<Detection>[
        Detection(id: 7, score: 0.99, cx: 0.5, cy: 0.5, w: 0.2, h: 0.2),
      ]);
      await tester.pump(const Duration(milliseconds: 100));

      // 播報歷史必須是空的——讀字模式沒有跑 onFrame。
      expect(session.announcer.history, isEmpty);
    });

    testWidgets('★ 相機跨模式存活：切到讀字不必重啟', (tester) async {
      final speaker = _FakeSpeaker();
      final source = _FakeSource();
      final session = VisionSession(
        speaker: speaker,
        sourceFactory: () => source,
      );

      // 先讓相機起來（模擬「引導模式已經開過相機」）
      final st = await session.ensureCamera();
      expect(st.ok, isTrue);
      expect(source.initialized, 1);

      // 再進讀字模式：**不可以**重新初始化相機。
      await tester.pumpWidget(MaterialApp(
        home: ReadTextPage(session: session),
      ));
      await tester.pumpAndSettle();

      expect(source.initialized, 1, reason: '切模式不該重建相機（重啟要 1–2 秒）');
      expect(source.disposed, 0);
    });

    testWidgets('★ 結束引導不該把共用相機 dispose 掉（跨模式的真實缺陷）', (tester) async {
      // 這是分模式時最容易犯的錯：`_stopGuidance` 原本會 `dispose()` 來源，
      // 而來源現在是**共用**的——於是從引導切回讀字後相機就死了，
      // 而讀字那一邊完全不知道發生什麼事。
      final speaker = _FakeSpeaker();
      final source = _FakeSource();
      final session = VisionSession(
        speaker: speaker,
        sourceFactory: () => source,
      );

      await tester.pumpWidget(MaterialApp(
        home: DemoPage(session: session),
      ));
      await tester.pumpAndSettle();
      expect(source.initialized, 1);

      // 按「結束引導」
      await tester.tap(find.text('結束引導'));
      await tester.pumpAndSettle();

      expect(source.disposed, 0,
          reason: '結束引導只該退訂，不該把共用相機弄死');
      // 而且要能再啟動（相機還在）。
      await tester.tap(find.text('啟動引導'));
      await tester.pumpAndSettle();
      expect(source.initialized, 1, reason: '相機還活著 → 不該重新初始化');
    });
  });

  group('讀字模式的回饋', () {
    testWidgets('★ 進入時先出聲（按了不能沒反應）', (tester) async {
      final speaker = _FakeSpeaker();
      final session = VisionSession(
        speaker: speaker,
        sourceFactory: () => _FakeSource(),
      );
      await tester.pumpWidget(MaterialApp(
        home: ReadTextPage(session: session),
      ));
      await tester.pumpAndSettle();

      expect(speaker.spoken.join(' '), contains('讀字模式'));
    });

    testWidgets('★ 有「再讀一次」按鈕（靜止時排程不會重讀）', (tester) async {
      final session = VisionSession(
        speaker: _FakeSpeaker(),
        sourceFactory: () => _FakeSource(),
      );
      await tester.pumpWidget(MaterialApp(
        home: ReadTextPage(session: session),
      ));
      await tester.pumpAndSettle();

      expect(find.text('再讀一次'), findsOneWidget);
    });

    testWidgets('相機起不來時出聲說明，不是靜默', (tester) async {
      final speaker = _FakeSpeaker();
      final session = VisionSession(
        speaker: speaker,
        sourceFactory: () => _FailingSource(),
      );
      await tester.pumpWidget(MaterialApp(
        home: ReadTextPage(session: session),
      ));
      await tester.pumpAndSettle();

      expect(speaker.spoken.join(' '), contains('沒有相機'));
    });
  });
}

class _FailingSource implements VisionSource {
  @override
  String get displayName => 'Fail';

  @override
  Size get frameSize => const Size(1280, 720);

  @override
  int get rotationDegrees => 90;

  @override
  double threshold = 0.3;

  @override
  Stream<VisionFrame> get frames => const Stream<VisionFrame>.empty();

  @override
  Future<VisionSourceStatus> initialize() async => const VisionSourceStatus(
        ok: false,
        message: '沒有相機',
        error: 'no camera',
      );

  @override
  Future<VisionDiagnostics?> diagnostics() async => null;

  @override
  Future<void> dispose() async {}
}
