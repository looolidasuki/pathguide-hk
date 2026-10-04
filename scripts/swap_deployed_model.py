"""把某个导出产物**临时**换上端（用于真机测量），并保持清单自洽。

## 为什么要脚本而不是手工复制

清单里有 `file` 字段。直接复制 tflite 而不改清单，会出现
「清单说 best_int8.tflite、实际却是 detector.tflite」的不一致 ——
虽然 Dart 侧目前用固定资产键、不看这个字段，但**不一致的清单本身就是隐患**：
换个解读方式就会误判，而这类静默错位正是本项目反复踩的坑。

所以这里复制模型 + 改写 `file` 为部署文件名，`bytes`/`sha256` 原样保留
（文件内容没变，哈希依然有效，也会被 App 校验）。

## 正式采用时应该用哪条路

正式采用请用 `export_tflite.py --copy-to-assets`（**不加 --no-copy**）——
那条路会按部署文件名生成**完整**清单与 sha256。
本脚本只用于「临时换上、测完还原」的测量场景。

用法：
    python scripts/swap_deployed_model.py --to-stage2
    python scripts/swap_deployed_model.py --restore     # git checkout 还原
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ASSETS = REPO_ROOT / "app" / "assets" / "models"
DEPLOY_MODEL = ASSETS / "detector.tflite"
DEPLOY_MANIFEST = ASSETS / "detector.json"

CANDIDATES = {
    "stage2": REPO_ROOT / "runs/pg_stage2/weights/best_saved_model/best_int8.tflite",
}


def restore() -> int:
    r = subprocess.run(["git", "checkout", "--", str(ASSETS)], cwd=REPO_ROOT,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"git checkout 失败：{r.stderr.strip()}")
        return 1
    print("已用 git 还原端上资产（回到已发布的 poc3）")
    return 0


def swap(name: str) -> int:
    src = CANDIDATES.get(name)
    if src is None:
        print(f"未知的候选：{name}（可选：{', '.join(CANDIDATES)}）")
        return 1
    if not src.exists():
        print(f"导出产物不存在：{src}")
        return 1
    src_manifest = src.with_suffix(".json")
    if not src_manifest.exists():
        print(f"清单不存在：{src_manifest}")
        return 1

    data = src.read_bytes()
    shutil.copy2(src, DEPLOY_MODEL)

    m = json.loads(src_manifest.read_text(encoding="utf-8"))
    # 只改 file 字段；bytes/sha256 由实际文件复算，确保与实物一致
    m["file"] = DEPLOY_MODEL.name
    m["bytes"] = len(data)
    m["sha256"] = hashlib.sha256(data).hexdigest()
    DEPLOY_MANIFEST.write_text(json.dumps(m, ensure_ascii=False, indent=2) + "\n",
                               encoding="utf-8")

    print(f"已把 {name} 换上端（**临时，测完请还原**）")
    print(f"  模型   {DEPLOY_MODEL.relative_to(REPO_ROOT)}  {len(data):,} 字节")
    print(f"  清单   {m['file']}  {m['modelClassCount']} 类  "
          f"modelClassIds={m['modelClassIds']}")
    print(f"  sha256 {m['sha256'][:16]}…（已按实际文件复算）")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--to-stage2", dest="name", action="store_const", const="stage2")
    ap.add_argument("--restore", action="store_true")
    args = ap.parse_args()
    if args.restore:
        return restore()
    if args.name:
        return swap(args.name)
    ap.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
