// Android 系統返回鍵／返回手勢。
//
// 2026-11-22 真機（Redmi／Android 16）：AppShell 以狀態切換任務頁、沒有接住系統返回，
// 於是在任何任務頁按返回都直接回到手機桌面。TalkBack 使用者常用返回手勢，
// 這等於「一按就離開 App」。系統返回必須與頁面左上角的返回箭頭做同一件事；
// 只有在首頁才交還系統（離開 App）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/main.dart';
import 'package:pathguide/settings/app_settings.dart';

const _homeHint = '用相機辨識支援的物件，聽取簡短結果。';

/// 模擬一次系統返回；回傳 App 是否自行處理（false = 交還系統、離開 App）。
Future<bool> _systemBack(WidgetTester t) async {
  final handled = await t.binding.handlePopRoute();
  await t.pumpAndSettle();
  return handled;
}

Future<void> _openApp(WidgetTester t) async {
  await t.pumpWidget(PathGuideApp(settings: AppSettings.memory()));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('home hands system back to the platform (leaves the app)', (
    t,
  ) async {
    await _openApp(t);
    expect(await _systemBack(t), isFalse);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('settings and developer pages step back one level at a time', (
    t,
  ) async {
    await _openApp(t);
    await t.tap(find.text('設定與使用教學'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('開發測試'));
    await t.tap(find.text('開發測試'));
    await t.pumpAndSettle();
    expect(find.text('錄路相機試驗'), findsOneWidget);

    expect(await _systemBack(t), isTrue);
    expect(find.text('錄路相機試驗'), findsNothing);
    expect(find.text('開發測試'), findsOneWidget);

    expect(await _systemBack(t), isTrue);
    expect(find.text(_homeHint), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('read text page returns to home on system back', (t) async {
    await _openApp(t);
    await t.tap(find.text('閱讀文字'));
    await t.pumpAndSettle();
    await t.tap(find.text('略過說明'));
    await t.pumpAndSettle();
    expect(find.text('拍攝或選取一張照片。'), findsOneWidget);

    expect(await _systemBack(t), isTrue);
    expect(find.text(_homeHint), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('route navigation hub returns to home on system back', (t) async {
    await _openApp(t);
    await t.tap(find.text('路線導航'));
    await t.pumpAndSettle();
    await t.tap(find.text('略過說明'));
    await t.pumpAndSettle();
    expect(find.text('搜尋目的地'), findsOneWidget);

    expect(await _systemBack(t), isTrue);
    expect(find.text(_homeHint), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
