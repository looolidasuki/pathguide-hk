"""從 Open Images V7 test 劃分建立獨立評估包（格式同 export_strict_bundle.py）。

用途：A10 凍結嚴格留集不在每台機器上時，用公開、人工核實、與 A10 訓練抽樣
最不重疊的 test 劃分，量度 Android 管線的逐類誤認／漏認。

覆蓋類別（A10 名稱 ← OID 類別）：
  person ← Person（框另含 Man／Woman／Boy／Girl）、bicycle ← Bicycle、
  door ← Door、stairs ← Stairs、bin ← Waste container。
  OID 無 bollard、traffic_cone、caution_slippery、escalator、fence 的框，這五類不評。

規則（下載影像前固定）：
  - 某類在某圖「已覆蓋」＝該圖有此類的人工核實圖像級標籤（有或無皆可）；
    只在已覆蓋類別計誤認。person 以 Person 本身的核實標籤為準。
  - 排除需要旋轉的影像，以及含上述類別「群組框」（IsGroupOf）的影像。
  - 隨機種子固定；每類最多 N 張「核實含有且有框」的影像，另加 N 張
    「至少一類核實不含、且五類皆無正例」的困難負樣本；取聯集。

影像授權 CC BY 2.0（逐圖保留作者與來源以便署名）、標註 CC BY 4.0。
評估包屬本機覆核產物，放在 review_artifacts/（已被 Git 忽略），不提交、不上傳。

用法：
  python dataset_pipeline/build_oid_bundle.py --meta <三份 CSV 所在目錄> --output <評估包目錄>
"""
import argparse
import csv
import hashlib
import json
import random
import time
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import cv2

SEED = 20261123
PER_CLASS = 200
PERSON_BOX = {'/m/01g317', '/m/04yx4', '/m/03bt1vf', '/m/01bl7v', '/m/05r655'}
CLASS_BOX = {'person': PERSON_BOX, 'bicycle': {'/m/0199g'}, 'door': {'/m/02dgv'},
             'stairs': {'/m/01lynh'}, 'bin': {'/m/0bjyj5'}}
CLASS_LABEL = {'person': {'/m/01g317'}, 'bicycle': {'/m/0199g'}, 'door': {'/m/02dgv'},
               'stairs': {'/m/01lynh'}, 'bin': {'/m/0bjyj5'}}
MID_TO_CLASS = {mid: c for c, mids in CLASS_BOX.items() for mid in mids}
IMAGE_URL = 'https://open-images-dataset.s3.amazonaws.com/test/{}.jpg'


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(image_id: str, target: Path):
    if target.exists() and target.stat().st_size > 0:
        return True
    for attempt in range(3):
        try:
            with urllib.request.urlopen(IMAGE_URL.format(image_id), timeout=60) as r:
                data = r.read()
            if data[:2] != b'\xff\xd8':
                return False
            target.write_bytes(data)
            return True
        except Exception:
            time.sleep(1 + attempt)
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--meta', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--per-class', type=int, default=PER_CLASS)
    args = ap.parse_args()
    bbox_csv = args.meta / 'test-annotations-bbox.csv'
    label_csv = args.meta / 'test-annotations-human-imagelabels-boxable.csv'
    info_csv = args.meta / 'test-images-with-rotation.csv'

    labels = defaultdict(dict)          # image -> class -> 0/1（人工核實）
    with label_csv.open(encoding='utf-8') as f:
        for r in csv.DictReader(f):
            for c, mids in CLASS_LABEL.items():
                if r['LabelName'] in mids:
                    v = int(float(r['Confidence']))
                    labels[r['ImageID']][c] = max(v, labels[r['ImageID']].get(c, 0))
    boxes = defaultdict(list)
    group = set()
    with bbox_csv.open(encoding='utf-8') as f:
        for r in csv.DictReader(f):
            c = MID_TO_CLASS.get(r['LabelName'])
            if c is None:
                continue
            if r['IsGroupOf'] == '1':
                group.add(r['ImageID'])
                continue
            boxes[r['ImageID']].append((c, float(r['XMin']), float(r['YMin']), float(r['XMax']), float(r['YMax'])))
    info = {}
    with info_csv.open(encoding='utf-8') as f:
        for r in csv.DictReader(f):
            if r['Subset'] == 'test':
                info[r['ImageID']] = r

    def eligible(i):
        rot = info.get(i, {}).get('Rotation', '')
        return i in info and i not in group and rot in ('', '0.0', '0')

    rng = random.Random(SEED)
    chosen, reason = [], {}
    for c in ['door', 'stairs', 'bin', 'bicycle', 'person']:
        pool = sorted(i for i, lab in labels.items()
                      if lab.get(c) == 1 and eligible(i) and any(b[0] == c for b in boxes[i]))
        pick = rng.sample(pool, min(args.per_class, len(pool)))
        for i in pick:
            if i not in reason:
                chosen.append(i)
                reason[i] = f'positive:{c}'
    negatives = sorted(i for i, lab in labels.items()
                       if eligible(i) and lab and all(v == 0 for v in lab.values()) and not boxes[i])
    for i in rng.sample(negatives, min(args.per_class, len(negatives))):
        if i not in reason:
            chosen.append(i)
            reason[i] = 'hard_negative'

    img_dir = args.output / 'images'
    img_dir.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=8) as pool:
        ok = dict(zip(chosen, pool.map(lambda i: download(i, img_dir / f'{i}.jpg'), chosen)))

    counts, by_reason, failed = Counter(), Counter(), []
    with (args.output / 'records.jsonl').open('w', encoding='utf-8') as out:
        for i in chosen:
            path = img_dir / f'{i}.jpg'
            img = cv2.imread(str(path)) if ok[i] else None
            if img is None:
                failed.append(i)
                continue
            h, w = img.shape[:2]
            gts = [{'name': c, 'xyxy': [x1 * w, y1 * h, x2 * w, y2 * h]} for c, x1, y1, x2, y2 in boxes[i]]
            counts.update(g['name'] for g in gts)
            by_reason[reason[i]] += 1
            meta = info[i]
            out.write(json.dumps({
                'id': i, 'source': 'oid-v7-test', 'file': path.name, 'sha256': sha256(path),
                'width': w, 'height': h, 'coverage': sorted(labels[i]), 'boxes': gts,
                'selected_as': reason[i], 'license': meta['License'], 'author': meta['Author'],
                'landing': meta['OriginalLandingURL'],
            }, ensure_ascii=False) + '\n')

    manifest = {
        'created_utc': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'source': 'Open Images V7 test split (images CC BY 2.0, annotations CC BY 4.0)',
        'seed': SEED, 'per_class': args.per_class,
        'rules': ['coverage = human-verified image-level label for the class (person: Person itself)',
                  'exclude images needing rotation or with group-of boxes of covered classes',
                  'per class: verified positive with at least one box; plus hard negatives'],
        'images': sum(by_reason.values()), 'selected_as': dict(by_reason),
        'boxes_per_class': dict(counts), 'download_failed': failed,
        'inputs': {p.name: {'sha256': sha256(p)} for p in (bbox_csv, label_csv, info_csv)},
        'not_evaluated': ['bollard', 'traffic_cone', 'caution_slippery', 'escalator', 'fence'],
    }
    (args.output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k: manifest[k] for k in ('images', 'selected_as', 'boxes_per_class')}, ensure_ascii=False),
          'failed', len(failed))


if __name__ == '__main__':
    main()
