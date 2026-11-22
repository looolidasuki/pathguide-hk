import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/scene/scene_backend.dart';

void main() {
  test('fixed content classes accepted; arbitrary content ignored', () {
    for (final key in [
      'text-number',
      'text-distance',
      'text-floor',
      'text-destination',
      'text-safety',
      'text-navigation',
      'text-advice',
      'text-simplified',
      'observation-number',
      'observation-distance',
      'observation-floor',
      'observation-destination',
      'observation-safety',
      'observation-navigation',
      'observation-advice',
      'observation-simplified',
    ]) {
      expect(parseSceneRejectionDetail(key), key);
    }
    expect(parseSceneRejectionDetail('private model answer'), isNull);
  });
  final fixtures = jsonDecode(
    File('test/fixtures/scene_validation.json').readAsStringSync(),
  ) as Map;
  test(
    'shared synthetic kitchen/bathroom overview and update are fully accepted',
    () {
      for (final fixture in fixtures['accepted']) {
        for (final mode in ['overview', 'update']) {
          final sentences = (fixture['sentences'] as List)
              .take(mode == 'update' ? 1 : 3)
              .join();
          final reply = SceneReply.fromMap({
            'requestId': 'a' * 32,
            'status': 'complete',
            'mode': mode,
            'text': sentences,
            'observations': fixture['observations'],
            'metrics': {'modelMs': 2000},
          }, 'a' * 32);
          expect(reply.text, sentences);
          expect(
            reply.observations.length,
            (fixture['observations'] as List).length,
          );
        }
      }
    },
  );
  test('noun exceptions cannot hide distance, floor, safety or navigation restrictions', () {
    for (final text in fixtures['rejectedText']) {
      expect(
        () => validateSceneText(text, minSentences: 1, maxSentences: 1),
        throwsA(isA<SceneFailure>()),
        reason: text,
      );
      expect(
        () => SceneObservation.parseList([
          {
            'category': 'other',
            'position': 'left',
            'detail': (text as String).replaceFirst(RegExp(r'[。！？]$'), ''),
          },
        ]),
        throwsA(isA<SceneFailure>()),
        reason: text,
      );
    }
  });
  test('malformed observations reject the entire phone response', () {
    for (final fixture in fixtures['rejectedObservations']) {
      expect(
        () => SceneReply.fromMap({
          'requestId': 'a' * 32,
          'status': 'complete',
          'mode': 'update',
          'text': '右邊有洗衣機。',
          'observations': fixture['items'],
          'metrics': {'modelMs': 2000},
        }, 'a' * 32),
        throwsA(isA<SceneFailure>()),
        reason: fixture['detail'],
      );
    }
  });
}
