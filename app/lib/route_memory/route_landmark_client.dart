import 'dart:async';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'route_observation_source.dart';
import 'route_localizer.dart';

class LandmarkFailure implements Exception {
  const LandmarkFailure(this.code);
  final String code;
}

class LandmarkAnalysis {
  LandmarkAnalysis(this.imageSha, List<int> feature, List<String> text)
    : feature = Uint8List.fromList(feature).asUnmodifiableView(),
      text = List.unmodifiable(text);
  final String imageSha;
  final Uint8List feature;
  final List<String> text;
}

/// Exact request identities prevent cancelled/old owners accepting late Vision
/// replies. Native retains its busy latch until cancelled work has drained.
class RouteLandmarkClient {
  static const _channel = MethodChannel('hk.pathguide/route_landmark');
  final _prefix = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  int _serial = 0, _epoch = 0;
  String? _pending;
  bool _disposed = false;
  Future<Map<String, Object?>> _call(
    String method,
    Map<String, Object?> args,
  ) async {
    if (_disposed) throw const LandmarkFailure('cancelled');
    if (_pending != null) throw const LandmarkFailure('busy');
    final id = '$_prefix-${++_serial}', epoch = _epoch;
    _pending = id;
    final payload = {
      ...args,
      'requestId': id,
      'featureRevision': RouteLocalizer.featureRevision,
      'preprocessRevision': RouteLocalizer.preprocessRevision,
    };
    try {
      final value = await _channel
          .invokeMapMethod<String, Object?>(method, payload)
          .timeout(const Duration(seconds: 8));
      if (_disposed || epoch != _epoch) {
        throw const LandmarkFailure('cancelled');
      }
      if (value == null ||
          value['requestId'] != id ||
          value['inputSha'] != args['inputSha'] ||
          value['featureRevision'] != RouteLocalizer.featureRevision ||
          value['preprocessRevision'] != RouteLocalizer.preprocessRevision) {
        throw const LandmarkFailure('invalid');
      }
      if (value['status'] != 'ok') {
        throw LandmarkFailure(value['status'] as String? ?? 'failed');
      }
      return value;
    } on TimeoutException {
      unawaited(_cancelNative(id));
      throw const LandmarkFailure('timeout');
    } on MissingPluginException {
      throw const LandmarkFailure('unsupported');
    } finally {
      if (_pending == id) _pending = null;
    }
  }

  Future<LandmarkAnalysis> analyze(RouteKeyframe frame) async {
    final bytes = Uint8List.fromList(frame.bytes),
        hash = sha256.convert(frame.bytes).toString();
    final v = await _call('analyze', {
      'jpeg': bytes,
      'width': frame.width,
      'height': frame.height,
      'inputSha': hash,
    });
    final feature = v['feature'];
    final text = v['text'];
    if (feature is! Uint8List ||
        feature.isEmpty ||
        feature.length > 65536 ||
        v['featureSha'] != sha256.convert(feature).toString() ||
        text is! List ||
        text.length > 32 ||
        text.any((t) => t is! String || t.length > 120) ||
        v['manualFloorConfirmationRequired'] != true ||
        ![2, 3].contains(v['ocrRevision'])) {
      throw const LandmarkFailure('invalid');
    }
    return LandmarkAnalysis(hash, feature, text.cast<String>());
  }

  Future<List<double>> compare(
    Uint8List query,
    List<Uint8List> references,
  ) async {
    if (query.isEmpty ||
        query.length > 65536 ||
        references.isEmpty ||
        references.length > 64 ||
        references.any((b) => b.isEmpty || b.length > 65536)) {
      throw const LandmarkFailure('invalid');
    }
    final v = await _call('compare', {
      'query': Uint8List.fromList(query),
      'references': [for (final b in references) Uint8List.fromList(b)],
      'inputSha': sha256.convert(query).toString(),
    });
    final raw = v['distances'];
    if (raw is! List ||
        raw.length != references.length ||
        raw.any((n) => n is! num || !n.isFinite || n < 0)) {
      throw const LandmarkFailure('invalid');
    }
    return raw.map((n) => (n as num).toDouble()).toList(growable: false);
  }

  Future<void> _cancelNative(String id) async {
    try {
      await _channel
          .invokeMethod<void>('cancel', {'requestId': id})
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {}
  }

  Future<void> cancel() async {
    _epoch++;
    final id = _pending;
    _pending = null;
    if (id != null) await _cancelNative(id);
  }

  void dispose() {
    _disposed = true;
    unawaited(cancel());
  }
}
