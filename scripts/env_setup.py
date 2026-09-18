"""把第三方库的写路径与并发原语适配到受限环境。

背景：本项目的运行环境受文件沙箱约束。以下冲突及处理方式均已实测确认：

1. **写路径**：Ultralytics 默认写 `%APPDATA%\\Ultralytics`，matplotlib 写用户缓存目录
   —— 均在工作区外，会被拒绝。
   处理：设置 `YOLO_CONFIG_DIR` 与 `MPLCONFIGDIR` 指向工作区内。

2. **命名管道**：受限沙箱下程序不能打开命名管道。`multiprocessing.pool.ThreadPool`
   与 DataLoader 的多进程 worker 都依赖它。
   处理：DataLoader 用 `workers=0`（见 `run_pipeline.py` 默认值）；
        Ultralytics 的 `cache_labels` 内部硬用 ThreadPool，需打补丁改为顺序执行。

3. **uv 缓存**：默认在 `%LOCALAPPDATA%\\uv\\cache`。
   处理：由 `.env.ps1` 设置 `UV_CACHE_DIR`。

4. **★ HF 缓存分居两地，不能统一**（本文件最贵的一条教训）：
      `nvidia/LocateAnything-3B`（7.3 GB）只在 `~/.cache/huggingface/hub`
      `IDEA-Research/grounding-dino-tiny`（~700 MB）只在工作区内 `.hf/hub`
   两处都**不可兼得**：`~/.cache` 在工作区外（只读，新模型下不进去），
   而 `.hf` 里没有 LocateAnything 的完整权重。
   **把 HF_HUB_CACHE 指向任一处，另一个模型都会触发重新下载**——
   实测曾因此静默重下 5.6 GB 并卡住 20 分钟以上。
   处理：`HF_HUB_CACHE` 保持指向 `~/.cache/huggingface/hub`（那里有最大的
   LocateAnything）；Grounding DINO 改用 `local_files_only=True` 从 `.hf/hub` 读，
   或在首次下载时临时覆盖 `HF_HUB_CACHE`。**不要全局覆盖 HF_HUB_CACHE。**

**必须在 `import ultralytics` 之前调用 `apply()`。**
"""
from __future__ import annotations

import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
YOLO_CONFIG_DIR = REPO_ROOT / ".ultralytics-config"
MPL_CONFIG_DIR = REPO_ROOT / ".mpl-cache"
# OpenAI CLIP 默认下载到 ~/.cache/clip（工作区外）。YOLO-World 的 set_classes 依赖它。
CLIP_CACHE_DIR = REPO_ROOT / ".cache" / "clip"
# torch 的 inductor/dynamo 缓存与临时目录同样默认在工作区外
TORCH_CACHE_DIR = REPO_ROOT / ".tmp" / "inductor"
# HF 缓存：**保持系统默认**（含 LocateAnything 完整权重，7.3 GB）。
# 见模块 docstring 第 4 条——不要把它指到工作区内。
HF_HUB_DEFAULT = Path.home() / ".cache" / "huggingface" / "hub"
# Grounding DINO 等在工作区内下载的模型放这里
HF_LOCAL_HUB = REPO_ROOT / ".hf" / "hub"
TMP_DIR = REPO_ROOT / ".tmp"


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
    # YOLO-World 的 set_classes 会用 CLIP 做文本编码；默认写 ~/.cache/clip。
    # 注意：环境变量无效，必须猴补 clip.load（见 _patch_clip_download_root）。
    CLIP_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    # torch 的缓存与临时文件
    TORCH_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("TORCHINDUCTOR_CACHE_DIR", str(TORCH_CACHE_DIR))
    os.environ.setdefault("TMPDIR", str(TMP_DIR))
    # 避免 ultralytics 用 pip 子进程自动装依赖（受限环境会失败）
    os.environ.setdefault("YOLO_AUTOINSTALL", "false")


def _patch_clip_download_root() -> bool:
    """强制 CLIP 从工作区内读取/下载权重。

    问题：Ultralytics 的 `build_text_model()` 调用 `clip.load(size, device=device)`，
    **不传 `download_root`**，于是 CLIP 回退到硬编码的 `~/.cache/clip`（工作区外），
    在受限环境中抛 PermissionError。设置 `CLIP_DOWNLOAD_ROOT` 环境变量**无效**——
    CLIP 根本没读它。

    处理：包装 `clip.load`，仅当调用方未指定 download_root 时注入工作区路径。
    """
    try:
        import clip as clip_mod
    except ImportError:
        return False
    if getattr(clip_mod.load, "__root_patched__", False):
        return True

    original_load = clip_mod.load
    root = str(CLIP_CACHE_DIR)

    def load(name, device="cpu", jit=False, download_root=None, **kwargs):  # noqa: ANN001
        return original_load(name, device=device, jit=jit,
                            download_root=download_root or root, **kwargs)

    load.__root_patched__ = True  # type: ignore[attr-defined]
    clip_mod.load = load
    return True


def _patch_clip_token_device() -> bool:
    """修复 Ultralytics 的 CLIP 文本编码 device 不匹配。

    问题（ultralytics 8.3.253 实测）：`CLIP.tokenize()` 返回的 token 张量在 **CPU**，
    而 `CLIP.__init__` 执行 `clip.load(size, device=device)` 与 `self.to(device)`，
    把内部 torch 模块放到了 `device`（有 GPU 时是 cuda）。
    `get_text_pe()` 随后执行 `model.encode_text(token)`，在 embedding 查表时抛：
        RuntimeError: Expected all tensors to be on the same device,
        but got index is on cpu, different from other tensors on cuda:0

    处理：包装 `CLIP.tokenize`，把返回的 token 移到**内部 torch 模块参数的真实设备**。

    关键细节（踩过的坑）：**不能用 `self.device`**。实测 `self.device` 可能记录为 `cpu`
    而 `self.model.parameters()` 实际在 `cuda:0`，用它反而制造出 device 不匹配。
    必须从参数真实位置推导。
    """
    try:
        from ultralytics.nn.text_model import CLIP
    except ImportError as exc:
        print(f"[env_setup] 无法导入 CLIP 文本模型，跳过 device 补丁：{exc}")
        return False
    if getattr(CLIP.tokenize, "__device_patched__", False):
        return True

    original_tokenize = CLIP.tokenize

    def tokenize(self, texts, truncate=True):  # noqa: ANN001
        tokens = original_tokenize(self, texts, truncate=truncate)
        try:
            inner = getattr(self, "model", None)  # CLIP 内部 torch 模块
            if inner is not None and hasattr(inner, "parameters"):
                param = next(inner.parameters(), None)
                if param is not None and hasattr(tokens, "to"):
                    tokens = tokens.to(param.device)
        except (StopIteration, AttributeError):
            pass
        return tokens

    tokenize.__device_patched__ = True  # type: ignore[attr-defined]
    CLIP.tokenize = tokenize
    return True


def prepare_ultralytics() -> bool:
    """在 import ultralytics 之后调用：按需打补丁。返回是否打了补丁（任一成功即为 True）。"""
    patched = [
        _patch_clip_download_root(),
        _patch_clip_token_device(),
    ]
    if not _threadpool_available():
        patched.append(_patch_ultralytics_cache_labels())
    return any(patched)


apply()

# 若 ultralytics 已经可导入，立刻尝试打补丁
prepare_ultralytics()
