import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum RouteCaptureStatus {
  idle,
  starting,
  stopping,
  running,
  captured,
  stopped,
  paused,
  permission,
  unsupported,
  unavailable,
  noFrame,
  busy,
  unknownClock,
  staleFrame,
  futureFrame,
  cancelled,
  stopUnconfirmed,
  invalid,
  failed;

  static RouteCaptureStatus parse(Object? value) => switch (value) {
    'starting' => starting,
    'stopping' => stopping,
    'running' => running,
    'captured' => captured,
    'stopped' => stopped,
    'paused' => paused,
    'interrupted' => paused,
    'permission' => permission,
    'unsupported' => unsupported,
    'unavailable' => unavailable,
    'no_frame' => noFrame,
    'busy' => busy,
    'unknown_clock' => unknownClock,
    'stale_frame' => staleFrame,
    'future_frame' => futureFrame,
    'cancelled' => cancelled,
    'stop_unconfirmed' => stopUnconfirmed,
    'stale_request' => cancelled,
    'bad_args' => invalid,
    _ => failed,
  };
}

class RouteKeyframe {
  RouteKeyframe(
    this.bytes,
    this.width,
    this.height,
    Map<String, Object?> observation,
  ) : observation = Map.unmodifiable(observation);
  final Uint8List bytes;
  final int width, height;
  final Map<String, Object?> observation;
}

class RouteCaptureResult {
  const RouteCaptureResult(this.status, [this.keyframe]);
  final RouteCaptureStatus status;
  final RouteKeyframe? keyframe;
}

class _RouteSession {
  _RouteSession(this.id, this.generation, this.routeId, this.routeVersion);
  final String id, routeId;
  final int generation, routeVersion;
  String get startRequest => '$id-$generation-start';
  Map<String, Object> args(String request) => {
    'requestId': request,
    'session': id,
    'generation': generation,
    'routeId': routeId,
    'routeVersion': routeVersion,
  };
}

/// Native channel is the system seam. No model, file store or cloud operation
/// belongs to this source; captured bytes live only until the caller releases them.
class RouteObservationSource {
  RouteObservationSource({bool? supported})
    : supported =
          supported ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
  final bool supported;
  static const _methods = MethodChannel('hk.pathguide/route_camera');
  static const _events = EventChannel('hk.pathguide/route_camera/events');
  // One binary event handler per engine. Per-page EventChannels would let an
  // older page's cancellation clear a newer page's handler on the same name.
  static final _rawEvents = _events.receiveBroadcastStream({
    'subscriber': 'route-camera-dart-stream',
  });
  static String _newId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  final _id = _newId();
  int _generation = 0, _request = 0;
  int _lastSequence = 0;
  String? _clockEpoch;
  _RouteSession? _current;
  _RouteSession? _unconfirmedStop;
  Future<RouteCaptureStatus>? _stopping;
  Completer<RouteCaptureResult>? _pending;
  String? _pendingId;

  Stream<RouteCaptureStatus> get events => !supported
      ? const Stream.empty()
      : _rawEvents
            .where((value) {
              final current = _current;
              return current != null &&
                  value is Map &&
                  value['session'] == current.id &&
                  value['generation'] == current.generation &&
                  value['routeId'] == current.routeId &&
                  value['routeVersion'] == current.routeVersion;
            })
            .map((value) => RouteCaptureStatus.parse((value as Map)['status']));

  Future<Map<String, Object?>> _invoke(
    String method,
    Map<String, Object> args,
  ) async {
    final value = await _methods
        .invokeMapMethod<String, Object?>(method, args)
        .timeout(const Duration(seconds: 8));
    if (value == null) throw const FormatException('Missing native response');
    return value;
  }

  Future<RouteCaptureStatus> start({
    required String routeId,
    required int routeVersion,
  }) async {
    if (!supported) return RouteCaptureStatus.unsupported;
    if (_unconfirmedStop != null || _stopping != null) {
      if (await stop() != RouteCaptureStatus.stopped) {
        return RouteCaptureStatus.stopUnconfirmed;
      }
    }
    final current = _RouteSession(_id, ++_generation, routeId, routeVersion);
    _cancelLocal();
    _current = current;
    _lastSequence = 0;
    _clockEpoch = null;
    try {
      final value = await _invoke('start', current.args(current.startRequest));
      if (_current != current) return RouteCaptureStatus.paused;
      if (value['status'] == 'running' && !_matches(value, current)) {
        await stop();
        return RouteCaptureStatus.invalid;
      }
      return RouteCaptureStatus.parse(value['status']);
    } on TimeoutException {
      // Retire this owner immediately. A missing reply never proves the camera
      // stopped; stop retains its unconfirmed identity until an exact retry ack.
      if (_current == current) unawaited(stop());
      return RouteCaptureStatus.failed;
    } on MissingPluginException {
      if (_current == current) _current = null;
      return RouteCaptureStatus.unsupported;
    } catch (_) {
      return RouteCaptureStatus.failed;
    }
  }

  Future<RouteCaptureResult> capture() async {
    final current = _current;
    if (current == null) {
      return const RouteCaptureResult(RouteCaptureStatus.paused);
    }
    if (_pending != null) {
      return const RouteCaptureResult(RouteCaptureStatus.busy);
    }
    final pending = Completer<RouteCaptureResult>();
    final id = '${current.id}-${current.generation}-capture-${++_request}';
    _pending = pending;
    _pendingId = id;
    final elapsed = Stopwatch()..start();
    unawaited(() async {
      RouteCaptureResult result;
      try {
        final value = await _invoke('captureKeyframe', current.args(id));
        if (pending.isCompleted) return;
        final status = RouteCaptureStatus.parse(value['status']);
        if (status != RouteCaptureStatus.captured) {
          result = RouteCaptureResult(status);
        } else {
          final bytes = value['jpeg'] as Uint8List;
          final header = Map<String, Object?>.from(value['header'] as Map);
          final width = value['width'] as int, height = value['height'] as int;
          if (!_validHeader(header, current, id) ||
              value['orientation'] != 'up' ||
              bytes.isEmpty ||
              bytes.length > 524288 ||
              value['byteCount'] != bytes.length ||
              width <= 0 ||
              height <= 0 ||
              width > 1280 ||
              height > 1280 ||
              width > (header['uprightWidth'] as int) ||
              height > (header['uprightHeight'] as int) ||
              bytes.length < 4 ||
              bytes[0] != 255 ||
              bytes[1] != 216 ||
              value['sha256'] != sha256.convert(bytes).toString()) {
            throw const FormatException('Invalid native keyframe contract');
          }
          final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
          try {
            final descriptor = await ui.ImageDescriptor.encoded(buffer);
            try {
              if (descriptor.width != width || descriptor.height != height) {
                throw const FormatException('JPEG dimensions mismatch');
              }
            } finally {
              descriptor.dispose();
            }
          } finally {
            buffer.dispose();
          }
          if (_current != current || pending.isCompleted) return;
          if ((header['ageMs'] as num).toDouble() +
                  elapsed.elapsedMilliseconds >
              1000) {
            result = const RouteCaptureResult(RouteCaptureStatus.staleFrame);
          } else {
            _lastSequence = header['sequence'] as int;
            _clockEpoch = header['clockEpoch'] as String;
            result = RouteCaptureResult(
              status,
              RouteKeyframe(Uint8List.fromList(bytes), width, height, header),
            );
          }
        }
      } catch (_) {
        result = const RouteCaptureResult(RouteCaptureStatus.invalid);
      }
      if (_current != current) {
        result = const RouteCaptureResult(RouteCaptureStatus.cancelled);
      }
      if (_pending == pending) {
        _pending = null;
        _pendingId = null;
      }
      if (!pending.isCompleted) pending.complete(result);
    }());
    return pending.future;
  }

  bool _matches(Map<String, Object?> value, _RouteSession current) =>
      value['session'] == current.id &&
      value['generation'] == current.generation &&
      value['routeId'] == current.routeId &&
      value['routeVersion'] == current.routeVersion;

  bool _validHeader(
    Map<String, Object?> h,
    _RouteSession current,
    String request,
  ) {
    if (!_matches(h, current) ||
        h['requestId'] != request ||
        h['startRequestId'] != current.startRequest ||
        h['source'] != 'avfoundation-back-wide' ||
        h['profile'] != 'route-camera-engineering-v1' ||
        h['clockMapping'] != 'coremedia-host' ||
        h['walkingValidated'] != false ||
        h['mirrored'] != false) {
      return false;
    }
    for (final field in [
      'sequence',
      'rawTimestampValue',
      'rawTimestampTimescale',
      'rawTimestampEpoch',
      'rawWidth',
      'rawHeight',
      'uprightWidth',
      'uprightHeight',
      'rotationDegrees',
    ]) {
      if (h[field] is! int) return false;
    }
    if ((h['sequence'] as int) <= 0 ||
        (h['sequence'] as int) < _lastSequence ||
        (h['rawTimestampTimescale'] as int) <= 0) {
      return false;
    }
    final epoch = h['clockEpoch'], clock = h['captureClockId'];
    if (epoch is! String ||
        epoch.isEmpty ||
        clock != 'avcapture-session-$epoch' ||
        (_clockEpoch != null && epoch != _clockEpoch)) {
      return false;
    }
    for (final field in [
      'capturedHostSeconds',
      'nativeNowHostSeconds',
      'ageMs',
    ]) {
      if (h[field] is! num || !(h[field] as num).isFinite) return false;
    }
    final captured = (h['capturedHostSeconds'] as num).toDouble();
    final now = (h['nativeNowHostSeconds'] as num).toDouble(),
        age = (h['ageMs'] as num).toDouble();
    if (captured < 0 ||
        now < captured ||
        age < 0 ||
        age > 1000 ||
        (age - (now - captured) * 1000).abs() > 0.01) {
      return false;
    }
    final w = h['rawWidth'] as int, height = h['rawHeight'] as int;
    final rotation = h['rotationDegrees'] as int;
    if (w <= 0 || height <= 0 || ![0, 90, 180, 270].contains(rotation)) {
      return false;
    }
    final portrait = rotation == 90 || rotation == 270;
    return h['uprightWidth'] == (portrait ? height : w) &&
        h['uprightHeight'] == (portrait ? w : height);
  }

  void _cancelLocal() {
    final pending = _pending;
    _pending = null;
    _pendingId = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(const RouteCaptureResult(RouteCaptureStatus.cancelled));
    }
  }

  Future<void> cancelCapture() async {
    final current = _current, id = _pendingId;
    _cancelLocal();
    if (current != null && id != null && supported) {
      try {
        await _invoke('cancelKeyframe', current.args(id));
      } catch (_) {
        /* Stop remains available. */
      }
    }
  }

  Future<RouteCaptureStatus> stop() async {
    final current = _current ?? _unconfirmedStop;
    _current = null;
    _cancelLocal();
    if (_stopping != null) return _stopping!;
    if (current == null || !supported) {
      return RouteCaptureStatus.stopped;
    }
    _unconfirmedStop = current;
    final operation = () async {
      try {
        final reply = await _invoke('stop', current.args('stop'));
        return reply['status'] == 'stopped' && _matches(reply, current)
            ? RouteCaptureStatus.stopped
            : RouteCaptureStatus.stopUnconfirmed;
      } catch (_) {
        return RouteCaptureStatus.stopUnconfirmed;
      }
    }();
    _stopping = operation;
    final status = await operation;
    if (_stopping == operation) {
      _stopping = null;
      if (status == RouteCaptureStatus.stopped && _unconfirmedStop == current) {
        _unconfirmedStop = null;
      }
    }
    return status;
  }
}
