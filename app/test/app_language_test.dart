
import 'package:flutter/services.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/l10n/app_language.dart';
import 'package:pathguide/main.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/ui/app_shell.dart';
import 'package:pathguide/ui/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('language persists independently of thresholds and speed', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    await settings.setLanguage(AppLanguage.english);
    final restored = await AppSettings.load();
    expect(restored.language, AppLanguage.english);
    expect(restored.speakThreshold, .7);
    expect(appText('辨識到：樓梯、門', restored.language), 'Detected: stairs, door');
    expect(
      appText('全程約 120 米，出發預估約 3 分鐘。', restored.language),
      'About 120 metres in total. Initial estimate: 3 minutes.',
    );
  });
  testWidgets(
    'switching language updates menus and retains the current task page',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const fontDir = String.fromEnvironment('INTEGRATION_FONT_DIR');
      if (fontDir.isNotEmpty) {
        await tester.runAsync(() async {
          for (final entry in {
            'CaptureRoboto': 'Roboto-Regular.ttf',
            'MaterialIcons': 'MaterialIcons-Regular.otf',
          }.entries) {
            final loader = FontLoader(entry.key)
              ..addFont(
                File('$fontDir/${entry.value}')
                    .readAsBytes()
                    .then(ByteData.sublistView),
              );
            await loader.load();
          }
        });
      }
      final settings = AppSettings.memory();
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: PathGuideApp(
            settings: settings,
            theme: fontDir.isEmpty
                ? null
                : buildAppTheme().copyWith(
                    textTheme: buildAppTheme().textTheme.apply(
                      fontFamily: 'CaptureRoboto',
                    ),
                  ),
            initialSection: AppSection.settings,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('app-language')));
      await tester.tap(find.byKey(const ValueKey('app-language')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      expect(settings.language, AppLanguage.english);
      expect(find.text('Settings'), findsWidgets);
      expect(find.text('Manage speech and live recognition.'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-page')), findsOneWidget);
      const folder = String.fromEnvironment('INTEGRATION_CAPTURE_DIR');
      if (folder.isNotEmpty) {
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(folder).create(recursive: true);
          await File('$folder/settings-english.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
