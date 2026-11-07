import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/main.dart';
import 'package:pathguide/settings/app_settings.dart';

void main() {
  testWidgets('home explains daily tasks and keeps testing behind settings', (
    t,
  ) async {
    await t.pumpWidget(PathGuideApp(settings: AppSettings.memory()));
    await t.pumpAndSettle();
    expect(find.text('用相機辨識支援的物件，聽取簡短結果。'), findsOneWidget);
    expect(find.text('搜尋戶外目的地，或錄製室內路標路線。'), findsOneWidget);
    expect(find.text('拍攝菜單，查詢菜名及價格。'), findsOneWidget);
    expect(find.text('室內路線工具（試驗）'), findsNothing);
    expect(find.text('首頁'), findsNothing);
    await t.tap(find.text('設定與使用教學'));
    await t.pumpAndSettle();
    expect(find.text('開發測試'), findsOneWidget);
    expect(find.text('未來功能'), findsNothing);
    expect(find.text('模型與下載'), findsNothing);
    await t.ensureVisible(find.text('開發測試'));
    await t.tap(find.text('開發測試'));
    await t.pumpAndSettle();
    expect(find.text('錄路相機試驗'), findsOneWidget);
    expect(find.text('只檢查預覽及取相；相片暫存此頁，不會保存路線或提供導航。'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'first-use help can be skipped and is not repeated for that task',
    (t) async {
      await t.pumpWidget(PathGuideApp(settings: AppSettings.memory()));
      await t.pumpAndSettle();
      await t.tap(find.text('菜單閱讀與語音搜尋'));
      await t.pumpAndSettle();
      expect(find.text('開始前'), findsOneWidget);
      expect(find.text('拍攝或選取菜單，再用文字或語音查詢。'), findsOneWidget);
      await t.tap(find.text('略過說明'));
      await t.pumpAndSettle();
      expect(find.text('菜單閱讀'), findsOneWidget);
      await t.tap(find.byTooltip('返回'));
      await t.pumpAndSettle();
      await t.tap(find.text('菜單閱讀與語音搜尋'));
      await t.pumpAndSettle();
      expect(find.text('開始前'), findsNothing);
      expect(find.text('菜單閱讀'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );
  for (final language in AppLanguage.values) {
    testWidgets(
      '${language.name}: task help remains usable at double text size',
      (t) async {
        t.view.physicalSize = const Size(320, 568);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        await t.pumpWidget(
          PathGuideApp(settings: AppSettings.memory(language: language)),
        );
        await t.pumpAndSettle();
        final task = find.text(
          language == AppLanguage.chinese ? '即時辨識' : 'Live recognition',
        );
        await t.scrollUntilVisible(task, 150);
        await t.ensureVisible(
          find.ancestor(of: task, matching: find.byType(FilledButton)),
        );
        await t.pumpAndSettle();
        await t.tap(task);
        await t.pumpAndSettle();
        expect(
          find.text(
            language == AppLanguage.chinese ? '開始前' : 'Before you start',
          ),
          findsOneWidget,
        );
        final back = find.text(language == AppLanguage.chinese ? '返回' : 'Back');
        await t.ensureVisible(back);
        await t.tap(back);
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('task-home')), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
}
