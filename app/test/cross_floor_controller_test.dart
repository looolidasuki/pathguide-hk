import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/cross_floor_contract.dart';
import 'package:pathguide/route_memory/cross_floor_mock_fixtures.dart';

void main() {
  late CrossFloorController c;
  late MockJourneyClock clock;
  void see(PerceptionState state) => c.perceive(
    PerceptionFrame(
      c.observe(EvidenceChannel.perception)!,
      state,
      objectLabel: state == PerceptionState.urgent ? 'synthetic box' : null,
    ),
  );
  void start() {
    c.startAt('g-entry', floorConfirmed: true, directionConfirmed: true);
    see(PerceptionState.noAlert);
  }

  void enter() {
    start();
    c.match(
      c.observe(EvidenceChannel.location)!,
      FloorMatch.matched,
      nodeId: 'g-connector',
      floor: mockGround,
    );
    expect(c.phase, FloorPhase.approachingConnector);
    c.enterConnector();
    expect(c.actualFloor, isNull);
    expect(c.expectedFloor, mockThird);
  }

  void propose() =>
      c.proposeExit(c.observe(EvidenceChannel.location)!, mockThird);
  void exit({bool ambiguous = false}) => c.confirmExit(
    c.observe(EvidenceChannel.location)!,
    nodeId: '3-exit',
    floor: mockThird,
    directionConfirmed: true,
    ambiguous: ambiguous,
  );
  setUp(() {
    clock = MockJourneyClock();
    c = CrossFloorController(
      route: crossFloorFixture(),
      elapsed: clock.elapsed,
    );
  });
  tearDown(() => c.dispose());

  test(
    'G to 3F requires floor then fresh exit/direction and explicit arrival',
    () {
      enter();
      propose();
      expect(c.actualFloor, isNull);
      expect(c.canConfirmFloor, isTrue);
      c.confirmFloor();
      expect(c.phase, FloorPhase.relocalizingExit);
      expect(c.actualFloor, isNull);
      exit();
      see(PerceptionState.noAlert);
      expect(c.actualFloor, mockThird);
      expect(c.guidance!.node!.id, '3-room');
      c.match(
        c.observe(EvidenceChannel.location)!,
        FloorMatch.matched,
        nodeId: '3-room',
        floor: mockThird,
      );
      expect(c.phase, FloorPhase.arrival);
      expect(c.expectedFloor, isNull);
      c.confirmArrival();
      expect(c.phase, FloorPhase.finished);
      expect(c.expectedFloor, isNull);
    },
  );
  test('start requires independent explicit floor and direction', () {
    c.startAt('g-entry', floorConfirmed: true, directionConfirmed: false);
    expect(c.phase, FloorPhase.idle);
    c.startAt('g-entry', floorConfirmed: false, directionConfirmed: true);
    expect(c.phase, FloorPhase.idle);
  });
  test('wrong floor cannot inherit expected floor', () {
    enter();
    c.proposeExit(c.observe(EvidenceChannel.location)!, mockSecond);
    c.confirmFloor();
    expect(c.canConfirmFloor, isFalse);
    expect(c.phase, FloorPhase.awaitingFloorConfirmation);
    expect(c.actualFloor, isNull);
    expect(c.issue, 'wrongFloor');
    see(PerceptionState.noAlert);
    expect(c.guidance!.reason, 'wrongFloor');
    expect(c.guidance!.node, isNull);
    propose();
    c.confirmFloor();
    exit();
    expect(c.actualFloor, mockThird);
  });
  test(
    'similar exits never grant floor and can recover at 3F without G reset',
    () {
      enter();
      c.proposeExit(
        c.observe(EvidenceChannel.location)!,
        mockThird,
        ambiguous: true,
      );
      c.confirmFloor();
      expect(c.canConfirmFloor, isFalse);
      propose();
      c.confirmFloor();
      exit(ambiguous: true);
      expect(c.phase, FloorPhase.unknown);
      c.startAt('3-exit', floorConfirmed: true, directionConfirmed: true);
      see(PerceptionState.noAlert);
      expect(c.actualFloor, mockThird);
      expect(c.nextNode!.id, '3-room');
    },
  );
  test('floor proposal expires; fresh landmark alone does not revive it', () {
    enter();
    propose();
    c.confirmFloor();
    clock.advance(const Duration(seconds: 3));
    exit();
    expect(c.phase, FloorPhase.unknown);
    expect(c.actualFloor, isNull);
  });
  test('wrong direction withdraws existing route guidance', () {
    start();
    c.match(c.observe(EvidenceChannel.location)!, FloorMatch.wrongDirection);
    expect(c.phase, FloorPhase.unknown);
    expect(c.guidance!.node, isNull);
  });
  test('urgent preempts; route advances; clear recomputes current target', () {
    start();
    final previous = c.guidance!.id;
    see(PerceptionState.urgent);
    expect(c.guidance!.priority, 3);
    expect(c.guidance!.node, isNull);
    c.match(
      c.observe(EvidenceChannel.location)!,
      FloorMatch.matched,
      nodeId: 'g-connector',
      floor: mockGround,
    );
    expect(c.guidance!.kind, GuidanceKind.critical);
    see(PerceptionState.noAlert);
    expect(c.guidance!.kind, GuidanceKind.floorConfirmation);
    expect(c.guidance!.id, isNot(previous));
    expect(c.guidance!.node, isNull);
  });
  test(
    'expired urgent frame becomes sensing failure, never resumes old cue',
    () {
      start();
      see(PerceptionState.urgent);
      clock.advance(const Duration(milliseconds: 501));
      c.refresh();
      expect(c.guidance!.reason, 'perceptionUnavailable');
      expect(c.guidance!.kind, GuidanceKind.critical);
      expect(c.guidance!.node, isNull);
    },
  );
  test('fresh sensing does not revive an expired location', () {
    start();
    clock.advance(const Duration(seconds: 3));
    see(PerceptionState.noAlert);
    expect(c.guidance!.reason, 'locationExpired');
    expect(c.guidance!.node, isNull);
  });
  test('no depth has no metres; inconsistent metric frame rejected', () {
    start();
    c.perceive(
      PerceptionFrame(
        c.observe(EvidenceChannel.perception)!,
        PerceptionState.object,
        objectLabel: 'box',
      ),
    );
    expect(c.currentPerception!.distanceMeters, isNull);
    c.perceive(
      PerceptionFrame(
        c.observe(EvidenceChannel.perception)!,
        PerceptionState.urgent,
        distanceMeters: 1,
        depthValid: false,
      ),
    );
    expect(c.guidance!.reason, 'perceptionUnavailable');
  });
  test(
    'location and perception order independently; same-channel old ignored',
    () {
      start();
      final location = c.observe(EvidenceChannel.location)!;
      final old = c.observe(EvidenceChannel.perception)!;
      see(PerceptionState.urgent);
      c.perceive(PerceptionFrame(old, PerceptionState.noAlert));
      expect(c.guidance!.kind, GuidanceKind.critical);
      c.match(
        location,
        FloorMatch.matched,
        nodeId: 'g-connector',
        floor: mockGround,
      );
      expect(c.phase, FloorPhase.approachingConnector);
    },
  );
  for (final operation in ['pause', 'background', 'delete']) {
    test('$operation invalidates both channels and never auto resumes', () {
      start();
      final location = c.observe(EvidenceChannel.location)!;
      final perception = c.observe(EvidenceChannel.perception)!;
      if (operation == 'delete') {
        c.deleteRoute();
      } else if (operation == 'background') {
        c.setForeground(false);
      } else {
        c.pause();
      }
      c.setForeground(true);
      c.match(
        location,
        FloorMatch.matched,
        nodeId: 'g-connector',
        floor: mockGround,
      );
      c.perceive(PerceptionFrame(perception, PerceptionState.urgent));
      expect(
        c.phase,
        operation == 'delete' ? FloorPhase.deleted : FloorPhase.paused,
      );
      expect(c.guidance!.node, isNull);
      expect(c.currentPerception, isNull);
    });
  }
  test('stairs landing is never auto converted into floor', () {
    c.dispose();
    c = CrossFloorController(
      route: crossFloorFixture(mode: ConnectorMode.stairs),
      elapsed: clock.elapsed,
    );
    enter();
    c.proposeExit(c.observe(EvidenceChannel.location)!, null);
    c.confirmFloor();
    expect(c.actualFloor, isNull);
    expect(c.phase, FloorPhase.awaitingFloorConfirmation);
  });
  test('floor identity is building scoped, never parsed from labels', () {
    expect(const FloorRef('other', 'floor-3', '3F'), isNot(mockThird));
    expect(const FloorRef('sample-building', 'floor-3', '三樓'), mockThird);
    expect(
      const FloorRef('sample-building', 'floor-m', 'M'),
      isNot(mockGround),
    );
  });
  test('cross-journey callbacks cannot change current guidance', () {
    start();
    final other = CrossFloorController(
      route: crossFloorFixture(),
      elapsed: clock.elapsed,
    );
    addTearDown(other.dispose);
    other.startAt('g-entry', floorConfirmed: true, directionConfirmed: true);
    c.perceive(
      PerceptionFrame(
        other.observe(EvidenceChannel.perception)!,
        PerceptionState.urgent,
      ),
    );
    expect(c.guidance!.kind, GuidanceKind.navigation);
    c.match(
      other.observe(EvidenceChannel.location)!,
      FloorMatch.matched,
      nodeId: 'g-connector',
      floor: mockGround,
    );
    expect(c.phase, FloorPhase.walkingOnFloor);
  });
  test(
    'route version mismatch and future monotonic capture withdraw guidance',
    () {
      start();
      final t = c.observe(EvidenceChannel.location)!;
      c.match(
        FloorObservation(
          journeyId: t.journeyId,
          generation: t.generation,
          sequence: t.sequence,
          routeId: t.routeId,
          routeVersion: t.routeVersion + 1,
          clockEpoch: t.clockEpoch,
          capturedAt: t.capturedAt,
          channel: EvidenceChannel.location,
        ),
        FloorMatch.matched,
        nodeId: 'g-connector',
        floor: mockGround,
      );
      expect(c.phase, FloorPhase.unknown);
      c.startAt('3-exit', floorConfirmed: true, directionConfirmed: true);
      final future = c.observe(EvidenceChannel.location)!;
      clock.now = const Duration(seconds: -1);
      c.match(future, FloorMatch.matched, nodeId: '3-room', floor: mockThird);
      expect(c.phase, FloorPhase.unknown);
      expect(c.guidance!.node, isNull);
    },
  );
  test('route rejects silent floor-crossing walk and broken direction', () {
    expect(
      () => FloorRoute(
        id: 'bad',
        version: 1,
        nodes: const [
          FloorNode('a', mockGround, 'a', 'a'),
          FloorNode('b', mockThird, 'b', 'b'),
        ],
        edges: const [FloorEdge('a', 'b', ConnectorMode.walk)],
      ),
      throwsArgumentError,
    );
    expect(
      () => FloorRoute(
        id: 'bad',
        version: 1,
        nodes: const [
          FloorNode('a', mockGround, 'a', 'a'),
          FloorNode('b', mockGround, 'b', 'b'),
        ],
        edges: const [FloorEdge('b', 'a', ConnectorMode.walk)],
      ),
      throwsArgumentError,
    );
  });
}
