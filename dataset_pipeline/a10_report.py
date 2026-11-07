#!/usr/bin/env python3
"""Aggregate the saved per-image A10 evaluation into a reviewable baseline.

No model inference here. It reuses per-image-ten.json / per-image-nine.json so
the same numbers can be audited without rerunning the network.
"""
import argparse
import json
import math
from collections import Counter
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from a10_evaluate import COMPARABLE, NAMES, ap50, match
from common import source_key

CONFS = (0.3, 0.7)


def rows_for(images, subset):
    return [image for image in images if subset in image['subsets']]


def table(images, conf, classes):
    total = {name: {'tp': 0, 'fp': 0, 'fn': 0, 'gt': 0} for name in classes}
    for image in images:
        gt = [g for g in image['gt'] if g['name'] in classes]
        dets = [d for d in image['detections']
                if d['name'] in classes and d['score'] >= conf]
        pairs, used = match([d['xyxy'] for d in dets], [d['score'] for d in dets],
                            [NAMES.index(d['name']) for d in dets],
                            [g['xyxy'] for g in gt],
                            [NAMES.index(g['name']) for g in gt],
                            set(image['coverage']))
        matched = {local for local, j, _ in pairs if j is not None}
        for name in classes:
            total[name]['gt'] += sum(1 for g in gt if g['name'] == name)
        for local, det in enumerate(dets):
            if det['class_id'] in image['coverage']:
                total[det['name']]['tp' if local in matched else 'fp'] += 1
        for j, gt_box in enumerate(gt):
            if j not in used:
                total[gt_box['name']]['fn'] += 1
    result = {}
    for name, value in total.items():
        tp, fp, fn, gt = value['tp'], value['fp'], value['fn'], value['gt']
        result[name] = {
            'tp': tp, 'fp': fp, 'fn': fn, 'ground_truth': gt,
            'precision': tp / (tp + fp) if tp + fp else None,
            'recall': tp / gt if gt else None,
        }
    return result


def wilson(k, n, z=1.96):
    if not n:
        return None
    p = k / n
    denominator = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denominator
    spread = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denominator
    return [round(max(0, centre - spread), 4), round(min(1, centre + spread), 4)]


def summarize(images, classes):
    out = {}
    for subset in ['all_val', 'legacy_val', 'clean_val', 'clean_legacy_val',
                   'strict_val', 'strict_legacy_val', 'door_val']:
        selected = rows_for(images, subset)
        if not selected:
            continue
        entry = {'images': len(selected)}
        for conf in CONFS:
            entry[str(conf)] = table(selected, conf, classes)
        entry['ap50'] = {name: ap50(selected, NAMES.index(name)) for name in classes}
        out[subset] = entry
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--eval-dir', type=Path, required=True)
    parser.add_argument('--audit-csv', type=Path, required=True)
    parser.add_argument('--source-index', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    ten = json.loads((args.eval_dir / 'per-image-ten.json').read_text())
    nine = json.loads((args.eval_dir / 'per-image-nine.json').read_text())
    clean = {}
    with args.audit_csv.open() as handle:
        for row in __import__('csv').DictReader(handle):
            clean[row['id']] = row['clean_gate'] == 'True'
    source = json.loads(args.source_index.read_text())
    def skey(row):
        return (row['source'], source_key(Path(row['path']).name))
    train_keys = {skey(row) for row in source if row['split'] == 'train'}
    strict = {row['id'] for row in source
              if row['split'] == 'val' and clean.get(row['id']) and skey(row) not in train_keys}
    for image in ten + nine:
        if image['id'] not in clean or not clean[image['id']]:
            continue
        if image['id'] in strict or image['source'] == 'oid-ccby2-fresh':
            image['subsets'].append('strict_val')
            if image['source'] == 'legacy-hk9':
                image['subsets'].append('strict_legacy_val')
    ten_tables = summarize(ten, NAMES)
    nine_tables = summarize(nine, COMPARABLE)

    door = ten_tables['door_val']['0.7']['door']
    person = ten_tables['clean_val']['0.7']['person']
    scores = []
    for image in rows_for(ten, 'door_val'):
        scores.append({'id': image['id'], 'max': image['max_scores']['door'],
                       'gt': sum(1 for g in image['gt'] if g['name'] == 'door')})
    bins = Counter()
    for item in scores:
        if not item['gt']:
            continue
        value = item['max'] or 0
        key = ('0.0-0.3' if value < 0.3 else '0.3-0.5' if value < 0.5
               else '0.5-0.7' if value < 0.7 else '0.7-1.0')
        bins[key] += 1

    fence_coverage = [image for image in ten
                      if image['coverage_has']['fence']]
    fence_gt = sum(1 for image in fence_coverage for g in image['gt'] if g['name'] == 'fence')
    fence_pred = {conf: sum(1 for image in fence_coverage for d in image['detections']
                            if d['name'] == 'fence' and d['score'] >= conf)
                  for conf in CONFS}

    comparison = {}
    for subset in ['all_val', 'clean_val', 'strict_val', 'legacy_val', 'clean_legacy_val']:
        if subset not in ten_tables or subset not in nine_tables:
            continue
        comparison[subset] = {}
        for name in COMPARABLE:
            comparison[subset][name] = {
                'ten': {'p': ten_tables[subset]['0.7'][name]['precision'],
                        'r': ten_tables[subset]['0.7'][name]['recall'],
                        'ap50': ten_tables[subset]['ap50'][name]},
                'nine': {'p': nine_tables[subset]['0.7'][name]['precision'],
                         'r': nine_tables[subset]['0.7'][name]['recall'],
                         'ap50': nine_tables[subset]['ap50'][name]},
            }

    report = {
        'ten_class': ten_tables,
        'nine_class_comparable': nine_tables,
        'ten_vs_nine': comparison,
        'fence_support': {
            'val_images_with_fence_coverage': len(fence_coverage),
            'val_fence_positive_boxes': fence_gt,
            'fence_predictions': fence_pred,
            'recall_measurable': bool(fence_gt),
        },
        'door_score_distribution_gt_images': dict(bins),
        'door_gt_images': sum(1 for item in scores if item['gt']),
        'door_gt_boxes': sum(item['gt'] for item in scores),
        'confidence_intervals': {
            'door_precision_0.7': wilson(door['tp'], door['tp'] + door['fp']),
            'door_recall_0.7': wilson(door['tp'], door['ground_truth']),
            'person_precision_0.7_clean': wilson(person['tp'], person['tp'] + person['fp']),
            'person_recall_0.7_clean': wilson(person['tp'], person['ground_truth']),
        },
        'score_bins': {k: int(v) for k, v in sorted(bins.items())},
        'limits': [
            'Door is 29 images/39 boxes; intervals are wide.',
            'Fence recall is not measurable: no positive fence box exists in validation.',
            'Nine-class model has no fence/door/stairs; seven classes only.',
            'Legacy validation includes train near-duplicates; clean subset is 1,095 legacy images.',
            'No test inference, phone capture, training or deployment.',
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({
        'door': door,
        'person_clean': person,
        'fence': report['fence_support'],
        'score_bins': report['score_bins'],
        'ci': report['confidence_intervals'],
        'nine_clean': {c: nine_tables['clean_val']['ap50'][c] for c in COMPARABLE},
    }, indent=2))
    print('WROTE', args.output)


if __name__ == '__main__':
    main()
