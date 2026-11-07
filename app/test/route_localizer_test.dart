import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/cross_floor_contract.dart';
import 'package:pathguide/route_memory/route_localizer.dart';

void main() {
  void accept(
    RouteLocalizer l,
    RouteLocalizationTicket t,
    List<RouteViewDistance> d, {
    String feature = 'vision-featureprint-v1',
    String preprocess = 'upright-jpeg-v1',
    List<String> ocr = const [],
  }) => l.accept(t, d, feature: feature, preprocess: preprocess, ocr: ocr);

  test('unrecorded floor sign is conflicting evidence, not ignored', () {
    const floor = FloorRef('b', 'three', '3F');
    final l = RouteLocalizer(
      routeId: 'route',
      routeVersion: 1,
      landmarks: const [
        RouteLandmarkIdentity(
          'exit',
          floor,
          ['front'],
          exitForConnectors: ['lift'],
        ),
      ],
    );
    l.expectFloor(floor, exitNodeId: 'exit', connectorId: 'lift');
    final t = l.beginObservation(frameAge: Duration.zero);
    accept(l, t, const [RouteViewDistance('exit', 'front', 0)], ocr: ['2F']);
    l.confirmFloor(floor);
    l.confirmExit(directionConfirmed: true);
    expect(l.actualFloor, isNull);
  });
  test('room cannot confirm a cross-floor exit', () {
    const floor = FloorRef('b', 'three', '3F');
    final l = RouteLocalizer(
      routeId: 'route',
      routeVersion: 1,
      landmarks: const [
        RouteLandmarkIdentity(
          'exit',
          floor,
          ['front'],
          exitForConnectors: ['lift'],
        ),
        RouteLandmarkIdentity('room', floor, ['front']),
      ],
    );
    l.expectFloor(floor, exitNodeId: 'exit', connectorId: 'lift');
    final t = l.beginObservation(frameAge: Duration.zero);
    accept(l, t, const [
      RouteViewDistance('exit', 'front', 9),
      RouteViewDistance('room', 'front', 0),
    ]);
    l.confirmFloor(floor);
    l.confirmExit(directionConfirmed: true);
    expect(l.actualFloor, isNull);
    expect(
      () => l.expectFloor(floor, exitNodeId: 'room', connectorId: 'lift'),
      throwsArgumentError,
    );
    expect(
      () => l.expectFloor(floor, exitNodeId: 'exit', connectorId: 'stairs'),
      throwsArgumentError,
    );
  });
  test('multiple views of a node form one candidate; floor and direction require confirmation', () {
    const floor = FloorRef('building', 'three', '3F');
    final localizer = RouteLocalizer(
      routeId: 'route',
      routeVersion: 1,
      landmarks: const [
        RouteLandmarkIdentity(
          'exit',
          floor,
          ['front', 'side'],
          exitForConnectors: ['lift'],
        ),
        RouteLandmarkIdentity('room', floor, ['front']),
      ],
    );
    localizer.expectFloor(floor, exitNodeId: 'exit', connectorId: 'lift');
    final ticket = localizer.beginObservation(frameAge: Duration.zero);
    accept(localizer, ticket, const [
      RouteViewDistance('exit', 'front', 1),
      RouteViewDistance('exit', 'side', 1.2),
      RouteViewDistance('room', 'front', 8),
    ]);
    expect(localizer.result, RouteMatchState.candidate);
    expect(localizer.candidateFloor, floor);
    expect(localizer.actualFloor, isNull);
    expect(localizer.confirmExit(directionConfirmed: true), isFalse);
    expect(localizer.confirmFloor(floor), isTrue);
    expect(localizer.actualFloor, isNull);
    expect(localizer.confirmExit(directionConfirmed: true), isTrue);
    expect(localizer.actualFloor, floor);
    expect(localizer.actualNodeId, 'exit');
    expect(
      () =>
          localizer.expectFloor(floor, exitNodeId: 'room', connectorId: 'lift'),
      throwsArgumentError,
    );
    expect(localizer.actualFloor, isNull);
  });

  for (final scenario in [
    'similar',
    'wrongFloor',
    'stale',
    'cancel',
    'oldSequence',
    'revision',
    'direction',
    'missing',
    'preprocess',
    'ocr',
    'nan',
    'age',
    'oversizedOCR',
  ]) {
    test('$scenario cannot establish actual floor', () {
      var now = Duration.zero;
      const three = FloorRef('building', 'three', '3F'),
          two = FloorRef('building', 'two', '2F');
      final l = RouteLocalizer(
        routeId: 'route',
        routeVersion: 1,
        elapsed: () => now,
        landmarks: const [
          RouteLandmarkIdentity(
            'three-exit',
            three,
            ['front'],
            exitForConnectors: ['lift'],
          ),
          RouteLandmarkIdentity(
            'two-exit',
            two,
            ['front'],
            exitForConnectors: ['lift'],
          ),
        ],
      );
      l.expectFloor(three, exitNodeId: 'three-exit', connectorId: 'lift');
      final old = l.beginObservation(
        frameAge: scenario == 'age'
            ? const Duration(seconds: 6)
            : Duration.zero,
      );
      var ticket = old;
      if (scenario == 'cancel') l.pause();
      if (scenario == 'oldSequence') {
        ticket = l.beginObservation(frameAge: Duration.zero);
      }
      if (scenario == 'stale') now = const Duration(seconds: 6);
      final d = scenario == 'wrongFloor'
          ? const [
              RouteViewDistance('three-exit', 'front', 9),
              RouteViewDistance('two-exit', 'front', 1),
            ]
          : [
              const RouteViewDistance('three-exit', 'front', 1),
              RouteViewDistance(
                'two-exit',
                'front',
                scenario == 'similar'
                    ? 1.1
                    : scenario == 'nan'
                    ? double.nan
                    : 9,
              ),
            ];
      accept(
        l,
        scenario == 'oldSequence' ? old : ticket,
        scenario == 'missing' ? d.take(1).toList() : d,
        preprocess: scenario == 'preprocess' ? 'other' : 'upright-jpeg-v1',
        ocr: scenario == 'ocr'
            ? ['2F']
            : scenario == 'oversizedOCR'
            ? ['A' * 121]
            : const [],
        feature: scenario == 'revision'
            ? 'other'
            : RouteLocalizer.featureRevision,
      );
      if (scenario == 'direction') {
        l.confirmFloor(three);
        l.confirmExit(directionConfirmed: false);
      } else {
        l.confirmFloor(three);
        l.confirmExit(directionConfirmed: true);
      }
      expect(l.actualFloor, isNull);
    });
  }
  test(
    'explicit intermediate-floor recovery and repeated response fencing',
    () {
      const floor = FloorRef('b', 'three', '3F');
      final l = RouteLocalizer(
        routeId: 'route',
        routeVersion: 2,
        landmarks: const [
          RouteLandmarkIdentity(
            'exit',
            floor,
            ['front'],
            exitForConnectors: ['lift'],
          ),
        ],
      );
      final t = l.beginObservation(frameAge: Duration.zero);
      accept(l, t, const [RouteViewDistance('exit', 'front', 0)]);
      expect(l.expectedFloor, isNull);
      expect(l.confirmFloor(floor), isTrue);
      expect(l.confirmExit(directionConfirmed: true), isTrue);
      accept(l, t, const [RouteViewDistance('exit', 'front', 99)]);
      expect(l.actualFloor, floor);
      l.setForeground(false);
      l.setForeground(true);
      expect(l.actualFloor, isNull);
    },
  );
}
