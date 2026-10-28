import 'dart:async';

import 'package:pathguide/depth/depth_session.dart';

class FakeDepthSource implements DepthSource {
  @override
  Set<int> get classIds => const {1, 6, 7, 18};
  final events = StreamController<Map<Object?, Object?>>.broadcast(sync: true);
  String? token;
  int starts = 0, stops = 0;
  bool lastObjects = false;
  String result = 'running';
  Completer<String>? pendingStart;
  @override
  Stream<Map<Object?, Object?>> get frames => events.stream;
  @override
  Future<String> start(String session, {bool objects = false}) async {
    token = session;
    lastObjects = objects;
    starts++;
    return pendingStart == null ? result : pendingStart!.future;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  void sample(
    double time, {
    double range = 2,
    String state = 'sample',
    Map<Object?, Object?> extra = const {},
  }) {
    events.add({
      'session': token,
      'timestamp': time,
      'ageMs': 20,
      'status': state,
      'rangeM': range,
      'planeZM': range * 0.99,
      'accepted': 25,
      'total': 25,
      'spreadM': 0.02,
      ...extra,
    });
  }

  void stable({double time = 1, double range = 2}) {
    for (var i = 0; i < 3; i++) {
      sample(time + i * 0.15, range: range);
    }
  }

  static Map<String, Object> object({
    int id = 7,
    double range = 2,
    List<double> box = const [.1, .2, .2, .5],
    bool known = true,
  }) => {
    'id': id,
    'score': .9,
    'box': box,
    'reason': known ? 'sample' : 'overlap',
    if (known) ...{
      'rangeM': range,
      'planeZM': range * .99,
      'accepted': 25,
      'total': 25,
      'spreadM': .02,
    },
  };
  void objectFrame(
    double time,
    List<Map<String, Object>> values, {
    Map<Object?, Object?> extra = const {},
  }) {
    sample(
      time,
      state: 'objects',
      extra: {
        'objects': values,
        'viewWidth': 358,
        'viewHeight': 220,
        'rotation': 90,
        ...extra,
      },
    );
  }
}
