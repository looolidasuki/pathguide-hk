"""Android 檢測前處理的 JVM 對照夾具（CameraPreprocessTest）。

期望輸出用與 dataset_pipeline/a10_evaluate.py prepare() 相同的 OpenCV 邏輯產生
（float RGB、round 取整、cv2.INTER_LINEAR、114 填充），只把 640 換成可配置的
input_size 以縮小夾具。影像為固定種子的合成圖，不含任何資料集或私人照片。

用法：python scripts/gen_camera_preprocess_fixtures.py
"""
from pathlib import Path

import cv2
import numpy as np

OUT = Path(__file__).resolve().parents[1] / 'app/android/app/src/test/resources/camera_preprocess'
INPUT = 96


def synthetic(w, h, seed):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    img = np.stack([xx / max(w - 1, 1) * 255, yy / max(h - 1, 1) * 255,
                    ((xx // 3 + yy // 3) % 2) * 255], -1)
    img += rng.normal(0, 25, img.shape)
    return np.clip(img, 0, 255).astype(np.uint8)


def expected(upright_uint8, size):
    rgb = upright_uint8.astype(np.float32) / 255.0
    h, w = rgb.shape[:2]
    scale = min(size / w, size / h)
    sw, sh = round(w * scale), round(h * scale)
    px, py = (size - sw) // 2, (size - sh) // 2
    frame = np.full((size, size, 3), 114 / 255, np.float32)
    frame[py:py + sh, px:px + sw] = cv2.resize(rgb, (sw, sh), interpolation=cv2.INTER_LINEAR)
    return frame, (sw, sh, px, py)


def to_raw(upright, rotation):
    # CameraX rotationDegrees = 把原始影格順時針轉幾度才直立，所以原始 = 直立逆時針轉。
    k = {0: 0, 90: 1, 180: 2, 270: 3}[rotation]
    return np.ascontiguousarray(np.rot90(upright, k))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    cases = [('down', 240, 180, 0), ('down', 240, 180, 90), ('down', 240, 180, 180), ('up', 40, 30, 270)]
    lines = []
    for name, w, h, rot in cases:
        upright = synthetic(w, h, seed=7 if name == 'down' else 11)
        raw = to_raw(upright, rot)
        frame, geo = expected(upright, INPUT)
        tag = f'{name}_r{rot}'
        (OUT / f'{tag}.raw_rgb').write_bytes(raw.tobytes())
        (OUT / f'{tag}.expected_f32le').write_bytes(frame.astype('<f4').tobytes())
        lines.append(f'{tag} {raw.shape[1]} {raw.shape[0]} {rot} {INPUT} {" ".join(map(str, geo))}')
    (OUT / 'cases.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
