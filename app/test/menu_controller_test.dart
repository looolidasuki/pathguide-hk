import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/menu/menu_controller.dart';
import 'package:pathguide/menu/menu_document.dart';
import 'package:pathguide/menu/menu_reader.dart';

import 'support/fake_menu.dart';

void main() {
  test(
    'voice searches recognized menu and reads only matching known price',
    () async {
      final reader = FakeMenuReader()..document = sampleMenu();
      final c = MenuReadingController(reader);
      expect(c.canSearch, false);
      await c.read(MenuImageSource.camera);
      expect(c.canSearch, true);
      expect(await c.listen(), '牛腩飯');
      expect(c.results.length, 1);
      expect(c.searchReadout, contains('\$48'));
      expect(c.searchReadout, isNot(contains('\$45')));
      c.dispose();
    },
  );
  test(
    'not found means absent from this OCR result, not absent from restaurant',
    () async {
      final c = MenuReadingController(
        FakeMenuReader()
          ..document = sampleMenu()
          ..phrase = '我想食鮑魚飯',
      );
      await c.read(MenuImageSource.library);
      await c.listen();
      expect(c.results, isEmpty);
      expect(c.searchReadout, contains('可能未拍齊'));
      c.dispose();
    },
  );
  test('cancelled OCR cannot resurrect an old result', () async {
    final wait = Completer<MenuDocument?>();
    final r = FakeMenuReader()..readFuture = wait.future;
    final c = MenuReadingController(r);
    final job = c.read(MenuImageSource.camera);
    await c.cancel();
    wait.complete(sampleMenu());
    await job;
    expect(c.document, isNull);
    expect(c.state, MenuState.ready);
    c.dispose();
  });
  test('cancelled voice cannot replace a newer typed query', () async {
    final wait = Completer<String?>();
    final r = FakeMenuReader()
      ..document = sampleMenu()
      ..speechFuture = wait.future;
    final c = MenuReadingController(r);
    await c.read(MenuImageSource.library);
    final job = c.listen();
    await c.cancel();
    c.search('叉燒飯');
    wait.complete('我想食牛腩飯');
    expect(await job, isNull);
    expect(c.query, '叉燒飯');
    c.dispose();
  });
  test('offline speech unavailable requires caller approval, never silently enables network', () async {
    final r = FakeMenuReader()
      ..document = sampleMenu()
      ..speechError = const MenuFailure(
        '需詢問',
        code: 'offline_speech_unavailable',
      );
    final c = MenuReadingController(r);
    await c.read(MenuImageSource.library);
    await expectLater(c.listen(), throwsA(isA<MenuFailure>()));
    expect(c.state, MenuState.result);
    expect(r.listens, 1);
    expect(await c.listen(allowNetwork: true), '牛腩飯');
    c.dispose();
  });
  test('empty OCR and empty speech retain retryable states', () async {
    final r = FakeMenuReader()
      ..document = const MenuDocument(
        entries: [],
        original: '',
        pages: 1,
        truncated: false,
      )
      ..phrase = '';
    final c = MenuReadingController(r);
    await c.read(MenuImageSource.camera);
    expect(c.message, contains('重拍'));
    expect(await c.listen(), isNull);
    expect(c.message, contains('重試'));
    c.dispose();
  });
}
