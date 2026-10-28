import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/main.dart';
import 'package:pathguide/overlay/box_painter.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/ui/app_shell.dart';
import 'package:pathguide/ui/app_theme.dart';
import 'package:pathguide/ui/demo_page.dart';
import 'package:pathguide/vision/vision_preview.dart';

void main() {
  final testerBinding = TestWidgetsFlutterBinding.ensureInitialized();
  final visionCalls = <String>[];
  final loadedModels = <Map<Object?, Object?>>[];
  final speechCalls = <MethodCall>[];
  var failSpeechSetup = false;
  var denyCamera = false;
  Completer<Object?>? pendingCamera;
  var speechLanguages = <String>['zh-HK', 'yue-HK'];
  Completer<Object?>? speechSetup;
  Completer<Object?>? speechStop;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    visionCalls.clear();
    loadedModels.clear();
    speechCalls.clear();
    failSpeechSetup = false;
    denyCamera = false;
    pendingCamera = null;
    rootBundle.evict('assets/models/detector.json');
    rootBundle.evict('assets/models/detector.tflite');
    speechLanguages = <String>['zh-HK', 'yue-HK'];
    speechSetup = null;
    speechStop = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
      call,
    ) async {
      speechCalls.add(call);
      if (call.method == 'stop' && speechStop != null) {
        return speechStop!.future;
      }
      if (call.method == 'setSpeechRate') {
        if (failSpeechSetup) throw PlatformException(code: 'voice_unavailable');
        if (speechSetup != null) return speechSetup!.future;
      }
      if (call.method == 'speak') {
        scheduleMicrotask(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
                'flutter_tts',
                const StandardMethodCodec().encodeMethodCall(
                  const MethodCall('speak.onComplete'),
                ),
                (_) {},
              );
        });
      }
      if (call.method == 'getLanguages') return speechLanguages;
      return 1;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('hk.pathguide/vision'),
      (call) async {
        visionCalls.add(call.method);
        if (call.method == 'loadModel') {
          loadedModels.add(Map<Object?, Object?>.from(call.arguments as Map));
        }
        if (call.method == 'startPreview') {
          if (denyCamera) throw PlatformException(code: 'camera_denied');
          if (pendingCamera != null) return pendingCamera!.future;
        }
        return switch (call.method) {
          'startPreview' => <String, Object>{'started': true},
          'modelDir' => '/models',
          'fileSize' => -1,
          'loadModel' => <String, Object>{
            'loaded': true,
            'classes':
                (call.arguments as Map)['model'].toString().contains(
                  'detector-hk9',
                )
                ? 9
                : 10,
            'inputSize': 640,
          },
          'status' => <String, Object>{'ready': true},
          _ => null,
        };
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('hk.pathguide/vision/frame'),
      (_) async => null,
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    testerBinding.platformDispatcher.clearAccessibilityFeaturesTestValue();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'flutter_tts',
      'hk.pathguide/vision',
      'hk.pathguide/vision/frame',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  Future<void> flushAsync(WidgetTester tester) async {
    // PlatformVision materializes the bundled model through multiple real async
    // hops. A plain fake-clock pump can observe the UI before that chain finishes.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> start(
    WidgetTester tester, {
    SourceMode initialMode = SourceMode.camera,
    AppSection initialSection = AppSection.explore,
    AppSettings? settings,
    bool automatic = true,
  }) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    const screenshotDirectory = String.fromEnvironment('PATHGUIDE_SCREENSHOTS');
    if (screenshotDirectory.isNotEmpty && Platform.isMacOS) {
      await tester.runAsync(() async {
        final loader = FontLoader('PathGuidePreview')
          ..addFont(
            File('/System/Library/Fonts/STHeiti Light.ttc')
                .readAsBytes()
                .then((bytes) => ByteData.sublistView(bytes)),
          );
        await loader.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('test-preview'),
        child: PathGuideApp(
          initialMode: initialMode,
          initialSection: initialSection,
          settings: settings,
          theme: screenshotDirectory.isEmpty
              ? null
              : buildAppTheme().copyWith(
                  textTheme: buildAppTheme().textTheme.apply(
                    fontFamily: 'PathGuidePreview',
                  ),
                  primaryTextTheme: buildAppTheme().primaryTextTheme.apply(
                    fontFamily: 'PathGuidePreview',
                  ),
                  segmentedButtonTheme: SegmentedButtonThemeData(
                    style: buildAppTheme().segmentedButtonTheme.style?.copyWith(
                      textStyle: const WidgetStatePropertyAll(
                        TextStyle(
                          fontFamily: 'PathGuidePreview',
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
    await tester.pump();
    await flushAsync(tester);
    await tester.pump(const Duration(milliseconds: 240));
    if (!automatic && initialSection == AppSection.explore) {
      await tester.tap(find.byKey(const ValueKey('vision-settings-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(find.byTooltip('關閉播報'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('關閉播報'));
      await tester.tap(find.byTooltip('關閉更多操作'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      speechCalls.clear();
    }
  }

  Future<void> openControls(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('vision-settings-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('重播目前結果'), findsOneWidget);
  }

  Future<void> closeControls(WidgetTester tester) async {
    await tester.tap(find.byTooltip('關閉更多操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('重播目前結果'), findsNothing);
  }

  DetectionBoxPainter painter(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w) => w.painter)
      .whereType<DetectionBoxPainter>()
      .single;

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    // 廣播流取消的完成通知可能在測試假時鐘以外的 zone。
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets(
    'navigation entry exposes search without starting camera or location',
    (tester) async {
      await start(tester, initialSection: AppSection.navigation);
      expect(find.text('路線導航'), findsOneWidget);
      expect(find.text('搜尋目的地'), findsOneWidget);
      expect(find.text('此手機收藏'), findsOneWidget);
      expect(find.text('最近使用'), findsOneWidget);
      expect(visionCalls, isNot(contains('startPreview')));
      await close(tester);
    },
  );

  testWidgets('bottom navigation leaves camera view and opens settings', (
    tester,
  ) async {
    await start(tester);
    expect(visionCalls, contains('startPreview'));

    await tester.tap(find.text('導航'));
    await tester.pumpAndSettle();
    expect(find.text('路線導航'), findsOneWidget);
    expect(find.byType(VisionPreview), findsNothing);

    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    expect(find.text('播報速度'), findsOneWidget);
    expect(find.text('1 倍速'), findsOneWidget);
    await close(tester);
  });

  testWidgets('settings exposes a persistent-style speech speed picker', (
    tester,
  ) async {
    final settings = AppSettings.memory();
    await start(
      tester,
      initialSection: AppSection.settings,
      settings: settings,
    );

    expect(find.text('播報速度'), findsOneWidget);
    expect(find.text('1 倍速'), findsOneWidget);
    expect(visionCalls, isNot(contains('startPreview')));

    await tester.tap(find.byKey(const ValueKey<String>('speech-speed-row')));
    await tester.pumpAndSettle();
    expect(find.text('0.8 倍速'), findsOneWidget);
    expect(find.text('1.2 倍速'), findsOneWidget);

    await tester.tap(find.text('0.8 倍速'));
    await tester.pumpAndSettle();
    expect(settings.speechSpeed, SpeechSpeed.slow);
    expect(find.text('0.8 倍速'), findsOneWidget);

    await tester.tap(find.text('即時辨識設定'));
    await tester.pump();
    await flushAsync(tester);
    expect(
      speechCalls
          .where((call) => call.method == 'setSpeechRate')
          .last
          .arguments,
      0.35,
    );
    await close(tester);
  });

  testWidgets(
    'future settings only explain requirements without starting a service',
    (tester) async {
      await start(tester, initialSection: AppSection.settings);
      expect(find.text('懸空障礙物偵測'), findsOneWidget);

      await tester.tap(find.text('懸空障礙物偵測'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不會要求新的系統權限'), findsOneWidget);
      expect(visionCalls, isNot(contains('startPreview')));
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('即時物件辨識模型'), 180);
      await tester.pump();
      await flushAsync(tester);
      expect(
        find.text('10 類 · 10.70 MB'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join('|'),
      );
      expect(find.text('未提供'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets('model selector reloads matching model and class mapping', (
    tester,
  ) async {
    await start(tester);
    expect(loadedModels.last['classIds'], <int>[
      6,
      11,
      7,
      8,
      9,
      24,
      1,
      49,
      26,
      18,
    ]);
    await openControls(tester);
    await tester.ensureVisible(find.text('原版九類'));
    await tester.tap(find.text('原版九類'));
    await tester.pump();
    await flushAsync(tester);
    expect(
      loadedModels.last['model'].toString(),
      endsWith('detector-hk9.tflite'),
    );
    expect(loadedModels.last['classIds'], <int>[
      11,
      7,
      8,
      50,
      49,
      6,
      9,
      51,
      24,
    ]);
    await tester.tap(find.text('新版十類'));
    await tester.pump();
    await flushAsync(tester);
    expect(loadedModels.last['model'].toString(), endsWith('/detector.tflite'));
    expect(loadedModels.last['classIds'], <int>[
      6,
      11,
      7,
      8,
      9,
      24,
      1,
      49,
      26,
      18,
    ]);
    await close(tester);
  });

  testWidgets('technical diagnostics stay collapsed until requested', (
    tester,
  ) async {
    await start(tester, initialMode: SourceMode.mock);
    expect(find.textContaining('播報門檻 ≥'), findsNothing);
    expect(find.text('技術資料'), findsNothing);
    await openControls(tester);
    await tester.ensureVisible(find.text('技術資料'));
    await tester.tap(find.text('技術資料'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('播報門檻 ≥'), findsOneWidget);
    await close(tester);
  });

  testWidgets('slow speech stop does not block mock startup', (tester) async {
    speechStop = Completer<Object?>();
    await start(tester, initialMode: SourceMode.mock);
    try {
      expect(painter(tester).mapped, hasLength(3));
      expect(speechCalls.where((c) => c.method == 'speak'), isEmpty);
    } finally {
      speechStop!.complete(1);
      await tester.pump();
      await close(tester);
    }
  });

  testWidgets(
    'iPhone boots into the native camera and keeps mock mode available',
    (tester) async {
      await start(tester);
      expect(find.text('介面演示・模擬資料'), findsNothing);
      expect(find.byType(VisionPreview), findsOneWidget);
      expect(visionCalls, contains('startPreview'));
      expect(find.text('更新 FPS'), findsNothing);
      expect(find.textContaining('推理耗時'), findsNothing);
      expect(find.text('技術資料'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('vision-status-pill')),
        findsOneWidget,
      );
      final settingsSize = tester.getSize(
        find.byKey(const ValueKey<String>('vision-settings-button')),
      );
      expect(settingsSize.width, greaterThanOrEqualTo(56));
      expect(settingsSize.height, greaterThanOrEqualTo(56));
      expect(find.text('暫停辨識'), findsOneWidget);
      expect(find.byKey(const ValueKey('read-current-result')), findsNothing);
      expect(find.text('更多操作'), findsOneWidget);

      await openControls(tester);
      expect(find.text('更新 FPS'), findsOneWidget);
      expect(find.textContaining('推理耗時'), findsOneWidget);
      expect(find.text('技術資料'), findsOneWidget);
      final selector = tester.widget<SegmentedButton<SourceMode>>(
        find.byType(SegmentedButton<SourceMode>),
      );
      expect(selector.segments.first.enabled, isTrue);
      expect(find.text('相機辨識尚未支援'), findsNothing);
      expect(
        Localizations.localeOf(tester.element(find.byType(Scaffold).first))
            .toLanguageTag(),
        'zh-Hant-HK',
      );
      expect(find.text('模擬資料'), findsOneWidget);
      final startsBeforeClose = visionCalls
          .where((method) => method == 'startPreview')
          .length;
      await closeControls(tester);
      expect(find.byType(VisionPreview), findsOneWidget);
      expect(
        visionCalls.where((method) => method == 'startPreview').length,
        startsBeforeClose,
      );
      await close(tester);
    },
  );

  testWidgets('threshold and label controls affect the real overlay', (
    tester,
  ) async {
    await start(tester, initialMode: SourceMode.mock);
    expect(painter(tester).mapped, hasLength(3));
    await openControls(tester);
    await tester.ensureVisible(find.byTooltip('隱藏標籤'));
    await tester.tap(find.byTooltip('隱藏標籤'));
    await tester.pump();
    expect(painter(tester).showLabels, isFalse);
    tester
        .widget<Slider>(
          find.byKey(const ValueKey<String>('detection-threshold')),
        )
        .onChanged!(0.95);
    await tester.pump(const Duration(milliseconds: 240));
    expect(painter(tester).mapped, isEmpty);
    await closeControls(tester);
    expect(painter(tester).showLabels, isFalse);
    await close(tester);
  });

  testWidgets('speech threshold changes announcements without hiding boxes', (
    tester,
  ) async {
    final settings = AppSettings.memory();
    await settings.setSpeakThreshold(0.95);
    await start(tester, initialMode: SourceMode.mock, settings: settings);
    await openControls(tester);
    final slider = find.byKey(const ValueKey<String>('speech-threshold'));
    await tester.ensureVisible(slider);
    tester.widget<Slider>(slider).onChanged!(0.95);
    await tester.pump();
    speechCalls.clear();
    await tester.pump(const Duration(seconds: 6));
    expect(settings.speakThreshold, 0.95);
    expect(painter(tester).mapped, hasLength(3));
    expect(speechCalls.where((c) => c.method == 'speak'), isEmpty);
    tester.widget<Slider>(slider).onChanged!(0.30);
    await closeControls(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(speechCalls.where((c) => c.method == 'speak'), isNotEmpty);
    await close(tester);
  });

  testWidgets('speech switch stops speech and disables future announcements', (
    tester,
  ) async {
    await start(tester, initialMode: SourceMode.mock);
    expect(speechCalls.where((c) => c.method == 'speak'), isNotEmpty);
    speechCalls.clear();
    await openControls(tester);
    await tester.ensureVisible(find.byTooltip('關閉播報'));
    await tester.tap(find.byTooltip('關閉播報'));
    await tester.pump();
    expect(speechCalls.where((c) => c.method == 'stop'), isNotEmpty);
    speechCalls.clear();
    await tester.pump(const Duration(seconds: 6));
    expect(speechCalls.where((c) => c.method == 'speak'), isEmpty);
    await close(tester);
  });

  testWidgets(
    'background stops recognition and foreground automatically resumes',
    (tester) async {
      await start(tester, initialMode: SourceMode.mock);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      tester.binding.scheduleForcedFrame();
      await tester.pump();
      expect(find.textContaining('已暫停'), findsWidgets);
      expect(speechCalls.where((c) => c.method == 'stop'), isNotEmpty);
      speechCalls.clear();
      await tester.pump(const Duration(seconds: 6));
      expect(speechCalls.where((c) => c.method == 'speak'), isEmpty);
      expect(painter(tester).mapped, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      await flushAsync(tester);
      await tester.pump(const Duration(milliseconds: 240));
      expect(painter(tester).mapped, hasLength(3));
      await close(tester);
    },
  );

  testWidgets(
    'speech failure cannot prevent the simulated scene from starting',
    (tester) async {
      failSpeechSetup = true;
      await start(tester, initialMode: SourceMode.mock);
      expect(painter(tester).mapped, hasLength(3));
      await openControls(tester);
      expect(find.textContaining('語音初始化失敗'), findsWidgets);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'non-Cantonese fallback remains visible after source initialization',
    (tester) async {
      speechLanguages = <String>['zh-TW'];
      await start(tester, initialMode: SourceMode.mock);
      await openControls(tester);
      expect(find.textContaining('目前使用 zh-TW，並非粵語'), findsWidgets);
      expect(painter(tester).mapped, hasLength(3));
      await close(tester);
    },
  );

  testWidgets(
    'slow speech initialization does not block demo or restart it in background',
    (tester) async {
      speechSetup = Completer<Object?>();
      await start(tester, initialMode: SourceMode.mock);
      expect(painter(tester).mapped, hasLength(3));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      speechSetup!.complete(1);
      await tester.pump();
      // 背景不排程新畫面；強制繪製一次以檢查初始化完成後的狀態。
      tester.binding.scheduleForcedFrame();
      await tester.pump(const Duration(milliseconds: 240));
      expect(painter(tester).mapped, isEmpty);
      expect(find.textContaining('已暫停'), findsWidgets);
      await close(tester);
    },
  );

  testWidgets('Android still initializes the native camera path', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await start(tester);
    expect(visionCalls, contains('startPreview'));
    expect(find.text('介面演示・模擬資料'), findsNothing);
    await close(tester);
  });

  testWidgets(
    'small iPhone with larger text keeps controls usable without overflow',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await start(tester, initialMode: SourceMode.mock);
      expect(find.text('介面演示・模擬資料'), findsNothing);
      expect(tester.takeException(), isNull);
      await openControls(tester);
      await tester.ensureVisible(find.byTooltip('關閉播報'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('關閉播報'));
      await tester.pump();
      expect(find.byTooltip('開啟播報'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'small iPhone with larger text keeps native settings scrollable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      await start(tester, initialSection: AppSection.settings);
      expect(find.text('播報速度'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('即時物件辨識模型'), 180);
      await flushAsync(tester);
      expect(find.text('10 類 · 10.70 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  Future<void> capture(WidgetTester tester, String name) async {
    const dir = String.fromEnvironment('PATHGUIDE_SCREENSHOTS');
    if (dir.isEmpty) return;
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('test-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(dir).create(recursive: true);
      await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('task home is accessible and never starts camera', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final semantics = tester.ensureSemantics();

    await start(tester, initialSection: AppSection.home);
    expect(find.text('即時辨識'), findsOneWidget);
    expect(find.text('路線導航'), findsOneWidget);
    expect(find.text('菜單閱讀與語音搜尋'), findsOneWidget);
    expect(visionCalls, isEmpty);
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    semantics.dispose();
    await capture(tester, 'task-home');
    await tester.tap(find.text('菜單閱讀與語音搜尋'));
    await tester.pumpAndSettle();
    expect(find.text('菜單閱讀'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(visionCalls, isEmpty);
    await close(tester);
  });

  testWidgets('automatic entry stays compact and replay is optional', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await start(tester, initialMode: SourceMode.mock);
    expect(painter(tester).mapped, hasLength(3));
    expect(speechCalls.where((c) => c.method == 'speak'), isNotEmpty);
    expect(find.byKey(const ValueKey('read-current-result')), findsNothing);
    expect(
      speechCalls.where(
        (c) => c.method == 'speak' && c.arguments.toString().contains('行人'),
      ),
      isNotEmpty,
    );
    expect(find.text('辨識信心門檻'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('recognition-preview'))).height,
      greaterThan(400),
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('current-result')),
              matching: find.byType(Text),
            ),
          )
          .data,
      startsWith('模擬結果：辨識到：'),
    );
    await capture(tester, 'recognition');
    await openControls(tester);
    await capture(tester, 'recognition-more');
    speechCalls.clear();
    await tester.tap(find.text('重播目前結果'));
    await flushAsync(tester);
    expect(
      speechCalls.lastWhere((c) => c.method == 'speak').arguments,
      startsWith('模擬結果：辨識到：'),
    );
    await tester.pumpAndSettle();
    expect(find.text('重播目前結果'), findsNothing);
    await tester.tap(find.text('暫停辨識'));
    await flushAsync(tester);
    expect(painter(tester).mapped, isEmpty);
    await openControls(tester);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('read-current-result')),
          )
          .onPressed,
      isNull,
    );
    await closeControls(tester);
    speechCalls.clear();
    await tester.pump(const Duration(seconds: 6));
    expect(speechCalls.where((c) => c.method == 'speak'), isEmpty);
    await close(tester);
  });

  testWidgets('screen reader reads requested results without duplicate TTS', (
    tester,
  ) async {
    final messages = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(SystemChannels.accessibility, (
      message,
    ) async {
      messages.add(message);
      return null;
    });
    addTearDown(
      () => messenger.setMockDecodedMessageHandler(
        SystemChannels.accessibility,
        null,
      ),
    );
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          accessibleNavigation: true,
          supportsAnnounce: true,
        );
    await start(tester, initialMode: SourceMode.mock, automatic: false);
    await tester.pump(const Duration(seconds: 6));
    expect(speechCalls.where((c) => c.method == 'speak'), isEmpty);
    messages.clear();
    await openControls(tester);
    await tester.tap(find.text('重播目前結果'));
    await flushAsync(tester);
    final announcements = messages.whereType<Map>().where(
      (m) => m['type'] == 'announce',
    );
    expect(announcements, hasLength(1));
    expect(
      (announcements.single['data'] as Map)['message'],
      startsWith('模擬結果：'),
    );
    expect(speechCalls.where((c) => c.method == 'speak'), isEmpty);
    await close(tester);
  });

  testWidgets('screen reader automatically announces objects without TTS', (
    tester,
  ) async {
    final messages = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(SystemChannels.accessibility, (
      message,
    ) async {
      messages.add(message);
      return null;
    });
    addTearDown(
      () => messenger.setMockDecodedMessageHandler(
        SystemChannels.accessibility,
        null,
      ),
    );
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          accessibleNavigation: true,
          supportsAnnounce: true,
        );
    await start(tester, initialMode: SourceMode.mock);
    expect(
      messages.whereType<Map>().where(
        (m) =>
            m['type'] == 'announce' &&
            (m['data'] as Map)['message'].toString().contains('行人'),
      ),
      isNotEmpty,
    );
    expect(speechCalls.where((c) => c.method == 'speak'), isEmpty);
    await close(tester);
  });

  testWidgets('enabling screen reader keeps automatic announcements enabled', (
    tester,
  ) async {
    await start(tester, initialMode: SourceMode.mock);
    expect(speechCalls.where((c) => c.method == 'speak'), isNotEmpty);
    speechCalls.clear();
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          accessibleNavigation: true,
          supportsAnnounce: true,
        );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(speechCalls.where((c) => c.method == 'speak'), isEmpty);
    await openControls(tester);
    expect(find.byTooltip('關閉播報'), findsOneWidget);
    await close(tester);
  });

  testWidgets('settings modal suspends automatic environment speech', (
    tester,
  ) async {
    await start(tester, initialMode: SourceMode.mock);
    await openControls(tester);
    speechCalls.clear();
    await tester.pump(const Duration(seconds: 6));
    expect(speechCalls.where((c) => c.method == 'speak'), isEmpty);
    await closeControls(tester);
    await tester.pump(const Duration(milliseconds: 240));
    expect(speechCalls.where((c) => c.method == 'speak'), isNotEmpty);
    await close(tester);
  });

  testWidgets('camera permission failure exposes explicit retry', (
    tester,
  ) async {
    denyCamera = true;
    await start(tester);
    expect(visionCalls.where((c) => c == 'startPreview'), hasLength(1));
    expect(find.text('重新嘗試'), findsOneWidget);
    expect(find.byType(VisionPreview), findsNothing);
    denyCamera = false;
    await tester.tap(find.text('重新嘗試'));
    await flushAsync(tester);
    expect(visionCalls.where((c) => c == 'startPreview'), hasLength(2));
    expect(find.text('暫停辨識'), findsOneWidget);
    await close(tester);
  });

  testWidgets('pausing during native startup discards the delayed result', (
    tester,
  ) async {
    pendingCamera = Completer<Object?>();
    await start(tester);
    await tester.tap(find.text('暫停辨識'));
    pendingCamera!.complete(<String, Object>{'started': true});
    await flushAsync(tester);
    await flushAsync(tester);
    expect(find.text('繼續辨識'), findsOneWidget);
    expect(find.byType(VisionPreview), findsNothing);
    expect(visionCalls, contains('release'));
    expect(speechCalls.where((c) => c.method == 'speak'), isEmpty);
    await close(tester);
  });

  testWidgets('manual pause remains paused after interruption', (tester) async {
    await start(tester, initialMode: SourceMode.mock);
    await tester.tap(find.text('暫停辨識'));
    await flushAsync(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flushAsync(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(painter(tester).mapped, isEmpty);
    expect(find.text('繼續辨識'), findsOneWidget);
    await tester.tap(find.text('繼續辨識'));
    await flushAsync(tester);
    await tester.pump(const Duration(milliseconds: 240));
    expect(painter(tester).mapped, hasLength(3));
    await close(tester);
  });

  testWidgets('permission dialog returns to the same pending startup', (
    tester,
  ) async {
    pendingCamera = Completer<Object?>();
    await start(tester);
    expect(visionCalls.where((c) => c == 'startPreview'), hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    pendingCamera!.complete(<String, Object>{'started': true});
    await flushAsync(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flushAsync(tester);
    expect(visionCalls.where((c) => c == 'startPreview'), hasLength(1));
    expect(find.text('暫停辨識'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('recognition controls have labels and minimum touch targets', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final semantics = tester.ensureSemantics();
    await start(tester, initialMode: SourceMode.mock);
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await openControls(tester);
    expect(find.byTooltip('關閉更多操作'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('read-current-result'))).height,
      greaterThanOrEqualTo(56),
    );
    semantics.dispose();
    await close(tester);
  });

  testWidgets(
    'two times text retains fixed task controls and scrollable teaching',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await start(tester, initialMode: SourceMode.mock);
      for (final key in ['recognition-start-pause', 'vision-settings-button']) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(56));
        expect(size.height, greaterThanOrEqualTo(56));
      }
      await capture(tester, 'recognition-large-text');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('返回首頁'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('設定與使用教學'), 120);
      await tester.ensureVisible(find.widgetWithText(FilledButton, '設定與使用教學'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('設定與使用教學'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用教學'));
      await tester.pumpAndSettle();
      expect(find.text('關閉教學'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'usage-guide-large-text');
      await tester.tap(find.text('關閉教學'));
      await tester.pumpAndSettle();
      await close(tester);
    },
  );
}
