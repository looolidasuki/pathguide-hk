import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/l10n/app_language.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/ui/usage_guide.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const newChineseSafety = '基本辨識只提示物件名稱，沒有辨識結果不代表前方安全；不提供扶手電梯方向或避障指令。';
  const newChineseRange = '站定後才開始';
  const newChineseUnknown = '缺乏可靠深度時顯示「距離未知」，不可用作避障。';
  const newEnglishSafety =
      'Basic recognition names objects; it does not determine escalator direction or provide obstacle avoidance.';
  const newEnglishRange = 'stand still before starting.';
  const newEnglishUnknown =
      'Without reliable depth, the result is Range unknown.';
  const staleChinese = '沒有辨識結果不代表前方安全；本版不提供距離、扶手電梯方向或避障指令。';
  const staleEnglish =
      'No detection does not mean the path is clear. This version does not measure distance, escalator direction or provide obstacle avoidance.';

  String closeLabel(AppLanguage language) =>
      language == AppLanguage.english ? 'Close guide' : '關閉教學';

  Widget launcher(AppLanguage language, {bool largeText = false}) =>
      AppLanguageScope(
        language: language,
        child: MaterialApp(
          builder: largeText
              ? (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                )
              : null,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showUsageGuide(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

  String joinedText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
      .join('\n');

  Future<void> openGuide(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  testWidgets('Chinese guide shows new safety and range content', (
    tester,
  ) async {
    await tester.pumpWidget(launcher(AppLanguage.chinese));
    await openGuide(tester);
    final text = joinedText(tester);
    expect(text, contains(newChineseSafety));
    expect(text, contains(newChineseRange));
    expect(text, contains('設定 → 開發測試'));
    expect(text, contains(newChineseUnknown));
    expect(text, isNot(contains(staleChinese)));
    expect(text, contains(closeLabel(AppLanguage.chinese)));
  });

  testWidgets('English guide shows new safety and range content', (
    tester,
  ) async {
    await tester.pumpWidget(launcher(AppLanguage.english));
    await openGuide(tester);
    final text = joinedText(tester);
    expect(text, contains(newEnglishSafety));
    expect(text, contains(newEnglishRange));
    expect(text, contains('Settings → Developer testing'));
    expect(text, contains(newEnglishUnknown));
    expect(text, isNot(contains(staleEnglish)));
    expect(text, isNot(contains(newChineseSafety)));
    expect(text, isNot(contains('測距試驗')));
    expect(find.text(closeLabel(AppLanguage.english)), findsOneWidget);
  });

  Finder guideScrollable() => find
      .descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Scrollable),
      )
      .first;

  Finder closeGuide(AppLanguage language) => find.descendant(
    of: find.byType(AlertDialog),
    matching: find.widgetWithText(TextButton, closeLabel(language)),
  );

  for (final language in AppLanguage.values) {
    testWidgets(
      '${language.name} guide scales text, scrolls at 320x568 without '
      'overflow and closes',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(launcher(language, largeText: true));
        await openGuide(tester);

        final dialogContext = tester.element(find.byType(AlertDialog));
        expect(
          MediaQuery.textScalerOf(dialogContext).scale(10),
          moreOrLessEquals(20),
        );

        expect(tester.takeException(), isNull);

        final close = closeGuide(language);
        expect(close, findsOneWidget);
        await tester.scrollUntilVisible(
          close,
          120,
          scrollable: guideScrollable(),
        );
        await tester.pumpAndSettle();
        expect(close, findsOneWidget);

        final size = tester.getSize(close);
        expect(size.width, greaterThanOrEqualTo(56));
        expect(size.height, greaterThanOrEqualTo(56));

        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('open'), findsOneWidget);
      },
    );
  }

  testWidgets('close guide is an enabled button with a tap action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(launcher(AppLanguage.english));
      await openGuide(tester);

      final node = tester.getSemantics(closeGuide(AppLanguage.english));
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isEnabled, Tristate.isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    } finally {
      semantics.dispose();
    }
  });
}
