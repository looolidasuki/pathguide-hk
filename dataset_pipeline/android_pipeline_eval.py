"""以 App 實際的 detector.tflite，比較 Android 相機前處理新舊管線的逐類誤認／漏認。

每張已標註照片先模擬手機相機輸出（JFIF 全範圍 BT.601 YUV420，色度 2×2 平均），
再分別經過：
  legacy  ：2026-11-23 前的 Android 管線——截斷取整、最近一點取樣、限幅範圍公式；
  android ：現行 CameraPreprocess（全範圍、.5 取偶、半像素雙線性、114 填充）；
  offline ：直接用 RGB 的離線參照（a10_evaluate.py prepare 同一邏輯）。
解碼與配對沿用 a10_evaluate.py：argmax 類別、逐類 NMS 0.45、最多 100、IoU 0.5，
只在資料集有標註的類別計誤認（未標註類別的偵測不計 FP）。

輸出每個門檻（0.30–0.90）逐類 TP／FP／FN、P、R，及每張圖的偵測（供覆核）。

注意：資料集若曾用於訓練此模型，絕對數字會偏樂觀；新舊管線看同一批圖，
相對差異仍有意義。正式基準請改用凍結的嚴格留集（見 DATASET-REVIEW）。

用法：
  python dataset_pipeline/android_pipeline_eval.py \
    --images data/dataset_hk_stage2/images/val --labels data/dataset_hk_stage2/labels/val \
    --dataset-yaml data/dataset_hk_stage2/dataset.yaml --output <out.json>
"""
import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np
from ai_edge_litert.interpreter import Interpreter

MODEL_NAMES = ['person', 'bicycle', 'bin', 'bollard', 'traffic_cone',
               'caution_slippery', 'stairs', 'escalator', 'fence', 'door']
DATASET_TO_MODEL = {'pedestrian': 'person', 'person': 'person', 'bicycle': 'bicycle',
                    'bin': 'bin', 'bollard': 'bollard', 'traffic_cone': 'traffic_cone',
                    'caution_slippery': 'caution_slippery', 'stairs': 'stairs',
                    'escalator': 'escalator', 'fence': 'fence', 'door': 'door'}
THRESHOLDS = [round(0.30 + 0.05 * i, 2) for i in range(13)]
SIZE, NMS_IOU, MAX_DET, MATCH_IOU = 640, 0.45, 100, 0.5


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ------------------------------------------------------------------ 相機模擬
def rgb_to_yuv420_full(rgb: np.ndarray):
    """JFIF 全範圍 BT.601；色度 2×2 平均（奇數邊以邊緣複製補齊）。"""
    f = rgb.astype(np.float64)
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    y = 0.299 * r + 0.587 * g + 0.114 * b
    cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128
    cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 128
    h, w = y.shape
    ph, pw = h + (h % 2), w + (w % 2)
    def sub(c):
        c = np.pad(c, ((0, ph - h), (0, pw - w)), mode='edge')
        return c.reshape(ph // 2, 2, pw // 2, 2).mean(axis=(1, 3))
    q = lambda a: np.clip(np.rint(a), 0, 255).astype(np.uint8)
    return q(y), q(sub(cb)), q(sub(cr))


def yuv_to_rgb(y, u, v, full_range: bool) -> np.ndarray:
    """與 CameraPreprocess.yuvToRgb 相同公式（full）或舊版 Kotlin 限幅公式（legacy）。"""
    h, w = y.shape
    U = np.repeat(np.repeat(u, 2, 0), 2, 1)[:h, :w].astype(np.float32) - 128
    V = np.repeat(np.repeat(v, 2, 0), 2, 1)[:h, :w].astype(np.float32) - 128
    Y = y.astype(np.float32)
    if full_range:
        r, g, b = Y + 1.402 * V, Y - 0.344136 * U - 0.714136 * V, Y + 1.772 * U
    else:  # 2026-11-23 前 VisionPlugin.sampleRgb 的公式
        yf = Y - 16
        r, g, b = 1.164 * yf + 1.596 * V, 1.164 * yf - 0.392 * U - 0.813 * V, 1.164 * yf + 2.017 * U
    return np.clip(np.stack([r, g, b], -1), 0, 255).astype(np.float32)


# ------------------------------------------------------------------ 前處理
def letterbox_bilinear(rgb255: np.ndarray):
    h, w = rgb255.shape[:2]
    scale = min(SIZE / w, SIZE / h)
    sw, sh = round(w * scale), round(h * scale)
    px, py = (SIZE - sw) // 2, (SIZE - sh) // 2
    frame = np.full((SIZE, SIZE, 3), 114 / 255, np.float32)
    frame[py:py + sh, px:px + sw] = cv2.resize(rgb255 / 255.0, (sw, sh), interpolation=cv2.INTER_LINEAR)
    return frame, (sw, sh, px, py)


def letterbox_legacy_nearest(rgb255: np.ndarray):
    h, w = rgb255.shape[:2]
    scale = min(np.float32(SIZE) / np.float32(w), np.float32(SIZE) / np.float32(h))
    sw, sh = max(1, int(np.float32(w) * scale)), max(1, int(np.float32(h) * scale))
    px, py = (SIZE - sw) // 2, (SIZE - sh) // 2
    xs = (np.arange(sw) * w) // sw
    ys = (np.arange(sh) * h) // sh
    frame = np.full((SIZE, SIZE, 3), 114 / 255, np.float32)
    frame[py:py + sh, px:px + sw] = rgb255[ys][:, xs] / 255.0
    return frame, (sw, sh, px, py)


def prepare(rgb: np.ndarray, pipeline: str):
    if pipeline == 'offline':
        return letterbox_bilinear(rgb.astype(np.float32))
    y, u, v = rgb_to_yuv420_full(rgb)
    if pipeline == 'android':
        return letterbox_bilinear(yuv_to_rgb(y, u, v, full_range=True))
    if pipeline == 'legacy':
        return letterbox_legacy_nearest(yuv_to_rgb(y, u, v, full_range=False))
    raise ValueError(pipeline)


# ------------------------------------------------------------------ 推理與解碼
def decode(raw: np.ndarray, geo, src_w, src_h):
    sw, sh, px, py = geo
    raw = raw.copy()
    # Ultralytics 匯出的 TFLite 以 0..1 輸出框（相對 640 輸入）；PyTorch 版為像素。
    if float(np.abs(raw[:4]).max()) <= 1.5:
        raw[:4] *= SIZE
    scores_all = raw[4:]
    cls = scores_all.argmax(0)
    score = scores_all.max(0)
    keep = (score >= 0.001) & (raw[2] > 0) & (raw[3] > 0)
    cx, cy, bw, bh = raw[0][keep], raw[1][keep], raw[2][keep], raw[3][keep]
    sx, sy = src_w / sw, src_h / sh
    boxes = np.stack([(cx - bw / 2 - px) * sx, (cy - bh / 2 - py) * sy,
                      (cx + bw / 2 - px) * sx, (cy + bh / 2 - py) * sy], 1)
    return boxes, score[keep], cls[keep]


def iou(a, b):
    x1, y1 = max(a[0], b[0]), max(a[1], b[1])
    x2, y2 = min(a[2], b[2]), min(a[3], b[3])
    inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def nms(boxes, scores, classes):
    out = []
    for c in np.unique(classes):
        idx = np.where(classes == c)[0]
        idx = idx[np.argsort(-scores[idx], kind='stable')]
        kept = []
        for i in idx:
            if all(iou(boxes[i], boxes[j]) <= NMS_IOU for j in kept):
                kept.append(i)
        out.extend(kept)
    out.sort(key=lambda i: -scores[i])
    return out[:MAX_DET]


def match(dets, gts, coverage, threshold):
    """類別相符、IoU ≥ 0.5、按分數貪婪配對；未標註類別的偵測不計。"""
    counts = defaultdict(lambda: [0, 0, 0])  # tp, fp, fn
    used = set()
    for d in sorted((d for d in dets if d['score'] >= threshold and d['name'] in coverage),
                    key=lambda d: -d['score']):
        best, best_iou = None, MATCH_IOU
        for j, g in enumerate(gts):
            if j in used or g['name'] != d['name']:
                continue
            v = iou(d['xyxy'], g['xyxy'])
            if v >= best_iou:
                best, best_iou = j, v
        if best is None:
            counts[d['name']][1] += 1
        else:
            used.add(best)
            counts[d['name']][0] += 1
    for j, g in enumerate(gts):
        if j not in used:
            counts[g['name']][2] += 1
    return counts


def load_labels(path: Path, names, w, h):
    gts = []
    if not path.exists():
        return gts
    for line in path.read_text(encoding='utf-8').splitlines():
        parts = line.split()
        if len(parts) != 5:
            continue
        name = DATASET_TO_MODEL.get(names[int(parts[0])])
        if name is None:
            continue
        cx, cy, bw, bh = (float(p) for p in parts[1:])
        gts.append({'name': name, 'xyxy': [(cx - bw / 2) * w, (cy - bh / 2) * h,
                                            (cx + bw / 2) * w, (cy + bh / 2) * h]})
    return gts


def read_names(yaml_path: Path):
    names, inside = {}, False
    for line in yaml_path.read_text(encoding='utf-8').splitlines():
        if line.startswith('names:'):
            inside = True
            continue
        if inside:
            if not line.startswith('  '):
                break
            k, v = line.strip().split(':', 1)
            names[int(k)] = v.strip()
    return [names[i] for i in range(len(names))]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--images', type=Path, required=True)
    ap.add_argument('--labels', type=Path, required=True)
    ap.add_argument('--dataset-yaml', type=Path, required=True)
    ap.add_argument('--model', type=Path, default=Path('app/assets/models/detector.tflite'))
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()

    names = read_names(args.dataset_yaml)
    coverage = sorted({DATASET_TO_MODEL[n] for n in names if n in DATASET_TO_MODEL})
    interp = Interpreter(model_path=str(args.model), num_threads=4)
    interp.allocate_tensors()
    inp, out = interp.get_input_details()[0], interp.get_output_details()[0]
    nchw = list(inp['shape']) == [1, 3, SIZE, SIZE]

    pipelines = ['legacy', 'android', 'offline']
    totals = {p: {t: defaultdict(lambda: [0, 0, 0]) for t in THRESHOLDS} for p in pipelines}
    images = []
    paths = sorted(p for p in args.images.iterdir() if p.suffix.lower() in ('.jpg', '.jpeg', '.png'))
    for n, path in enumerate(paths, 1):
        bgr = cv2.imread(str(path))
        if bgr is None:
            continue
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        h, w = rgb.shape[:2]
        gts = load_labels(args.labels / (path.stem + '.txt'), names, w, h)
        record = {'file': path.name, 'sha256': sha256(path), 'gt': gts}
        for p in pipelines:
            frame, geo = prepare(rgb, p)
            tensor = frame.transpose(2, 0, 1)[None] if nchw else frame[None]
            interp.set_tensor(inp['index'], tensor.astype(np.float32))
            interp.invoke()
            boxes, scores, classes = decode(interp.get_tensor(out['index'])[0], geo, w, h)
            keep = nms(boxes, scores, classes)
            dets = [{'name': MODEL_NAMES[int(classes[i])], 'score': float(scores[i]),
                     'xyxy': [float(x) for x in boxes[i]]} for i in keep if scores[i] >= 0.25]
            record[p] = dets
            for t in THRESHOLDS:
                for name, (tp, fp, fn) in match(dets, gts, coverage, t).items():
                    acc = totals[p][t][name]
                    acc[0] += tp; acc[1] += fp; acc[2] += fn
        images.append(record)
        if n % 20 == 0:
            print(f'{n}/{len(paths)}', flush=True)

    def table(acc):
        rows = {}
        for name in coverage:
            tp, fp, fn = acc.get(name, [0, 0, 0])
            rows[name] = {'tp': tp, 'fp': fp, 'fn': fn,
                          'precision': tp / (tp + fp) if tp + fp else None,
                          'recall': tp / (tp + fn) if tp + fn else None}
        tp = sum(r['tp'] for r in rows.values()); fp = sum(r['fp'] for r in rows.values())
        fn = sum(r['fn'] for r in rows.values())
        rows['_all'] = {'tp': tp, 'fp': fp, 'fn': fn,
                        'precision': tp / (tp + fp) if tp + fp else None,
                        'recall': tp / (tp + fn) if tp + fn else None}
        return rows

    result = {
        'model': {'path': str(args.model), 'sha256': sha256(args.model)},
        'dataset': {'images': str(args.images), 'labels': str(args.labels),
                    'count': len(images), 'covered_classes': coverage,
                    'caveat': 'may overlap the model training data; compare pipelines relatively'},
        'method': {'camera': 'JFIF full-range BT.601 YUV420, 2x2 chroma mean',
                   'nms_iou': NMS_IOU, 'max_det': MAX_DET, 'match_iou': MATCH_IOU,
                   'fp_counted_only_for_covered_classes': True},
        'thresholds': THRESHOLDS,
        'summary': {p: {str(t): table(totals[p][t]) for t in THRESHOLDS} for p in pipelines},
        'images': images,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding='utf-8')
    for t in (0.3, 0.5, 0.7):
        print(f'\n== 門檻 {t}')
        for p in pipelines:
            a = result['summary'][p][str(t)]['_all']
            print(f"{p:8s} TP={a['tp']:4d} FP={a['fp']:4d} FN={a['fn']:4d} "
                  f"P={a['precision'] or 0:.3f} R={a['recall'] or 0:.3f}")


if __name__ == '__main__':
    main()
