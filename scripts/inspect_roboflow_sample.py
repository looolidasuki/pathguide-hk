"""抽样 Roboflow 数据集并把框画出来，用于**在训练前**判断这批数据能不能用。

判三件事，缺一不可：
1. **域**：是不是香港街景？还是俯视/CCTV/体育场？本项目部署在香港行人视角。
2. **标签质量**：person 的框是整个人还是只有头？有没有框满全图？
3. **被丢弃的框**：未映射类别的框画成红色——大量红框意味着这些图里
   有我们不要的物件占着画面，那会让「负样本」的含义变脏。

用法：
    python scripts/inspect_roboflow_sample.py --dir data/raw/roboflow --n 48
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]

# data.yaml 的类别名列表，main() 里填。标签文件里的类别 id 是它的下标。
names_list: list[str] = []

GREEN = (80, 220, 80)      # pedestrian（映射上）
BLUE = (230, 160, 60)      # bicycle（映射上）
RED = (60, 60, 230)        # 未映射（将被丢弃）


def read_label(p: Path) -> list[tuple[int, float, float, float, float]]:
    out = []
    if not p.exists():
        return out
    for ln in p.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = ln.split()
        if len(parts) < 5:
            continue
        try:
            cid = int(float(parts[0]))
            x, y, w, h = (float(v) for v in parts[1:5])
        except ValueError:
            continue
        out.append((cid, x, y, w, h))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="data/raw/roboflow")
    ap.add_argument("--n", type=int, default=48)
    ap.add_argument("--cols", type=int, default=6)
    ap.add_argument("--thumb", type=int, default=320)
    ap.add_argument("--out", default="artifacts/inspect/roboflow_sample.jpg")
    args = ap.parse_args()

    root = REPO_ROOT / args.dir
    ov = json.loads((root / "_class_override.json").read_text(encoding="utf-8"))
    # 标签里的类别 id 是 data.yaml 的 `names` 列表下标，所以必须用**同一份**
    # 解析器（import_roboflow.read_yaml_names）来还原名字，
    # 否则这里看到的类别与导入时用的类别可能不一致。
    sys.path.insert(0, str(REPO_ROOT / "scripts"))
    from import_roboflow import read_yaml_names
    global names_list
    names_list = read_yaml_names(root / "data.yaml")
    print(f"data.yaml 读出 {len(names_list)} 个类别")

    # 收集 (图, 标签) 对，按 split 分层抽样，保证三个 split 都看到
    per_split: dict[str, list[tuple[Path, Path]]] = {}
    for split in ("train", "valid", "test"):
        imgs = sorted((root / split / "images").glob("*"))
        imgs = [p for p in imgs if p.suffix.lower() in (".jpg", ".jpeg", ".png")]
        picks = []
        if imgs:
            step = max(1, len(imgs) // max(1, args.n // 3))
            picks = imgs[::step][: max(1, args.n // 3)]
        per_split[split] = [(p, root / split / "labels" / f"{p.stem}.txt") for p in picks]

    pairs = [x for s in ("train", "valid", "test") for x in per_split[s]]
    pairs = pairs[: args.n]
    print(f"抽样 {len(pairs)} 张（train/valid/test 各 {args.n // 3} 左右）")

    tiles = []
    stat = {"kept_ped": 0, "kept_bike": 0, "dropped": 0, "empty": 0}
    for img_p, lbl_p in pairs:
        img = cv2.imread(str(img_p))
        if img is None:
            continue
        h, w = img.shape[:2]
        labels = read_label(lbl_p)
        kept = 0
        for cid, x, y, bw, bh in labels:
            name = None
            # 反查：用 data.yaml 的类别顺序（标签里的 cid 是它的下标）
            if cid < len(names_list):
                name = names_list[cid]
            tgt = ov.get(name)
            if tgt == 6:
                color, stat_key = GREEN, "kept_ped"
            elif tgt == 11:
                color, stat_key = BLUE, "kept_bike"
            else:
                color, stat_key = RED, "dropped"
                stat["dropped"] += 1
                cv2.rectangle(img, (int((x - bw / 2) * w), int((y - bh / 2) * h)),
                              (int((x + bw / 2) * w), int((y + bh / 2) * h)), color, 2)
                continue
            stat[stat_key] += 1
            kept += 1
            cv2.rectangle(img, (int((x - bw / 2) * w), int((y - bh / 2) * h)),
                          (int((x + bw / 2) * w), int((y + bh / 2) * h)), color, 2)
        if kept == 0 and not labels:
            stat["empty"] += 1
        scale = args.thumb / w
        img = cv2.resize(img, (args.thumb, max(1, int(h * scale))))
        # 标注文件名与 split，便于回查
        cv2.putText(img, f"{img_p.parent.parent.name[:5]} {img_p.stem[:14]}",
                    (4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.42, (255, 255, 255), 1, cv2.LINE_AA)
        tiles.append(img)

    if not tiles:
        print("没有可用的图")
        return 1

    th = max(t.shape[0] for t in tiles)
    tw = max(t.shape[1] for t in tiles)
    cols = args.cols
    rows = (len(tiles) + cols - 1) // cols
    sheet = np.full((rows * th, cols * tw, 3), 32, np.uint8)
    for i, t in enumerate(tiles):
        r, c = divmod(i, cols)
        sheet[r * th:r * th + t.shape[0], c * tw:c * tw + t.shape[1]] = t

    out = REPO_ROOT / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out), sheet)

    print(f"\n已写 {out.relative_to(REPO_ROOT)}  ({sheet.shape[1]}x{sheet.shape[0]})")
    print(f"  绿=pedestrian 保留 {stat['kept_ped']} 框")
    print(f"  蓝=bicycle 保留 {stat['kept_bike']} 框")
    print(f"  红=未映射将丢弃 {stat['dropped']} 框")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
