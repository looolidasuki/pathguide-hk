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
