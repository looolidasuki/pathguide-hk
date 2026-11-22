import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/encrypted_route_store.dart';
import 'package:pathguide/route_memory/route_learning_review_page.dart';
import 'package:pathguide/route_memory/route_learning_store.dart';

import 'captured_route_store_test.dart'
    show TestVault, capturedDocument, capturedMedia;

void main() {
  for (final english in [false, true]) {
    testWidgets('review at double text size, English=$english', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('review-page-');
        addTearDown(() => root.delete(recursive: true));
        final routes = await EncryptedRouteStore.open(
          root: root,
          vault: TestVault(),
        );
        final learning = await RouteLearningStore.open(
          root: root,
          vault: TestVault(),
        );
        final doc = capturedDocument();
        final snapshot = await routes.save(
          doc,
          token: routes.capture(doc.id),
          expectedRevision: 0,
          activate: true,
          media: capturedMedia(),
        );
        final id = await learning.add(
          routeId: doc.id,
          routeVersion: snapshot.version,
          tripId: 'trip',
          session: 'session',
          sequence: 1,
          requestedNode: 'g',
          predictedNode: 'end',
          result: 'candidate',
          jpeg: File('test/fixtures/route_camera/keyframe-8x4.jpg')
              .readAsBytesSync(),
          feature: Uint8List.fromList([1, 2, 3]),
          featureProfile: doc.featureRevision,
          preprocessProfile: doc.preprocessRevision,
        );
        return (routes, learning, id, doc.id);
      }))!;
      final (routes, learning, id, routeId) = fixture;
      String label(String zh, String en) => english ? en : zh;
      final pending = find.textContaining(label('待覆核', 'Pending review'));

      await tester.pumpWidget(
        MaterialApp(
          home: RouteLearningReviewPage(
            openStore: () async => learning,
            routes: routes,
            routeId: routeId,
            english: english,
          ),
        ),
      );

      Future<void> loadUntil(Finder finder) async {
        for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(finder, findsOneWidget);
      }

      Future<void> show(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
      }

      await loadUntil(pending);
      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(label('候選路標相片', 'Candidate landmark photo')),
        findsOneWidget,
      );
      semantics.dispose();
      expect(
        find.textContaining(label('原比對路標', 'Matched landmark')),
        findsOneWidget,
      );

      final decision = find.byType(DropdownButtonFormField<LearningReview>);
      await show(decision);
      await tester.tap(decision);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label('待補資料', 'Needs information')).last);
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      await show(fields.at(0));
      await tester.enterText(fields.at(0), 'Field reviewer');
      await show(fields.at(1));
      await tester.enterText(fields.at(1), 'Direction needs another visit');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final save = find.widgetWithText(
        FilledButton,
        label('保存覆核', 'Save review'),
      );
      await show(save);
      await tester.tap(save);
      await tester.pump();
      await loadUntil(
        find.textContaining(
          label('覆核狀態 · 待補資料', 'Review status · Needs information'),
        ),
      );
      final record = (await tester.runAsync(() => learning.read(id)))!;
      expect(record['state'], 'needsInformation');
      expect(record['predictedNode'], 'end');
      expect(record['requestedNode'], 'g');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
