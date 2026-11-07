import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_package.dart';

import 'captured_route_store_test.dart' show capturedDocument;

Map<String, dynamic> inherited() {
  final map = jsonDecode(
    jsonEncode(capturedDocument().toMap()),
  ) as Map<String, dynamic>;
  map['schemaVersion'] = 3;
  map['nodes'][0].addAll({
    'floorEvidence': 'confirmed',
    'floorAnchor': null,
    'floorContextAnchor': true,
  });
  map['nodes'][1].addAll({'floorEvidence': 'inherited', 'floorAnchor': 'g'});
  return map;
}

void main() {
  test(
    'unknown document version fails as incompatible without parsing its nodes',
    () {
      expect(
        () => RouteDocument.fromMap({'schemaVersion': 99}),
        throwsA(
          isA<RouteStoreFailure>().having(
            (e) => e.problem,
            'problem',
            RouteProblem.incompatible,
          ),
        ),
      );
    },
  );
  test(
    'legacy schema2 stays schema2 and inherited schema3 cannot be complete',
    () {
      expect(capturedDocument().toMap()['schemaVersion'], 2);
      final d = RouteDocument.fromMap(inherited());
      expect(d.complete, isFalse);
      expect(d.nodes.last.floorEvidence, FloorEvidence.inherited);
      expect(d.toMap()['schemaVersion'], 3);
    },
  );
  test('legacy schema cannot silently discard explicit floor provenance', () {
    final map = inherited();
    map['schemaVersion'] = 2;
    expect(() => RouteDocument.fromMap(map), throwsA(isA<RouteStoreFailure>()));
  });
  for (final failure in [
    'selfAnchor',
    'missingAnchor',
    'floorMismatch',
    'crossConnector',
    'unknownSource',
  ]) {
    test('rejects invalid provenance $failure', () {
      final map = inherited();
      switch (failure) {
        case 'selfAnchor':
          map['nodes'][1]['floorAnchor'] = 'end';
        case 'missingAnchor':
          map['nodes'][1]['floorAnchor'] = 'missing';
        case 'floorMismatch':
          map['nodes'][1]['floor']['label'] = '3F';
        case 'crossConnector':
          map['edges'][0].addAll({'mode': 'elevator', 'connector': 'lift'});
        case 'unknownSource':
          map['nodes'][1]['floorEvidence'] = 'guessed';
      }
      expect(
        () => RouteDocument.fromMap(map),
        throwsA(isA<RouteStoreFailure>()),
      );
    });
  }
}
