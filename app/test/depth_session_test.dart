import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/depth/depth_session.dart';

import 'support/fake_depth.dart';

void main() {
  test(
    'non iOS reports unsupported without opening a platform channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final source = PlatformDepthSource();
        final subscription = source.frames.listen(
          (_) => fail('unexpected frame'),
        );
        expect(await source.start('unsupported-device'), 'unsupported');
        await source.stop();
        await subscription.cancel();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  late FakeDepthSource source;
  late DepthSession session;
  setUp(() {
    source = FakeDepthSource();
    session = DepthSession(source);
  });
  tearDown(() async {
    await session.stop();
    session.dispose();
    await source.events.close();
  });

  test(
    'three fresh distinct times stabilize range; duplicate withdraws it',
    () async {
      await session.start();
      source.sample(1);
      source.sample(1.15);
      expect(session.rangeM, isNull);
      source.sample(1.3);
      expect(session.rangeM, 2);
      source.sample(1.3);
      expect(session.rangeM, isNull);
    },
  );
  test('unrelated session cannot overwrite a current result', () async {
    await session.start();
    source.stable();
    source.sample(1.5, extra: {'session': 'old', 'rangeM': 3});
    expect(session.rangeM, 2);
  });
  for (final state in ['moving', 'tracking', 'unavailable', 'unreliable']) {
    test(
      '$state immediately withdraws range; recovery needs fresh stability',
      () async {
        await session.start();
        source.stable();
        source.sample(1.5, state: state);
        expect(session.rangeM, isNull);
        source.sample(1.7);
        expect(session.rangeM, isNull);
        source.sample(1.85);
        source.sample(2);
        expect(session.rangeM, 2);
      },
    );
  }
  test('expired and future ages withdraw current reading', () async {
    await session.start();
    source.stable();
    source.sample(2, extra: {'ageMs': 351});
    expect(session.rangeM, isNull);
    source.stable(time: 3);
    expect(session.rangeM, 2);
    source.sample(4, extra: {'ageMs': -1});
    expect(session.rangeM, isNull);
  });
  test('invalid geometry and insufficient coverage never stabilize', () async {
    await session.start();
    var time = 1.0;
    for (final extra in <Map<Object?, Object?>>[
      {'rangeM': double.nan},
      {'rangeM': 4.1},
      {'planeZM': 3},
      {'accepted': 13},
      {'accepted': 26},
      {'total': 0},
      {'spreadM': .3},
    ]) {
      source.stable(time: time);
      expect(session.rangeM, 2);
      source.sample(time + .5, extra: extra);
      expect(session.rangeM, isNull);
      time += 2;
    }
  });
  test(
    'a different surface cannot blend an older surface into range',
    () async {
      await session.start();
      source.stable();
      source.sample(1.5, range: 3);
      expect(session.rangeM, isNull);
      source.sample(1.65, range: 3);
      source.sample(1.8, range: 3);
      expect(session.rangeM, 3);
    },
  );
  test('sparse samples cannot meet temporal stability', () async {
    await session.start();
    source.sample(1);
    source.sample(2);
    source.sample(3);
    expect(session.rangeM, isNull);
  });
  test('silence expires range without waiting for another frame', () async {
    await session.start();
    source.stable();
    expect(session.rangeM, 2);
    await Future<void>.delayed(const Duration(milliseconds: 850));
    expect(session.rangeM, isNull);
    expect(session.status, 'stale');
  });
  test('interruption stops and ignores all later frames', () async {
    await session.start();
    source.stable();
    source.sample(2, state: 'interrupted');
    expect(session.running, isFalse);
    source.stable(time: 3);
    expect(session.rangeM, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(source.stops, greaterThan(1));
  });
  test(
    'leaving while native permission pending reaches stop immediately',
    () async {
      source.pendingStart = Completer<String>();
      await session.start();
      final before = source.stops;
      await session.stop();
      expect(source.stops, before + 1);
      source.pendingStart!.complete('running');
      await Future<void>.delayed(Duration.zero);
      expect(session.running, isFalse);
      expect(session.rangeM, isNull);
    },
  );
  test(
    'late start from old session cannot overwrite new unsupported state',
    () async {
      source.pendingStart = Completer<String>();
      final old = source.pendingStart!;
      await session.start();
      await session.stop();
      source.pendingStart = null;
      source.result = 'unsupported';
      await session.start();
      await Future<void>.delayed(Duration.zero);
      expect(session.status, 'unsupported');
      old.complete('running');
      await Future<void>.delayed(Duration.zero);
      expect(session.status, 'unsupported');
    },
  );
  test('stream error withdraws reading and stops camera', () async {
    await session.start();
    source.stable();
    source.events.addError(StateError('lost'));
    expect(session.running, isFalse);
    expect(session.status, 'failed');
    expect(session.rangeM, isNull);
  });
}
