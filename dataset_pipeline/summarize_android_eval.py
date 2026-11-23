"""彙總 android_pipeline_eval.py 的輸出：逐類 P／R（含 95% Wilson 區間）、新舊管線對照、
跨類重複框，以及按「精確率 ≥ 目標」挑出的逐類候選門檻（只作建議，不改 App）。

用法：python dataset_pipeline/summarize_android_eval.py <eval.json> [--target-precision 0.8]
"""
import argparse
import json
import math
from pathlib import Path


def wilson(k, n, z=1.96):
    if n == 0:
        return None
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [round(c - h, 3), round(c + h, 3)]


def iou(a, b):
    x1, y1, x2, y2 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    i = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i
    return i / u if u > 0 else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('eval_json', type=Path)
    ap.add_argument('--target-precision', type=float, default=0.80)
    args = ap.parse_args()
    d = json.loads(args.eval_json.read_text(encoding='utf-8'))
    S, classes, ts = d['summary'], d['dataset']['covered_classes'], [str(t) for t in d['thresholds']]

    per_class = {}
    for c in classes:
        rows = {}
        for t in ts:
            r = S['android'][t][c]
            rows[t] = {'tp': r['tp'], 'fp': r['fp'], 'fn': r['fn'],
                       'precision': r['precision'], 'p95ci': wilson(r['tp'], r['tp'] + r['fp']),
                       'recall': r['recall'], 'r95ci': wilson(r['tp'], r['tp'] + r['fn'])}
        cand = next((t for t in ts if rows[t]['p95ci'] and rows[t]['p95ci'][0] >= args.target_precision), None)
        per_class[c] = {'by_threshold': rows,
                        'candidate_threshold': cand,
                        'candidate_rule': f'lowest threshold whose precision 95% lower bound >= {args.target_precision}'}

    compare = {t: {p: S[p][t]['_all'] for p in ('legacy', 'android', 'offline')} for t in ('0.3', '0.5', '0.7')}

    dup = {t: 0 for t in ('0.5', '0.7')}
    pairs = {}
    for im in d['images']:
        for t in dup:
            dets = [x for x in im['android'] if x['score'] >= float(t)]
            for i, a in enumerate(dets):
                for b in dets[i + 1:]:
                    if a['name'] != b['name'] and iou(a['xyxy'], b['xyxy']) > 0.7:
                        dup[t] += 1
                        if t == '0.5':
                            k = '/'.join(sorted((a['name'], b['name'])))
                            pairs[k] = pairs.get(k, 0) + 1

    out = {'per_class_android': per_class, 'pipelines_all_classes': compare,
           'cross_class_duplicates_iou_gt_0_7': dup, 'duplicate_pairs_at_0_5': pairs}
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
