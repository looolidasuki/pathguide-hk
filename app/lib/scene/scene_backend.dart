import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../platform/app_attestation.dart';

class SceneFailure implements Exception {
  const SceneFailure(
    this.code, {
    this.beforeProvider = false,
    this.stopReason,
    this.limits,
  });
  factory SceneFailure.fromBackend(String code, Object? details) =>
      SceneFailure(
        code,
        beforeProvider: details is Map && details['beforeProvider'] == true,
        stopReason: details is Map
            ? parseSceneStopReason(details['stopReason'])
            : null,
        limits: details is Map
            ? SceneTrialLimits.parse(details['limits'])
            : null,
      );
  final String code;
  final bool beforeProvider;
  final String? stopReason;
  final SceneTrialLimits? limits;
}

String? parseSceneStopReason(Object? value) =>
    const {
      'budget-reserve',
      'trial-count',
      'window-expired',
      'allowance-stopped',
      'in-flight',
      'duplicate-request',
      'rate-cooldown',
      'daily-count',
      'configuration-mismatch',
      'usage-unknown',
    }.contains(value)
    ? value as String
    : null;

String? parseSceneRejectionDetail(Object? value) =>
    const {
      'text-format',
      'text-length',
      'text-content',
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

      'json-syntax',
      'answer-fields',
      'sentence-count',
      'observations-array',
      'observation-fields',
      'observation-category',
      'observation-position',
      'observation-detail',
      'observation-content',
      'observation-duplicate',
      'provider-truncated',
    }.contains(value)
    ? value as String
    : null;

String sceneStopMessage(
  String? reason,
  SceneTrialLimits? limits,
) => switch (reason) {
  'budget-reserve' =>
    limits == null
        ? '估算預算餘額不足下一次預留，已暫停新分析。'
        : '估算預算餘額 US\$${((limits.budgetMicroUsd - limits.spentMicroUsd).clamp(0, limits.budgetMicroUsd) / 1000000).toStringAsFixed(6)}，不足下一次預留 US\$0.002458；已暫停新分析。',
  'trial-count' => '已達累計測試次數上限，已暫停新分析。',
  'window-expired' => '場景測試許可已到期，已暫停新分析。',
  'in-flight' => '伺服器仍有一個請求未結算，暫停新分析。',
  'usage-unknown' => '前次用量未能確認，暫停新分析並等待核對。',
  'rate-cooldown' => '伺服器冷卻尚未完成，今次沒有呼叫模型。',
  'daily-count' => '已達伺服器當日次數限制，暫停新分析。',
  'configuration-mismatch' => '場景許可設定與帳本未一致，暫停新分析並等待核對。',
  'duplicate-request' => '伺服器拒絕重複請求，今次沒有呼叫模型。',
  _ => '場景模式受限，額度或許可需核對；暫停新分析。',
};

abstract interface class SceneStatusBackend {
  Future<SceneAccountStatus> readStatus();
}

class SceneAccountStatus {
  SceneAccountStatus.fromMap(Map map) {
    limits = SceneTrialLimits.parse(map['limits']);
    stopReason = parseSceneStopReason(map['stopReason']);
    final values = map['recentResults'];
    if (values is List) {
      for (final value in values.take(3)) {
        if (value is! Map ||
            value['requestId'] is! String ||
            !RegExp(r'^[a-f0-9]{32}$').hasMatch(value['requestId'] as String) ||
            !const {'complete', 'rejected'}.contains(value['status'])) {
          continue;
        }
        try {
          final metrics = SceneMetrics.fromMap(value['metrics']);
          final reason = value['rejectionReason'];
          final allowedReason =
              const {
                'answer-format',
                'answer-length',
                'sentence-count',
                'disallowed-content',
                'provider-response',
                'provider-refusal',
                'incomplete-answer',
              }.contains(reason)
              ? reason as String
              : '無';
          final detail =
              parseSceneRejectionDetail(value['rejectionDetail']) ?? '無';
          recentReports.add(
            '請求 ${value['requestId']}；後端 ${value['status']}；拒絕 $allowedReason／$detail；模型 ${metrics.modelMs} ms；tokens ${metrics.totalTokens ?? '未知'}；估算 US\$${metrics.estimatedUsd?.toStringAsFixed(6) ?? '未知'}',
          );
        } on SceneFailure {
          /* Ignore malformed numerical history, never render arbitrary values. */
        }
      }
    }
  }
  SceneTrialLimits? limits;
  String? stopReason;
  final List<String> recentReports = [];
}

String sceneRequestId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

// Defense in depth; a prompt alone is not an output validation boundary.
String validateSceneText(
  Object? value, {
  int minSentences = 2,
  int maxSentences = 3,
}) {
  if (value is! String) throw const SceneFailure('invalid-answer');
  final text = value.trim();
  // Keep in sync with backend scene_description.js. Only these nouns exempt
  // 米/層; all other restrictions still inspect the complete original text.
  final nonNounText = text.replaceAll(
    RegExp(r'米缸|米桶|米袋|米飯|玉米|粟米|米白色|層架|層板'),
    '',
  );
  final sentences = RegExp(r'[^。！？]+[。！？]').allMatches(text).toList();
  if (text.length > 240 ||
      sentences.length < minSentences ||
      sentences.length > maxSentences ||
      sentences.map((m) => m[0]).join() != text ||
      !RegExp(r'[\u3400-\u9fff]').hasMatch(text) ||
      RegExp(r'[米層]').hasMatch(nonNounText) ||
      RegExp(
        r'[\r\n<>0-9０-９]|公尺|厘米|公里|met(?:er|re)|樓(?!梯)|目的地|安全|暢通|通行|避開|繞過|向左|向右|左轉|右轉|可以行|可以走|往前|前進|直行|行過去|走過去|左邊行|右邊行|靠左|靠右|向前|向後|往左|往右|前行|後退|退後|行去|行入|行出|走去|走入|走出|繼續行|繼續走|可通過|可行|可走|請|建議|應該|必須|你可|呎|尺|英寸|英吋|马|车|门|栏|电|这|个|侧|见|间|楼|层',
        caseSensitive: false,
      ).hasMatch(text)) {
    throw const SceneFailure('invalid-answer');
  }
  return text;
}

class SceneReply {
  SceneReply.fromMap(Map map, String expectedId) {
    if (map['requestId'] != expectedId) {
      throw const SceneFailure('wrong-request');
    }
    metrics = SceneMetrics.fromMap(map['metrics']);
    rejectionDetail = parseSceneRejectionDetail(map['rejectionDetail']);
    limits = SceneTrialLimits.parse(map['limits']);
    final value = map['mode'];
    if (value != null && value != 'overview' && value != 'update') {
      throw const SceneFailure('invalid-answer');
    }
    mode = value as String?;
    if (map['status'] == 'complete') {
      text = validateSceneText(
        map['text'],
        minSentences: mode == 'update' ? 1 : 2,
        maxSentences: mode == 'update' ? 1 : 3,
      );
      if (mode != null) {
        observations = SceneObservation.parseList(map['observations']);
      }
    } else if (map['status'] != 'rejected' || map.containsKey('text')) {
      throw const SceneFailure('invalid-answer');
    } else if (const {
      'answer-format',
      'answer-length',
      'sentence-count',
      'disallowed-content',
      'provider-response',
      'provider-refusal',
      'incomplete-answer',
    }.contains(map['rejectionReason'])) {
      rejectionReason = map['rejectionReason'] as String;
    }
  }
  String? text, rejectionReason, rejectionDetail, mode;
  List<SceneObservation> observations = const [];
  SceneTrialLimits? limits;
  late final SceneMetrics metrics;
}

/// Ephemeral visible facts, compared only on the phone; never diagnostic content.
class SceneObservation {
  const SceneObservation(this.category, this.position, this.detail);
  final String category, position, detail;
  static List<SceneObservation> parseList(Object? value) {
    const categories = {
      'person',
      'door',
      'stairs',
      'table',
      'chair',
      'passage',
      'vehicle',
      'sign',
      'other',
    };
    const positions = {'left', 'centre', 'right'};
    if (value is! List || value.length > 6) {
      throw const SceneFailure('invalid-answer');
    }
    final seen = <String>{};
    return value
        .map((o) {
          if (o is! Map ||
              o.length != 3 ||
              !categories.contains(o['category']) ||
              !positions.contains(o['position']) ||
              o['detail'] is! String) {
            throw const SceneFailure('invalid-answer');
          }
          final detail = (o['detail'] as String).trim();
          if (detail.isEmpty ||
              detail.length > 40 ||
              RegExp(r'[。！？]').hasMatch(detail)) {
            throw const SceneFailure('invalid-answer');
          }
          validateSceneText('$detail。未能確認。');
          final key = '${o['category']}:${o['position']}';
          if (!seen.add(key)) throw const SceneFailure('invalid-answer');
          return SceneObservation(
            o['category'] as String,
            o['position'] as String,
            detail,
          );
        })
        .toList(growable: false);
  }

  String get semanticKey {
    final normalized = detail
        .replaceAll('棕', '啡')
        .replaceAll('開咗', '打開')
        .replaceAll('關咗', '關閉');
    final features = RegExp(
      '紅|黃|藍|綠|白|黑|啡|木|金屬|玻璃|多人|少人|稀少|一般|密集|窗|櫃|出口|升降機|扶手|走廊|貨架|打開|關閉|闊|窄|空',
    ).allMatches(normalized).map((m) => m[0]!).toSet().toList()..sort();
    return '$category:$position:${features.join(',')}';
  }
}

abstract interface class SceneModeBackend implements SceneBackend {
  Future<SceneReply> describeMode(
    Uint8List jpeg,
    String requestId, {
    required String mode,
    bool Function()? isCurrent,
  });
}

class SceneTrialLimits {
  SceneTrialLimits(
    this.count,
    this.maxRequests,
    this.spentMicroUsd,
    this.budgetMicroUsd,
    this.windowRemaining,
    this.expiresAtMs,
  );
  final int count,
      maxRequests,
      spentMicroUsd,
      budgetMicroUsd,
      windowRemaining,
      expiresAtMs;
  static SceneTrialLimits? parse(Object? value) {
    if (value is! Map) return null;
    const keys = [
      'count',
      'maxRequests',
      'spentMicroUsd',
      'budgetMicroUsd',
      'windowRemaining',
      'expiresAtMs',
    ];
    if (keys.any((k) => value[k] is! int || value[k] < 0)) return null;
    if (value['maxRequests'] > 100 ||
        value['count'] > value['maxRequests'] ||
        value['budgetMicroUsd'] > 500000 ||
        value['windowRemaining'] > 100) {
      return null;
    }
    return SceneTrialLimits(
      value['count'],
      value['maxRequests'],
      value['spentMicroUsd'],
      value['budgetMicroUsd'],
      value['windowRemaining'],
      value['expiresAtMs'],
    );
  }
}

/// Only bounded numerical telemetry crosses into the retained measurements.
class SceneMetrics {
  SceneMetrics.fromMap(Object? value) {
    if (value is! Map) throw const SceneFailure('invalid-metrics');
    final ms = value['modelMs'];
    if (ms is! int || ms < 0 || ms > 40000) {
      throw const SceneFailure('invalid-metrics');
    }
    modelMs = ms;
    final u = value['usage'];
    if (u is Map) {
      final p = u['prompt_tokens'],
          c = u['completion_tokens'],
          t = u['total_tokens'];
      if (p is int && c is int && t is int && p >= 0 && c >= 0 && t == p + c) {
        promptTokens = p;
        completionTokens = c;
        totalTokens = t;
      }
    }
    final e = value['estimate'];
    if (totalTokens != null && e is Map && e['notBillingCap'] == true) {
      final usd = e['usd'];
      if (usd is num && usd.isFinite && usd >= 0) estimatedUsd = usd.toDouble();
    }
  }
  late final int modelMs;
  int? promptTokens, completionTokens, totalTokens;
  double? estimatedUsd;
}

/// Device verification can be slow; cancellation before it finishes must not
/// start a new paid upload afterward.
Future<void> awaitSceneAttestation(
  Future<bool> activation,
  bool Function()? isCurrent,
) async {
  final ready = await activation;
  if (!(isCurrent?.call() ?? true)) {
    throw const SceneFailure('cancelled', beforeProvider: true);
  }
  if (!ready) {
    throw const SceneFailure('app-check-unavailable', beforeProvider: true);
  }
}

abstract interface class SceneBackend {
  Future<SceneReply> describe(
    Uint8List jpeg,
    String requestId, {
    bool Function()? isCurrent,
  });
}

class FirebaseSceneBackend implements SceneModeBackend, SceneStatusBackend {
  // Only used to isolate in-memory numerical diagnostics across page re-entry.
  // The scope itself is never included in a diagnostic report.
  String? get diagnosticScope =>
      Firebase.apps.isEmpty ? null : FirebaseAuth.instance.currentUser?.uid;
  // Across page/controller replacement: cancellation never starts a second call.
  static bool _inFlight = false;
  @override
  Future<SceneAccountStatus> readStatus() async {
    if (!const bool.fromEnvironment('SCENE_DESCRIPTION_ENABLED') ||
        Firebase.apps.isEmpty ||
        FirebaseAuth.instance.currentUser == null) {
      throw const SceneFailure('not-configured', beforeProvider: true);
    }
    await awaitSceneAttestation(activateAppAttestation(), null);
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final response = await FirebaseFunctions.instanceFor(region: 'asia-east2')
        .httpsCallable(
          'describeScene',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 12)),
        )
        .call<dynamic>({'operation': 'status', 'expectedUid': uid});
    if (FirebaseAuth.instance.currentUser?.uid != uid) {
      throw const SceneFailure('stale-account');
    }
    if (response.data is! Map) throw const SceneFailure('invalid-answer');
    return SceneAccountStatus.fromMap(response.data as Map);
  }

  @override
  Future<SceneReply> describe(
    Uint8List jpeg,
    String requestId, {
    bool Function()? isCurrent,
  }) => _describe(jpeg, requestId, isCurrent: isCurrent);
  @override
  Future<SceneReply> describeMode(
    Uint8List jpeg,
    String requestId, {
    required String mode,
    bool Function()? isCurrent,
  }) => _describe(jpeg, requestId, mode: mode, isCurrent: isCurrent);
  Future<SceneReply> _describe(
    Uint8List jpeg,
    String requestId, {
    String? mode,
    bool Function()? isCurrent,
  }) async {
    if (_inFlight) throw const SceneFailure('busy', beforeProvider: true);
    _inFlight = true;
    try {
      if (!const bool.fromEnvironment('SCENE_DESCRIPTION_ENABLED') ||
          Firebase.apps.isEmpty ||
          FirebaseAuth.instance.currentUser == null) {
        throw const SceneFailure('not-configured', beforeProvider: true);
      }
      await awaitSceneAttestation(activateAppAttestation(), isCurrent);
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final response = await FirebaseFunctions.instanceFor(region: 'asia-east2')
          .httpsCallable(
            'describeScene',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 40)),
          )
          .call<dynamic>({
            'schemaVersion': mode == null ? 1 : 2,
            'mode': ?mode,
            'expectedUid': uid,
            'requestId': requestId,
            'mimeType': 'image/jpeg',
            'jpegBase64': base64Encode(jpeg),
          });
      if (FirebaseAuth.instance.currentUser?.uid != uid) {
        throw const SceneFailure('stale-account');
      }
      if (response.data is! Map) throw const SceneFailure('invalid-answer');
      final reply = SceneReply.fromMap(response.data as Map, requestId);
      if (mode != null && reply.text != null && reply.mode != mode) {
        throw const SceneFailure('invalid-answer');
      }
      return reply;
    } on FirebaseFunctionsException catch (error) {
      throw SceneFailure.fromBackend(error.code, error.details);
    } finally {
      _inFlight = false;
    }
  }
}
