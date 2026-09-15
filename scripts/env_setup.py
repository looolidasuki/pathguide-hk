"""把第三方库的写路径与并发原语适配到受限环境。

背景：本项目的运行环境受文件沙箱约束。三个已知冲突，以及各自的处理方式：

1. **写路径**：Ultralytics 默认写 `%APPDATA%\\Ultralytics`，matplotlib 写用户缓存目录
   —— 均在工作区外，会被拒绝。
   处理：设置 `YOLO_CONFIG_DIR` 与 `MPLCONFIGDIR` 指向工作区内。

2. **命名管道**：受限沙箱下程序不能打开命名管道。`multiprocessing.pool.ThreadPool`
   与 DataLoader 的多进程 worker 都依赖它。
   处理：DataLoader 用 `workers=0`（见 `run_pipeline.py` 默认值）；
        Ultralytics 的 `cache_labels` 内部硬用 ThreadPool，需打补丁改为顺序执行。

3. **uv 缓存**：默认在 `%LOCALAPPDATA%\\uv\\cache`。
   处理：由 `.env.ps1` 设置 `UV_CACHE_DIR`。

**必须在 `import ultralytics` 之前调用 `apply()`。**
"""
from __future__ import annotations

import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
YOLO_CONFIG_DIR = REPO_ROOT / ".ultralytics-config"
MPL_CONFIG_DIR = REPO_ROOT / ".mpl-cache"


def _threadpool_available() -> bool:
    """探测本环境能否使用依赖命名管道的 ThreadPool。"""
    try:
        from multiprocessing.pool import ThreadPool

        with ThreadPool(2) as pool:
            pool.map(abs, [-1, -2])
        return True
    except (PermissionError, OSError):
        return False


def _patch_ultralytics_cache_labels() -> bool:
    """把 Ultralytics 的 cache_labels 换成顺序版本，避免 ThreadPool 依赖命名管道。

    仅在 ThreadPool 不可用时生效。返回是否实际打了补丁。

    说明：
    - `cache_labels` 实际定义在 `ultralytics.data.dataset.YOLODataset` 上（经 MRO 确认）。
    - 补丁严格复刻上游产出的缓存字典结构（labels/hash/results/msgs/version），
      并调用官方 `save_dataset_cache_file`，以保证 `get_labels()` 能正确读取。
    - `verify_image_label` 在本版本接受**单个元组参数**，返回 **10 元素 list**
      （成功与失败路径都是 10 元素），失败时 result[0] 为 None。
    - `DATASET_CACHE_VERSION` 定义在 `ultralytics.data.dataset`，不在 `data.utils`。
    - `BaseDataset` 未提供 `get_hash` 方法，hash 需用官方工具函数计算。
    """
    try:
        from ultralytics.data import dataset as ds
        from ultralytics.data.utils import (
            get_hash,
            save_dataset_cache_file,
            verify_image_label,
        )
    except Exception:  # noqa: BLE001  ultralytics 未安装或接口变动
        return False

    cache_version = getattr(ds, "DATASET_CACHE_VERSION", None)
    target = getattr(ds, "YOLODataset", None)
    if target is None or cache_version is None:
        return False
    if getattr(target.cache_labels, "__sequential_patch__", False):
        return True

    def cache_labels(self, path=Path("./labels.cache")):  # noqa: ANN001
        x: dict = {"labels": []}
        nm = nf = ne = nc = 0
        msgs: list[str] = []
        nkpt, ndim = self.data.get("kpt_shape", (0, 0))
        n_names = len(self.data["names"])

        for im_file, lb_file in zip(self.im_files, self.label_files):
            result = verify_image_label((
                im_file,
                lb_file,
                self.prefix,
                self.use_keypoints,
                n_names,
                nkpt,
                ndim,
                self.single_cls,
            ))
            img_out, lb, shape, segments, keypoint, nm_f, nf_f, ne_f, nc_f, msg = result
            nm += nm_f
            nf += nf_f
            ne += ne_f
            nc += nc_f
            if img_out is not None:
                x["labels"].append({
                    # 必须是 str：下游 load_image() 会调用 im_file.endswith(...)
                    "im_file": str(img_out),
                    "shape": shape,
                    "cls": lb[:, 0:1],
                    "bboxes": lb[:, 1:],
                    "segments": segments,
                    "keypoints": keypoint,
                    "normalized": True,
                    "bbox_format": "xywh",
                })
            if msg:
                msgs.append(msg)

        if msgs:
            for m in msgs[:20]:
                print(f"  [cache_labels] {m}")
        if nf == 0:
            print(f"  [cache_labels] 警告：{path} 中未找到任何标签文件")
        x["hash"] = get_hash(self.label_files + self.im_files)
        x["results"] = nf, nm, ne, nc, len(self.im_files)
        x["msgs"] = msgs
        save_dataset_cache_file(self.prefix, path, x, cache_version)
        return x

    cache_labels.__sequential_patch__ = True  # type: ignore[attr-defined]
    target.cache_labels = cache_labels
    return True


def apply() -> None:
    YOLO_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("YOLO_CONFIG_DIR", str(YOLO_CONFIG_DIR))
    MPL_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("MPLCONFIGDIR", str(MPL_CONFIG_DIR))


def prepare_ultralytics() -> bool:
    """在 import ultralytics 之后调用：按需打补丁。返回是否打了补丁。"""
    if _threadpool_available():
        return False
    return _patch_ultralytics_cache_labels()


apply()

# 若 ultralytics 已经可导入，立刻尝试打补丁
prepare_ultralytics()
