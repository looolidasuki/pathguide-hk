"""训练流程复现脚本（可重复执行）。

按顺序跑完：生成合成数据 → manifest → 分组划分 → 标签门禁 → 训练 → 评测 → 报告。
**不含 TFLite 导出**——导出需下载 TensorFlow 并调用转换子进程，在受限沙箱中会挂起，
请在普通终端执行 `scripts/export_model.py`。

用法：
    .venv\\Scripts\\python.exe scripts\\run_all.py
"""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / "scripts"

STEPS: list[tuple[str, list[str]]] = [
    ("生成合成数据集", ["gen_synthetic.py", "--per-class", "24", "--sources", "8"]),
    ("生成 manifest", ["make_manifest.py"]),
    ("分组分层划分", ["split_dataset.py", "--seed", "42"]),
    ("标签质量门禁", ["check_labels.py"]),
]

TRAIN_AND_EVAL = [
    "run_pipeline.py",
    "--skip-generate", "--epochs", "60", "--imgsz", "416", "--batch", "8", "--workers", "0",
]


def main() -> int:
    t0 = time.time()
    py = str(Path(sys.executable))

    for title, script_args in STEPS:
        print(f"\n{'=' * 66}\n>> {title}\n{'=' * 66}", flush=True)
        proc = subprocess.run([py, str(SCRIPTS / script_args[0]), *script_args[1:]],
                              cwd=str(REPO_ROOT))
        # check_labels 在仅有警告时返回 0，存在致命错误时返回 2
        if proc.returncode != 0:
            print(f"步骤失败（退出码 {proc.returncode}）：{script_args[0]}")
            return proc.returncode

    print(f"\n{'=' * 66}\n>> 训练与评测\n{'=' * 66}", flush=True)
    proc = subprocess.run([py, str(SCRIPTS / TRAIN_AND_EVAL[0]), *TRAIN_AND_EVAL[1:]],
                          cwd=str(REPO_ROOT))
    if proc.returncode != 0:
        return proc.returncode

    print(f"\n全部完成，耗时 {(time.time() - t0) / 60:.1f} 分钟。")
    print(f"报告：{(REPO_ROOT / 'runs' / 'pipeline_report.md').relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
