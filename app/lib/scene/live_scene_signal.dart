import 'dart:math' as math;

/// Ephemeral camera luminance and device attitude; never stored or uploaded.
class LiveSceneSignal {
  LiveSceneSignal({
    required this.sequence,
    required this.luma,
    required this.attitude,
    required this.rotationRate,
  });
  final int sequence;
  final List<int> luma;
  final List<double> attitude;
  final double rotationRate;

  static LiveSceneSignal? parse(Object? value) {
    if (value is! Map) return null;
    final seq = value['sequence'],
        grid = value['luma'],
        q = value['attitude'],
        rate = value['rotationRate'];
    if (seq is! int ||
        seq < 1 ||
        grid is! List ||
        grid.length != 64 ||
        grid.any((v) => v is! int || v < 0 || v > 255) ||
        q is! List ||
        q.length != 4 ||
        q.any((v) => v is! num || !v.isFinite) ||
        rate is! num ||
        !rate.isFinite ||
        rate < 0 ||
        value['motionFresh'] != true) {
      return null;
    }
    final quaternion = q.map((v) => (v as num).toDouble()).toList();
    final norm = quaternion.fold<double>(0, (a, v) => a + v * v);
    if ((norm - 1).abs() > 0.02) return null;
    return LiveSceneSignal(
      sequence: seq,
      luma: List<int>.from(grid),
      attitude: quaternion,
      rotationRate: rate.toDouble(),
    );
  }

  double difference(LiveSceneSignal other) {
    var total = 0;
    for (var i = 0; i < 64; i++) {
      total += (luma[i] - other.luma[i]).abs();
    }
    return total / (64 * 255);
  }

  /// Remove uniform exposure changes before treating a frame as a candidate.
  /// This is a visual candidate measure, not evidence of semantic novelty.
  double structuralDifference(LiveSceneSignal other) {
    final offsets = List.generate(64, (i) => luma[i] - other.luma[i]);
    final mean = offsets.reduce((a, b) => a + b) / 64;
    return offsets.fold<double>(0, (sum, v) => sum + (v - mean).abs()) /
        (64 * 255);
  }

  double angle(LiveSceneSignal other) {
    var dot = 0.0;
    for (var i = 0; i < 4; i++) {
      dot += attitude[i] * other.attitude[i];
    }
    return 2 * math.acos(dot.abs().clamp(0.0, 1.0)) * 180 / math.pi;
  }
}

class LiveSceneUpdate {
  LiveSceneUpdate(this.signal, this.issue);
  final LiveSceneSignal? signal;
  final String? issue;
  static LiveSceneUpdate parse(Map value) {
    final issue = value['issue'];
    return LiveSceneUpdate(
      LiveSceneSignal.parse(value),
      const [
            'waiting-motion',
            'motion-stale',
            'motion-unavailable',
          ].contains(issue)
          ? issue as String
          : null,
    );
  }
}
