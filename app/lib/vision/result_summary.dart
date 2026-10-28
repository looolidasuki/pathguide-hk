import 'detection.dart';
import 'labels.dart';

/// Describe only supported, sufficiently confident classes. No distance,
/// escalator direction, safety or instance-count inference comes from boxes.
String resultSummary(
  List<Detection> detections, {
  required double minScore,
  bool simulated = false,
}) {
  final labels = <int, Label>{};
  for (final detection in detections) {
    final label = labelOf(detection.id);
    if (label != null &&
        label.announced &&
        detection.score.isFinite &&
        detection.score <= 1 &&
        detection.score >= minScore) {
      labels[label.id] = label;
    }
  }
  final sorted = labels.values.toList()
    ..sort((a, b) {
      final priority = a.priority.compareTo(b.priority);
      return priority == 0 ? a.id.compareTo(b.id) : priority;
    });
  final prefix = simulated ? '模擬結果：' : '';
  if (sorted.isEmpty) return '$prefix暫未辨識到支援的物件';
  return '$prefix辨識到：${sorted.map((label) => label.nameZh).join('、')}';
}
