#!/usr/bin/env python3
"""Per-image A10 evaluation under the App's one-class-per-anchor settings.

This runs the frozen source PyTorch checkpoint (the source of the shipped
TFLite) with the same float RGB preprocessing and decoder contract used by the
App: 640 bilinear letterbox padded with 114, argmax over class channels,
class-aware NMS at IoU 0.45, maximum 100. It is not an NV12 camera-format test
and not a phone task test; those remain separate evidence.

Coverage filtering follows the frozen source manifests: a prediction outside
an image's annotated class set is neither TP nor FP. Test-split images are
never inferred here.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys

import cv2
import numpy as np
import torch
from ultralytics import YOLO

NAMES = ['person', 'bicycle', 'bin', 'bollard', 'traffic_cone',
         'caution_slippery', 'stairs', 'escalator', 'fence', 'door']
COMPARABLE = ['person', 'bicycle', 'bin', 'bollard', 'traffic_cone',
              'caution_slippery', 'escalator']
NINE_MAP = {'wet_floor_sign': 'caution_slippery'}
CONFS = (0.3, 0.7)
NMS_IOU = 0.45
MAX_DET = 100
MATCH_IOU = 0.5


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def overlap(a, b):
    a = np.asarray(a, np.float32).reshape(-1, 4)
    b = np.asarray(b, np.float32).reshape(-1, 4)
    size = np.maximum(0, np.minimum(a[:, None, 2:], b[None, :, 2:])
                      - np.maximum(a[:, None, :2], b[None, :, :2]))
    inter = size.prod(2)
    area_a = np.maximum(0, a[:, 2:] - a[:, :2]).prod(1)
    area_b = np.maximum(0, b[:, 2:] - b[:, :2]).prod(1)
    return inter / np.maximum(1e-12, area_a[:, None] + area_b[None, :] - inter)


def prepare(path):
    raw = cv2.imread(str(path))
    if raw is None:
        raise ValueError(f'Cannot decode image: {path}')
    rgb = cv2.cvtColor(raw, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
    height, width = rgb.shape[:2]
    scale = min(640 / width, 640 / height)
    sw, sh = round(width * scale), round(height * scale)
    px, py = (640 - sw) // 2, (640 - sh) // 2
    frame = np.full((640, 640, 3), 114 / 255, np.float32)
    frame[py:py + sh, px:px + sw] = cv2.resize(rgb, (sw, sh), interpolation=cv2.INTER_LINEAR)
    return frame.transpose(2, 0, 1), (sw, sh, px, py)


def decode(values, geo):
    sw, sh, px, py = geo
    classes = values[4:].argmax(0)
    scores = values[4:].max(0)
    mask = (scores >= np.float32(0.001)) & (values[2] > 0) & (values[3] > 0)
    xywh = values[:4, mask].T
    cls = classes[mask]
    scores = scores[mask]
    corners = np.concatenate([xywh[:, :2] - xywh[:, 2:] / 2,
                              xywh[:, :2] + xywh[:, 2:] / 2], 1)
    boxes = np.clip((corners - np.array([px, py, px, py], np.float32))
                    / np.array([sw, sh, sw, sh], np.float32), 0, 1)
    good = np.all(boxes[:, 2:] > boxes[:, :2], 1)
    boxes, cls, scores = boxes[good], cls[good], scores[good]
    order = np.argsort(-scores, kind='stable')
    kept = []
    while len(order) and len(kept) < MAX_DET:
        first = order[0]
        kept.append(first)
        rest = order[1:]
        suppress = ((cls[rest] == cls[first])
                    & (overlap(boxes[first:first + 1], boxes[rest])[0] > NMS_IOU))
        order = rest[~suppress]
    kept = np.array(kept, dtype=int)
    return boxes[kept], scores[kept], cls[kept]


def match(pred_boxes, pred_scores, pred_cls, gt_boxes, gt_cls, coverage):
    used = set()
    pairs = []
    pred_boxes = np.asarray(pred_boxes, np.float32).reshape(-1, 4)
    pred_scores = np.asarray(pred_scores, np.float32)
    pred_cls = np.asarray(pred_cls, np.int64)
    order = np.argsort(-pred_scores, kind='stable') if len(pred_scores) else []
    for local in order:
        c = int(pred_cls[local])
        if c not in coverage:
            continue
        candidates = [(float(overlap([pred_boxes[local]], [g])[0, 0]), j)
                      for j, g in enumerate(gt_boxes) if j not in used and int(gt_cls[j]) == c]
        if candidates and max(candidates)[0] >= MATCH_IOU:
            score, j = max(candidates)
            used.add(j)
            pairs.append((local, j, score))
        else:
            pairs.append((local, None, 0.0))
    return pairs, used


def counts_for(image, conf):
    counts = {name: {'tp': 0, 'fp': 0, 'fn': 0, 'gt': 0} for name in NAMES}
    for gt in image['gt']:
        counts[gt['name']]['gt'] += 1
    matched = {m['pred_index']: m['gt_index'] for m in image['matches'][str(conf)]}
    for i, det in enumerate(image['detections']):
        if det['score'] < conf or not det['in_coverage']:
            continue
        counts[det['name']]['tp' if matched.get(i) is not None else 'fp'] += 1
    matched_gt = {j for j in matched.values() if j is not None}
    for j, gt in enumerate(image['gt']):
        if j not in matched_gt:
            counts[gt['name']]['fn'] += 1
    return counts


def finish(total):
    result = {}
    for name, value in total.items():
        result[name] = {
            'tp': value['tp'], 'fp': value['fp'], 'fn': value['fn'],
            'ground_truth': value['gt'],
            'precision': value['tp'] / (value['tp'] + value['fp'])
            if value['tp'] + value['fp'] else None,
            'recall': value['tp'] / value['gt'] if value['gt'] else None,
        }
    return result


def ap50(images, class_id):
    """101-point COCO-style AP50 with one-to-one class-aware matching."""
    records = []
    gt_total = 0
    for image in images:
        gt = [b for b in image['gt'] if b['class_id'] == class_id]
        gt_total += len(gt)
        for det in image['detections']:
            if det['class_id'] == class_id and det.get('in_coverage', True):
                records.append((det['score'], image['id'], det['xyxy'], gt))
    if not gt_total:
        return None
    records.sort(key=lambda x: -x[0])
    matched = {}
    tp, fp = [], []
    for _, image_id, box, gt in records:
        used = matched.setdefault(image_id, set())
        candidates = [(float(overlap([box], [g['xyxy']])[0, 0]), j)
                      for j, g in enumerate(gt) if j not in used]
        if candidates and max(candidates)[0] >= MATCH_IOU:
            used.add(max(candidates)[1])
            tp.append(1)
            fp.append(0)
        else:
            tp.append(0)
            fp.append(1)
    cum_tp = np.cumsum(tp)
    cum_fp = np.cumsum(fp)
    recall = cum_tp / gt_total
    precision = cum_tp / np.maximum(1, cum_tp + cum_fp)
    precision = np.maximum.accumulate(precision[::-1])[::-1]
    values = [float(precision[recall >= level][0]) if np.any(recall >= level) else 0.0
              for level in np.linspace(0, 1, 101)]
    return float(np.mean(values))


def evaluate(model_path, rows, device, label, name_map=None):
    name_map = name_map or {}
    model = YOLO(str(model_path))
    names = [model.names[i] for i in range(len(model.names))]
    canonical = {i: name_map.get(name, name) for i, name in enumerate(names)}
    net = model.model.float().eval().fuse().to(device)
    out_rows = []
    batch_size = 8
    for start in range(0, len(rows), batch_size):
        batch = rows[start:start + batch_size]
        prepared = [prepare(row['path']) for row in batch]
        tensor = torch.from_numpy(np.stack([p[0] for p in prepared])).to(device)
        with torch.inference_mode():
            prediction = net(tensor)
            prediction = (prediction[0] if isinstance(prediction, (tuple, list))
                          else prediction).float().cpu().numpy()
        if not np.isfinite(prediction).all():
            raise ValueError('Non-finite model output')
        for row, raw, (_, geo) in zip(batch, prediction, prepared):
            boxes, scores, classes = decode(raw, geo)
            coverage = set(row['coverage'])
            detections = []
            for box, score, cls in zip(boxes, scores, classes):
                if score < 0.001:
                    continue
                name = canonical.get(int(cls))
                if name not in NAMES:
                    continue
                class_id = NAMES.index(name)
                detections.append({
                    'class_id': class_id, 'name': name, 'score': float(score),
                    'xyxy': [float(x) for x in box],
                    'in_coverage': class_id in coverage,
                })
            gt_boxes = [b['xyxy'] for b in row['boxes']]
            gt_cls = [b['class_id'] for b in row['boxes']]
            matches = {}
            for conf in CONFS:
                selected = [(i, det) for i, det in enumerate(detections)
                            if det['score'] >= conf]
                pairs, _ = match([det['xyxy'] for _, det in selected],
                                 [det['score'] for _, det in selected],
                                 [det['class_id'] for _, det in selected],
                                 gt_boxes, gt_cls, coverage)
                by_local = {local: (j, score) for local, j, score in pairs}
                matches[str(conf)] = [
                    {'pred_index': i, 'gt_index': by_local.get(local, (None, 0.0))[0],
                     'iou': by_local.get(local, (None, 0.0))[1]}
                    for local, (i, _) in enumerate(selected)
                ]
            max_scores = {name: None for name in NAMES}
            for channel, name in canonical.items():
                if name not in max_scores:
                    continue
                value = float(raw[4 + channel].max())
                if max_scores[name] is None or value > max_scores[name]:
                    max_scores[name] = value
            out_rows.append({
                'id': row['id'], 'source': row['source'], 'subsets': row['subsets'],
                'path': row['path'], 'coverage': sorted(coverage),
                'coverage_has': {name: (NAMES.index(name) in coverage) for name in NAMES},
                'gt': [{'index': j, 'class_id': int(c), 'name': NAMES[int(c)],
                        'xyxy': [float(x) for x in b['xyxy']]}
                       for j, (b, c) in enumerate(zip(row['boxes'], gt_cls))],
                'detections': detections,
                'matches': matches,
                'max_scores': max_scores,
            })
        if start % 160 == 0:
            print(label, min(start + batch_size, len(rows)), '/', len(rows), flush=True)
    del net
    if device == 'mps':
        torch.mps.empty_cache()
    return names, out_rows


def subset_rows(rows, subset):
    return [r for r in rows if subset in r['subsets']]


def summarize(rows):
    out = {}
    for subset in ['all_val', 'legacy_val', 'original_oid_val', 'fresh_oid_val',
                   'clean_val', 'clean_legacy_val', 'door_val']:
        selected = subset_rows(rows, subset)
        if not selected:
            continue
        entry = {'images': len(selected)}
        for conf in CONFS:
            total = {name: {'tp': 0, 'fp': 0, 'fn': 0, 'gt': 0} for name in NAMES}
            for image in selected:
                for name, value in counts_for(image, conf).items():
                    for key in ('tp', 'fp', 'fn', 'gt'):
                        total[name][key] += value[key]
            entry[str(conf)] = finish(total)
        entry['ap50'] = {name: ap50(selected, NAMES.index(name)) for name in NAMES}
        out[subset] = entry
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-index', type=Path, required=True)
    parser.add_argument('--fresh-review', type=Path, required=True)
    parser.add_argument('--audit-csv', type=Path, required=True)
    parser.add_argument('--ten-model', type=Path, required=True)
    parser.add_argument('--nine-model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', default='mps')
    parser.add_argument('--limit', type=int, default=0, help='Smoke-test only')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)

    source = json.loads(args.source_index.read_text())
    fresh = json.loads(args.fresh_review.read_text())['records']
    clean = {}
    with args.audit_csv.open() as handle:
        header = handle.readline().strip().split(',')
        for line in handle:
            values = line.rstrip('\n').split(',')
            row = dict(zip(header, (v.strip('"') for v in values)))
            clean[row['id']] = row.get('clean_gate') == 'True'

    rows = []
    for row in source:
        if row['split'] != 'val':
            continue
        coverage = list(row['coverage'])
        subsets = ['all_val', 'legacy_val' if row['source'] == 'legacy-hk9'
                   else 'original_oid_val']
        if 9 in coverage:
            subsets.append('door_val')
        rows.append({'id': row['id'], 'source': row['source'], 'path': row['path'],
                     'boxes': row['boxes'], 'coverage': coverage, 'subsets': subsets})
    for row in fresh:
        if row['split'] != 'val':
            continue
        coverage = list(row['coverage'])
        subsets = ['all_val', 'fresh_oid_val']
        if 9 in coverage:
            subsets.append('door_val')
        rows.append({'id': row['id'], 'source': 'oid-ccby2-fresh', 'path': row['path'],
                     'boxes': row['boxes'], 'coverage': coverage, 'subsets': subsets})
    for row in rows:
        if clean.get(row['id']):
            row['subsets'].append('clean_val')
            if row['source'] == 'legacy-hk9':
                row['subsets'].append('clean_legacy_val')
    if args.limit:
        rows = rows[:args.limit]
    print('ROWS', len(rows), Counter(s for r in rows for s in r['subsets']), flush=True)

    ten_names, ten_rows = evaluate(args.ten_model, rows, args.device, 'ten')
    nine_names, nine_rows = evaluate(args.nine_model, rows, args.device, 'nine', NINE_MAP)
    if ten_names != NAMES:
        raise ValueError(f'Ten-class names differ: {ten_names}')
    for row in nine_rows:
        row['gt'] = [g for g in row['gt'] if g['name'] in COMPARABLE]
        row['detections'] = [d for d in row['detections'] if d['name'] in COMPARABLE]
        row['coverage_has'] = {name: (name in COMPARABLE) for name in NAMES}

    ten_summary = summarize(ten_rows)
    nine_tables = {}
    selected_nine = subset_rows(nine_rows, 'all_val')
    for conf in CONFS:
        total = {name: {'tp': 0, 'fp': 0, 'fn': 0, 'gt': 0} for name in COMPARABLE}
        for image in selected_nine:
            for gt in image['gt']:
                total[gt['name']]['gt'] += 1
            gt = image['gt']
            dets = [d for d in image['detections'] if d['score'] >= conf]
            pairs, used = match([d['xyxy'] for d in dets], [d['score'] for d in dets],
                                [NAMES.index(d['name']) for d in dets],
                                [g['xyxy'] for g in gt],
                                [NAMES.index(g['name']) for g in gt],
                                set(range(len(NAMES))))
            matched = {local for local, j, _ in pairs if j is not None}
            for local, det in enumerate(dets):
                total[det['name']]['tp' if local in matched else 'fp'] += 1
            for j, gt_box in enumerate(gt):
                if j not in used:
                    total[gt_box['name']]['fn'] += 1
        nine_tables[str(conf)] = finish(total)
    nine_summary = {'images': len(selected_nine), **nine_tables,
                    'ap50': {name: ap50(selected_nine, NAMES.index(name))
                             for name in COMPARABLE}}
    comparison = {}
    for name in COMPARABLE:
        comparison[name] = {}
        for conf in CONFS:
            comparison[name][str(conf)] = {
                'ten': ten_summary['all_val'][str(conf)][name],
                'nine': nine_summary[str(conf)][name],
                'clean_ten': (ten_summary.get('clean_val', {}).get(str(conf), {})
                              .get(name)),
            }

    door_images = []
    for row in ten_rows:
        if 'door_val' not in row['subsets']:
            continue
        entry = {'id': row['id'], 'source': row['source'],
                 'gt_doors': sum(1 for g in row['gt'] if g['name'] == 'door'),
                 'max_door_score': row['max_scores']['door']}
        for conf in CONFS:
            entry[str(conf)] = counts_for(row, conf)['door']
        entry['predicted_top'] = sorted(
            [{'name': d['name'], 'score': d['score']} for d in row['detections']],
            key=lambda x: -x['score'])[:3]
        door_images.append(entry)
    person_fence = []
    for row in ten_rows:
        if row['source'] == 'legacy-hk9':
            continue
        entry = {'id': row['id'], 'source': row['source']}
        for name in ('person', 'fence', 'door'):
            entry[name] = {str(conf): counts_for(row, conf)[name] for conf in CONFS}
        person_fence.append(entry)

    report = {
        'status': 'baseline_only_no_candidate_or_weight_change',
        'app_version': '1.4.3+8',
        'model': {
            'ten': {'path': str(args.ten_model), 'sha256': sha256(args.ten_model),
                    'names': ten_names},
            'nine': {'path': str(args.nine_model), 'sha256': sha256(args.nine_model),
                     'names': nine_names},
        },
        'settings': {
            'input': 'independent float RGB half-pixel bilinear 640 letterbox, 114 padding',
            'argmax_before_coverage_filter': True,
            'nms_iou': NMS_IOU, 'maximum': MAX_DET, 'match_iou': MATCH_IOU,
            'confidences': list(CONFS), 'ap': '101-point COCO-style AP50, class-aware',
            'not_nv12_camera_capture': True,
        },
        'subsets': {
            'definition': {
                'all_val': '1,388 fixed validation records plus 15 fresh OID val',
                'legacy_val': 'fixed legacy validation split (leakage audited separately)',
                'original_oid_val': '14 original OID validation door images',
                'fresh_oid_val': '15 frozen fresh OID door images, unseen by training',
                'clean_val': 'validation images with no train pHash group within radius 6',
                'door_val': 'images whose coverage annotates door',
            },
            'counts': {k: len(subset_rows(ten_rows, k)) for k in
                       ['all_val', 'legacy_val', 'original_oid_val', 'fresh_oid_val',
                        'clean_val', 'clean_legacy_val', 'door_val']},
        },
        'ten_class': ten_summary,
        'nine_class_comparable': nine_summary,
        'ten_vs_nine': comparison,
        'door_per_image': door_images,
        'person_fence_per_image': person_fence,
        'limits': [
            'Source PyTorch weights, not a phone capture or TFLite run in this pass.',
            'Legacy validation split contains train near-duplicates; clean_val is a subset, not a re-split.',
            'Door holdout is 29 public images/39 boxes; there is no independent positive fence holdout.',
            'Labels are assistant-reviewed candidates, not independent human adjudication.',
            'Nine-class comparison covers seven exact classes; stairs/fence/door differ by taxonomy.',
            'No test-split inference, no training, no deployment, no quality-gate pass.',
        ],
        'quality_gate_passed': False,
        'deployment_performed': False,
    }
    (args.output / 'evaluation.json').write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    (args.output / 'per-image-ten.json').write_text(json.dumps(ten_rows, indent=1) + '\n')
    (args.output / 'per-image-nine.json').write_text(json.dumps(nine_rows, indent=1) + '\n')
    print(json.dumps({
        'subsets': report['subsets']['counts'],
        'door': ten_summary.get('door_val', {}).get('0.7'),
        'ten': {c: ten_summary['all_val']['0.7'][c] for c in COMPARABLE},
        'nine': nine_summary['0.7'],
    }, indent=2)[:5000])
    print('WROTE', args.output / 'evaluation.json', flush=True)


if __name__ == '__main__':
    main()
