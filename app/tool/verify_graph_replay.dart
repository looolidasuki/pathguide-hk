import 'dart:convert';
import 'dart:io';

import 'package:pathguide/indoor/indoor_graph.dart';
import 'package:pathguide/indoor/replay_scenarios.dart';

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart tool/verify_graph_replay.dart OUTPUT.json');
    exitCode = 64;
    return;
  }
  final traces = <Map<String, Object?>>[];
  for (final scenario in replayScenarios) {
    final session = GraphReplaySession(
      graph: demoIndoorGraph,
      sessionId: scenario.id,
      destination: scenario.destination,
    );
    final observations = <Map<String, Object?>>[];
    for (final event in scenario.events) {
      final result = session.observe(
        event.observation,
        receivedAt: event.receivedAt,
      );
      observations.add({
        'captureSequence': event.observation.sequence,
        'captureTime': event.observation.capturedAt.toIso8601String(),
        'receivedTime': event.receivedAt.toIso8601String(),
        'state': result.state.name,
        'currentNode': session.currentNode,
        'lastTrustedNode': session.lastTrustedNode,
        'candidates': result.candidates,
        'matchedObjectCount': result.matchedObjects,
        'expectedNode': result.expectedNode,
        'path': session.path,
        'captureQueue': session.observations.map((o) => o.sequence).toList(),
      });
    }
    traces.add({'scenario': scenario.id, 'observations': observations});
  }
  final report = {
    'appVersion': '1.2.0+3',
    'type': 'hand-annotated synthetic logic replay',
    'isImageLocalizationBenchmark': false,
    'isRealSiteMap': false,
    'metricCoordinates': false,
    'graphId': demoIndoorGraph.id,
    'mapVersion': demoIndoorGraph.version,
    'nodeCount': demoIndoorGraph.nodes.length,
    'edgeCount': demoIndoorGraph.edges.length,
    'closedEdgeCount': demoIndoorGraph.edges.where((e) => !e.open).length,
    'scenarioCount': replayScenarios.length,
    'traces': traces,
  };
  final output = File(arguments.single)..parent.createSync(recursive: true);
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(
    'Saved ${traces.length} synthetic replay traces. No image accuracy or metric navigation claim.',
  );
}
