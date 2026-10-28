import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/vision/detection.dart';
import 'package:pathguide/vision/result_summary.dart';

Detection box(int id, double score) =>
    Detection(id: id, score: score, cx: .5, cy: .5, w: .2, h: .2);

void main() {
  test('empty or low confidence never becomes a safety statement', () {
    expect(resultSummary([box(7, .4)], minScore: .7), '暫未辨識到支援的物件');
    expect(resultSummary([], minScore: .7), '暫未辨識到支援的物件');
  });

  test('deduplicates classes and rejects unknown or invalid scores', () {
    expect(
      resultSummary([
        box(7, .9),
        box(7, .8),
        box(9999, .99),
        box(11, 1.5),
        box(11, double.nan),
      ], minScore: .7),
      '辨識到：垃圾桶',
    );
  });

  test('simulation is identified and no distance or direction is inferred', () {
    expect(
      resultSummary([box(49, .9)], minScore: .7, simulated: true),
      '模擬結果：辨識到：扶手電梯',
    );
  });
}
