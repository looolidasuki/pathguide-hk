import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/l10n/app_locale.dart';
import 'package:pathguide/l10n/app_strings.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/ui/settings_page.dart';

/// 測試注入的模型摘要（等同 `ModelManifest` 算出來的那一行）。
const String kInjectedSummary = '18 類 · 2.87 MB · 2026-10-02.stage2';

/// 一句話裡出現幾次 `needle`。用來抓「同一個字被唸兩次」。
int countOccurrences(String haystack, String needle) =>
    needle.isEmpty ? 0 : haystack.split(needle).length - 1;

void main() {
  setUp(() => AppLocale.current = AppLanguage.zh);

  Future<AppSettings> pump(WidgetTester tester) async {
    final settings = AppSettings.memory();
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        settings: settings,
        modelSummary: () async => kInjectedSummary,
      ),
    ));
    await tester.pumpAndSettle();
    return settings;
  }

  /// 把字級調到 200%，並把畫布縮成一部 360×640 dp 的手機。
  ///
  /// 兩個都要：只看 200%、畫布還是預設的 800×600 時，en 的「Speech speed」
  /// 在 800 dp 寬下不會折行，那條測試就抓不到審查意見說的那個截斷。
  /// 真正的觸發條件是「窄機 + 大字」。
  void scaleTo200(WidgetTester tester, AppLanguage language) {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(1080, 1920); // 360×640 dp
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    AppLocale.current = language;
  }

  /// 點開語速面板。
  ///
  /// 用 `OutlinedButton` 定位而不是文字：en 的說明句 'Speech speed only'
  /// 也含 'Speech speed'，純文字找會命中兩個。
  Future<void> openSpeedSheet(WidgetTester tester, AppStrings s) async {
    await tester.tap(find.widgetWithText(OutlinedButton, s.speechSpeed));
    await tester.pumpAndSettle();
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

  group('★ 200% 字級不截斷', () {
    for (final language in AppLanguage.values) {
      testWidgets('200% 字級（${language.name}）：設定頁不截斷', (tester) async {
        scaleTo200(tester, language);
        await pump(tester);
        final s = AppStrings.of(language);

        final speedRow = find.widgetWithText(OutlinedButton, s.speechSpeed);
        expect(speedRow, findsOneWidget);
        expect(
          tester.getSize(speedRow).height,
          greaterThanOrEqualTo(60.0),
          reason: '100% 下的觸控目標下限是 60；200% 只能長大不能變矮',
        );
        expect(find.textContaining(s.modelInfo), findsOneWidget);
        // 200% 下任何 RenderFlex / Text 溢出都會直接讓這條測試失敗
        // （Flutter 在測試裡把 overflow 當成例外），所以「測試綠」
        // 本身就等於「頁面沒有被裁掉」。
      });

      testWidgets('200% 字級（${language.name}）：語速面板不截斷', (tester) async {
        scaleTo200(tester, language);
        await pump(tester);
        final s = AppStrings.of(language);
        await openSpeedSheet(tester, s);

        for (final name in <String>[
          s.speechSpeedSlow,
          s.speechSpeedNormal,
          s.speechSpeedFast,
        ]) {
          final row = find.widgetWithText(TextButton, name);
          expect(row, findsOneWidget, reason: '面板要有「$name」這一列');
          expect(
            tester.getSize(row).height,
            greaterThanOrEqualTo(56.0),
            reason: '「$name」那一列在 200% 下要長高，不能被 56 切掉',
          );
        }
      });
    }
  });

  testWidgets('★ 面板上「目前是哪個語速」聽得出來：selected + 「已選取」', (tester) async {
    final handle = tester.ensureSemantics();
    final settings = await pump(tester);
    final s = AppStrings.of(AppLanguage.zh);
    expect(settings.speechSpeed, SpeechSpeed.normal);

    await openSpeedSheet(tester, s);

    // 預設是「正常」，所以只有那一列該被唸成已選取。
    final selectedRow = find.bySemanticsLabel(RegExp(s.speechSpeedSelected));
    expect(selectedRow, findsOneWidget, reason: '只有「正常」這一列是選中的');

    final node = tester.getSemantics(selectedRow);
    expect(
      node.flagsCollection.isSelected,
      Tristate.isTrue,
      reason: '少了 selected，TalkBack 唸不出哪個是目前的語速',
    );
    expect(node.label, contains(s.speechSpeedSelected));

    // 沒選中的那一列不能被一起標成已選取，否則等於大家都選取。
    final unselectedRow = tester.getSemantics(find.bySemanticsLabel('選快'));
    expect(unselectedRow.flagsCollection.isSelected, Tristate.isFalse);

    handle.dispose();
  });

  testWidgets('★ 模型資訊是**一個**語意節點：標題一次、摘要一次', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);

    final block = find.bySemanticsLabel(RegExp('模型資訊'));
    expect(
      block,
      findsOneWidget,
      reason: '內層 Text 若沒被 ExcludeSemantics 吃掉，會多出一個只唸標題的節點',
    );

    final label = tester.getSemantics(block).label;
    expect(countOccurrences(label, '模型資訊'), 1, reason: '標題只能唸一次');
    expect(countOccurrences(label, kInjectedSummary), 1, reason: '摘要只能唸一次');

    handle.dispose();
  });

  testWidgets('摘要還沒讀回來時唸「載入中」，不唸破折號', (tester) async {
    final handle = tester.ensureSemantics();
    final gate = Completer<String?>();
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        settings: AppSettings.memory(),
        modelSummary: () => gate.future,
      ),
    ));
    await tester.pump();

    final label = tester.getSemantics(find.bySemanticsLabel(RegExp('模型資訊'))).label;
    expect(label, contains('載入中'));
    expect(
      label,
      isNot(contains('—')),
      reason: '螢幕閱讀器唸「—」是 “dash”，等於什麼都沒說',
    );

    gate.complete(null);
    await tester.pumpAndSettle();
    handle.dispose();
  });
}
