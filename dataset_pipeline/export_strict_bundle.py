"""把 A10 嚴格留集匯出成可攜帶的評估包（供另一台電腦重跑 android_pipeline_eval.py）。

在產生 A10 基準的那台機器上執行（輸入與 a10_evaluate.py／a10_report.py 相同）：

  python dataset_pipeline/export_strict_bundle.py \
    --source-index dataset_pipeline/review_artifacts/2026-10-30/coverage-repair-v1/source-index.json \
    --fresh-review dataset_pipeline/review_artifacts/2026-10-30/fresh-door-review/reviewed-candidates.json \
    --audit-csv   dataset_pipeline/review_artifacts/2026-10-31/a10-baseline/audit/val-images.csv \
    --output      dataset_pipeline/review_artifacts/strict-bundle-a10

嚴格留集定義與 a10_report.py 相同：驗證集中 clean_gate 為真，且其
(source, source_key) 不見於任何訓練圖；新增 OID 門樣本（oid-ccby2-fresh）
在 clean_gate 為真時亦納入。

輸出：
  images/<id><副檔名>   原圖複本（不改內容；SHA-256 見 records.jsonl）
  records.jsonl         每行一張：id, source, file, sha256, width, height,
                        coverage（有標註的類別名）, boxes [{name, xyxy}]（像素座標）
  manifest.json         張數、各類框數、輸入檔 SHA-256、定義與時間

包內只有評估所需的驗證圖與標註，不含訓練圖、權重或私人照片；
屬於本機覆核產物，請勿提交 Git（review_artifacts/ 已被忽略）。
"""
import argparse
import csv
import hashlib
import json
import shutil
import struct
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
import sys

# common.py 與 a10_report.py 相同，位於產生基準那台機器的 dataset_pipeline/（未入庫）。
sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import source_key  # noqa: E402

NAMES = ['person', 'bicycle', 'bin', 'bollard', 'traffic_cone',
         'caution_slippery', 'stairs', 'escalator', 'fence', 'door']


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def image_size(path: Path):
    """只讀檔頭取得寬高（JPEG／PNG），不依賴影像庫。"""
    data = path.read_bytes()
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        return struct.unpack('>II', data[16:24])
    i = 2
    while i < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        length = struct.unpack('>H', data[i + 2:i + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            h, w = struct.unpack('>HH', data[i + 5:i + 9])
            return w, h
        i += 2 + length
    raise ValueError(f'無法讀取尺寸：{path}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--source-index', type=Path, required=True)
    ap.add_argument('--fresh-review', type=Path, required=True)
    ap.add_argument('--audit-csv', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / 'images').mkdir()

    source = json.loads(args.source_index.read_text())
    fresh = json.loads(args.fresh_review.read_text())['records']
    with args.audit_csv.open() as handle:
        clean = {r['id']: r['clean_gate'] == 'True' for r in csv.DictReader(handle)}

    def skey(row):
        return (row['source'], source_key(Path(row['path']).name))

    train_keys = {skey(r) for r in source if r['split'] == 'train'}
    rows = [dict(r, source=r['source']) for r in source
            if r['split'] == 'val' and clean.get(r['id']) and skey(r) not in train_keys]
    rows += [dict(r, source='oid-ccby2-fresh') for r in fresh
             if r['split'] == 'val' and clean.get(r['id'])]

    boxes_per_class, by_source = Counter(), Counter()
    with (args.output / 'records.jsonl').open('w', encoding='utf-8') as out:
        for r in rows:
            src = Path(r['path'])
            target = args.output / 'images' / f"{r['id']}{src.suffix.lower()}"
            shutil.copy2(src, target)
            w, h = image_size(target)
            boxes = [{'name': NAMES[int(b['class_id'])], 'xyxy': [float(x) for x in b['xyxy']]}
                     for b in r['boxes']]
            boxes_per_class.update(b['name'] for b in boxes)
            by_source[r['source']] += 1
            out.write(json.dumps({
                'id': r['id'], 'source': r['source'], 'file': target.name,
                'sha256': sha256(target), 'width': w, 'height': h,
                'coverage': [NAMES[int(c)] for c in r['coverage']],
                'boxes': boxes,
            }, ensure_ascii=False) + '\n')

    manifest = {
        'created_utc': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'definition': 'val & clean_gate & (source, source_key) not in train; plus clean oid-ccby2-fresh val (as a10_report.py)',
        'images': len(rows),
        'by_source': dict(by_source),
        'boxes_per_class': dict(boxes_per_class),
        'inputs': {name: {'path': str(p), 'sha256': sha256(p)} for name, p in
                   (('source_index', args.source_index), ('fresh_review', args.fresh_review),
                    ('audit_csv', args.audit_csv))},
        'expected_images_per_dataset_review': 1082,
    }
    (args.output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k: manifest[k] for k in ('images', 'by_source', 'boxes_per_class')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
