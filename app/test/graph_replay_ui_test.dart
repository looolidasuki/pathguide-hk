import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/indoor/graph_replay_page.dart';
import 'package:pathguide/main.dart';
import 'package:pathguide/ui/app_shell.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/ui/app_theme.dart';

class ReplaySpeaker extends NullSpeaker {
  final words = <String>[];
  int stops = 0;
  @override
  Future<void> speak(String text) async {
    words.add(text);
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

Future<void> start(
  WidgetTester tester, {
  AppLanguage language = AppLanguage.chinese,
  double scale = 1,
  ReplaySpeaker? speaker,
  GlobalKey? capture,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  const fontDir = String.fromEnvironment('GRAPH_FONT_DIR');
  if (fontDir.isNotEmpty) {
    await tester.runAsync(() async {
      for (final entry in {
        'GraphRoboto': '$fontDir/Roboto-Regular.ttf',
        'MaterialIcons': '$fontDir/MaterialIcons-Regular.otf',
        'GraphChinese': '/System/Library/Fonts/STHeiti Medium.ttc',
      }.entries) {
        final file = File(entry.value);
        if (!await file.exists()) continue;
        final loader = FontLoader(entry.key)
          ..addFont(file.readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
    });
  }
  var theme = buildAppTheme();
  if (fontDir.isNotEmpty) {
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(
        fontFamily: language == AppLanguage.english
            ? 'GraphRoboto'
            : 'GraphChinese',
        fontFamilyFallback: const ['GraphChinese'],
      ),
    );
  }
  await tester.pumpWidget(
    RepaintBoundary(
      key: capture,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: const Size(390, 844),
              textScaler: TextScaler.linear(scale),
            ),
            child: GraphReplayPage(
              settings: AppSettings.memory(language: language),
              speaker: speaker ?? ReplaySpeaker(),
              onBack: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.textContaining('情境：'));
  await tester.tap(find.textContaining('情境：'));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text(text),
    120,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

Future<void> step(WidgetTester tester, [int n = 1]) async {
  for (var i = 0; i < n; i++) {
    await tester.tap(find.byKey(const ValueKey('graph-step')));
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final language in AppLanguage.values) {
    testWidgets(
      'large text fixed replay controls remain usable in ${language.name}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await start(tester, language: language, scale: 2);
        for (final key in [
          'graph-step',
          'graph-play',
          'graph-reset',
          'graph-read',
        ]) {
          expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
          expect(
            tester.getSize(find.byKey(ValueKey(key))).height,
            greaterThanOrEqualTo(48),
          );
        }
        await step(tester);
        expect(tester.takeException(), isNull);
        await tester.drag(
          find.byKey(const ValueKey('graph-replay-content')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('graph-step')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
      },
    );
  }
  testWidgets(
    'similar storefronts withdraw position until distinct evidence arrives',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await start(tester);
      await choose(tester, '重複店面／不確定');
      await step(tester, 2);
      await tester.ensureVisible(find.byKey(const ValueKey('graph-position')));
      expect(find.text('目前位置：未知'), findsOneWidget);
      expect(find.text('多個位置相似，暫不選定'), findsOneWidget);
      await step(tester);
      expect(find.textContaining('目前對照：N08'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'background pauses replay and does not resume without user action',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final speaker = ReplaySpeaker();
      await start(tester, speaker: speaker);
      await tester.tap(find.byKey(const ValueKey('graph-play')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.scrollUntilVisible(find.text('觀察 1 / 7'), 150);
      expect(find.text('觀察 1 / 7'), findsOneWidget);
      expect(speaker.words, isEmpty);
      expect(speaker.stops, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('read only the current result and restart clears observations', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final speaker = ReplaySpeaker();
    final capture = GlobalKey();
    await start(
      tester,
      speaker: speaker,
      capture: capture,
      language: AppLanguage.english,
    );
    await step(tester, 3);
    await tester.tap(find.byKey(const ValueKey('graph-read')));
    await tester.pumpAndSettle();
    expect(speaker.words.single, contains('N03 Junction'));
    const folder = String.fromEnvironment('GRAPH_CAPTURE_DIR');
    if (folder.isNotEmpty) {
      await tester.ensureVisible(find.byKey(const ValueKey('graph-position')));
      await tester.drag(
        find.byKey(const ValueKey('graph-replay-content')),
        const Offset(0, 120),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(folder).create(recursive: true);
        await File('$folder/graph-english.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.byKey(const ValueKey('graph-reset')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Observation 0 / 7'), 150);
    expect(find.text('Observation 0 / 7'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'the sample entry replaces outdoor navigation and returns without starting the camera',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      final channels = [
        'plugins.it_nomads.com/flutter_secure_storage',
        'flutter_tts',
        'hk.pathguide/navigation',
        'hk.pathguide/menu',
        'hk.pathguide/vision',
      ];
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
          calls.add('$name:${call.method}');
          if (call.method == 'getLanguages') return ['zh-HK'];
          return null;
        });
      }
      addTearDown(() {
        for (final name in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(name), null);
        }
      });
      await tester.pumpWidget(
        PathGuideApp(
          settings: AppSettings.memory(),
          initialSection: AppSection.navigation,
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('室內路標回放（樣例）'));
      await tester.tap(find.text('室內路標回放（樣例）'));
      await tester.pumpAndSettle();
      expect(find.byType(GraphReplayPage), findsOneWidget);
      expect(find.byKey(const ValueKey('navigation-home')), findsNothing);
      await tester.tap(find.byTooltip('返回導航'));
      await tester.pumpAndSettle();
      expect(find.byType(GraphReplayPage), findsNothing);
      expect(find.byKey(const ValueKey('navigation-home')), findsOneWidget);
      expect(
        calls.where((value) => value.startsWith('hk.pathguide/vision:')),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
