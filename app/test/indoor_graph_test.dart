import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/indoor/indoor_graph.dart';
import 'package:pathguide/indoor/replay_scenarios.dart';

ReplayScenario scenario(String id) =>
    replayScenarios.firstWhere((s) => s.id == id);
GraphReplaySession session(String id, {int hops = 5}) => GraphReplaySession(
  graph: demoIndoorGraph,
  sessionId: id,
  destination: 'N07',
  neighborHops: hops,
);
LandmarkMatch apply(GraphReplaySession session, ReplayEvent event) =>
    session.observe(event.observation, receivedAt: event.receivedAt);
void main() {
  test(
    'routes use real edges in either direction and reject a closed shortcut',
    () {
      expect(demoIndoorGraph.route('N04', 'N08'), ['N04', 'N03', 'N08']);
      expect(demoIndoorGraph.route('N08', 'N04'), ['N08', 'N03', 'N04']);
      expect(demoIndoorGraph.route('N01', 'N07'), [
        'N01',
        'N02',
        'N03',
        'N04',
        'N05',
        'N06',
        'N07',
      ]);
      expect(demoIndoorGraph.route('N01', 'missing'), isEmpty);
      expect(demoIndoorGraph.route('N01', 'N01'), ['N01']);
    },
  );
  test(
    'a fork neighborhood follows edges instead of adjacent array indices',
    () {
      expect(demoIndoorGraph.neighborhood('N03', hops: 1), {
        'N03',
        'N02',
        'N04',
        'N08',
      });
      expect(
        demoIndoorGraph.neighborhood('N01', hops: 5),
        isNot(contains('N12')),
      );
    },
  );
  test('a disconnected destination produces no route', () {
    final graph = IndoorGraph(
      id: 'test',
      version: '1',
      floor: 'F1',
      nodes: [demoIndoorGraph.nodes['N01']!, demoIndoorGraph.nodes['N07']!],
      edges: [],
    );
    expect(graph.route('N01', 'N07'), isEmpty);
  });
  test('invalid graph edges and duplicate place IDs are rejected', () {
    final node = demoIndoorGraph.nodes['N01']!;
    expect(
      () => IndoorGraph(
        id: 'test',
        version: '1',
        floor: 'F1',
        nodes: [node, node],
        edges: [],
      ),
      throwsArgumentError,
    );
    expect(
      () => IndoorGraph(
        id: 'test',
        version: '1',
        floor: 'F1',
        nodes: [node],
        edges: [const IndoorEdge('N01', 'missing')],
      ),
      throwsArgumentError,
    );
    final ambiguousNode = IndoorNode(
      id: 'A',
      nameZh: '示例',
      nameEn: 'sample',
      contentVersion: '1',
      objects: [
        LandmarkObject(id: 'one', aliases: ['same sign']),
        LandmarkObject(id: 'two', aliases: ['same_sign']),
      ],
    );
    expect(
      () => IndoorGraph(
        id: 'test',
        version: '1',
        floor: 'F1',
        nodes: [ambiguousNode],
        edges: [],
      ),
      throwsArgumentError,
    );
  });
  const expected = <String, List<String>>{
    'forward': ['N01', 'N02', 'N03', 'N04', 'N05', 'N06', 'N07'],
    'dwell': ['N03', 'N04', 'N04', 'N04', 'N05'],
    'skip': ['N01', 'N03', 'N05', 'N07'],
    'reverse': ['N07', 'N06', 'N05', 'N04', 'N03', 'N02', 'N01'],
    'fork': ['N01', 'N02', 'N03', 'N08', 'N09', 'N10'],
  };
  for (final entry in expected.entries) {
    test(
      '${entry.key}: annotated observation sequence preserves the expected place IDs',
      () {
        final replay = session(entry.key);
        final matches = scenario(entry.key).events
            .map((event) => apply(replay, event))
            .toList();
        expect(matches.map((m) => m.nodeId).toList(), entry.value);
        expect(matches.every((m) => m.state == MatchState.matched), isTrue);
        expect(demoIndoorGraph.nodes.length, 12);
      },
    );
  }
  test('a repeated observation does not create a place or require forward movement', () {
    final replay = session('dwell');
    final matches = scenario('dwell').events
        .map((event) => apply(replay, event))
        .toList();
    expect(matches[2].repeated, isTrue);
    expect(matches[3].repeated, isTrue);
    expect(replay.observations.length, 5);
    expect(demoIndoorGraph.nodes.length, 12);
  });
  test(
    'a reachable branch is accepted without forcing the planned next node',
    () {
      final replay = session('fork');
      final matches = scenario('fork').events
          .map((event) => apply(replay, event))
          .toList();
      expect(matches[3].expectedNode, 'N04');
      expect(matches[3].nodeId, 'N08');
      expect(replay.path, [
        'N10',
        'N09',
        'N08',
        'N03',
        'N04',
        'N05',
        'N06',
        'N07',
      ]);
    },
  );
  test(
    'shared storefront evidence is ambiguous even near a known position',
    () {
      final replay = session('ambiguous');
      apply(replay, scenario('ambiguous').events[0]);
      final result = apply(replay, scenario('ambiguous').events[1]);
      expect(result.state, MatchState.ambiguous);
      expect(result.candidates, containsAll(['N04', 'N08']));
      expect(replay.currentNode, isNull);
      expect(replay.path, isEmpty);
      expect(replay.lastTrustedNode, 'N03');
      expect(apply(replay, scenario('ambiguous').events[2]).nodeId, 'N08');
    },
  );
  test('approved aliases retain node identity; unknown names do not rewrite content', () {
    final replay = session('rename');
    final original = demoIndoorGraph.nodes['N08']!;
    final matches = scenario('rename').events
        .map((event) => apply(replay, event))
        .toList();
    expect(matches[0].nodeId, 'N08');
    expect(matches[1].nodeId, 'N08');
    expect(matches[2].state, MatchState.unknown);
    expect(identical(original, demoIndoorGraph.nodes['N08']), isTrue);
    expect(original.contentVersion, '2');
    expect(
      () => original.objects.add(original.objects.first),
      throwsUnsupportedError,
    );
  });
  test(
    'several aliases of one object cannot count as independent landmarks',
    () {
      final replay = session('aliases');
      expect(
        apply(
          replay,
          sampleEvent('aliases', 1, ['咖啡店', '舊角落咖啡', '新角落咖啡']),
        ).state,
        MatchState.unknown,
      );
    },
  );
  test('unknown evidence and wrong floor withdraw the current position', () {
    final replay = session('unknown');
    final events = scenario('unknown').events;
    apply(replay, events[0]);
    expect(apply(replay, events[1]).state, MatchState.unknown);
    expect(replay.currentNode, isNull);
    expect(apply(replay, events[2]).state, MatchState.outOfScope);
    expect(replay.lastTrustedNode, isNull);
    expect(replay.path, isEmpty);
  });
  test('a late response is queued in capture order but cannot replace a newer location', () {
    final replay = session('late');
    final events = scenario('late').events;
    apply(replay, events[0]);
    apply(replay, events[1]);
    expect(apply(replay, events[2]).state, MatchState.ignored);
    expect(replay.currentNode, 'N03');
    expect(replay.observations.map((o) => o.sequence), [1, 2, 3]);
    expect(apply(replay, events[3]).state, MatchState.expired);
    expect(replay.currentNode, isNull);
  });
  test(
    'distant candidates require two fresh observations before relocalizing',
    () {
      final replay = session('relocalize');
      final events = scenario('relocalize').events;
      apply(replay, events[0]);
      expect(apply(replay, events[1]).state, MatchState.confirming);
      expect(replay.currentNode, isNull);
      final confirmed = apply(replay, events[2]);
      expect(confirmed.nodeId, 'N12');
      expect(confirmed.relocalized, isTrue);
    },
  );
  test('reusing the same capture time cannot satisfy confirmation', () {
    final replay = session('clock');
    apply(replay, sampleEvent('clock', 1, sampleEvidence('N01')));
    apply(replay, sampleEvent('clock', 2, sampleEvidence('N12')));
    expect(
      apply(
        replay,
        sampleEvent(
          'clock',
          3,
          sampleEvidence('N12'),
          captureSeconds: 10,
          receiveSeconds: 15,
        ),
      ).state,
      MatchState.confirming,
    );
    expect(replay.currentNode, isNull);
    expect(
      apply(replay, sampleEvent('clock', 4, sampleEvidence('N12'))).nodeId,
      'N12',
    );
  });
  test('expired anchors need confirmation before a new global match', () {
    final replay = session('expired');
    apply(replay, sampleEvent('expired', 1, sampleEvidence('N01')));
    expect(
      apply(
        replay,
        sampleEvent('expired', 2, sampleEvidence('N02'), receiveSeconds: 40),
      ).state,
      MatchState.expired,
    );
    expect(
      apply(
        replay,
        sampleEvent('expired', 3, sampleEvidence('N02'), captureSeconds: 45),
      ).state,
      MatchState.confirming,
    );
    expect(
      apply(
        replay,
        sampleEvent('expired', 4, sampleEvidence('N02'), captureSeconds: 50),
      ).nodeId,
      'N02',
    );
  });
  test('another session and duplicate sequences cannot update position', () {
    final replay = session('owner');
    apply(replay, sampleEvent('owner', 1, sampleEvidence('N01')));
    expect(
      apply(replay, sampleEvent('other', 2, sampleEvidence('N07'))).state,
      MatchState.ignored,
    );
    expect(
      apply(replay, sampleEvent('owner', 1, sampleEvidence('N07'))).state,
      MatchState.ignored,
    );
    expect(replay.currentNode, 'N01');
    expect(replay.observations.length, 1);
  });
  test('queue is bounded and immutable to callers', () {
    final replay = session('queue');
    for (var i = 1; i <= 70; i++) {
      apply(replay, sampleEvent('queue', i, sampleEvidence('N04')));
    }
    expect(replay.observations.length, 50);
    expect(replay.observations.first.sequence, 21);
    expect(() => replay.observations.clear(), throwsUnsupportedError);
  });
}
