#!/usr/bin/env python3
"""A10 trusted-baseline audit: source/split composition, near-duplicate groups,
leakage from train into validation, and per-class ground-truth support.

This is a *candidate* grouping audit, not human scene verification. A pHash
match can be a visually similar scene rather than the same photograph. The
report therefore keeps exact-byte groups, near-duplicate candidates and
same-video/source candidates separate, and exposes the threshold used.

Inputs are the recovered frozen source index (12,346 rows), the 15+27 fresh
Open Images door records, and their images. Original labels are never changed.
"""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
import hashlib
import io
import json
import math
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import BKTree, UnionFind, json_write, parse_label, source_key, video_key

NAMES = ['person', 'bicycle', 'bin', 'bollard', 'traffic_cone',
         'caution_slippery', 'stairs', 'escalator', 'fence', 'door']

N = np.arange(32)
DCT = np.cos(np.pi * (2 * N[None, :] + 1) * N[:, None] / 64)
DCT[0] *= 1 / np.sqrt(2)


def image_features(row):
    path = Path(row['path'])
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    with Image.open(io.BytesIO(raw)) as image:
        image.load()
        orientation = int(image.getexif().get(274, 1))
        width, height = image.size
        rgb = ImageOps.exif_transpose(image).convert('RGB')
        if rgb.size != (width, height):
            width, height = rgb.size
        gray = np.asarray(rgb.convert('L').resize((32, 32), Image.Resampling.LANCZOS),
                          dtype=np.float64)
    low = (DCT @ gray @ DCT.T)[:8, :8].flatten()
    bits = low > np.median(low[1:])
    bits[0] = False
    phash = sum(int(bit) << i for i, bit in enumerate(bits))
    return {'id': row['id'], 'sha256': digest, 'phash': f'{phash:016x}',
            'width': width, 'height': height, 'exif_orientation': orientation,
            'sha_matches_record': digest == row['image_sha256']}


def load_rows(args):
    rows = json.loads(Path(args.source_index).read_text())
    fresh = json.loads(Path(args.fresh_review).read_text())['records']
    records = []
    for row in rows:
        records.append({
            'id': row['id'], 'source': row['source'], 'split': row['split'],
            'path': row['path'], 'image_sha256': row['image_sha256'],
            'boxes': row['boxes'], 'coverage': list(row['coverage']),
            'sampling_repeats': row.get('sampling_repeats', 1),
            'group_id': row.get('group_id'), 'fresh': False,
        })
    for row in fresh:
        records.append({
            'id': row['id'], 'source': 'oid-ccby2-fresh', 'split': row['split'],
            'path': row['path'], 'image_sha256': row['image_sha256'],
            'boxes': row['boxes'], 'coverage': list(row['coverage']),
            'sampling_repeats': 1, 'group_id': row.get('group_id'),
            'author': row.get('author'), 'fresh': True,
        })
    return records


def compute_features(records, workers):
    payload = [{'id': r['id'], 'path': r['path'], 'image_sha256': r['image_sha256']}
               for r in records]
    if workers <= 1:
        results = [image_features(r) for r in payload]
    else:
        with ProcessPoolExecutor(max_workers=workers) as pool:
            results = list(pool.map(image_features, payload, chunksize=32))
    by_id = {r['id']: r for r in results}
    for record in records:
        feat = by_id[record['id']]
        record.update({k: v for k, v in feat.items() if k != 'id'})
    return records


def hamming_min(values, target):
    return int(np.bitwise_count(values ^ np.uint64(target)).min())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-index', type=Path, required=True)
    parser.add_argument('--fresh-review', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--workers', type=int, default=8)
    parser.add_argument('--near-radius', type=int, default=6,
                        help='Hamming radius for candidate near-duplicate pairs')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    records = load_rows(args)
    print(f'LOADED {len(records)} records; reading {args.workers} workers', flush=True)
    records = compute_features(records, args.workers)
    bad_sha = [r['id'] for r in records if not r['sha_matches_record']]
    if bad_sha:
        raise SystemExit(f'Source SHA mismatch: {bad_sha[:5]} ({len(bad_sha)})')

    by_id = {r['id']: r for r in records}
    index = {r['id']: i for i, r in enumerate(records)}
    uf = UnionFind(len(records))

    # Exact byte identity.
    exact = defaultdict(list)
    for i, r in enumerate(records):
        exact[r['sha256']].append(i)
    exact_groups = {k: v for k, v in exact.items() if len(v) > 1}
    for members in exact_groups.values():
        for i in members[1:]:
            uf.union(members[0], i)

    # Perceptual-hash near duplicates. Same pHash is also exact here.
    tree = BKTree()
    pairs = []
    for i, r in enumerate(records):
        value = int(r['phash'], 16)
        for other, distance in tree.query(value, args.near_radius):
            pairs.append((i, other, distance))
            uf.union(i, other)
        tree.add(value, i)

    # Same-video / same-source filename candidates. These are separate signals,
    # not proof, and are only unioned within the same source dataset.
    filename_groups = defaultdict(list)
    for i, r in enumerate(records):
        name = Path(r['path']).name
        skey = source_key(name)
        if skey:
            filename_groups[('source', r['source'], skey)].append(i)
        vkey = video_key(name)
        if vkey:
            filename_groups[('video', r['source'], vkey)].append(i)
    filename_groups = {k: v for k, v in filename_groups.items() if len(v) > 1}
    for members in filename_groups.values():
        for i in members[1:]:
            uf.union(members[0], i)

    # Fresh author groups were allocated as connected groups before review.
    author_groups = defaultdict(list)
    for i, r in enumerate(records):
        if r.get('author'):
            author_groups[r['author']].append(i)
    author_groups = {k: v for k, v in author_groups.items() if len(v) > 1}
    for members in author_groups.values():
        for i in members[1:]:
            uf.union(members[0], i)

    groups = defaultdict(list)
    for i in range(len(records)):
        groups[uf.find(i)].append(i)
    group_list = []
    for root, members in groups.items():
        if len(members) < 2:
            continue
        rows = [records[i] for i in members]
        group_list.append({
            'splits': sorted({r['split'] for r in rows}),
            'sources': sorted({r['source'] for r in rows}),
            'size': len(rows),
            'members': [r['id'] for r in rows][:20],
            'n_members': len(rows),
        })
    cross_split_groups = [g for g in group_list if len(g['splits']) > 1]
    cross_split_exact = [sha for sha, members in exact_groups.items()
                         if len({records[i]['split'] for i in members}) > 1]

    # Nearest train pHash distance for each validation image. Both fixed splits
    # and fresh records are covered; test rows are never inferred.
    train = [r for r in records if r['split'] == 'train']
    train_values = {r['source']: np.array([int(x['phash'], 16) for x in train
                                          if x['source'] == r['source']], dtype=np.uint64)
                    for r in train}
    all_train = np.array([int(r['phash'], 16) for r in train], dtype=np.uint64)
    all_train_legacy = np.array([int(r['phash'], 16) for r in train
                                 if r['source'] == 'legacy-hk9'], dtype=np.uint64)
    legacy_shas = {r['sha256'] for r in train if r['source'] == 'legacy-hk9'}

    val_rows = [r for r in records if r['split'] == 'val']
    for r in val_rows:
        value = int(r['phash'], 16)
        same_source = train_values.get(r['source'])
        r['nearest_train_phash_same_source'] = (hamming_min(same_source, value)
                                                if same_source is not None and len(same_source)
                                                else None)
        r['near_train_any'] = hamming_min(all_train, value) if len(all_train) else None
        r['near_train_legacy'] = (hamming_min(all_train_legacy, value)
                                  if len(all_train_legacy) else None)
        r['exact_train_sha'] = r['sha256'] in {x['sha256'] for x in train}
        r['video_group_in_train'] = False  # refined below from filename groups
    for key, members in filename_groups.items():
        if key[0] != 'video':
            continue
        splits = {records[i]['split'] for i in members}
        if 'train' in splits:
            for i in members:
                if records[i]['split'] == 'val':
                    records[i]['video_group_in_train'] = True

    # Contamination is reported at several radii so callers do not have to
    # pretend one threshold is ground truth.
    for r in val_rows:
        r['dup_candidate'] = bool(r['exact_train_sha'] or r['video_group_in_train']
                                  or (r['near_train_any'] is not None
                                      and r['near_train_any'] <= args.near_radius))
        r['clean_gate'] = (not r['exact_train_sha'] and not r['video_group_in_train']
                           and r['near_train_any'] is not None
                           and r['near_train_any'] > args.near_radius)

    # Per-class annotated positives, split by evaluation scope.
    def class_counts(rows):
        counts = Counter()
        for r in rows:
            for box in r['boxes']:
                if box['class_id'] in r['coverage']:
                    counts[NAMES[box['class_id']]] += 1
        return {name: counts.get(name, 0) for name in NAMES}

    legacy_val = [r for r in val_rows if r['source'] == 'legacy-hk9']
    oid_val = [r for r in val_rows if r['source'] == 'oid-ccby2' and not r['fresh']]
    fresh_val = [r for r in val_rows if r['fresh']]
    clean_val = [r for r in val_rows if r['clean_gate']]
    clean_legacy_val = [r for r in clean_val if r['source'] == 'legacy-hk9']

    # Fresh train/val author leakage (already asserted by the frozen package).
    fresh_train_authors = {r.get('author') for r in records
                           if r['fresh'] and r['split'] == 'train'}
    fresh_val_authors = {r.get('author') for r in records
                         if r['fresh'] and r['split'] == 'val'}
    fresh_val_values = np.array([int(r['phash'], 16) for r in fresh_val], dtype=np.uint64)
    fresh_train_values = np.array([int(r['phash'], 16) for r in records
                                   if r['fresh'] and r['split'] == 'train'], dtype=np.uint64)
    fresh_pairs = []
    for i, r in enumerate(fresh_val):
        d = hamming_min(fresh_train_values, int(r['phash'], 16))
        fresh_pairs.append({'id': r['id'], 'nearest_fresh_train_phash': d})
    if len(fresh_val_values):
        fresh_to_source_train = [hamming_min(all_train, int(r['phash'], 16)) for r in fresh_val]
    else:
        fresh_to_source_train = []

    # Validation label sanity.
    label_errors = []
    for r in records:
        for box in r['boxes']:
            x1, y1, x2, y2 = box['xyxy']
            if box['class_id'] not in r['coverage']:
                label_errors.append({'id': r['id'], 'reason': 'box_outside_coverage'})
            if not (0 <= x1 < x2 <= 1 and 0 <= y1 < y2 <= 1):
                label_errors.append({'id': r['id'], 'reason': 'invalid_geometry'})
    exif_flagged = [r['id'] for r in records if r['exif_orientation'] != 1]

    summary = {
        'audit': 'A10 candidate grouping and validation-support audit',
        'not_human_scene_verification': True,
        'inputs': {
            'source_index': str(args.source_index),
            'fresh_review': str(args.fresh_review),
            'near_radius_hamming': args.near_radius,
            'source_images_verified': len(records),
            'sha_mismatches': bad_sha,
        },
        'composition': {
            'total': len(records),
            'by_source_split': {f'{s}/{sp}': n for (s, sp), n in sorted(
                Counter((r['source'], r['split']) for r in records).items())},
            'by_source': dict(sorted(Counter(r['source'] for r in records).items())),
            'coverage_lengths': dict(sorted(Counter(len(r['coverage']) for r in records).items())),
            'exif_orientation_flagged': len(exif_flagged),
        },
        'duplicate_candidates': {
            'exact_byte_groups': len(exact_groups),
            'exact_byte_groups_cross_split': len(cross_split_exact),
            'phash_pairs_within_radius': len(pairs),
            'all_multimember_groups': len(group_list),
            'cross_split_groups': len(cross_split_groups),
            'largest_group': max((g['size'] for g in group_list), default=1),
        },
        'validation_leakage': {
            'val_images': len(val_rows),
            'exact_sha_in_train': sum(r['exact_train_sha'] for r in val_rows),
            'same_video_group_in_train': sum(r['video_group_in_train'] for r in val_rows),
            'nearest_train_radius_counts': {
                str(radius): sum(1 for r in val_rows if r['near_train_any'] is not None
                                 and r['near_train_any'] <= radius)
                for radius in (2, 4, 6, 8, 10)},
            'dup_candidates_at_radius': sum(r['dup_candidate'] for r in val_rows),
            'clean_gate_images': len(clean_val),
            'clean_gate_legacy_images': len(clean_legacy_val),
        },
        'class_ground_truth_positives': {
            'all_val': class_counts(val_rows),
            'legacy_val': class_counts(legacy_val),
            'original_oid_val': class_counts(oid_val),
            'fresh_oid_val': class_counts(fresh_val),
            'clean_val': class_counts(clean_val),
            'train': class_counts(train),
        },
        'fresh_door_cohort': {
            'train_images': sum(1 for r in records if r['fresh'] and r['split'] == 'train'),
            'val_images': len(fresh_val),
            'train_authors': len(fresh_train_authors),
            'val_authors': len(fresh_val_authors),
            'author_overlap': sorted(fresh_train_authors & fresh_val_authors),
            'val_nearest_fresh_train_phash': fresh_pairs,
            'val_nearest_source_train_phash': fresh_to_source_train,
        },
        'label_sanity': {
            'errors': len(label_errors),
            'examples': label_errors[:10],
        },
        'limits': [
            'pHash and filename groups are candidate evidence, not scene truth.',
            'The fixed legacy validation split was not re-split; clean_gate is a subset definition.',
            'Macao and indoor CC BY images exist only in train, so they have no held-out validation.',
            'Fresh door validation has no independent human adjudication and no fence positives.',
            'Test split photos were not inferred or inspected in this audit.',
        ],
    }

    json_write(args.output / 'audit.json', summary)
    with (args.output / 'val-images.csv').open('w', encoding='utf-8') as handle:
        fields = ['id', 'source', 'subset', 'coverage', 'gt_counts', 'exact_train_sha',
                  'video_group_in_train', 'nearest_train_phash_any', 'near_train_legacy',
                  'dup_candidate', 'clean_gate', 'boxes']
        handle.write(','.join(fields) + '\n')
        for r in val_rows:
            subset = ('fresh_oid_val' if r['fresh'] else
                      'original_oid_val' if r['source'] == 'oid-ccby2' else 'legacy_val')
            gt = Counter(NAMES[b['class_id']] for b in r['boxes'] if b['class_id'] in r['coverage'])
            row = [r['id'], r['source'], subset, '|'.join(map(str, r['coverage'])),
                   '|'.join(f'{k}:{v}' for k, v in sorted(gt.items())),
                   r['exact_train_sha'], r['video_group_in_train'],
                   r['near_train_any'], r['near_train_legacy'], r['dup_candidate'],
                   r['clean_gate'], len(r['boxes'])]
            handle.write(','.join('"' + str(x) + '"' for x in row) + '\n')
    with (args.output / 'groups.csv').open('w', encoding='utf-8') as handle:
        handle.write('splits,sources,size,members\n')
        for g in group_list:
            handle.write('"' + '|'.join(g['splits']) + '","' + '|'.join(g['sources'])
                         + f'",{g["size"]},"' + '|'.join(g['members']) + '"\n')
    json_write(args.output / 'near-duplicate-pairs.json',
               [{'a': records[i]['id'], 'b': records[j]['id'], 'distance': d,
                 'a_split': records[i]['split'], 'b_split': records[j]['split']}
                for i, j, d in pairs])
    print(json.dumps({k: summary[k] for k in
                      ['composition', 'duplicate_candidates', 'validation_leakage',
                       'class_ground_truth_positives', 'fresh_door_cohort']},
                     indent=2)[:6000])
    print('WROTE', args.output / 'audit.json', flush=True)


if __name__ == '__main__':
    main()
