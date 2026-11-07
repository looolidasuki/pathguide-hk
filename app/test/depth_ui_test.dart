import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/depth/depth_page.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/ui/app_theme.dart';

import 'support/fake_depth.dart';

const _previews = String.fromEnvironment('PATHGUIDE_DEPTH_PREVIEWS');

Future<void> captureDepth(WidgetTester tester, String name) async {
  if (_previews.isEmpty) return;
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('depth-preview')),
  );
  await tester.runAsync(() async {
    final frame = await boundary.toImage(pixelRatio: 1);
    final data = await frame.toByteData(format: ui.ImageByteFormat.png);
    await Directory(_previews).create(recursive: true);
    await File('$_previews/$name.png').writeAsBytes(data!.buffer.asUint8List());
    frame.dispose();
  });
}

class DepthSpeaker extends NullSpeaker {
  final words = <String>[];
  Completer<void>? initialized;
  int stops = 0;
  Completer<void>? speaking;
  @override
  Future<void> speak(String text) async {
    words.add(text);
    await speaking?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

Future<void> showDepth(
  WidgetTester tester,
  FakeDepthSource source, {
  AppLanguage language = AppLanguage.chinese,
  double scale = 1,
  DepthSpeaker? speaker,
  bool objects = false,
  bool screenReader = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  var theme = buildAppTheme();
  if (_previews.isNotEmpty) {
    await tester.runAsync(() async {
      final font = FontLoader('DepthPreview')
        ..addFont(
          File('/System/Library/Fonts/STHeiti Light.ttc')
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'DepthPreview'),
    );
  }
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('depth-preview'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: const Size(390, 844),
              textScaler: TextScaler.linear(scale),
              accessibleNavigation: screenReader,
            ),
            child: DepthPage(
              initialObjects: objects,
              settings: AppSettings.memory(language: language),
              source: source,
              speaker: speaker ?? DepthSpeaker(),
              preview: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final language in AppLanguage.values) {
    testWidgets(
      'empty and stale observations can be read and recovered ${language.name}',
      (tester) async {
        final source = FakeDepthSource(), speaker = DepthSpeaker();
        await showDepth(
          tester,
          source,
          language: language,
          objects: true,
          speaker: speaker,
        );
        await tester.tap(find.byKey(const ValueKey('depth-toggle')));
        await tester.pump();
        source.objectFrame(1, []);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('depth-read')));
        await tester.pump();
        expect(
          speaker.words.single,
          contains(
            language == AppLanguage.english ? 'Keep observing' : '可繼續觀察',
          ),
        );
        for (var i = 0; i < 3; i++) {
          source.objectFrame(1.1 + i * .15, []);
        }
        await tester.pump();
        expect(
          speaker.words,
          hasLength(1),
          reason: 'Repeated frames do not repeat status speech',
        );
        for (var i = 0; i < 3; i++) {
          source.objectFrame(2 + i * .15, [FakeDepthSource.object()]);
        }
        await tester.pump();
        speaker.speaking = Completer<void>();
        await tester.tap(find.byKey(const ValueKey('depth-read')));
        await tester.pump();
        final stops = speaker.stops;
        await tester.pump(const Duration(milliseconds: 801));
        expect(
          find.textContaining(language == AppLanguage.english ? 'bin' : '垃圾桶'),
          findsNothing,
        );
        expect(speaker.stops, greaterThan(stops));
        expect(
          find.textContaining(
            language == AppLanguage.english ? 'Results expired' : '結果已過期',
          ),
          findsOneWidget,
        );
        speaker.speaking!.complete();
        await tester.pump();
        source.objectFrame(3, [FakeDepthSource.object(known: false)]);
        await tester.pump();
        speaker.speaking = null;
        await tester.tap(find.byKey(const ValueKey('depth-read')));
        await tester.pump();
        expect(
          speaker.words.last,
          contains(
            language == AppLanguage.english ? 'Objects overlap' : '物件重疊',
          ),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await source.events.close();
      },
    );
  }
  testWidgets('VoiceOver reads unknown status once without TTS', (
    tester,
  ) async {
    final source = FakeDepthSource(), speaker = DepthSpeaker();
    final messages = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler<Object?>(
      SystemChannels.accessibility,
      (message) async {
        messages.add(message);
        return null;
      },
    );
    addTearDown(
      () => messenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility,
        null,
      ),
    );
    await showDepth(tester, source, speaker: speaker, screenReader: true);
    await tester.tap(find.byKey(const ValueKey('depth-read')));
    await tester.pump();
    expect(
      messages.whereType<Map>().where((m) => m['type'] == 'announce'),
      hasLength(1),
    );
    expect(speaker.words, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await source.events.close();
  });
  testWidgets(
    'permission settings return allows only an explicit camera retry',
    (tester) async {
      final source = FakeDepthSource()..result = 'permission';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var opened = 0;
      messenger.setMockMethodCallHandler(
        const MethodChannel('hk.pathguide/depth'),
        (call) async {
          if (call.method == 'openSettings') opened++;
          return true;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('hk.pathguide/depth'),
          null,
        ),
      );
      await showDepth(tester, source);
      await tester.tap(find.byKey(const ValueKey('depth-toggle')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('depth-toggle')))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('depth-settings')));
      await tester.tap(find.byKey(const ValueKey('depth-settings')));
      await tester.pump();
      expect(opened, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(source.starts, 1);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('depth-toggle')))
            .onPressed,
        isNotNull,
      );
      source.result = 'running';
      await tester.tap(find.byKey(const ValueKey('depth-toggle')));
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(source.starts, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await source.events.close();
    },
  );
  for (final language in AppLanguage.values) {
    testWidgets('shows refusal cause and depth point counts ${language.name}', (
      tester,
    ) async {
      final source = FakeDepthSource();
      await showDepth(
        tester,
        source,
        language: language,
        objects: true,
        scale: 2,
      );
      await tester.tap(find.byKey(const ValueKey('depth-toggle')));
      await tester.pump();
      source.objectFrame(1, [
        {
          ...FakeDepthSource.object(known: false),
          'reason': 'low_depth',
          'validDepth': 8,
          'depthTotal': 25,
          'samplePoint': [.2, .4],
        },
      ]);
      await tester.pump();
      expect(
        find.text(
          language == AppLanguage.english
              ? 'Insufficient high-confidence depth in range'
              : '量程內高信心深度不足',
        ),
        findsNothing,
      );
      expect(find.textContaining('8/25'), findsNothing);
      expect(
        find.textContaining(
          language == AppLanguage.english
              ? 'Stand still and re-aim'
              : '可站定並重新對準',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('depth-status')));
      await captureDepth(tester, 'app-1.4.2+7-depth-${language.name}-2x');
      await tester.ensureVisible(
        find.byKey(const ValueKey('depth-diagnostics')),
      );
      await tester.tap(
        find.text(
          language == AppLanguage.english
              ? 'Range diagnostics (advanced)'
              : '測距診斷（進階）',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('8/25'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await source.events.close();
    });
  }
  for (final language in AppLanguage.values) {
    testWidgets(
      'depth ${language.name} large text retains start/read controls',
      (tester) async {
        final source = FakeDepthSource();
        await showDepth(tester, source, language: language, scale: 2);
        for (final key in ['depth-toggle', 'depth-read']) {
          expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
          expect(
            tester.getSize(find.byKey(ValueKey(key))).height,
            greaterThanOrEqualTo(48),
          );
        }
        await tester.tap(find.byKey(const ValueKey('depth-toggle')));
        await tester.pump();
        source.stable();
        await tester.pump();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('depth-range')),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.text(
            language == AppLanguage.english ? 'About 2.0 m' : '約 2.0 米',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await source.events.close();
      },
    );
  }
  testWidgets(
    'manual read uses current value; background clears and never auto resumes',
    (tester) async {
      final source = FakeDepthSource();
      final speaker = DepthSpeaker();
      await showDepth(tester, source, speaker: speaker);
      await tester.tap(find.byKey(const ValueKey('depth-toggle')));
      await tester.pump();
      source.stable();
      await tester.pump();
      expect(speaker.words, isEmpty);
      await tester.tap(find.byKey(const ValueKey('depth-read')));
      await tester.pump();
      expect(speaker.words.single, contains('2.0 米'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('距離未知'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(source.starts, 1);
      expect(find.text('開始測距'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await source.events.close();
    },
  );
  testWidgets('unsupported sensor explains and does not offer a distance', (
    tester,
  ) async {
    final source = FakeDepthSource()..result = 'unsupported';
    await showDepth(tester, source);
    await tester.tap(find.byKey(const ValueKey('depth-toggle')));
    await tester.pump();
    expect(find.textContaining('此裝置不支援測距'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('depth-toggle')))
          .onPressed,
      isNull,
    );
    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('depth-read')),
    );
    expect(button.onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await source.events.close();
  });
  for (final language in AppLanguage.values) {
    testWidgets(
      'object names ranges and unknown depth at double text ${language.name}',
      (tester) async {
        final source = FakeDepthSource(), speaker = DepthSpeaker();
        await showDepth(
          tester,
          source,
          language: language,
          scale: 2,
          speaker: speaker,
          objects: true,
        );
        await tester.tap(find.byKey(const ValueKey('depth-toggle')));
        await tester.pump();
        for (var i = 0; i < 3; i++) {
          source.objectFrame(1 + i * .15, [
            FakeDepthSource.object(),
            FakeDepthSource.object(id: 18, box: [.7, .2, .2, .5], known: false),
          ]);
        }
        await tester.pump();
        expect(source.lastObjects, isTrue);
        expect(
          find.textContaining(language == AppLanguage.english ? 'bin' : '垃圾桶'),
          findsOneWidget,
        );
        expect(
          find.text(
            language == AppLanguage.english
                ? 'Surface inside box about 2.0 m'
                : '框內表面約 2.0 米',
          ),
          findsOneWidget,
        );
        expect(
          find.text(language == AppLanguage.english ? 'Range unknown' : '距離未知'),
          findsOneWidget,
        );
        for (final key in ['depth-toggle', 'depth-read']) {
          expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
        }
        expect(speaker.words, isEmpty);
        await tester.tap(find.byKey(const ValueKey('depth-read')));
        await tester.pump();
        expect(
          speaker.words.single,
          contains(language == AppLanguage.english ? 'Range unknown' : '距離未知'),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await source.events.close();
      },
    );
  }
  testWidgets(
    'pause is required to change camera mode and background clears objects',
    (tester) async {
      final source = FakeDepthSource();
      await showDepth(tester, source, objects: true);
      await tester.tap(find.byKey(const ValueKey('depth-toggle')));
      await tester.pump();
      final control = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('depth-objects')),
      );
      expect(control.onChanged, isNull);
      for (var i = 0; i < 3; i++) {
        source.objectFrame(1 + i * .15, [FakeDepthSource.object()]);
      }
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.textContaining('垃圾桶'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(source.starts, 1);
      await tester.ensureVisible(find.byKey(const ValueKey('depth-objects')));
      await tester.tap(find.byKey(const ValueKey('depth-objects')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('depth-objects')))
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('depth-toggle')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('depth-toggle')));
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(source.starts, 2);
      expect(source.lastObjects, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await source.events.close();
    },
  );
}
