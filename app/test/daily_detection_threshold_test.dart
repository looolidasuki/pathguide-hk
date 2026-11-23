// 日常辨識的逐類門檻：行人 0.80，其他沿用播報門檻（取兩者較高者）。
// 依據：verification/android-oid-test-eval-20261123.json（獨立 Open Images test 評估）。

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/ui/demo_page.dart';
import 'package:pathguide/vision/detection.dart';

Detection _det(int id, double score) =>
    Detection(id: id, score: score, cx: 0.5, cy: 0.5, w: 0.2, h: 0.2);

void main() {
  const person = 6, bin = 7, door = 18;

  test(
    'daily mode needs 0.80 for pedestrians and the speech threshold for others',
    () {
      final kept = dailyDetections(
        [
          _det(person, 0.75),
          _det(person, 0.82),
          _det(bin, 0.72),
          _det(door, 0.69),
        ],
        developerControls: false,
        speakThreshold: 0.70,
      );
      expect(kept.map((d) => (d.id, d.score)), [(person, 0.82), (bin, 0.72)]);
    },
  );

  test('a higher speech threshold still applies to pedestrians', () {
    final kept = dailyDetections(
      [_det(person, 0.85), _det(person, 0.92)],
      developerControls: false,
      speakThreshold: 0.90,
    );
    expect(kept.single.score, 0.92);
  });

  test('a lower speech threshold does not lower the pedestrian floor', () {
    final kept = dailyDetections(
      [_det(person, 0.60), _det(bin, 0.55)],
      developerControls: false,
      speakThreshold: 0.50,
    );
    expect(kept.map((d) => d.id), [bin]);
  });

  test('developer diagnostics keep every detection for comparison', () {
    final raw = [_det(person, 0.40), _det(door, 0.31)];
    expect(
      dailyDetections(raw, developerControls: true, speakThreshold: 0.70),
      same(raw),
    );
  });

  test('the pedestrian floor is the documented evidence value', () {
    expect(kDailyClassMinScore, {person: 0.80});
  });
}
