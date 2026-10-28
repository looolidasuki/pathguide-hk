import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/menu/menu_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hk.pathguide/menu');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });
  Future<void> event(String method, Map<String, Object> args) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) => done.complete(),
    );
    await done.future;
  }

  test('bridge forwards ready/finishing, awaits delayed final and ignores stale request events', () async {
    final result = Completer<Map<String, Object>>();
    String id = '';
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listenMenuQuery') {
        id = (call.arguments as Map)['requestId'] as String;
        return result.future;
      }
      return null;
    });
    final reader = NativeMenuReader();
    final phases = <MenuSpeechPhase>[];
    final partials = <String>[];
    var completed = false;
    final job = reader
        .listen(
          allowNetwork: false,
          onPartial: partials.add,
          onPhase: phases.add,
        )
        .then((value) {
          completed = true;
          return value;
        });
    await Future<void>.delayed(Duration.zero);
    await event('speechPhase', {'requestId': id, 'phase': 'listening'});
    await event('speechPartial', {'requestId': 'old', 'text': '錯誤'});
    await event('speechPartial', {'requestId': id, 'text': '我想食'});
    await event('speechPhase', {'requestId': id, 'phase': 'finishing'});
    expect(completed, false);
    result.complete({'outcome': 'finalText', 'text': '我想食三文治'});
    expect((await job).text, '我想食三文治');
    expect(partials, ['我想食']);
    expect(phases, MenuSpeechPhase.values);
    reader.dispose();
  });
  test('speech outcomes distinguish cancellation, silence and timeout', () {
    for (final outcome in MenuSpeechOutcome.values) {
      expect(
        MenuSpeechResult.fromMap({'outcome': outcome.name}).outcome,
        outcome,
      );
    }
    expect(MenuSpeechResult.fromMap(null).outcome, MenuSpeechOutcome.cancelled);
  });
}
