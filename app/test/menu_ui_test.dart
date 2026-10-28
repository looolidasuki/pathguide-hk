import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/menu/menu_page.dart';
import 'package:pathguide/menu/menu_document.dart';
import 'package:pathguide/menu/menu_reader.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/ui/app_theme.dart';

import 'support/fake_menu.dart';

void main() {
  const preview = String.fromEnvironment('PATHGUIDE_MENU_PREVIEWS');
  Future<void> capture(WidgetTester tester, String name) async {
    if (preview.isEmpty) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('menu-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(preview).create(recursive: true);
      await File('$preview/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> open(
    WidgetTester tester,
    FakeMenuReader reader,
    MenuTestSpeaker speaker, {
    double scale = 1,
  }) async {
    ThemeData theme = buildAppTheme();
    if (preview.isNotEmpty && Platform.isMacOS) {
      await tester.runAsync(() async {
        final loader = FontLoader('MenuPreview')
          ..addFont(
            File('/System/Library/Fonts/STHeiti Light.ttc')
                .readAsBytes()
                .then((b) => ByteData.sublistView(b)),
          );
        await loader.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      theme = theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'MenuPreview'),
        primaryTextTheme: theme.primaryTextTheme.apply(
          fontFamily: 'MenuPreview',
        ),
      );
    }
    if (preview.isNotEmpty && tester.view.physicalSize.width > 500) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('menu-preview'),
        child: MaterialApp(
          theme: theme,
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: MenuPage(
            settings: AppSettings.memory(),
            reader: reader,
            speaker: speaker,
            onBack: () {},
          ),
        ),
      ),
    );
  }

  Future<void> read(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('capture-menu')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'spoken dish automatically searches and reads price without another confirmation',
    (tester) async {
      final reader = FakeMenuReader()..document = sampleMenu();
      final speaker = MenuTestSpeaker();
      await open(tester, reader, speaker);
      await read(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('voice-menu-search')),
      );
      await tester.tap(find.byKey(const ValueKey('voice-menu-search')));
      await tester.pumpAndSettle();
      await capture(tester, 'menu-search');
      expect(reader.listens, 1);
      expect(find.text('牛腩飯'), findsOneWidget);
      expect(speaker.utterances.single, contains('\$48'));
      expect(speaker.utterances.single, isNot(contains('\$45')));
      expect(find.text('牛腩飯 \$48'), findsOneWidget);
      expect(find.text('叉燒飯 \$45'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('online speech fallback asks first and can be refused', (
    tester,
  ) async {
    final reader = FakeMenuReader()
      ..document = sampleMenu()
      ..speechError = const MenuFailure(
        '沒有離線語音',
        code: 'offline_speech_unavailable',
      );
    final speaker = MenuTestSpeaker();
    await open(tester, reader, speaker);
    await read(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('voice-menu-search')));
    await tester.tap(find.byKey(const ValueKey('voice-menu-search')));
    await tester.pumpAndSettle();
    expect(find.text('使用 Apple 線上語音搜尋？'), findsOneWidget);
    expect(reader.listens, 1);
    await tester.tap(find.text('取消，改用文字'));
    await tester.pumpAndSettle();
    expect(reader.listens, 1);
    expect(speaker.utterances, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'two-times text retains usable capture, search and fixed stop controls',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final reader = FakeMenuReader()..document = sampleMenu();
      final speaker = MenuTestSpeaker();
      await open(tester, reader, speaker, scale: 2);
      await tester.ensureVisible(find.byKey(const ValueKey('capture-menu')));
      await read(tester);
      await tester.scrollUntilVisible(
        find.byType(TextField),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), '牛腩飯');
      await tester.ensureVisible(find.text('文字搜尋'));
      await tester.tap(find.text('文字搜尋'));
      await tester.pumpAndSettle();
      expect(speaker.utterances.single, contains('\$48'));
      expect(find.text('停止 App 朗讀'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'menu-large');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'five searches each automatically speak once; empty speech asks to retry',
    (tester) async {
      final reader = FakeMenuReader()..document = sampleMenu();
      final speaker = MenuTestSpeaker();
      await open(tester, reader, speaker);
      await read(tester);
      for (var i = 0; i < 5; i++) {
        reader.phrase = i.isEven ? '唔該，我想食 牛腩飯呀' : '牛腩飯';
        await tester.ensureVisible(
          find.byKey(const ValueKey('voice-menu-search')),
        );
        await tester.tap(find.byKey(const ValueKey('voice-menu-search')));
        await tester.pumpAndSettle();
        expect(speaker.utterances.length, i + 1);
        expect(speaker.utterances.last, contains('48'));
      }
      reader.phrase = '';
      await tester.tap(find.byKey(const ValueKey('voice-menu-search')));
      await tester.pumpAndSettle();
      expect(speaker.utterances.length, 6);
      expect(speaker.utterances.last, contains('未收到可用語音'));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'permission inactive holds output until resume, actual background discards it',
    (tester) async {
      final wait = Completer<String?>();
      final reader = FakeMenuReader()
        ..document = sampleMenu()
        ..speechFuture = wait.future;
      final speaker = MenuTestSpeaker();
      await open(tester, reader, speaker);
      await read(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('voice-menu-search')),
      );
      await tester.tap(find.byKey(const ValueKey('voice-menu-search')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      wait.complete('我想食牛腩飯');
      await tester.pumpAndSettle();
      expect(speaker.utterances, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(speaker.utterances.length, 1);
      final late = Completer<String?>();
      reader.speechFuture = late.future;
      await tester.tap(find.byKey(const ValueKey('voice-menu-search')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      late.complete('我想食叉燒飯');
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(speaker.utterances.length, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'VoiceOver uses announcement only, without competing result live region',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final announcements = <Object?>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, (
            message,
          ) async {
            announcements.add(message);
            return null;
          });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<Object?>(
              SystemChannels.accessibility,
              null,
            ),
      );
      final speaker = MenuTestSpeaker();
      await open(tester, FakeMenuReader()..document = sampleMenu(), speaker);
      await read(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('voice-menu-search')),
      );
      await tester.tap(find.byKey(const ValueKey('voice-menu-search')));
      await tester.pumpAndSettle();
      expect(speaker.utterances, isEmpty);
      expect(announcements.where((m) => m.toString().contains('48')).length, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'camera presentation hides Flutter without cancelling acquisition',
    (tester) async {
      final wait = Completer<MenuDocument?>();
      final reader = FakeMenuReader()
        ..notifyRecognizing = false
        ..readFuture = wait.future;
      final speaker = MenuTestSpeaker();
      await open(tester, reader, speaker);
      await tester.tap(find.byKey(const ValueKey('capture-menu')));
      await tester.pump();
      final before = reader.cancels;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(reader.cancels, before);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      wait.complete(sampleMenu());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice-menu-search')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('camera failure is audible and capture can be retried', (
    tester,
  ) async {
    final reader = FakeMenuReader()
      ..readError = const MenuFailure('未獲相機權限，請在設定開啟。', code: 'camera_denied');
    final speaker = MenuTestSpeaker();
    await open(tester, reader, speaker);
    await read(tester);
    expect(speaker.utterances.single, contains('相機權限'));
    reader.readError = null;
    reader.document = sampleMenu();
    await read(tester);
    expect(reader.reads, 2);
    expect(find.byKey(const ValueKey('voice-menu-search')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('user tea menu voice query automatically reads variant prices', (
    tester,
  ) async {
    final data = jsonDecode(
      File('test/fixtures/menu/tea-menu.macos-vision.json').readAsStringSync(),
    ) as Map;
    final document = parseMenu(
      (data['lines'] as List).map((l) => MenuLine.fromMap(l as Map)).toList(),
      pages: 1,
    );
    final reader = FakeMenuReader()
      ..document = document
      ..phrase = '我想食，三文治';
    final speaker = MenuTestSpeaker();
    await open(tester, reader, speaker);
    await read(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('voice-menu-search')));
    await tester.tap(find.byKey(const ValueKey('voice-menu-search')));
    await tester.pumpAndSettle();
    expect(speaker.utterances.single, contains('單拼 \$31'));
    expect(speaker.utterances.single, contains('雙拼 \$33'));
    expect(speaker.utterances.single, contains('三拼 \$36'));
    expect(speaker.utterances.single, isNot(contains('\$26')));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('raw OCR dialog copies local diagnostics including geometry', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final reader = FakeMenuReader()..document = sampleMenu();
    await open(tester, reader, MenuTestSpeaker());
    await read(tester);
    await tester.scrollUntilVisible(
      find.text('查看辨識原文'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('查看辨識原文'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('複製排查資料'));
    await tester.pumpAndSettle();
    expect(copied, contains('完整價錢標記：2'));
    expect(copied, contains('x=0.100'));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('phone OCR geometry automatically reads the queried dish price', (
    tester,
  ) async {
    final data = jsonDecode(
      File('test/fixtures/menu/dense-menu.iphone-selected.json')
          .readAsStringSync(),
    ) as Map;
    final document = parseMenu(
      (data['lines'] as List).map((l) => MenuLine.fromMap(l as Map)).toList(),
      pages: 1,
    );
    final reader = FakeMenuReader()
      ..document = document
      ..phrase = '我想食星洲炒烏冬';
    final speaker = MenuTestSpeaker();
    await open(tester, reader, speaker);
    await read(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('voice-menu-search')));
    await tester.tap(find.byKey(const ValueKey('voice-menu-search')));
    await tester.pumpAndSettle();
    expect(speaker.utterances.single, contains('星洲炒烏冬 \$58'));
    expect(speaker.utterances.single, isNot(contains('未能確認價錢')));
    await tester.pumpWidget(const SizedBox());
  });
}
