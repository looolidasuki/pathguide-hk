import 'dart:async';

import 'package:flutter/foundation.dart';

import 'route_observation_source.dart';

/// Owns one explicit camera trial. No route package, persistent storage or model
/// is needed; all callbacks are fenced by the current user operation.
class RouteCaptureController extends ChangeNotifier {
  RouteCaptureController({RouteObservationSource? source})
    : source = source ?? RouteObservationSource() {
    if (!this.source.supported) _status = RouteCaptureStatus.unsupported;
    _subscription = this.source.events.listen(
      _event,
      onError: (Object _) {
        if (!_disposed) unawaited(stop(reason: RouteCaptureStatus.failed));
      },
    );
  }
  final RouteObservationSource source;
  StreamSubscription<RouteCaptureStatus>? _subscription;
  int _operation = 0;
  bool _disposed = false, _foreground = true, _running = false;
  bool _capturing = false, _stopping = false;
  RouteCaptureStatus _status = RouteCaptureStatus.idle;
  RouteKeyframe? _keyframe;

  RouteCaptureStatus get status => _status;
  RouteKeyframe? get keyframe => _keyframe;
  bool get foreground => _foreground;
  bool get running => _running;
  bool get capturing => _capturing;
  bool get busy =>
      _capturing || _stopping || _status == RouteCaptureStatus.starting;
  bool get canStart =>
      !_disposed &&
      _foreground &&
      !_running &&
      !busy &&
      _status != RouteCaptureStatus.unsupported;
  bool get canCapture => !_disposed && _foreground && _running && !busy;
  bool _current(int operation) => !_disposed && operation == _operation;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (!canStart) return;
    final operation = ++_operation;
    _keyframe = null;
    _status = RouteCaptureStatus.starting;
    _changed();
    final stopped = await source.stop();
    if (!_current(operation) || !_foreground) return;
    if (stopped == RouteCaptureStatus.stopUnconfirmed) {
      _status = stopped;
      _changed();
      return;
    }
    // A permission prompt must not prevent stop/back reaching native code.
    unawaited(
      source.start(routeId: 'capture-trial', routeVersion: 1).then((status) {
        if (!_current(operation) || !_foreground) return;
        _status = status;
        _running = status == RouteCaptureStatus.running;
        _changed();
      }),
    );
  }

  Future<void> capture() async {
    if (!canCapture) return;
    final operation = _operation;
    _capturing = true;
    _keyframe = null;
    _changed();
    final result = await source.capture();
    if (!_current(operation) || !_foreground) return;
    _capturing = false;
    _status = result.status;
    _keyframe = result.keyframe;
    if ([
      RouteCaptureStatus.paused,
      RouteCaptureStatus.unavailable,
      RouteCaptureStatus.stopUnconfirmed,
    ].contains(result.status)) {
      _running = false;
    }
    _changed();
  }

  Future<void> stop({
    RouteCaptureStatus reason = RouteCaptureStatus.stopped,
  }) async {
    if (_disposed) return;
    final operation = ++_operation;
    _running = false;
    _capturing = false;
    _stopping = true;
    _keyframe = null;
    _status = reason == RouteCaptureStatus.stopped
        ? RouteCaptureStatus.stopping
        : reason;
    _changed();
    final stopped = await source.stop();
    if (!_current(operation)) return;
    _stopping = false;
    _status = stopped == RouteCaptureStatus.stopUnconfirmed ? stopped : reason;
    _changed();
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      unawaited(stop(reason: RouteCaptureStatus.paused));
    } else {
      _changed();
    }
  }

  void _event(RouteCaptureStatus status) {
    if (_disposed || !_foreground) return;
    if ([
      RouteCaptureStatus.paused,
      RouteCaptureStatus.stopped,
      RouteCaptureStatus.permission,
      RouteCaptureStatus.stopUnconfirmed,
      RouteCaptureStatus.unavailable,
      RouteCaptureStatus.failed,
    ].contains(status)) {
      unawaited(stop(reason: status));
    } else if (status == RouteCaptureStatus.running && !_stopping) {
      _running = true;
      _status = status;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _operation++;
    _keyframe = null;
    unawaited(source.stop());
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
