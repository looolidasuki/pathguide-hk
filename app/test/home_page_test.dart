import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pathguide/l10n/app_locale.dart';
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
