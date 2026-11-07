import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_memory_contract.dart';

const nodes = [
  LandmarkNode('entry', '入口', 'Entrance'),
  LandmarkNode('corner', '轉角', 'Corner'),
  LandmarkNode('end', '終點', 'End'),
];

void saveRoute(RouteMemoryController c) {
  c.startRecording();
  for (final n in nodes) {
    c.recordLandmark(n);
  }
  c.finishRecording();
  c.saveRoute('test');
}

void start(RouteMemoryController c) {
  c.selectRoute(c.routes.first.id);
  c.confirmStart(true);
  c.confirmDirection(true);
  c.startReplay();
}

void main() {
  late RouteMemoryController c;
  var now = DateTime.utc(2026, 11, 4);
  setUp(() {
    now = DateTime.utc(2026, 11, 4);
    c = RouteMemoryController(clock: () => now);
  });
  tearDown(() => c.dispose());

  test('record pause resume save is immutable, deduplicated and directed', () {
    c.startRecording();
    c.recordLandmark(nodes[0]);
    c.recordLandmark(nodes[0]);
    c.pause();
    c.recordLandmark(nodes[1]);
    expect(c.draft.length, 1);
    c.resumeRecording();
    c.recordLandmark(nodes[1]);
    c.finishRecording();
    c.saveRoute('  Home  ');
    c.saveRoute('again');
    expect(c.routes.length, 1);
    expect(c.routes.single.name, 'Home');
    expect(c.routes.single.edges, [('entry', 'corner')]);
    expect(() => c.routes.single.nodes.clear(), throwsUnsupportedError);
  });

  test(
    'cannot save incomplete/unnamed route or bypass independent confirmations',
    () {
      c.startRecording();
      c.finishRecording();
      expect(c.phase, RoutePhase.recording);
      c.recordLandmark(nodes[0]);
      c.recordLandmark(nodes[1]);
      c.finishRecording();
      c.saveRoute(' ');
      expect(c.routes, isEmpty);
      c.saveRoute('route');
      c.selectRoute(c.routes.single.id);
      c.startReplay();
      expect(c.phase, RoutePhase.confirming);
      c.confirmStart(true);
      c.startReplay();
      expect(c.canStartReplay, isFalse);
      c.confirmDirection(true);
      c.startReplay();
      expect(c.nextLandmark?.id, 'corner');
    },
  );

  test('unknown/ambiguous/wrong direction withdraw instructions and require reconfirmation', () {
    saveRoute(c);
    for (final result in [
      MockMatch.unknown,
      MockMatch.ambiguous,
      MockMatch.wrongDirection,
    ]) {
      if (c.phase != RoutePhase.saved) {
        c.stop();
      }
      start(c);
      final t = c.beginObservation()!;
      c.acceptObservation(t, result);
      expect(c.nextLandmark, isNull);
      c.acceptObservation(t, MockMatch.matched, nodeId: 'corner');
      expect(c.nextLandmark, isNull);
      c.reconfirm();
      expect(c.startConfirmed, isFalse);
      expect(c.directionConfirmed, isFalse);
      expect(c.canStartReplay, isFalse);
    }
  });

  test('background and pause invalidate in-flight results across resume', () {
    saveRoute(c);
    start(c);
    final old = c.beginObservation()!;
    c.setForeground(false);
    c.setForeground(true);
    expect(c.phase, RoutePhase.pausedReplay);
    expect(c.nextLandmark, isNull);
    c.reconfirm();
    c.confirmStart(true);
    c.confirmDirection(true);
    c.startReplay();
    c.acceptObservation(old, MockMatch.matched, nodeId: 'corner');
    expect(c.position, 0);
    expect(c.nextLandmark?.id, 'corner');
  });

  test('deletion prevents late result resurrecting route or position', () {
    saveRoute(c);
    start(c);
    final old = c.beginObservation()!;
    final id = c.selected!.id;
    c.deleteRoute(id);
    c.acceptObservation(old, MockMatch.matched, nodeId: 'corner');
    expect(c.routes, isEmpty);
    expect(c.selected, isNull);
    expect(c.nextLandmark, isNull);
    expect(c.phase, RoutePhase.deleted);
    c.reconfirm();
    expect(c.canStartReplay, isFalse);
  });

  test('out of order and duplicate results cannot skip landmarks', () {
    saveRoute(c);
    start(c);
    final first = c.beginObservation()!;
    final second = c.beginObservation()!;
    c.acceptObservation(second, MockMatch.matched, nodeId: 'corner');
    c.acceptObservation(first, MockMatch.matched, nodeId: 'end');
    c.acceptObservation(second, MockMatch.matched, nodeId: 'end');
    expect(c.phase, RoutePhase.replaying);
    expect(c.position, 1);
    c.acceptObservation(
      c.beginObservation()!,
      MockMatch.matched,
      nodeId: 'end',
    );
    expect(c.phase, RoutePhase.arrival);
    expect(c.nextLandmark, isNull);
    c.confirmArrival();
    expect(c.phase, RoutePhase.finished);
  });

  test('future or stale observations withdraw instructions', () {
    saveRoute(c);
    start(c);
    final t = c.beginObservation()!;
    now = now.add(const Duration(seconds: 16));
    c.acceptObservation(t, MockMatch.matched, nodeId: 'corner');
    expect(c.issue, RouteIssue.stale);
    expect(c.nextLandmark, isNull);
    c.stop();
    start(c);
    final future = c.beginObservation()!;
    now = now.subtract(const Duration(seconds: 1));
    c.acceptObservation(future, MockMatch.matched, nodeId: 'corner');
    expect(c.issue, RouteIssue.stale);
  });

  test(
    'incompatible route/feature/direction and unexpected node never advance',
    () {
      saveRoute(c);
      for (final which in [
        'route',
        'version',
        'feature',
        'direction',
        'node',
      ]) {
        c.stop();
        start(c);
        final t = c.beginObservation()!;
        c.acceptObservation(
          ObservationTicket(
            session: t.session,
            sequence: t.sequence,
            routeId: which == 'route' ? 'other' : t.routeId,
            routeVersion: which == 'version' ? 2 : t.routeVersion,
            featureRevision: which == 'feature' ? 'other' : 'synthetic-v1',
            direction: which == 'direction' ? 'reverse' : 'recorded',
            capturedAt: t.capturedAt,
          ),
          MockMatch.matched,
          nodeId: which == 'node' ? 'end' : 'corner',
        );
        expect(c.phase, RoutePhase.unknown);
        expect(c.nextLandmark, isNull);
        expect(c.position, 0);
      }
    },
  );

  test('arrival confirmation cannot survive background interruption', () {
    saveRoute(c);
    start(c);
    c.acceptObservation(
      c.beginObservation()!,
      MockMatch.matched,
      nodeId: 'corner',
    );
    c.acceptObservation(
      c.beginObservation()!,
      MockMatch.matched,
      nodeId: 'end',
    );
    c.setForeground(false);
    c.setForeground(true);
    c.confirmArrival();
    expect(c.phase, RoutePhase.pausedReplay);
  });
}
