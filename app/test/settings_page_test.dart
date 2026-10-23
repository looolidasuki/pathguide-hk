import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/auth/auth_service.dart';
import 'package:pathguide/auth/mock_auth_service.dart';
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

  /// 掛上設定頁。`authService` 預設不給：不給就**不畫帳號列**，
  /// 所以前面三條既有測試（播報速度／模型資訊／返回）不受帳號功能影響。
  Future<AppSettings> pump(
    WidgetTester tester, {
    AuthService? authService,
    VoidCallback? onOpenAccount,
  }) async {
    final settings = AppSettings.memory();
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        settings: settings,
        modelSummary: () async => kInjectedSummary,
        authService: authService,
        onOpenAccount: onOpenAccount,
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

  /// 把帳號列捲進視窗，回傳 **捲進來之後**才存在的 finder。
  ///
  /// 360×640 dp + 200% 字級時，帳號列落在 `ListView` 可見區**底下**，而
  /// `ListView` 只建可見範圍（含 cacheExtent）的子項——沒捲到的話整列根本
  /// 還沒被建出來，`find` 自然是 0 個。這是測試視窗只有 640 dp 高的問題，
  /// 不是頁面把字裁掉。
  ///
  /// 捲進來之後那一列才真的被排版、被繪製；`RenderFlex` 溢出是**畫**的
  /// 時候才丟出來的，所以「捲 → 再斷言」抓的仍然是「有沒有被裁掉」，
  /// 而且比不捲更嚴：不捲的話那條溢出的 bug 根本沒機會發生。
  ///
  /// 刻意不改成「把視窗調高」（例如 360×1200）來讓東西全部建出來：帳號列的
  /// 風險在**寬**——「訪客（可完整使用識別）」要塞進 360 dp 就得折行長高；
  /// 捲動完全不動寬度，維持原本要驗的那個條件。
  Future<Finder> revealAccountRow(WidgetTester tester, AppStrings s) async {
    final accountRow = find.widgetWithText(OutlinedButton, s.account);
    await tester.scrollUntilVisible(
      accountRow,
      200,
      // 指定這一頁的 `ListView`：頁面上只有它一個 `Scrollable`，
      // 但寫明白才不會哪天多出別的捲動區就默默失效。
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    return accountRow;
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

      // 帳號列的狀態文字是這一頁最長的一句（zh 的「訪客（可完整使用識別）」
      // 就有 11 個全形字），窄機 + 200% 是它唯一會撞牆的組合。
      testWidgets('200% 字級（${language.name}）：帳號列不截斷', (tester) async {
        scaleTo200(tester, language);
        await pump(tester, authService: MockAuthService());
        final s = AppStrings.of(language);

        // 先捲到帳號列：它在折線以下，不捲就還沒被建出來（見 `revealAccountRow`）。
        final accountRow = await revealAccountRow(tester, s);
        expect(accountRow, findsOneWidget);
        expect(
          tester.getSize(accountRow).height,
          greaterThanOrEqualTo(60.0),
          reason: '200% 只能長大不能變矮；固定高度就是把字切掉',
        );
        // 狀態那句話必須完整存在（不是被裁掉的半句）。
        expect(find.textContaining(s.accountGuest), findsOneWidget);
        // 捲進來之後那一列會真的被排版、被繪製：200% 下任何 RenderFlex 溢出
        // 都會直接讓這條測試失敗，所以「測試綠」本身就等於「帳號列沒有被裁掉」。
      });
    }
  });

  // 審查的 must-fix：返回鍵曾是這頁唯一還留著 `SizedBox(height: 52)` 的地方，
  // 而固定高度正是「200% 字級把字切掉」的元凶（本分支其他地方都改成 minHeight）。
  //
  // 這裡做的是**形狀**的斷言，不是高度數字：`getSize(back).height >= 52` 對舊
  // 寫法也成立（套套邏輯），真正該鎖住的是「沒有那個固定高度的盒子」。
  testWidgets('★ 返回鍵不是固定 52 高（用 minHeight 下限 + padding）', (tester) async {
    await pump(tester);
    final s = AppStrings.of(AppLanguage.zh);
    final back = find.widgetWithText(OutlinedButton, s.backToHome);
    expect(back, findsOneWidget);

    expect(
      find.ancestor(
        of: back,
        matching:
            find.byWidgetPredicate((w) => w is SizedBox && w.height == 52),
      ),
      findsNothing,
      reason: '固定 52 高會讓 200% 字級下的標籤被切掉；要的是 minHeight 下限',
    );
    // 下限還在（100% 字級下的觸控目標），只是不再是上限。
    expect(tester.getSize(back).height, greaterThanOrEqualTo(52.0));
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

  // --- 帳號列（Task 10）---

  testWidgets('★ 訪客狀態要說清楚「識別仍可完整使用」，不是只寫「未登入」', (tester) async {
    await pump(tester, authService: MockAuthService());

    expect(find.textContaining('訪客'), findsOneWidget);
    expect(find.textContaining('完整使用'), findsOneWidget);
    expect(
      find.textContaining('未登入'),
      findsNothing,
      reason: '只寫「未登入」等於暗示功能被鎖住，但訪客本來就能完整使用識別',
    );
  });

  testWidgets('帳號列可點，且不是裸圖標', (tester) async {
    final handle = tester.ensureSemantics();
    var opened = 0;
    await pump(
      tester,
      authService: MockAuthService(),
      onOpenAccount: () => opened++,
    );
    final s = AppStrings.of(AppLanguage.zh);

    // 真正的那顆按鈕（不是圖示假裝的），而且夠高。
    final accountRow = find.widgetWithText(OutlinedButton, s.account);
    expect(accountRow, findsOneWidget);
    expect(
      tester.getSize(accountRow).height,
      greaterThanOrEqualTo(48.0),
      reason: '可操作項的觸控目標下限是 48',
    );

    // 一個語意節點，標籤是「動作 + 現況」。
    final node = find.bySemanticsLabel(RegExp(s.account));
    expect(node, findsOneWidget, reason: '內層文字若沒被吃掉，會多出兩個只唸一半的節點');
    final label = tester.getSemantics(node).label;
    expect(label, contains(s.accountGuest));
    expect(label, contains('點兩下'), reason: '標籤要說出按下去會怎樣');

    await tester.ensureVisible(find.text(s.account));
    await tester.tap(find.text(s.account));
    await tester.pumpAndSettle();
    expect(opened, 1, reason: '按一次只能呼叫一次');

    handle.dispose();
  });

  testWidgets('★ 已登入狀態唸「已登入」，不唸「訪客」', (tester) async {
    final handle = tester.ensureSemantics();
    // ★ 用現成的 `signedIn` 工廠：它在建構時就備好 `initialAccount` 與
    //   已寫入的 store，所以 `restore()` 一定回得出帳號，不必先跑一次登入流程。
    final service = MockAuthService.signedIn(MockAuthService.defaultAccount);
    await pump(tester, authService: service);
    final s = AppStrings.of(AppLanguage.zh);

    expect(find.text(s.accountSignedIn), findsOneWidget);
    expect(
      find.textContaining('訪客'),
      findsNothing,
      reason: '已登入卻還被唸成訪客，使用者會以為登入沒成功',
    );

    final node = find.bySemanticsLabel(RegExp(s.accountSignedIn));
    expect(node, findsOneWidget);
    final label = tester.getSemantics(node).label;
    expect(label, contains(s.accountSignedIn));
    expect(countOccurrences(label, s.accountSignedIn), 1, reason: '狀態只能唸一次');
    expect(label, isNot(contains('訪客')));

    expect(
      service.calls.where((c) => c == 'restore').length,
      1,
      reason: '`restore()` 只能跑一次：設定頁每次重建（例如調語速）都重讀儲存的話，'
          '帳號列會閃一下「訪客」',
    );

    handle.dispose();
  });
}
