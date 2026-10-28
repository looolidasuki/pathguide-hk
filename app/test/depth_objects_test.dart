import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/depth/depth_objects.dart';
import 'package:pathguide/depth/depth_session.dart';

import 'support/fake_depth.dart';

void main() {
  test('sample point change cannot inherit the old surface distance', () {
    final tracker = DepthObjects();
    Map<String, Object> at(double y) => {
      ...FakeDepthSource.object(),
      'samplePoint': [.2, y],
      'validDepth': 23,
      'depthTotal': 25,
    };
    for (var i = 0; i < 3; i++) {
      tracker.update([at(.4)], 1 + i * .15, acceptedIds: {7});
    }
    expect(tracker.snapshot.single.rangeM, 2);
    tracker.update([at(.55)], 1.5, acceptedIds: {7});
    expect(tracker.snapshot.single.rangeM, isNull);
    expect(tracker.snapshot.single.reason, 'sampling_changed');
    expect(tracker.snapshot.single.validDepth, 23);
  });
  test(
    'refusal diagnosis is retained and invalid markers cannot yield range',
    () {
      final tracker = DepthObjects();
      tracker.update(
        [
          {
            ...FakeDepthSource.object(known: false),
            'reason': 'low_depth',
            'validDepth': 8,
            'depthTotal': 25,
          },
        ],
        1,
        acceptedIds: {7},
      );
      expect(tracker.snapshot.single.reason, 'low_depth');
      expect(tracker.snapshot.single.validDepth, 8);
      for (var i = 0; i < 3; i++) {
        tracker.update(
          [
            {
              ...FakeDepthSource.object(),
              'samplePoint': [.95, .95],
            },
          ],
          2 + i * .15,
          acceptedIds: {7},
        );
      }
      expect(tracker.snapshot.single.rangeM, isNull);
    },
  );
  late DepthObjects tracker;
  setUp(() => tracker = DepthObjects());
  void update(double time, List<Map<String, Object>> objects) {
    expect(
      tracker.update(objects, time, acceptedIds: const {6, 7, 18}),
      isTrue,
    );
  }

  void stable({double time = 1, int id = 7, double range = 2}) {
    for (var i = 0; i < 3; i++) {
      update(time + i * .15, [FakeDepthSource.object(id: id, range: range)]);
    }
  }

  test('requires three consistent same-object surface observations', () {
    update(1, [FakeDepthSource.object()]);
    expect(tracker.snapshot.single.rangeM, isNull);
    final track = tracker.snapshot.single.trackId;
    update(1.15, [FakeDepthSource.object()]);
    update(1.3, [FakeDepthSource.object()]);
    expect(tracker.snapshot.single.trackId, track);
    expect(tracker.snapshot.single.rangeM, 2);
  });
  test('class change cannot inherit a range', () {
    stable();
    final old = tracker.snapshot.single.trackId;
    update(1.5, [FakeDepthSource.object(id: 6)]);
    expect(tracker.snapshot.single.trackId, isNot(old));
    expect(tracker.snapshot.single.rangeM, isNull);
  });
  test('box jump and disappearing object invalidate old association', () {
    stable();
    final old = tracker.snapshot.single.trackId;
    update(1.5, [
      FakeDepthSource.object(box: [.7, .2, .2, .5]),
    ]);
    expect(tracker.snapshot.single.rangeM, isNull);
    expect(tracker.snapshot.single.trackId, isNot(old));
    update(1.7, []);
    expect(tracker.snapshot, isEmpty);
    update(1.9, [FakeDepthSource.object()]);
    expect(tracker.snapshot.single.rangeM, isNull);
  });
  test('same-class reordered boxes preserve their own different distances', () {
    final left = FakeDepthSource.object(range: 1),
        right = FakeDepthSource.object(range: 3, box: [.7, .2, .2, .5]);
    update(1, [left, right]);
    update(1.15, [right, left]);
    update(1.3, [left, right]);
    expect(tracker.snapshot.map((e) => e.rangeM), [1, 3]);
  });
  test('ambiguous two-to-one matches cannot reuse an old range', () {
    stable();
    for (var i = 0; i < 3; i++) {
      update(1.5 + i * .15, [
        FakeDepthSource.object(),
        FakeDepthSource.object(),
      ]);
    }
    expect(tracker.snapshot.every((e) => e.rangeM == null), isTrue);
  });
  test(
    'unknown depth preserves object name but withdraws range immediately',
    () {
      stable();
      update(1.5, [FakeDepthSource.object(known: false)]);
      expect(tracker.snapshot.single.classId, 7);
      expect(tracker.snapshot.single.rangeM, isNull);
      expect(tracker.snapshot.single.reason, 'overlap');
      update(1.65, [FakeDepthSource.object()]);
      expect(tracker.snapshot.single.rangeM, isNull);
    },
  );
  test('large depth change and long gap require a new stable window', () {
    stable();
    update(1.5, [FakeDepthSource.object(range: 3)]);
    expect(tracker.snapshot.single.rangeM, isNull);
    update(1.65, [FakeDepthSource.object(range: 3)]);
    update(1.8, [FakeDepthSource.object(range: 3)]);
    expect(tracker.snapshot.single.rangeM, 3);
    update(3, [FakeDepthSource.object(range: 3)]);
    expect(tracker.snapshot.single.rangeM, isNull);
  });
  test('bad class or box rejects the whole object frame', () {
    for (final object in [
      FakeDepthSource.object(id: 0),
      FakeDepthSource.object(box: [-.1, .2, .2, .5]),
      FakeDepthSource.object(box: [.1, .2, double.nan, .5]),
      FakeDepthSource.object(box: [.9, .2, .2, .5]),
    ]) {
      stable();
      expect(tracker.update([object], 2, acceptedIds: const {7}), isFalse);
      expect(tracker.snapshot, isEmpty);
    }
  });
  test('invalid depth metadata retains only the unknown object', () {
    for (final patch in <String, Object>{
      'rangeM': double.infinity,
      'planeZM': 3,
      'accepted': 14,
      'spreadM': 1,
    }.entries) {
      tracker = DepthObjects();
      stable();
      update(1.5, [
        {...FakeDepthSource.object(), patch.key: patch.value},
      ]);
      expect(tracker.snapshot.single.rangeM, isNull);
    }
  });
  test('too many objects cannot exceed the bounded output', () {
    expect(
      tracker.update(
        List.generate(6, (_) => FakeDepthSource.object()),
        1,
        acceptedIds: const {7},
      ),
      isFalse,
    );
    expect(tracker.snapshot, isEmpty);
  });
  test(
    'viewport change resets object ranges before accepting new geometry',
    () async {
      final source = FakeDepthSource();
      final active = DepthSession(source);
      await active.start(recognizeObjects: true);
      for (var i = 0; i < 3; i++) {
        source.objectFrame(1 + i * .15, [FakeDepthSource.object()]);
      }
      expect(active.objects.single.rangeM, 2);
      source.objectFrame(
        1.5,
        [FakeDepthSource.object()],
        extra: {'viewWidth': 400},
      );
      expect(active.objects.single.rangeM, isNull);
      await active.stop();
      active.dispose();
      await source.events.close();
    },
  );
  test(
    'empty, moving and expired frames remove object results and ranges',
    () async {
      final source = FakeDepthSource();
      final active = DepthSession(source);
      await active.start(recognizeObjects: true);
      for (var i = 0; i < 3; i++) {
        source.objectFrame(1 + i * .15, [FakeDepthSource.object()]);
      }
      source.sample(1.5, state: 'moving');
      expect(active.objects, isEmpty);
      for (var i = 0; i < 3; i++) {
        source.objectFrame(2 + i * .15, [FakeDepthSource.object()]);
      }
      expect(active.objects.single.rangeM, 2);
      await Future<void>.delayed(const Duration(milliseconds: 850));
      expect(active.objects, isEmpty);
      expect(active.status, 'stale');
      await active.stop();
      active.dispose();
      await source.events.close();
    },
  );
  test('centre samples cannot become labelled object distances', () async {
    final source = FakeDepthSource();
    final session = DepthSession(source);
    await session.start(recognizeObjects: true);
    source.stable();
    expect(session.rangeM, isNull);
    expect(session.objects, isEmpty);
    await session.stop();
    session.dispose();
    await source.events.close();
  });
}
