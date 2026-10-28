import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'depth_model.dart';
import 'depth_objects.dart';

abstract class DepthSource {
  Stream<Map<Object?, Object?>> get frames;
  Set<int> get classIds;
  Future<String> start(String session, {bool objects = false});
  Future<void> stop();
}

class PlatformDepthSource implements DepthSource {
  PlatformDepthSource({this.threshold = 0.7});
  final double threshold;
  int _generation = 0;
  Set<int> _classIds = const {};
  @override
  Set<int> get classIds => _classIds;
  static bool get _native =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static const _methods = MethodChannel('hk.pathguide/depth');
  static const _events = EventChannel('hk.pathguide/depth/frames');
  @override
  Stream<Map<Object?, Object?>> get frames => _native
      ? _events.receiveBroadcastStream().map(
          (event) => Map<Object?, Object?>.from(event as Map),
        )
      : Stream<Map<Object?, Object?>>.multi((_) {});
  @override
  Future<String> start(String session, {bool objects = false}) async {
    final generation = ++_generation;
    if (!_native) return 'unsupported';
    Map<String, Object> model = const {};
    if (objects) {
      try {
        model = await prepareDepthModel();
        _classIds = Set.unmodifiable((model['classIds'] as List<int>));
      } catch (_) {
        return 'model';
      }
    }
    if (generation != _generation) return 'paused';
    final value = await _methods.invokeMapMethod<String, Object?>('start', {
      'session': session,
      'objects': objects,
      'threshold': threshold.clamp(0.05, 0.95),
      ...model,
    });
    return value?['status'] as String? ?? 'failed';
  }

  @override
  Future<void> stop() async {
    ++_generation;
    if (_native) await _methods.invokeMethod<void>('stop');
  }
}

/// Values are always withdrawn on invalid input, stop, silence or interruption.
/// A stable patch is not a verified object distance or a clear walking route.
class DepthSession extends ChangeNotifier {
  DepthSession(this.source);
  final DepthSource source;
  StreamSubscription<Map<Object?, Object?>>? _subscription;
  Timer? _expiry;
  int _generation = 0;
  String _token = '';
  bool _disposed = false;
  Future<void> _operations = Future.value();
  final _window = <({double time, double range})>[];
  final _objects = DepthObjects();
  List<DepthObject> get objects => _objects.snapshot;
  bool objectsEnabled = false;
  String? _viewport;
  double? _lastTimestamp;
  String status = 'idle';
  bool running = false;
  double? rangeM, planeZM;
  int accepted = 0, total = 0;
  double? spreadM;

  void _clear(String next) {
    status = next;
    rangeM = planeZM = spreadM = null;
    accepted = total = 0;
    _window.clear();
    _objects.clear();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() task) {
    final next = _operations.then((_) => task());
    _operations = next.catchError((Object _) {});
    return next;
  }

  Future<void> start({bool recognizeObjects = false}) async {
    if (_disposed) return;
    final generation = ++_generation;
    _token = '$generation-${DateTime.now().microsecondsSinceEpoch}';
    final token = _token;
    objectsEnabled = recognizeObjects;
    _viewport = null;
    running = true;
    _expiry?.cancel();
    _lastTimestamp = null;
    _clear('starting');
    _changed();
    await _enqueue(() async {
      await _subscription?.cancel();
      _subscription = null;
      await source.stop();
      if (_disposed || generation != _generation) return;
      _subscription = source.frames.listen(
        (event) {
          if (generation == _generation) _onFrame(event);
        },
        onError: (Object _) => _fail(generation),
        onDone: () => _fail(generation),
      );
      // Issuing start is ordered, but the permission dialog must not block
      // a later stop from reaching native code when this page is left.
      unawaited(
        source
            .start(token, objects: recognizeObjects)
            .then((result) {
              if (_disposed || generation != _generation) return;
              if (result != 'running') {
                running = false;
                _clear(result);
              } else if (status == 'starting') {
                status = 'waiting';
                _armExpiry();
              }
              _changed();
            })
            .catchError((Object _) => _fail(generation)),
      );
    }).catchError((Object _) => _fail(generation));
  }

  void _fail(int generation) {
    if (_disposed || generation != _generation) return;
    unawaited(stop(reason: 'failed'));
  }

  void _armExpiry() {
    _expiry?.cancel();
    _expiry = Timer(const Duration(milliseconds: 800), () {
      if (_disposed || !running) return;
      _clear('stale');
      _changed();
    });
  }

  void _onFrame(Map<Object?, Object?> event) {
    if (_disposed || !running || event['session'] != _token) return;
    final state = event['status'];
    if (const ['paused', 'interrupted', 'failed'].contains(state)) {
      unawaited(stop(reason: state as String));
      return;
    }
    double? number(String key) {
      final v = event[key];
      return v is num && v.toDouble().isFinite ? v.toDouble() : null;
    }

    final time = number('timestamp'), age = number('ageMs');
    if (time == null ||
        time < 0 ||
        age == null ||
        age < 0 ||
        age > 350 ||
        (_lastTimestamp != null && time <= _lastTimestamp!)) {
      _clear('stale');
      _changed();
      return;
    }
    _lastTimestamp = time;
    _armExpiry();
    if (state == 'objects' && objectsEnabled) {
      final width = number('viewWidth'), height = number('viewHeight');
      final rotation = event['rotation'];
      if (width == null ||
          height == null ||
          width <= 0 ||
          height <= 0 ||
          !const [0, 90, 180, 270].contains(rotation)) {
        _clear('unreliable');
        _changed();
        return;
      }
      final viewport = '$width/$height/$rotation';
      if (_viewport != viewport) _objects.clear();
      _viewport = viewport;
      if (!_objects.update(
        event['objects'],
        time,
        acceptedIds: source.classIds,
      )) {
        _clear('unreliable');
      } else {
        status = objects.isEmpty ? 'noObjects' : 'objectsReady';
      }
      _changed();
      return;
    }
    if (state == 'sample' && objectsEnabled) {
      _clear('unreliable');
      _changed();
      return;
    }
    if (state != 'sample') {
      _clear(
        const [
              'tracking',
              'moving',
              'unavailable',
              'unreliable',
              'stale',
            ].contains(state)
            ? state as String
            : 'unavailable',
      );
      _changed();
      return;
    }
    final range = number('rangeM'), z = number('planeZM');
    final count = number('accepted'),
        all = number('total'),
        spread = number('spreadM');
    if (range == null ||
        z == null ||
        range < 0.2 ||
        range > 4 ||
        z < 0.2 ||
        z > range ||
        count == null ||
        all == null ||
        count != count.roundToDouble() ||
        all != all.roundToDouble() ||
        all < 25 ||
        count > all ||
        count / all < 0.56 ||
        spread == null ||
        spread < 0 ||
        spread > (z * 0.08).clamp(0.1, double.infinity)) {
      _clear('unreliable');
      _changed();
      return;
    }
    _window.removeWhere((value) => time - value.time > 0.7);
    // A discontinuity begins a new window; never blend different surfaces.
    if (_window.any(
      (value) =>
          (value.range - range).abs() >
          (range * 0.05).clamp(0.08, double.infinity),
    )) {
      _window.clear();
    }
    _window.add((time: time, range: range));
    if (_window.length > 3) _window.removeAt(0);
    if (_window.length < 3 || time - _window.first.time < 0.2) {
      rangeM = planeZM = spreadM = null;
      accepted = total = 0;
      status = 'stabilizing';
    } else {
      final ranges = _window.map((e) => e.range).toList()..sort();
      rangeM = ranges[1];
      planeZM = z;
      spreadM = spread;
      accepted = count.toInt();
      total = all.toInt();
      status = 'ready';
    }
    _changed();
  }

  Future<void> stop({String reason = 'paused'}) async {
    ++_generation;
    running = false;
    _expiry?.cancel();
    _lastTimestamp = null;
    _clear(reason);
    _changed();
    await _enqueue(() async {
      await _subscription?.cancel();
      _subscription = null;
      await source.stop();
    }).catchError((Object _) {});
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
