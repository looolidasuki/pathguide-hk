import 'dart:ui' show Rect, Offset;

String depthReasonText(String reason, {required bool english}) =>
    switch (reason) {
      'ready' => english ? 'Local surface confirmed' : '局部表面已確認',
      'stabilizing' =>
        english ? 'Waiting for three consistent observations' : '等待三筆一致觀察',
      'sampling_changed' =>
        english ? 'Sample point changed; confirming again' : '取樣點改變，重新確認',
      'association' => english ? 'Object association is ambiguous' : '物件對照有歧義',
      'overlap' =>
        english ? 'Sample area covered by another object' : '取樣區被其他物件遮擋',
      'small' =>
        english ? 'Box too small for 25 distinct depth pixels' : '框太細，深度像素不足',
      'low_depth' =>
        english ? 'Insufficient high-confidence depth in range' : '量程內高信心深度不足',
      'mixed_depth' =>
        english ? 'Local surface depths are inconsistent' : '局部表面深度不一致',
      'out_of_range' =>
        english ? 'Surface outside trial measurement range' : '表面超出試驗量程',
      'depth_missing' =>
        english ? 'No scene depth or confidence map' : '未收到場景深度或可信度圖',
      'depth_format' =>
        english ? 'Depth format or intrinsics unavailable' : '深度格式或相機內參不可用',
      _ => english ? 'Surface depth not reliable' : '表面深度未能確認',
    };

class DepthObject {
  const DepthObject({
    required this.trackId,
    required this.classId,
    required this.score,
    required this.box,
    required this.reason,
    this.rangeM,
    this.samplePoint,
    this.validDepth,
    this.depthTotal,
  });
  final int trackId, classId;
  final double score;
  final Rect box;
  final double? rangeM;
  final String reason;
  final Offset? samplePoint;
  final int? validDepth, depthTotal;
}

double _iou(Rect a, Rect b) {
  final intersection = a.intersect(b);
  if (intersection.isEmpty) return 0;
  final area = intersection.width * intersection.height;
  return area / (a.width * a.height + b.width * b.height - area);
}

double? _number(Object? value) =>
    value is num && value.toDouble().isFinite ? value.toDouble() : null;

class _Observation {
  _Observation(
    this.id,
    this.score,
    this.box,
    this.range,
    this.reason,
    this.samplePoint,
    this.validDepth,
    this.depthTotal,
  );
  final int id;
  final double score;
  final Rect box;
  final double? range;
  final String reason;
  final Offset? samplePoint;
  final int? validDepth, depthTotal;
  static _Observation? parse(Object? raw, Set<int> acceptedIds) {
    if (raw is! Map || raw['id'] is! int || !acceptedIds.contains(raw['id'])) {
      return null;
    }
    final score = _number(raw['score']);
    final coordinates = raw['box'];
    if (score == null ||
        score < 0.05 ||
        score > 1 ||
        coordinates is! List ||
        coordinates.length != 4) {
      return null;
    }
    final values = coordinates.map(_number).toList();
    if (values.any((v) => v == null)) return null;
    final box = Rect.fromLTWH(values[0]!, values[1]!, values[2]!, values[3]!);
    if (box.left < 0 ||
        box.top < 0 ||
        box.right > 1.000001 ||
        box.bottom > 1.000001 ||
        box.isEmpty) {
      return null;
    }
    final range = _number(raw['rangeM']), z = _number(raw['planeZM']);
    final count = _number(raw['accepted']),
        total = _number(raw['total']),
        spread = _number(raw['spreadM']);
    final valid =
        raw['reason'] == 'sample' &&
        range != null &&
        z != null &&
        range >= 0.2 &&
        range <= 4 &&
        z >= 0.2 &&
        z <= range &&
        count != null &&
        count == count.roundToDouble() &&
        count >= 15 &&
        count <= 25 &&
        total == 25 &&
        spread != null &&
        spread >= 0 &&
        spread <= (z * 0.08).clamp(0.1, double.infinity);
    Offset? point;
    final rawPoint = raw['samplePoint'];
    if (rawPoint is List && rawPoint.length == 2) {
      final x = _number(rawPoint[0]), y = _number(rawPoint[1]);
      if (x != null &&
          y != null &&
          x >= 0 &&
          x <= 1 &&
          y >= 0 &&
          y <= 1 &&
          box.inflate(0.000001).contains(Offset(x, y))) {
        point = Offset(x, y);
      }
    }
    final depthValid = raw['validDepth'], depthTotal = raw['depthTotal'];
    final countsValid =
        depthValid is int &&
        depthTotal == 25 &&
        depthValid >= 0 &&
        depthValid <= 25;
    final reason = raw['reason'];
    final validRange = valid && (rawPoint == null || point != null);
    return _Observation(
      raw['id'] as int,
      score,
      box,
      validRange ? range : null,
      validRange
          ? 'sample'
          : const [
              'overlap',
              'small',
              'low_depth',
              'mixed_depth',
              'out_of_range',
              'depth_missing',
              'depth_format',
            ].contains(reason)
          ? reason as String
          : 'unreliable',
      point,
      countsValid ? depthValid : null,
      countsValid ? 25 : null,
    );
  }
}

class _Track {
  _Track(this.id, this.observation, this.time, this.history);
  final int id;
  final _Observation observation;
  final double time;
  final List<({double time, double range})> history;
}

/// Short image-space association, not persistent 3D identity tracking.
/// Disappearing, ambiguous or invalid observations cannot retain old ranges.
class DepthObjects {
  int _nextId = 0;
  List<_Track> _tracks = [];
  List<DepthObject> _snapshot = const [];
  List<DepthObject> get snapshot => _snapshot;
  void clear() {
    _tracks = [];
    _snapshot = const [];
  }

  bool update(Object? raw, double time, {required Set<int> acceptedIds}) {
    if (raw is! List || raw.length > 5) {
      clear();
      return false;
    }
    final parsed = raw
        .map((value) => _Observation.parse(value, acceptedIds))
        .toList();
    if (parsed.any((e) => e == null)) {
      clear();
      return false;
    }
    final observations = parsed.cast<_Observation>();
    bool matches(_Track previous, _Observation current) =>
        current.id == previous.observation.id &&
        time - previous.time <= 0.7 &&
        _iou(current.box, previous.observation.box) >= 0.45;
    final next = <_Track>[], outputs = <DepthObject>[];
    for (final observation in observations) {
      final candidates = _tracks
          .where((old) => matches(old, observation))
          .toList();
      final previous =
          candidates.length == 1 &&
              observations
                      .where((current) => matches(candidates.single, current))
                      .length ==
                  1
          ? candidates.single
          : null;
      final history =
          previous?.history.where((item) => time - item.time <= 0.7).toList() ??
          <({double time, double range})>[];
      double? range;
      bool sampleChanged = false;
      if (previous?.observation.samplePoint != null &&
          observation.samplePoint != null) {
        Offset relative(_Observation value) => Offset(
          (value.samplePoint!.dx - value.box.left) / value.box.width,
          (value.samplePoint!.dy - value.box.top) / value.box.height,
        );
        sampleChanged =
            (relative(previous!.observation) - relative(observation)).distance >
            0.12;
        if (sampleChanged) history.clear();
      }
      if (observation.range == null) {
        history.clear();
      } else {
        final value = observation.range!;
        if (history.any(
          (item) =>
              (item.range - value).abs() >
              (value * 0.05).clamp(0.08, double.infinity),
        )) {
          history.clear();
        }
        history.add((time: time, range: value));
        if (history.length > 3) history.removeAt(0);
        if (history.length == 3 && time - history.first.time >= 0.2) {
          final values = history.map((item) => item.range).toList()..sort();
          range = values[1];
        }
      }
      final id = previous?.id ?? ++_nextId;
      next.add(_Track(id, observation, time, history));
      outputs.add(
        DepthObject(
          trackId: id,
          classId: observation.id,
          score: observation.score,
          box: observation.box,
          rangeM: range,
          samplePoint: observation.samplePoint,
          validDepth: observation.validDepth,
          depthTotal: observation.depthTotal,
          reason: range != null
              ? 'ready'
              : observation.range == null
              ? observation.reason
              : sampleChanged
              ? 'sampling_changed'
              : candidates.isNotEmpty && previous == null
              ? 'association'
              : 'stabilizing',
        ),
      );
    }
    _tracks = next;
    _snapshot = List.unmodifiable(outputs);
    return true;
  }
}
