import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:pathguide/ui/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/main.dart';

import 'support/fake_accounts.dart';

void main() {
  const previewDir = String.fromEnvironment('PATHGUIDE_ACCOUNT_PREVIEWS');
  Future<void> capture(WidgetTester tester, String name) async {
    if (previewDir.isEmpty) return;
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('account-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(previewDir).create(recursive: true);
      await File('$previewDir/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(accountTick);
    await tester.pump();
  }

  Future<AccountFixture> open(
    WidgetTester tester, {
    bool configured = true,
  }) async {
    final fixture = AccountFixture();
    fixture.auth.configured = configured;
    ThemeData? theme;
    if (previewDir.isNotEmpty && Platform.isMacOS) {
      if (tester.view.physicalSize.width > 500) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
      }
      await tester.runAsync(() async {
        final loader = FontLoader('PathGuidePreview')
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
      theme = buildAppTheme().copyWith(
        textTheme: buildAppTheme().textTheme.apply(
          fontFamily: 'PathGuidePreview',
        ),
        primaryTextTheme: buildAppTheme().primaryTextTheme.apply(
          fontFamily: 'PathGuidePreview',
        ),
      );
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('account-preview'),
        child: PathGuideApp(account: fixture.controller, theme: theme),
      ),
    );
    await settle(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('manage-account')),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('manage-account')));
    await settle(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
    return fixture;
  }

  testWidgets('unconfigured account explains status and keeps visitor usable', (
    tester,
  ) async {
    await open(tester, configured: false);
    expect(find.textContaining('尚未配置'), findsOneWidget);
    await capture(tester, 'account-unconfigured');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('google-sign-in')))
          .onPressed,
      isNull,
    );
    expect(find.textContaining('Apple'), findsNothing);
    expect(find.textContaining('驗證碼'), findsNothing);
    await tester.tap(find.byTooltip('返回原任務'));
    await settle(tester);
    expect(find.text('即時辨識'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Google login can skip optional contact and returns to original task',
    (tester) async {
      final f = await open(tester);
      await tester.tap(find.byKey(const ValueKey('account-terms')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('google-sign-in')));
      await settle(tester);
      expect(f.controller.profileReady, isTrue);
      await capture(tester, 'account-ready');
      await tester.ensureVisible(find.byKey(const ValueKey('skip-contact')));
      await tester.tap(find.byKey(const ValueKey('skip-contact')));
      await settle(tester);
      expect(find.text('即時辨識'), findsOneWidget);
      expect(f.controller.contact, isNull);
    },
  );
  testWidgets(
    'contact editor saves, calls only on user action, and hides old UID',
    (tester) async {
      final f = await open(tester);
      await f.controller.signIn(acceptTerms: true);
      await settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('edit-contact')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('edit-contact')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('contact-name')), '媽媽');
      await tester.enterText(
        find.byKey(const ValueKey('contact-phone')),
        '91234567',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('save-contact')),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('save-contact')));
      await settle(tester);
      expect(f.controller.contact?.phone, '+85291234567');
      await capture(tester, 'account-contact');
      expect(f.dialer.calls, isEmpty);
      await tester.tap(find.byTooltip('返回原任務'));
      await settle(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('call-emergency-contact')),
      );
      await tester.tap(find.byKey(const ValueKey('call-emergency-contact')));
      await settle(tester);
      expect(f.dialer.calls, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('manage-account')));
      await settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('edit-contact')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('edit-contact')));
      await settle(tester);
      f.repository.profiles.add('bob');
      f.auth.switchTo(bob);
      await settle(tester);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('帳號已變更'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'large text account and contact form remain scrollable and labeled',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final semantics = tester.ensureSemantics();
      final f = await open(tester);
      await f.controller.signIn(acceptTerms: true);
      await settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('edit-contact')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('edit-contact')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('contact-name')), '家人');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('contact-phone')),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('contact-phone')),
        '92345678',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('save-contact')),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('save-contact'))).height,
        greaterThanOrEqualTo(56),
      );
      await capture(tester, 'contact-large-text');
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}
