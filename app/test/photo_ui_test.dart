import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/photos/photo_controller.dart';
import 'package:pathguide/photos/photo_ui.dart';
import 'package:pathguide/account/account_ui.dart';
import 'package:pathguide/ui/app_theme.dart';

import 'support/fake_accounts.dart';
import 'photo_controller_test.dart'
    show FakePhotos, MemoryPhotos, FakeNetwork;

void main() {
  testWidgets(
    'photo page explains unavailable service without blocking guest use',
    (tester) async {
      final fixture = AccountFixture();
      final backend = FakePhotos()..configured = false;
      final photos = PhotoController(
        account: fixture.controller,
        backend: backend,
        queue: MemoryPhotos(),
        network: FakeNetwork(),
        project: 'demo',
      );
      await tester.pumpWidget(
        PhotoScope(
          controller: photos,
          child: AccountScope(
            controller: fixture.controller,
            child: MaterialApp(theme: buildAppTheme(), home: const PhotoPage()),
          ),
        ),
      );
      expect(find.textContaining('照片雲端服務尚未配置'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      photos.dispose();
      fixture.controller.dispose();
      await fixture.auth.stream.close();
    },
  );
  testWidgets(
    'large text consent can be cancelled and automatic capture remains off',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = AccountFixture();
      await fixture.controller.signIn(acceptTerms: true);
      final photos = PhotoController(
        account: fixture.controller,
        backend: FakePhotos(),
        queue: MemoryPhotos(),
        network: FakeNetwork(),
        project: 'demo',
      );
      await tester.pump();
      await tester.pumpWidget(
        PhotoScope(
          controller: photos,
          child: AccountScope(
            controller: fixture.controller,
            child: MaterialApp(
              theme: buildAppTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const PhotoPage(),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('閱讀用途並開啟收集'));
      await tester.tap(find.text('閱讀用途並開啟收集'));
      await tester.pumpAndSettle();
      expect(find.text('同意個人模型照片用途'), findsOneWidget);
      await tester.ensureVisible(find.text('不同意'));
      await tester.tap(find.text('不同意'));
      await tester.pumpAndSettle();
      expect(photos.enabled, false);
      expect(photos.autoCapture, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      photos.dispose();
      fixture.controller.dispose();
      await fixture.auth.stream.close();
    },
  );
}
