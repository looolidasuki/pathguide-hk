# 领路通（PathGuide HK）M0–M2 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立可复现的数据→标注→训练→导出流水线，产出 16 类主检测器与店铺 logo 分类器的量化模型（`best.tflite`），并为真机 Demo 提供已验证的模型资产。

**Architecture:** 以 `data/dataset/` 为全流程单一事实源（images + labels + manifest.csv + split.json），所有脚本围绕它做幂等变换。数据集划分以"来源文件夹"为分组键防止视频抽帧造成的泄漏。训练与导出均以黄金集（`data/golden/baseline_200`）为不可污染的质量门禁。

**Tech Stack:** Python 3.11 / Ultralytics YOLOv8 / PyTorch CUDA / OpenCV / imagehash / pytest；Windows 本机 NVIDIA 显卡。

**Spec:** `docs/superpowers/specs/2026-09-15-pathguide-thesis-design.md`

---

## Global Constraints

以下约束对**每一个** Task 生效，不再逐条重复：

1. **运行环境**：Windows + 本机 NVIDIA 显卡（RTX 5070 / sm_120 / 11.91 GB）。所有训练/导出命令必须先执行 `. .\.env.ps1` 激活虚拟环境。**不使用 conda**（本机未安装），改用 uv + venv + Python 3.12。
2. **Windows 多进程**：任何使用 DataLoader 多进程的入口脚本必须置于 `if __name__ == "__main__":` 保护内。`workers` 起始值为 **2**，出现卡死或共享内存错误时降为 **0**。
3. **路径**：仓库内一律使用 `__file__` 推导的绝对路径（`Path(__file__).resolve().parents[N]`），禁止硬编码盘符，禁止依赖当前工作目录。Python 代码中路径统一用 `pathlib.Path`，仅在传给 cv2 时转为 `str`。
4. **图像读取**：必须用 `cv2.imdecode(np.fromfile(path, dtype=np.uint8), cv2.IMREAD_COLOR)` 而非 `cv2.imread`，以支持中文路径。
5. **编码**：所有文件写入显式 `encoding="utf-8"`，CSV 使用 `utf-8-sig`（便于 Excel 打开）。控制台打印避免 emoji 与非 GBK 字符（Windows GBK 控制台会抛 `UnicodeEncodeError`）。
6. **随机性**：所有涉及随机划分的脚本必须接受 `--seed`，默认 **42**，并在输出中记录实际使用值。
7. **类别表单一事实源**：`configs/classes.json`。任何脚本、测试、应用都不得硬编码类别名或顺序。类别顺序**一经用于训练即冻结**（YOLO 标签以索引写入，重排会导致标签语义错位）。
8. **黄金集不可污染**：`data/golden/baseline_200/` 在任何训练、预标、增强流程中都必须被排除，仅用于评测对照。
9. **保存与提交**：每完成一个 Task 的最后一个 Step 执行一次 git 提交，提交信息使用该 Task 给出的原文。
10. **阈值与指标**：天桥入口召回率 > 70%、障碍物召回率 > 70% 为 M2 出口条件；量化后精度损失 > 1.5% 则回退 FP16。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `configs/classes.json` | **类别表单一事实源**：16 类 id / name_en / name_zh / group / priority / announced |
| `configs/collect_plan.md` | 采集计划：目标点位、每类目标张数、覆盖维度、现场清单 |
| `scripts/env_check.py` | 环境与 CUDA/显存验证，产出机器可读报告 |
| `scripts/extract_frames.py` | 视频抽帧 + 拉普拉斯模糊过滤 |
| `scripts/dedup.py` | 感知哈希去重（默认仅作用于训练域，刻意保留评测集真实冗余） |
| `scripts/make_manifest.py` | 扫描 `data/dataset/` 生成 `manifest.csv` |
| `scripts/split_dataset.py` | 分组 + 分层划分，产出 `split.json` 与 `datasets/pathguide.yaml` |
| `scripts/check_labels.py` | 标签质量门禁，产出 `dataset_report.md` |
| `scripts/train_cls.py` | logo 分类器训练与评测包装（含 Windows 保护） |
| `scripts/smoke_test.py` | 2 分钟环境冒烟测试（YOLOv8n 预训练权重 + 20 张图，2 epoch） |
| `tests/test_extract_frames.py` | 抽帧质量判定与文件名生成的单元测试 |
| `tests/test_dedup.py` | 去重逻辑单元测试 |
| `tests/test_manifest.py` | manifest 列与元数据解析单元测试 |
| `tests/test_split.py` | 划分无泄漏与分层保证的单元测试 |
| `tests/test_check_labels.py` | 标签校验规则单元测试 |
| `tests/test_classes.py` | 类别表自洽性单元测试 |
| `data/dataset/` | 单一事实源：images / labels / manifest.csv / split.json / dataset_report.md |
| `data/logos/` | logo 分类器 ImageFolder 数据集（`{store_id}/` 与 `unknown/`） |
| `datasets/pathguide.yaml` | 训练配置（由 `split_dataset.py` 生成，不手工编辑） |

**边界说明：** 所有 `scripts/` 下的脚本是**独立的 CLI 工具**，彼此不 import；共享逻辑若出现重复（如路径常量），宁可重复也不建立隐式耦合——因为流水线各步骤会被单独重跑。唯一被多处引用的模块是 `configs/classes.json`（以文件读取方式，非 Python import）。

---

## Task 1: 工程骨架与环境验证

**Files:**
- Create: `configs/classes.json`
- Create: `scripts/env_check.py`
- Create: `tests/test_classes.py`
- Create: `requirements.txt`
- Create: `.gitignore`
- Create: 空目录占位 `data/raw/route_A/.gitkeep` 等（见 Step 5）

**Interfaces:**
- Consumes: 无（起始任务）
- Produces:
  - `configs/classes.json`，结构为 `{"version": 1, "classes": [{"id": 0, "name_en": str, "name_zh": str, "group": str, "priority": str, "announced": bool}, ...]}`，共 16 项，`id` 从 0 连续递增。
  - `scripts/env_check.py` 可执行，退出码 0 表示环境可用，非 0 表示不可用。

---

- [ ] **Step 1: 创建目录骨架与 `.gitignore`**

```bash
cd "C:/Users/user/PycharmProjects/Accessible Visual Guidance"
mkdir -p configs scripts tests datasets docs/superpowers/specs docs/superpowers/plans
mkdir -p data/raw/route_A data/raw/route_B data/frames data/dataset/images data/dataset/labels
mkdir -p data/golden/baseline_200 data/golden/seed_300 data/logos runs app
```

创建 `.gitignore`：

```gitignore
# Python
__pycache__/
*.py[cod]
.venv/
venv/
.pytest_cache/

# 数据（体积大，不入库；raw/ 与 dataset/ 由外部备份盘维护）
data/raw/**
data/frames/**
data/dataset/images/**
data/dataset/labels/**
data/logos/**
!data/**/.gitkeep

# 训练产物
runs/**
weights/
*.pt
*.onnx
*.tflite

# IDE
.idea/
.vscode/

# 临时
*.tmp
~$*
```

- [ ] **Step 2: 写 `tests/test_classes.py`（先写测试）**

```python
import json
from pathlib import Path

import pytest

CLASSES_PATH = Path(__file__).resolve().parents[1] / "configs" / "classes.json"

EXPECTED_GROUPS = ["footbridge", "obstacle", "guide", "indoor", "train_only"]


@pytest.fixture(scope="module")
def classes():
    with CLASSES_PATH.open(encoding="utf-8") as f:
        return json.load(f)["classes"]


def test_class_count_is_16(classes):
    assert len(classes) == 16


def test_ids_are_contiguous_from_zero(classes):
    assert [c["id"] for c in classes] == list(range(16))


def test_names_en_are_unique(classes):
    names = [c["name_en"] for c in classes]
    assert len(names) == len(set(names))


def test_names_en_are_snake_case_ascii(classes):
    for c in classes:
        assert c["name_en"].isascii()
        assert c["name_en"] == c["name_en"].lower()
        assert " " not in c["name_en"]


def test_every_class_has_chinese_label(classes):
    for c in classes:
        assert c["name_zh"].strip()


def test_groups_are_known(classes):
    for c in classes:
        assert c["group"] in EXPECTED_GROUPS


def test_train_only_class_is_not_announced(classes):
    train_only = [c for c in classes if c["group"] == "train_only"]
    assert len(train_only) == 1
    assert train_only[0]["name_en"] == "ambiguous_vertical"
    assert train_only[0]["announced"] is False


def test_all_p0_classes_are_announced(classes):
    for c in classes:
        if c["priority"] == "P0" and c["group"] != "train_only":
            assert c["announced"] is True
```

- [ ] **Step 3: 运行测试确认失败**

Run: `pytest tests/test_classes.py -v`
Expected: FAIL —— `FileNotFoundError`，因为 `configs/classes.json` 尚不存在。

- [ ] **Step 4: 创建 `configs/classes.json`**

> **类别顺序即标签索引，一经训练不得重排。**

```json
{
  "version": 1,
  "note": "类别顺序即 YOLO 标签索引，一经用于训练即冻结，不得重排。",
  "classes": [
    { "id": 0,  "name_en": "footbridge_entrance", "name_zh": "天橋入口",   "group": "footbridge", "priority": "P0", "announced": true },
    { "id": 1,  "name_en": "stairs",              "name_zh": "樓梯",       "group": "footbridge", "priority": "P0", "announced": true },
    { "id": 2,  "name_en": "escalator_outdoor",   "name_zh": "戶外扶梯",   "group": "footbridge", "priority": "P0", "announced": true },
    { "id": 3,  "name_en": "elevator",            "name_zh": "升降機",     "group": "footbridge", "priority": "P0", "announced": true },
    { "id": 4,  "name_en": "ramp",                "name_zh": "斜道",       "group": "footbridge", "priority": "P0", "announced": true },
    { "id": 5,  "name_en": "footbridge_railing",  "name_zh": "天橋欄杆",   "group": "footbridge", "priority": "P1", "announced": true },
    { "id": 6,  "name_en": "pedestrian",          "name_zh": "行人",       "group": "obstacle",   "priority": "P0", "announced": true },
    { "id": 7,  "name_en": "street_obstacle",     "name_zh": "路邊障礙",   "group": "obstacle",   "priority": "P0", "announced": true },
    { "id": 8,  "name_en": "step",                "name_zh": "台階",       "group": "obstacle",   "priority": "P0", "announced": true },
    { "id": 9,  "name_en": "glass_door",          "name_zh": "玻璃門",     "group": "obstacle",   "priority": "P0", "announced": true },
    { "id": 10, "name_en": "tactile_paving",      "name_zh": "盲道",       "group": "guide",      "priority": "P1", "announced": true },
    { "id": 11, "name_en": "zebra_crossing",      "name_zh": "斑馬線",     "group": "guide",      "priority": "P1", "announced": true },
    { "id": 12, "name_en": "shop_front",          "name_zh": "店鋪門面",   "group": "indoor",     "priority": "P0", "announced": true },
    { "id": 13, "name_en": "escalator_indoor",    "name_zh": "商場扶梯",   "group": "indoor",     "priority": "P0", "announced": true },
    { "id": 14, "name_en": "glass_door_indoor",   "name_zh": "商場玻璃門", "group": "indoor",     "priority": "P0", "announced": true },
    { "id": 15, "name_en": "ambiguous_vertical",  "name_zh": "垂直設施不明", "group": "train_only", "priority": "P0", "announced": false }
  ]
}
```

- [ ] **Step 5: 创建占位文件与 `requirements.txt`**

```bash
for d in data/raw/route_A data/raw/route_B data/frames data/dataset/images data/dataset/labels data/golden/baseline_200 data/golden/seed_300 data/logos runs; do touch "$d/.gitkeep"; done
```

`requirements.txt`：

```
ultralytics>=8.3,<8.4
torch>=2.2
torchvision>=0.17
opencv-python>=4.9
imagehash>=4.3
Pillow>=10.0
pandas>=2.0
pyyaml>=6.0
pytest>=8.0
onnx>=1.16
onnxruntime>=1.18
```

- [ ] **Step 6: 创建并验证环境（uv + venv，实际采用方案）**

> **与原计划的偏差说明：** 原计划使用 conda，但本机未安装 conda，且系统默认 Python 为 **3.14.4**
> ——PyTorch 尚无 3.14 的 wheel。实测改用 **uv + venv + Python 3.12.3**（`py -0p` 已存在该解释器）。
>
> 另一处偏差：uv 默认缓存在 `%LOCALAPPDATA%\uv\cache`，被文件沙箱拒绝写入。
> 因此必须把 `UV_CACHE_DIR` 指向工作区内（见 `.env.ps1`）。

```powershell
# 激活环境（已封装为脚本）
. .\.env.ps1
```

该脚本等价于：

```powershell
uv venv --python 3.12 .venv
$env:UV_CACHE_DIR = "$PWD\.uv-cache"

# RTX 50 系为 Blackwell (sm_120)，必须用 CUDA 12.8+ 的 PyTorch 构建
uv pip install --python .venv\Scripts\python.exe torch torchvision `
  --index-url https://download.pytorch.org/whl/cu128

uv pip install --python .venv\Scripts\python.exe -r requirements.txt
```

**实测结果（2026-09-15）：** `torch 2.11.0+cu128` / `torchvision 0.26.0+cu128` / CUDA 12.8 /
RTX 5070 / sm_120 / 11.91 GB 显存 / GPU 矩阵乘法通过。

- [ ] **Step 7: 写 `scripts/env_check.py`**

```python
"""验证训练环境可用性。退出码 0 = 可用，1 = 不可用。"""
from __future__ import annotations

import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
REPORT_PATH = REPO_ROOT / "runs" / "env_report.json"
MIN_FREE_DISK_GB = 20.0


def check_python() -> dict:
    ok = sys.version_info >= (3, 10)
    return {"name": "python", "ok": ok, "detail": platform.python_version()}


def check_packages() -> dict:
    missing: list[str] = []
    versions: dict[str, str] = {}
    for mod in ("torch", "torchvision", "cv2", "ultralytics", "imagehash", "pandas", "yaml"):
        try:
            m = __import__(mod)
            versions[mod] = getattr(m, "__version__", "unknown")
        except ImportError:
            missing.append(mod)
    return {"name": "packages", "ok": not missing, "detail": versions, "missing": missing}


def check_cuda() -> dict:
    try:
        import torch
    except ImportError:
        return {"name": "cuda", "ok": False, "detail": "torch 未安装"}
    if not torch.cuda.is_available():
        return {
            "name": "cuda",
            "ok": False,
            "detail": "torch.cuda.is_available() == False；将退化为 CPU 训练",
        }
    idx = torch.cuda.current_device()
    props = torch.cuda.get_device_properties(idx)
    total_gb = props.total_memory / (1024 ** 3)
    return {
        "name": "cuda",
        "ok": True,
        "detail": {
            "torch": torch.__version__,
            "cuda_runtime": torch.version.cuda,
            "device": props.name,
            "vram_gb": round(total_gb, 2),
            "recommended_batch": recommend_batch(total_gb),
        },
    }


def recommend_batch(vram_gb: float) -> int:
    if vram_gb >= 12:
        return 16
    if vram_gb >= 8:
        return 12
    if vram_gb >= 6:
        return 8
    if vram_gb >= 4:
        return 4
    return 2


def check_nvidia_smi() -> dict:
    exe = shutil.which("nvidia-smi")
    if exe is None:
        return {"name": "nvidia_smi", "ok": False, "detail": "未找到 nvidia-smi"}
    try:
        out = subprocess.run(
            [exe, "--query-gpu=name,driver_version", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=20, check=False,
        )
        detail = out.stdout.strip() or out.stderr.strip()
        return {"name": "nvidia_smi", "ok": out.returncode == 0, "detail": detail}
    except Exception as exc:  # noqa: BLE001
        return {"name": "nvidia_smi", "ok": False, "detail": repr(exc)}


def check_disk() -> dict:
    usage = shutil.disk_usage(REPO_ROOT)
    free_gb = usage.free / (1024 ** 3)
    return {
        "name": "disk",
        "ok": free_gb >= MIN_FREE_DISK_GB,
        "detail": {"free_gb": round(free_gb, 1), "required_gb": MIN_FREE_DISK_GB},
    }


def main() -> int:
    checks = [check_python(), check_packages(), check_cuda(), check_nvidia_smi(), check_disk()]
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(
        json.dumps({"checks": checks}, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    for c in checks:
        print(f"[{'OK ' if c['ok'] else 'FAIL'}] {c['name']}: {c['detail']}")
    print(f"\nreport -> {REPORT_PATH}")
    for c in checks:
        if not c["ok"] and c["name"] == "cuda":
            print("\n警告：无可用 GPU，训练将极慢。请先修复 CUDA 后再进入 Task 8。")
    return 0 if all(c["ok"] for c in checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 8: 运行环境检查**

Run: `python scripts/env_check.py`
Expected: 输出 5 行检查结果，`cuda` 行显示显卡名与显存，并给出 `recommended_batch`。

**若 `cuda` FAIL**：不要在 CPU 上继续。先安装匹配的 CUDA 版 PyTorch：
```bash
pip uninstall -y torch torchvision
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
```
然后重跑 `python scripts/env_check.py` 直到 `cuda` 为 OK。

**记录 `recommended_batch` 的值**，Task 8 与 Task 11 的 `batch` 参数使用它。

- [ ] **Step 9: 运行类别表测试**

Run: `pytest tests/test_classes.py -v`
Expected: PASS（9 passed）

- [ ] **Step 10: 提交**

```bash
git add .gitignore requirements.txt configs/classes.json scripts/env_check.py tests/test_classes.py
git add -f data/raw/route_A/.gitkeep data/raw/route_B/.gitkeep
git commit -m "chore: 工程骨架、16 类类别表单一事实源、环境验证脚本"
```

---

## Task 2: 采集计划与标注规范

**Files:**
- Create: `configs/collect_plan.md`
- Create: `configs/annotate_spec.md`
- Modify: `configs/classes.json`（仅当实地核实后需要调整类别中文名；**不得变更 id 顺序**）

**Interfaces:**
- Consumes: `configs/classes.json`（Task 1）
- Produces: 两份人工规范文档。`configs/annotate_spec.md` 中的"边界判定规则"将在 Task 8 的人工标注与 Task 9 的 VLM 复核 Prompt 中被直接引用。

---

- [ ] **Step 1: 写 `configs/collect_plan.md`**

内容必须包含以下章节，逐项填写真实点位与数量（下表为模板，**采集前必须补全"实际点位"列**）：

```markdown
# 采集计划

## 1. 两条路线的分工
| 路线 | 角色 | 是否参与训练 |
|---|---|---|
| A 调景岭站 → 彩明苑天桥 → 彩明商场 | 主实验区 | 是（train/val） |
| B 中环站 A 出口 → 中环天桥 → IFC | 泛化验证集 | **否，仅 test** |

## 2. 采集方式要求（强制）
- 每个点位**视频与照片同时录制**：视频用于抽帧（训练集主力），照片用于补充稀有类别。
- 视频：1080p / 30fps，每个点位连续录制 ≥ 60 秒，缓慢平移 + 缓慢靠近。
- 照片：每点位 ≥ 30 张，覆盖 3 距离 × 3 角度 × 2 光照。
- 目录：`data/raw/route_A/<YYYYMMDD>_<点位名>/`，目录名只用 ASCII 与下划线。

## 3. 每类目标张数（抽帧去重后计）
| 组 | 类别 | 目标张数 | 实际点位 | 已完成 |
|---|---|---|---|---|
| 天桥专项 | footbridge_entrance | ≥250 | | |
| 天桥专项 | stairs | ≥180 | | |
| 天桥专项 | escalator_outdoor | ≥120 | | |
| 天桥专项 | elevator | ≥100 | | |
| 天桥专项 | ramp | ≥100 | | |
| 天桥专项 | footbridge_railing | ≥150 | | |
| 障碍物 | pedestrian | ≥300 | | |
| 障碍物 | street_obstacle | ≥200 | | |
| 障碍物 | step | ≥150 | | |
| 障碍物 | glass_door | ≥150 | | |
| 导航辅助 | tactile_paving | ≥200 | | |
| 导航辅助 | zebra_crossing | ≥150 | | |
| 室内 | shop_front | ≥250 | | |
| 室内 | escalator_indoor | ≥150 | | |
| 室内 | glass_door_indoor | ≥100 | | |
| 训练专用 | ambiguous_vertical | ≥250 | | |
| 负样本 | （无标注） | ≥300 | | |
| 路线 B | （全部类别） | ≥400 | | |

## 4. 关键硬约束
- **第 1 周内必须拍满 footbridge_entrance ≥ 250 张**。天桥入口不是随处可见的物体，
  样本不足会直接拖垮 M2；不可留到第 3 周再补。
- `ambiguous_vertical` 必须在**正对扶梯口 / 正对楼梯口**的视角下采集，
  因该视角下难以区分，是安全关键类。

## 5. 隐私与合规
- 避免对可辨识面部特写；行人类别以远景、背影、侧影、剪影为主。
- 商场内拍摄若被保安询问，说明为学术研究用途；避免拍摄柜台内部与店员。
- 网络补充图片须在 `manifest.csv` 的备注列注明来源，论文中声明。
```

- [ ] **Step 2: 写 `configs/annotate_spec.md`**

```markdown
# 标注规范

## 1. 标注工具
X-AnyLabeling（YOLO 格式导出至 `data/dataset/labels/`，与图像同名 `.txt`）。

## 2. 格式
每行：`<class_id> <cx> <cy> <w> <h>`，均为相对图像宽高的归一化浮点数，范围 [0, 1]。
class_id 必须取自 `configs/classes.json`，不得臆造。

## 3. 边界判定规则（核心，逐类）
| 类别 | 框住什么 | 反例（不标） |
|---|---|---|
| footbridge_entrance | 天桥入口的**通道开口整体**（含上方标识牌） | 天桥全貌、远处的桥身 |
| stairs | 可见的**阶梯段整体** | 单级台阶（标 step） |
| escalator_outdoor | 户外扶梯**含扶手带与梳齿板的整体** | 楼梯、静止的自动人行道 |
| elevator | 电梯**门与门框** | 电梯按钮面板、楼层显示器 |
| ramp | 坡道**斜面与两侧护栏围成的区域** | 台阶、平地 |
| footbridge_railing | 一段连续的栏杆 | 临时围栏（标 street_obstacle） |
| pedestrian | 人的**整个人形** | 海报/广告牌上的人像 |
| street_obstacle | 围栏、立柱、垃圾桶、施工物料等**占据通行空间**的物体 | 正常摆放且不占道的设施 |
| step | **单级或两级**台阶、路缘 | 大段阶梯（标 stairs） |
| glass_door | 需要**穿越**的玻璃门 | 玻璃幕墙、玻璃窗 |
| tactile_paving | 盲道/触觉引路带的**可见段** | 普通地砖 |
| zebra_crossing | 斑马线的**可见段** | 其他路面标线 |
| shop_front | 店铺**门面整体**（含招牌区域），供后续 logo 裁剪 | 单独的招牌、店内场景 |
| escalator_indoor | 商场内扶梯（同 escalator_outdoor 判定） | 楼梯 |
| glass_door_indoor | 商场内需穿越的玻璃门 | 玻璃隔断 |
| ambiguous_vertical | **正对视角下无法判断是楼梯还是扶梯**的画面区域 | 任何能明确判定的情况 |

## 4. 强制规则
1. **遮挡处理**：遮挡 > 70% 不标；遮挡 30%–70% 标可见部分边界（不外推）。
2. **最小框尺寸**：短边 < 8 px 不标。
3. **`ambiguous_vertical` 优先级**：当无法确定是楼梯还是扶梯时，
   **只标 `ambiguous_vertical`，不得同时标 `stairs` 或 `escalator_*`**。三者互斥。
4. **玻璃门互斥**：户外场景标 `glass_door`，商场室内场景标 `glass_door_indoor`，
   **同一目标只标其一**。判定依据是拍摄时所处环境（室外/室内）。
5. **负样本**：无任何目标类别的图像，**生成同名空 `.txt` 文件**（不是不生成文件）。
   空标签文件是有效的负样本，`check_labels.py` 会区分"空标签"与"缺标签"。
6. **一致性优先于完美**：同一目标在不同图像中的框选范围必须一致。
   规范未覆盖的情形，记录下来并统一裁决，不要各自随意处理。

## 5. 黄金集冻结
- `data/golden/baseline_200/`：200 张纯人工精标，**永不参与训练/预标/增强**。
  用于论文中"AI 辅助标注 vs 纯人工标注"的对照实验。
- `data/golden/seed_300/`：300 张人工精标，覆盖全部 16 类，作为自举种子。
```

- [ ] **Step 3: 运行类别表测试确认未被破坏**

Run: `pytest tests/test_classes.py -v`
Expected: PASS（9 passed）。若因修改 `classes.json` 而失败，说明改动破坏了约束，须回退。

- [ ] **Step 4: 提交**

```bash
git add configs/collect_plan.md configs/annotate_spec.md
git commit -m "docs: 采集计划与标注规范，含逐类边界判定与互斥规则"
```

---

## Task 3: 视频抽帧与模糊过滤

**Files:**
- Create: `scripts/extract_frames.py`
- Create: `tests/test_extract_frames.py`

**Interfaces:**
- Consumes: `data/raw/route_A|route_B/<source>/` 下的 `.mp4` / `.mov` / `.avi`
- Produces:
  - `data/frames/<route>/<source>/<source>_<视频名>_<帧序号:06d>.jpg`
  - CLI：`python scripts/extract_frames.py --route route_A --fps 2 --blur-thresh 100`
  - 函数 `frame_filename(source: str, video_stem: str, frame_idx: int) -> str`
  - 函数 `is_sharp(gray: np.ndarray, threshold: float) -> bool`
  - 输出末尾打印 `kept=N skipped_blur=M skipped_dup=K`，供人工核对

---

- [ ] **Step 1: 写 `tests/test_extract_frames.py`**

```python
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from extract_frames import frame_filename, is_sharp  # noqa: E402


def test_frame_filename_is_zero_padded_and_ascii():
    name = frame_filename("20260920_tsk_footbridge", "VID_001", 7)
    assert name == "20260920_tsk_footbridge_VID_001_000007.jpg"
    assert name.isascii()


def test_frame_filename_pads_beyond_six_digits():
    name = frame_filename("s", "v", 1234567)
    assert name.endswith("_1234567.jpg")


def test_is_sharp_rejects_flat_image():
    flat = np.full((100, 100), 128, dtype=np.uint8)
    assert is_sharp(flat, threshold=100.0) is False


def test_is_sharp_accepts_high_contrast_noise():
    rng = np.random.default_rng(0)
    noisy = rng.integers(0, 256, size=(100, 100), dtype=np.uint8)
    assert is_sharp(noisy, threshold=100.0) is True


def test_is_sharp_threshold_is_exclusive():
    flat = np.full((50, 50), 200, dtype=np.uint8)
    assert is_sharp(flat, threshold=0.0) is False
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pytest tests/test_extract_frames.py -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'extract_frames'`

- [ ] **Step 3: 实现 `scripts/extract_frames.py`**

```python
"""从视频中按固定时间间隔抽帧，并过滤模糊帧。

用法：
    python scripts/extract_frames.py --route route_A --fps 2 --blur-thresh 100
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import cv2
import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
FRAMES_DIR = REPO_ROOT / "data" / "frames"
RAW_DIR = REPO_ROOT / "data" / "raw"

VIDEO_EXTS = {".mp4", ".mov", ".avi", ".mkv", ".MP4", ".MOV", ".AVI", ".MKV"}


def frame_filename(source: str, video_stem: str, frame_idx: int) -> str:
    """生成抽帧文件名：<source>_<video>_<六位帧号>.jpg"""
    return f"{source}_{video_stem}_{frame_idx:06d}.jpg"


def is_sharp(gray: np.ndarray, threshold: float) -> bool:
    """拉普拉斯方差 > threshold 视为清晰。"""
    return float(cv2.Laplacian(gray, cv2.CV_64F).var()) > threshold


def find_videos(raw_route_dir: Path) -> list[Path]:
    if not raw_route_dir.exists():
        return []
    return sorted(
        p for p in raw_route_dir.rglob("*") if p.is_file() and p.suffix in VIDEO_EXTS
    )


def extract_one(
    video_path: Path,
    out_dir: Path,
    source: str,
    fps: float,
    blur_thresh: float,
    max_frames: int | None,
) -> tuple[int, int, int]:
    """返回 (kept, skipped_blur, skipped_read_fail)。"""
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print(f"  [WARN] 无法打开视频：{video_path}")
        return 0, 0, 0

    video_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    if video_fps <= 0:
        video_fps = 30.0
    step = max(1, int(round(video_fps / fps)))

    out_dir.mkdir(parents=True, exist_ok=True)
    kept = skipped_blur = read_fail = 0
    read_idx = 0

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if read_idx % step == 0:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            if not is_sharp(gray, blur_thresh):
                skipped_blur += 1
            else:
                name = frame_filename(source, video_path.stem, read_idx)
                ok_write, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
                if not ok_write:
                    read_fail += 1
                else:
                    buf.tofile(str(out_dir / name))
                    kept += 1
                    if max_frames is not None and kept >= max_frames:
                        cap.release()
                        return kept, skipped_blur, read_fail
        read_idx += 1

    cap.release()
    return kept, skipped_blur, read_fail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--route", required=True, choices=["route_A", "route_B"])
    ap.add_argument("--fps", type=float, default=2.0, help="每秒抽取帧数")
    ap.add_argument("--blur-thresh", type=float, default=100.0)
    ap.add_argument("--max-frames", type=int, default=None)
    args = ap.parse_args()

    raw_route = RAW_DIR / args.route
    videos = find_videos(raw_route)
    if not videos:
        print(f"未在 {raw_route} 找到视频文件。")
        return 1

    total_kept = total_blur = total_fail = 0
    for video in videos:
        source = video.parent.name
        out_dir = FRAMES_DIR / args.route / source
        kept, blur, fail = extract_one(
            video, out_dir, source, args.fps, args.blur_thresh, args.max_frames
        )
        total_kept += kept
        total_blur += blur
        total_fail += fail
        print(f"{source}/{video.name}: kept={kept} blur={blur} fail={fail}")

    print(f"\nkept={total_kept} skipped_blur={total_blur} skipped_read_fail={total_fail}")
    print(f"输出目录：{FRAMES_DIR / args.route}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: 运行测试确认通过**

Run: `pytest tests/test_extract_frames.py -v`
Expected: PASS（5 passed）

- [ ] **Step 5: 在小样本上实测抽帧**

先把 1 个短视频放入 `data/raw/route_A/test_point/`，然后：

Run: `python scripts/extract_frames.py --route route_A --fps 2 --max-frames 20`
Expected: 输出 `kept=20 ...`，且 `data/frames/route_A/test_point/` 下有 20 个 jpg。

人工抽查 5 张：确认画面清晰、文件名含来源与帧号、无损坏文件。

- [ ] **Step 6: 提交**

```bash
git add scripts/extract_frames.py tests/test_extract_frames.py
git commit -m "feat: 视频抽帧与拉普拉斯模糊过滤"
```

---

## Task 4: 感知哈希去重

**Files:**
- Create: `scripts/dedup.py`
- Create: `tests/test_dedup.py`

**Interfaces:**
- Consumes: 图像目录树（`data/frames/<route>/<source>/` 与照片目录）
- Produces:
  - `data/dataset/images/<source>/<name>.jpg`（去重后）
  - 重复文件移入 `data/dataset/_duplicates/<source>/`（不删除，便于人工复核）
  - CLI：`python scripts/dedup.py --method phash --threshold 6 --scope train_only`
  - 函数 `hamming(a: int, b: int) -> int`
  - 函数 `is_duplicate(hash_bits: int, seen: list[int], threshold: int) -> bool`

> **职责边界：** `extract_frames.py` 只做"抽帧 + 去模糊"，**不做去重**；
> 去重完全由本脚本负责。两者职责分离，便于单独重跑。
>
> **设计说明：** 去重的目的是消除"同一段视频相邻帧几乎相同"造成的划分泄漏。
> 但**刻意保留路线 B 的真实冗余**——评测集若过度去重会偏乐观，失去泛化度量意义。
> 因此 `--scope` 默认为 `train_only`，即只对路线 A 去重，路线 B 原样保留。

---

- [ ] **Step 1: 写 `tests/test_dedup.py`**

```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from dedup import hamming, is_duplicate  # noqa: E402


def test_hamming_identical_is_zero():
    assert hamming(0b1010, 0b1010) == 0


def test_hamming_counts_differing_bits():
    assert hamming(0b1010, 0b0000) == 2


def test_hamming_symmetric():
    assert hamming(12345, 999) == hamming(999, 12345)


def test_is_duplicate_true_when_within_threshold():
    baseline = 0b1111111111
    assert is_duplicate(0b1111111101, [baseline], threshold=2) is True


def test_is_duplicate_false_when_beyond_threshold():
    baseline = 0b1111111111
    assert is_duplicate(0b0000000000, [baseline], threshold=2) is False


def test_is_duplicate_false_on_empty_seen():
    assert is_duplicate(0b1111, [], threshold=6) is False
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pytest tests/test_dedup.py -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'dedup'`

- [ ] **Step 3: 实现 `scripts/dedup.py`**

```python
"""基于感知哈希的图像去重。

用法：
    python scripts/dedup.py --method phash --threshold 6 --scope train_only
"""
from __future__ import annotations

import argparse
import shutil
from collections import defaultdict
from pathlib import Path

import imagehash
import numpy as np
from PIL import Image, UnidentifiedImageError

REPO_ROOT = Path(__file__).resolve().parents[1]
FRAMES_DIR = REPO_ROOT / "data" / "frames"
DATASET_IMAGES = REPO_ROOT / "data" / "dataset" / "images"
DUP_DIR = REPO_ROOT / "data" / "dataset" / "_duplicates"

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG"}
# 路线 B 为泛化评测域，刻意保留真实冗余，不去重
EVAL_ONLY_ROUTES = {"route_B"}


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def is_duplicate(hash_bits: int, seen: list[int], threshold: int) -> bool:
    return any(hamming(hash_bits, s) <= threshold for s in seen)


def compute_hash(path: Path, method: str) -> int:
    with Image.open(path) as im:
        im = im.convert("L")
        if method == "phash":
            return int(str(imagehash.phash(im)), 16)
        if method == "dhash":
            return int(str(imagehash.dhash(im)), 16)
        if method == "ahash":
            return int(str(imagehash.average_hash(im)), 16)
        raise ValueError(f"未知 method: {method}")


def iter_images(root: Path):
    if not root.exists():
        return
    for p in sorted(root.rglob("*")):
        if p.is_file() and p.suffix in IMAGE_EXTS:
            yield p


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--method", default="phash", choices=["phash", "dhash", "ahash"])
    ap.add_argument("--threshold", type=int, default=6, help="汉明距离阈值，<= 阈值判为重复")
    ap.add_argument("--scope", default="train_only", choices=["train_only", "all"])
    ap.add_argument("--with-photos", action="store_true", help="同时处理 data/raw 下的照片")
    args = ap.parse_args()

    src_roots: list[Path] = []
    for route_dir in sorted(p for p in FRAMES_DIR.glob("route_*") if p.is_dir()):
        if args.scope == "train_only" and route_dir.name in EVAL_ONLY_ROUTES:
            print(f"[跳过] {route_dir.name}（评测域，保留真实冗余）")
            continue
        src_roots.append(route_dir)
    if args.with_photos:
        for route_dir in sorted(p for p in (REPO_ROOT / "data" / "raw").glob("route_*") if p.is_dir()):
            if args.scope == "train_only" and route_dir.name in EVAL_ONLY_ROUTES:
                continue
            src_roots.append(route_dir)

    if not src_roots:
        print("没有找到可处理的图像目录。请先运行 extract_frames.py。")
        return 1

    kept_total = dup_total = err_total = 0
    summary: dict[str, tuple[int, int]] = defaultdict(lambda: (0, 0))

    for root in src_roots:
        route = root.name
        seen_by_source: dict[str, list[int]] = defaultdict(list)
        for img in iter_images(root):
            source = img.parent.name
            out_dir = DATASET_IMAGES / source
            out_dir.mkdir(parents=True, exist_ok=True)
            try:
                bits = compute_hash(img, args.method)
            except (UnidentifiedImageError, OSError) as exc:
                print(f"  [WARN] 无法读取 {img.name}: {exc}")
                err_total += 1
                continue

            if is_duplicate(bits, seen_by_source[source], args.threshold):
                dup_dir = DUP_DIR / source
                dup_dir.mkdir(parents=True, exist_ok=True)
                shutil.move(str(img), str(dup_dir / img.name))
                dup_total += 1
                k, d = summary[source]
                summary[source] = (k, d + 1)
            else:
                seen_by_source[source].append(bits)
                shutil.copy2(str(img), str(out_dir / img.name))
                kept_total += 1
                k, d = summary[source]
                summary[source] = (k + 1, d)

    for source in sorted(summary):
        k, d = summary[source]
        print(f"{source}: kept={k} dup={d}")
    print(f"\nkept={kept_total} dup={dup_total} unreadable={err_total}")
    print(f"输出：{DATASET_IMAGES}")
    print(f"重复件：{DUP_DIR}（未删除，可人工复核）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: 运行测试确认通过**

Run: `pytest tests/test_dedup.py -v`
Expected: PASS（6 passed）

- [ ] **Step 5: 在实测抽帧结果上运行去重**

Run: `python scripts/dedup.py --method phash --threshold 6 --scope train_only`
Expected: 输出每来源的 `kept/dup` 统计；`data/dataset/images/` 下出现图像；`route_B` 被跳过（若已有数据）。

**人工抽查**：从 `data/dataset/_duplicates/` 随机看 5 张，确认它们与保留帧确实高度相似。若发现被误判为重复的不同场景，提高 `--threshold` 到 4 重跑（需先清空 `data/dataset/images/` 与 `_duplicates/`）。

- [ ] **Step 6: 提交**

```bash
git add scripts/dedup.py tests/test_dedup.py
git commit -m "feat: 感知哈希去重，评测域刻意保留冗余以保证泛化度量有效"
```

---

## Task 5: manifest 生成

**Files:**
- Create: `scripts/make_manifest.py`
- Create: `tests/test_manifest.py`

**Interfaces:**
- Consumes: `data/dataset/images/<source>/*.jpg`、`data/dataset/labels/<name>.txt`
- Produces:
  - `data/dataset/manifest.csv`，列严格为：`image_name, source_folder, route, capture, has_label, has_positive, n_boxes, classes`
  - 函数 `parse_source_meta(source_folder: str) -> dict`，返回 `{"route": str, "capture": str}`
  - 函数 `read_label_summary(label_path: Path) -> tuple[int, list[int]]`，返回 `(框数, 类别 id 列表)`

> **`source_folder` 是划分的分组键**，其命名必须能区分路线与采集方式。
> 约定：文件夹名以 `route_A` / `route_B` 前缀标识路线；`capture` 由文件名或子目录名推断（`video` / `photo`）。

---

- [ ] **Step 1: 写 `tests/test_manifest.py`**

```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from make_manifest import parse_source_meta, read_label_summary  # noqa: E402


def test_parse_source_meta_detects_route_a():
    meta = parse_source_meta("route_A_20260920_tsk_footbridge")
    assert meta["route"] == "route_A"


def test_parse_source_meta_detects_route_b():
    meta = parse_source_meta("route_B_20260922_central_bridge")
    assert meta["route"] == "route_B"


def test_parse_source_meta_unknown_route():
    meta = parse_source_meta("misc_photos")
    assert meta["route"] == "unknown"


def test_parse_source_meta_detects_photo_capture():
    meta = parse_source_meta("route_A_photos_20260920")
    assert meta["capture"] == "photo"


def test_parse_source_meta_defaults_to_video():
    meta = parse_source_meta("route_A_20260920_tsk_footbridge")
    assert meta["capture"] == "video"


def test_read_label_summary_counts_boxes_and_classes(tmp_path):
    label = tmp_path / "a.txt"
    label.write_text("0 0.5 0.5 0.2 0.2\n3 0.1 0.1 0.05 0.05\n0 0.7 0.7 0.1 0.1\n", encoding="utf-8")
    n_boxes, classes = read_label_summary(label)
    assert n_boxes == 3
    assert classes == [0, 3]


def test_read_label_summary_empty_file_is_zero_boxes(tmp_path):
    label = tmp_path / "empty.txt"
    label.write_text("", encoding="utf-8")
    assert read_label_summary(label) == (0, [])


def test_read_label_summary_missing_file(tmp_path):
    assert read_label_summary(tmp_path / "nope.txt") == (-1, [])
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pytest tests/test_manifest.py -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'make_manifest'`

- [ ] **Step 3: 实现 `scripts/make_manifest.py`**

```python
"""扫描 data/dataset/ 生成 manifest.csv，作为划分与评测的依据。"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = REPO_ROOT / "data" / "dataset"
IMAGES_DIR = DATASET_DIR / "images"
LABELS_DIR = DATASET_DIR / "labels"
MANIFEST_PATH = DATASET_DIR / "manifest.csv"

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG"}
MANIFEST_COLUMNS = [
    "image_name",
    "source_folder",
    "route",
    "capture",
    "has_label",
    "has_positive",
    "n_boxes",
    "classes",
]


def parse_source_meta(source_folder: str) -> dict:
    """从来源文件夹名解析路线与采集方式。"""
    lower = source_folder.lower()
    if lower.startswith("route_a") or "_route_a" in lower:
        route = "route_A"
    elif lower.startswith("route_b") or "_route_b" in lower:
        route = "route_B"
    else:
        route = "unknown"
    capture = "photo" if "photo" in lower else "video"
    return {"route": route, "capture": capture}


def read_label_summary(label_path: Path) -> tuple[int, list[int]]:
    """返回 (框数, 排序去重后的类别 id 列表)。文件缺失返回 (-1, [])。"""
    if not label_path.exists():
        return -1, []
    classes: set[int] = set()
    n_boxes = 0
    with label_path.open(encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 5:
                continue
            try:
                classes.add(int(parts[0]))
            except ValueError:
                continue
            n_boxes += 1
    return n_boxes, sorted(classes)


def build_rows() -> list[dict]:
    rows: list[dict] = []
    if not IMAGES_DIR.exists():
        return rows
    for source_dir in sorted(p for p in IMAGES_DIR.iterdir() if p.is_dir()):
        source = source_dir.name
        meta = parse_source_meta(source)
        for img in sorted(source_dir.iterdir()):
            if not img.is_file() or img.suffix not in IMAGE_EXTS:
                continue
            n_boxes, classes = read_label_summary(LABELS_DIR / f"{img.stem}.txt")
            rows.append({
                "image_name": img.name,
                "source_folder": source,
                "route": meta["route"],
                "capture": meta["capture"],
                "has_label": n_boxes >= 0,
                "has_positive": n_boxes > 0,
                "n_boxes": max(n_boxes, 0),
                "classes": "|".join(str(c) for c in classes),
            })
    return rows


def main() -> int:
    rows = build_rows()
    if not rows:
        print(f"未在 {IMAGES_DIR} 找到图像。请先运行 dedup.py。")
        return 1
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    with MANIFEST_PATH.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=MANIFEST_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)

    n_missing = sum(1 for r in rows if not r["has_label"])
    n_negative = sum(1 for r in rows if r["has_label"] and not r["has_positive"])
    by_route: dict[str, int] = {}
    for r in rows:
        by_route[r["route"]] = by_route.get(r["route"], 0) + 1

    print(f"图像总数：{len(rows)}")
    for route, n in sorted(by_route.items()):
        print(f"  {route}: {n}")
    print(f"负样本（空标签）：{n_negative}")
    print(f"缺标签文件：{n_missing}")
    print(f"manifest -> {MANIFEST_PATH}")
    if n_missing:
        print("\n注意：缺标签表示尚未标注。完成标注后重新运行本脚本。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 运行测试确认通过**

Run: `pytest tests/test_manifest.py -v`
Expected: PASS（8 passed）

- [ ] **Step 5: 生成 manifest**

Run: `python scripts/make_manifest.py`
Expected: 打印图像总数与各路线计数。此时 `缺标签文件` 等于图像总数（尚未标注），这是**预期状态**。

用 Excel 打开 `data/dataset/manifest.csv`，确认中文无乱码、列名正确。

- [ ] **Step 6: 提交**

```bash
git add scripts/make_manifest.py tests/test_manifest.py
git commit -m "feat: manifest 生成，含路线/采集方式解析与标签摘要"
```

---

## Task 6: 分组分层划分（防泄漏）

**Files:**
- Create: `scripts/split_dataset.py`
- Create: `tests/test_split.py`

**Interfaces:**
- Consumes: `data/dataset/manifest.csv`（Task 5）、`configs/classes.json`（Task 1）
- Produces:
  - `data/dataset/split.json`：`{"seed": int, "train": [image_name...], "val": [...], "test": [...]}`
  - `datasets/pathguide.yaml`：Ultralytics 训练配置
  - 函数 `assign_folds(rows: list[dict], ratios: tuple[float, float, float], seed: int) -> dict[str, list[str]]`
  - 函数 `validate_no_leakage(split: dict, manifest: list[dict]) -> list[str]`，返回违规描述列表（空列表表示通过）

> **这是本计划最关键的脚本。** 若采用随机划分，同一段视频抽出的相邻帧会同时进入训练集与验证集，**指标虚高 10+ 个百分点**，且论文结论不可信。

---

- [ ] **Step 1: 写 `tests/test_split.py`**

```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from split_dataset import assign_folds, validate_no_leakage  # noqa: E402


def _row(name: str, source: str, cls: int) -> dict:
    return {"image_name": name, "source_folder": source, "classes": str(cls),
            "has_label": True, "has_positive": True}


def test_no_source_folder_appears_in_two_folds():
    rows = [_row(f"img{i}.jpg", f"src{i // 10}", i % 3) for i in range(200)]
    split = assign_folds(rows, (0.8, 0.1, 0.1), seed=42)
    assert validate_no_leakage(split, rows) == []


def test_all_images_are_assigned_exactly_once():
    rows = [_row(f"img{i}.jpg", f"src{i // 10}", i % 3) for i in range(120)]
    split = assign_folds(rows, (0.8, 0.1, 0.1), seed=42)
    assigned = [n for fold in ("train", "val", "test") for n in split[fold]]
    assert sorted(assigned) == sorted(r["image_name"] for r in rows)


def test_same_seed_is_reproducible():
    rows = [_row(f"img{i}.jpg", f"src{i // 10}", i % 3) for i in range(120)]
    assert assign_folds(rows, (0.8, 0.1, 0.1), seed=42) == assign_folds(rows, (0.8, 0.1, 0.1), seed=42)


def test_different_seed_changes_assignment():
    rows = [_row(f"img{i}.jpg", f"src{i // 10}", i % 3) for i in range(120)]
    assert assign_folds(rows, (0.8, 0.1, 0.1), seed=1) != assign_folds(rows, (0.8, 0.1, 0.1), seed=2)


def test_val_covers_every_present_class_when_possible():
    # 6 个来源各含 3 个类别，val 至少应出现全部 3 个类别
    rows = []
    for s in range(6):
        for c in range(3):
            for k in range(5):
                rows.append(_row(f"s{s}_c{c}_{k}.jpg", f"src{s}", c))
    split = assign_folds(rows, (0.6, 0.2, 0.2), seed=42)
    val_rows = [r for r in rows if r["image_name"] in set(split["val"])]
    present = {int(r["classes"]) for r in val_rows}
    assert present == {0, 1, 2}


def test_validate_no_leakage_detects_violation():
    rows = [_row("a.jpg", "srcX", 0)]
    split = {"train": ["a.jpg"], "val": ["a.jpg"], "test": []}
    assert validate_no_leakage(split, rows) != []


def test_validate_no_leakage_detects_unassigned():
    rows = [_row("a.jpg", "srcX", 0)]
    split = {"train": [], "val": [], "test": []}
    assert validate_no_leakage(split, rows) != []
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pytest tests/test_split.py -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'split_dataset'`

- [ ] **Step 3: 实现 `scripts/split_dataset.py`**

```python
"""按来源文件夹分组、按类别分层的训练/验证/测试划分。

用法：
    python scripts/split_dataset.py --ratios 0.8 0.1 0.1 --seed 42
"""
from __future__ import annotations

import argparse
import csv
import json
import random
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = REPO_ROOT / "data" / "dataset"
MANIFEST_PATH = DATASET_DIR / "manifest.csv"
SPLIT_PATH = DATASET_DIR / "split.json"
DATASETS_DIR = REPO_ROOT / "datasets"
YAML_PATH = DATASETS_DIR / "pathguide.yaml"
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"


def load_manifest() -> list[dict]:
    with MANIFEST_PATH.open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def load_class_names() -> list[str]:
    with CLASSES_PATH.open(encoding="utf-8") as f:
        data = json.load(f)
    return [c["name_en"] for c in sorted(data["classes"], key=lambda c: c["id"])]


def source_class_multihot(rows: list[dict], n_classes: int) -> dict[str, set[int]]:
    out: dict[str, set[int]] = defaultdict(set)
    for r in rows:
        for token in str(r.get("classes", "")).split("|"):
            token = token.strip()
            if token.isdigit():
                out[r["source_folder"]].add(int(token))
    return out


def assign_folds(
    rows: list[dict], ratios: tuple[float, float, float], seed: int
) -> dict[str, list[str]]:
    """按 source_folder 分组、按类别分层划分。

    分层方式：以"来源包含的类别集合"为桶，桶内洗牌后在 (train, val, test) 三折间轮转，
    val 与 test 只取桶内前两个来源，从而保证每个类别都有来源进入 val/test。

    优先级裁决（依 spec §11 风险登记）：
        无泄漏 > val 覆盖全类别 > train/val/test 比例精确性
    """
    by_source: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_source[r["source_folder"]].append(r)

    src_classes = source_class_multihot(rows, 16)
    buckets: dict[tuple[int, ...], list[str]] = defaultdict(list)
    for source in sorted(by_source):
        buckets[tuple(sorted(src_classes.get(source, set())))].append(source)

    rng = random.Random(seed)
    fold_sources: dict[str, list[str]] = {"train": [], "val": [], "test": []}
    fold_order = ("train", "val", "test")

    for key in sorted(buckets):
        group = sorted(buckets[key])
        rng.shuffle(group)
        for i, source in enumerate(group):
            if i == 1:
                fold_sources["val"].append(source)
            elif i == 2:
                fold_sources["test"].append(source)
            else:
                # 其余来源按当前张数最少者优先，使比例接近 ratios
                fold = min(fold_order, key=lambda f: _count(by_source, fold_sources[f]))
                fold_sources[fold].append(source)

    # 兜底：任一折为空时，从最大的折迁出一个来源
    for fold in ("val", "test"):
        if not fold_sources[fold]:
            donor = max(fold_order, key=lambda f: (len(fold_sources[f]), f))
            if len(fold_sources[donor]) >= 2:
                fold_sources[fold].append(fold_sources[donor].pop())

    def names(src_list: list[str]) -> list[str]:
        return [r["image_name"] for s in src_list for r in by_source[s]]

    split = {fold: sorted(names(fold_sources[fold])) for fold in fold_order}
    return split


def _count(by_source: dict[str, list[dict]], src_list: list[str]) -> int:
    return sum(len(by_source[s]) for s in src_list)


def validate_no_leakage(split: dict, manifest: list[dict]) -> list[str]:
    """返回违规描述列表；空列表表示通过。"""
    problems: list[str] = []
    src_of = {r["image_name"]: r["source_folder"] for r in manifest}

    folds = {fold: set(split.get(fold, [])) for fold in ("train", "val", "test")}

    for name in folds["train"]:
        if name in folds["val"] or name in folds["test"]:
            problems.append(f"图像出现在多个折中：{name}")
    for name in folds["val"]:
        if name in folds["test"]:
            problems.append(f"图像出现在多个折中：{name}")

    for a, b in (("train", "val"), ("train", "test"), ("val", "test")):
        shared = {src_of[n] for n in folds[a] if n in src_of} & {src_of[n] for n in folds[b] if n in src_of}
        if shared:
            problems.append(f"{a} 与 {b} 共享来源文件夹（泄漏）：{sorted(shared)[:5]}")

    assigned = folds["train"] | folds["val"] | folds["test"]
    unassigned = set(src_of) - assigned
    if unassigned:
        problems.append(f"{len(unassigned)} 张图像未被分配到任何折，例如 {sorted(unassigned)[:5]}")

    return problems


def write_yaml(split: dict, class_names: list[str]) -> None:
    names_block = "\n".join(f"  {i}: {n}" for i, n in enumerate(class_names))
    content = (
        "# 由 scripts/split_dataset.py 自动生成，请勿手工编辑\n"
        f"path: {DATASET_DIR.as_posix()}\n"
        "train: train.txt\n"
        "val: val.txt\n"
        "test: test.txt\n\n"
        f"nc: {len(class_names)}\n"
        "names:\n"
        f"{names_block}\n"
    )
    DATASETS_DIR.mkdir(parents=True, exist_ok=True)
    YAML_PATH.write_text(content, encoding="utf-8")

    for fold in ("train", "val", "test"):
        listing = DATASET_DIR / f"{fold}.txt"
        lines = [f"images/{n}" for n in split[fold]]
        listing.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ratios", type=float, nargs=3, default=[0.8, 0.1, 0.1],
                    metavar=("TRAIN", "VAL", "TEST"))
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    if not MANIFEST_PATH.exists():
        print(f"未找到 {MANIFEST_PATH}。请先运行 make_manifest.py。")
        return 1

    rows = [r for r in load_manifest() if str(r.get("has_label", "")).lower() in ("true", "1")]
    if not rows:
        print("manifest 中没有已标注的图像。请先完成标注（Task 8）。")
        return 1

    total_ratio = sum(args.ratios)
    if abs(total_ratio - 1.0) > 1e-6:
        print(f"ratios 之和必须为 1.0，当前为 {total_ratio}")
        return 1

    split = assign_folds(rows, tuple(args.ratios), args.seed)
    problems = validate_no_leakage(split, rows)
    if problems:
        print("划分校验失败：")
        for p in problems:
            print(f"  - {p}")
        return 1

    payload = {"seed": args.seed, "ratios": list(args.ratios),
               "counts": {k: len(v) for k, v in split.items()}, **split}
    SPLIT_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    write_yaml(split, load_class_names())

    print(f"seed={args.seed}")
    for fold in ("train", "val", "test"):
        print(f"  {fold}: {len(split[fold])} 张, {len({r['source_folder'] for r in rows if r['image_name'] in set(split[fold])})} 个来源")
    print(f"split -> {SPLIT_PATH}")
    print(f"yaml  -> {YAML_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

> **实现提示：** `assign_folds` 采用"类别集合分桶 + 桶内轮转"策略：桶内第 2、3 个来源分别进 val 与 test，
> 其余来源按当前张数最少者归入，从而兼顾分层与比例。
>
> **裁决优先级（依 spec §11）：无泄漏 > val 覆盖全类别 > 比例精确性。**
> 比例是 0.8/0.1/0.1 还是 0.75/0.13/0.12 无所谓，但 **val 中没有 `footbridge_entrance`
> 就意味着 M2 无法产出该类召回率**，那才是必须修的问题。
>
> 执行 Task 6 Step 5 后必须人工确认：`val` 折的类别覆盖是否包含全部 5 个 P0 天桥/障碍类。

- [ ] **Step 4: 运行测试确认通过**

Run: `pytest tests/test_split.py -v`
Expected: PASS（7 passed）

- [ ] **Step 5: 在真实数据上运行划分**

Run: `python scripts/split_dataset.py --ratios 0.8 0.1 0.1 --seed 42`
Expected: 打印三折张数与来源数，无"划分校验失败"，生成 `split.json`、`train.txt`、`val.txt`、`test.txt`、`datasets/pathguide.yaml`。

**人工核查**：打开 `datasets/pathguide.yaml`，确认 `nc: 16` 且 16 个类名与 `configs/classes.json` 一致。

- [ ] **Step 6: 提交**

```bash
git add scripts/split_dataset.py tests/test_split.py datasets/pathguide.yaml data/dataset/split.json
git commit -m "feat: 按来源分组、按类别分层的划分，含泄漏校验"
```

---

## Task 7: 标签质量门禁

**Files:**
- Create: `scripts/check_labels.py`
- Create: `tests/test_check_labels.py`

**Interfaces:**
- Consumes: `data/dataset/images/`、`data/dataset/labels/`、`configs/classes.json`
- Produces:
  - `data/dataset/dataset_report.md`（人工阅读）
  - 退出码 0 = 通过，2 = 存在致命问题（越界框、非法类别 id、坐标非数值）
  - 函数 `validate_line(line: str, n_classes: int) -> list[str]`，返回该行的错误列表（空 = 合法）
  - 函数 `parse_box(line: str) -> tuple[int, float, float, float, float] | None`

> **这是训练前置门禁。** 标注错误在训练时不会报错，只会让 mAP 莫名偏低，
> 然后耗费数日怀疑模型。必须先跑通本脚本。

---

- [ ] **Step 1: 写 `tests/test_check_labels.py`**

```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from check_labels import parse_box, validate_line  # noqa: E402

N = 16


def test_valid_line_has_no_errors():
    assert validate_line("0 0.5 0.5 0.2 0.2", N) == []


def test_wrong_field_count_is_error():
    assert validate_line("0 0.5 0.5 0.2", N) != []


def test_non_numeric_is_error():
    assert validate_line("0 abc 0.5 0.2 0.2", N) != []


def test_class_id_out_of_range_is_error():
    assert validate_line("16 0.5 0.5 0.2 0.2", N) != []
    assert validate_line("-1 0.5 0.5 0.2 0.2", N) != []


def test_coordinate_out_of_range_is_error():
    assert validate_line("0 1.5 0.5 0.2 0.2", N) != []
    assert validate_line("0 0.5 0.5 0.2 -0.1", N) != []


def test_zero_size_box_is_error():
    assert validate_line("0 0.5 0.5 0.0 0.2", N) != []


def test_parse_box_returns_tuple():
    assert parse_box("3 0.25 0.75 0.1 0.2") == (3, 0.25, 0.75, 0.1, 0.2)


def test_parse_box_returns_none_on_bad_input():
    assert parse_box("nonsense") is None


def test_box_exceeding_image_bounds_is_error():
    # cx=0.95, w=0.2 -> x2=1.05 越界
    assert validate_line("0 0.95 0.5 0.2 0.2", N) != []
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pytest tests/test_check_labels.py -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'check_labels'`

- [ ] **Step 3: 实现 `scripts/check_labels.py`**

```python
"""标注质量门禁：越界框、非法类别、极小框、类别分布、空标签统计。

用法：
    python scripts/check_labels.py
退出码：0 通过；2 存在致命问题。
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = REPO_ROOT / "data" / "dataset"
IMAGES_DIR = DATASET_DIR / "images"
LABELS_DIR = DATASET_DIR / "labels"
REPORT_PATH = DATASET_DIR / "dataset_report.md"
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG"}

TINY_BOX_PX = 8.0          # 短边小于该像素值视为极小框（警告）
MIN_IMAGES_PER_CLASS = 50  # 类别样本下限（警告）


def load_classes() -> list[dict]:
    with CLASSES_PATH.open(encoding="utf-8") as f:
        return sorted(json.load(f)["classes"], key=lambda c: c["id"])


def parse_box(line: str) -> tuple[int, float, float, float, float] | None:
    parts = line.split()
    if len(parts) != 5:
        return None
    try:
        return int(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]), float(parts[4])
    except ValueError:
        return None


def validate_line(line: str, n_classes: int) -> list[str]:
    """返回该行的错误列表，空列表表示合法。"""
    errors: list[str] = []
    parts = line.split()
    if len(parts) != 5:
        return [f"字段数应为 5，实际 {len(parts)}"]
    parsed = parse_box(line)
    if parsed is None:
        return ["存在非数值字段"]
    cid, cx, cy, w, h = parsed
    if not (0 <= cid < n_classes):
        errors.append(f"类别 id {cid} 超出范围 [0, {n_classes - 1}]")
    for name, val in (("cx", cx), ("cy", cy), ("w", w), ("h", h)):
        if not (0.0 <= val <= 1.0):
            errors.append(f"{name}={val} 不在 [0, 1]")
    if w <= 0.0 or h <= 0.0:
        errors.append(f"框尺寸非正：w={w}, h={h}")
    if not errors:
        x1, y1, x2, y2 = cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2
        if x1 < -1e-6 or y1 < -1e-6 or x2 > 1 + 1e-6 or y2 > 1 + 1e-6:
            errors.append(f"框越界：({x1:.3f}, {y1:.3f})-({x2:.3f}, {y2:.3f})")
    return errors


def image_size(path: Path) -> tuple[int, int] | None:
    try:
        with Image.open(path) as im:
            return im.size
    except Exception:  # noqa: BLE001
        return None


def main() -> int:
    classes = load_classes()
    class_names = [c["name_en"] for c in classes]
    n_classes = len(classes)

    images = [p for p in IMAGES_DIR.rglob("*") if p.is_file() and p.suffix in IMAGE_EXTS]
    if not images:
        print(f"未在 {IMAGES_DIR} 找到图像。")
        return 1

    fatal: list[str] = []
    warnings: list[str] = []
    class_counts: Counter[int] = Counter()
    tiny_boxes = 0
    empty_labels = 0
    missing_labels = 0
    total_boxes = 0
    widths: list[float] = []
    heights: list[float] = []
    unreadable = 0

    for img in sorted(images):
        label_path = LABELS_DIR / f"{img.stem}.txt"
        if not label_path.exists():
            missing_labels += 1
            continue
        size = image_size(img)
        if size is None:
            unreadable += 1
            continue
        iw, ih = size
        lines = [ln.strip() for ln in label_path.read_text(encoding="utf-8").splitlines() if ln.strip()]
        if not lines:
            empty_labels += 1
            continue
        for ln in lines:
            errs = validate_line(ln, n_classes)
            if errs:
                fatal.append(f"{label_path.name}: '{ln}' -> {'; '.join(errs)}")
                continue
            cid, cx, cy, w, h = parse_box(ln)  # type: ignore[misc]
            class_counts[cid] += 1
            total_boxes += 1
            widths.append(w)
            heights.append(h)
            if min(w * iw, h * ih) < TINY_BOX_PX:
                tiny_boxes += 1

    for cid, n in class_counts.items():
        if n < MIN_IMAGES_PER_CLASS:
            warnings.append(
                f"类别 {class_names[cid]}(id={cid}) 仅 {n} 个框，低于建议下限 {MIN_IMAGES_PER_CLASS}"
            )
    for cid in range(n_classes):
        if class_counts.get(cid, 0) == 0:
            warnings.append(f"类别 {class_names[cid]}(id={cid}) 没有任何标注框")
    if missing_labels:
        warnings.append(f"{missing_labels} 张图像没有对应标签文件（标注未完成，或需生成空标签作为负样本）")
    if unreadable:
        warnings.append(f"{unreadable} 张图像无法读取")

    lines_out = [
        "# 数据集质量报告",
        "",
        f"- 图像总数：{len(images)}",
        f"- 有标注的图像：{len(images) - missing_labels - empty_labels}",
        f"- 空标签（负样本）：{empty_labels}",
        f"- 缺标签文件：{missing_labels}",
        f"- 标注框总数：{total_boxes}",
        f"- 极小框（短边 < {TINY_BOX_PX:.0f}px）：{tiny_boxes}",
        f"- 致命错误：{len(fatal)}",
        "",
        "## 类别分布",
        "",
        "| id | 类别 | 组 | 框数 |",
        "|---|---|---|---|",
    ]
    for c in classes:
        lines_out.append(
            f"| {c['id']} | {c['name_en']} | {c['group']} | {class_counts.get(c['id'], 0)} |"
        )
    lines_out += [
        "",
        "## 框尺寸（归一化）",
        "",
        f"- 宽：min={min(widths):.4f} mean={sum(widths)/len(widths):.4f} max={max(widths):.4f}" if widths else "- 宽：无数据",
        f"- 高：min={min(heights):.4f} mean={sum(heights)/len(heights):.4f} max={max(heights):.4f}" if heights else "- 高：无数据",
        "",
    ]
    if fatal:
        lines_out += ["## 致命错误（须修复后才能训练）", ""]
        lines_out += [f"- {e}" for e in fatal[:200]]
        if len(fatal) > 200:
            lines_out.append(f"- ...另有 {len(fatal) - 200} 条")
        lines_out.append("")
    if warnings:
        lines_out += ["## 警告", ""]
        lines_out += [f"- {w}" for w in warnings]
        lines_out.append("")

    REPORT_PATH.write_text("\n".join(lines_out), encoding="utf-8")

    print(f"图像 {len(images)} | 框 {total_boxes} | 空标签 {empty_labels} | 缺标签 {missing_labels}")
    print(f"致命错误 {len(fatal)} | 警告 {len(warnings)}")
    print(f"report -> {REPORT_PATH}")
    for e in fatal[:20]:
        print(f"  [FATAL] {e}")
    for w in warnings[:20]:
        print(f"  [WARN ] {w}")

    return 2 if fatal else 0


if __name__ == "__main__":
    raise SystemExit(main())
```

> **注意：** 本脚本只统计"文件级"错误，不做 IoU 重叠分析。
> 重度重叠（同一目标被标两次）属于标注质量范畴，在论文的"数据集质量"章节以人工抽样方式说明即可。

- [ ] **Step 4: 运行测试确认通过**

Run: `pytest tests/test_check_labels.py -v`
Expected: PASS（9 passed）

- [ ] **Step 5: 在真实数据上运行门禁**

Run: `python scripts/check_labels.py`
Expected: 此时因标注未完成，会输出大量 `缺标签文件` 警告但**致命错误应为 0**。
打开 `data/dataset/dataset_report.md` 核对类别分布表。

**这一步的判定标准：** 只有当 `致命错误 = 0` 时才可以进入 Task 8 的训练。

- [ ] **Step 6: 运行全部单元测试**

Run: `pytest tests/ -v`
Expected: PASS（44 passed）

**分布：** `test_classes.py` 9、`test_extract_frames.py` 5、`test_dedup.py` 6、`test_manifest.py` 8、`test_split.py` 7、`test_check_labels.py` 9。

若有用例失败，**先修测试或实现，不要跳过**——这些用例保护的是"划分无泄漏""标签合法""类别表一致"三条不可回退的约束。

- [ ] **Step 7: 提交**

```bash
git add scripts/check_labels.py tests/test_check_labels.py
git commit -m "feat: 标注质量门禁，含越界/非法类别/极小框/分布检查"
```

---

## Task 8: 环境冒烟测试（Windows + CUDA 关键验证）

**Files:**
- Create: `scripts/smoke_test.py`

**Interfaces:**
- Consumes: `datasets/pathguide.yaml`（Task 6，若尚未标注则使用内置的 20 张随机图临时生成）
- Produces: `runs/smoke/` 下的短期训练输出，以及退出码 0/1

> **为什么必须有这个 Task：** Windows 上的 Ultralytics 训练最常见的失败是
> DataLoader 多进程与 CUDA 初始化问题，往往在长训练跑到一半才暴露。
> 本 Task 用 **20 张图、2 epoch、约 2 分钟**把这类问题提前暴露。

---

- [ ] **Step 1: 实现 `scripts/smoke_test.py`**

```python
"""Windows + CUDA 冒烟测试：20 张图、2 epoch，验证训练链路可用。

用法：
    python scripts/smoke_test.py
"""
from __future__ import annotations

import json
import random
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = REPO_ROOT / "data" / "dataset"
IMAGES_DIR = DATASET_DIR / "images"
LABELS_DIR = DATASET_DIR / "labels"
SMOKE_DIR = REPO_ROOT / "data" / "_smoke"
SMOKE_YAML = REPO_ROOT / "datasets" / "smoke.yaml"
N_SAMPLES = 20
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG"}


def collect_labelled_pairs() -> list[tuple[Path, Path]]:
    pairs: list[tuple[Path, Path]] = []
    for img in IMAGES_DIR.rglob("*"):
        if not img.is_file() or img.suffix not in IMAGE_EXTS:
            continue
        label = LABELS_DIR / f"{img.stem}.txt"
        if label.exists():
            pairs.append((img, label))
    return pairs


def build_smoke_dataset(pairs: list[tuple[Path, Path]], seed: int = 42) -> Path:
    if SMOKE_DIR.exists():
        shutil.rmtree(SMOKE_DIR)
    (SMOKE_DIR / "images").mkdir(parents=True)
    (SMOKE_DIR / "labels").mkdir(parents=True)

    rng = random.Random(seed)
    sample = rng.sample(pairs, min(N_SAMPLES, len(pairs)))
    # 8:2 划分，样本极少时至少保证 val 非空
    n_val = max(1, len(sample) // 5)
    for i, (img, label) in enumerate(sample):
        sub = "val" if i < n_val else "train"
        shutil.copy2(img, SMOKE_DIR / "images" / f"{sub}_{img.name}")
        shutil.copy2(label, SMOKE_DIR / "labels" / f"{sub}_{img.stem}.txt")

    SMOKE_YAML.write_text(
        "# 冒烟测试用，自动生成，勿手工编辑\n"
        f"path: {SMOKE_DIR.as_posix()}\n"
        "train: images\n"
        "val: images\n\n"
        "nc: 16\n"
        "names:\n" + "\n".join(f"  {i}: c{i}" for i in range(16)) + "\n",
        encoding="utf-8",
    )
    return SMOKE_YAML


def main() -> int:
    try:
        import torch
    except ImportError:
        print("torch 未安装，请先 pip install -r requirements.txt")
        return 1

    if not torch.cuda.is_available():
        print("CUDA 不可用。请先修复 GPU 环境再运行冒烟测试。")
        return 1

    props = torch.cuda.get_device_properties(torch.cuda.current_device())
    vram_gb = props.total_memory / (1024 ** 3)
    print(f"GPU: {props.name} ({vram_gb:.1f} GB)")

    pairs = collect_labelled_pairs()
    if len(pairs) < 5:
        print(f"已标注图像不足（找到 {len(pairs)} 对），无法构成冒烟集。")
        print("请先完成至少 5 张图的标注（Task 8 之前的人工标注步骤）。")
        return 1

    yaml_path = build_smoke_dataset(pairs)
    print(f"冒烟集已构建：{SMOKE_DIR}（{min(N_SAMPLES, len(pairs))} 张）")

    from ultralytics import YOLO

    batch = 4
    if vram_gb >= 8:
        batch = 8

    model = YOLO("yolov8n.pt")
    results = model.train(
        data=str(yaml_path),
        epochs=2,
        imgsz=320,
        batch=batch,
        workers=2,
        project=str(REPO_ROOT / "runs"),
        name="smoke",
        exist_ok=True,
        verbose=True,
        plots=False,
    )

    save_dir = Path(getattr(results, "save_dir", REPO_ROOT / "runs" / "smoke"))
    best = save_dir / "weights" / "best.pt"
    print(f"\nsave_dir: {save_dir}")
    print(f"best.pt 存在: {best.exists()}")
    if not best.exists():
        print("冒烟测试失败：未产出权重文件。")
        return 1

    print("冒烟测试通过。训练链路（CUDA + DataLoader + 保存）均可用。")
    print("提示：Windows 下若出现卡死，请把 workers 改为 0 后重跑本脚本验证。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: 先用 5 张图手工标注作为输入**

在 X-AnyLabeling 中标注 5 张图，导出 YOLO 格式到 `data/dataset/labels/`。
（这一步是正式标注流程的预热，同时为冒烟测试提供最小输入。）

- [ ] **Step 3: 运行冒烟测试**

Run: `python scripts/smoke_test.py`
Expected: 打印 GPU 名称与显存，训练 2 epoch 完成，输出 `runs/smoke/weights/best.pt 存在: True`，末行 `冒烟测试通过`。

**若出现 CUDA out of memory**：把 `batch` 手动改为 2 重跑。
**若出现卡死无输出**：把 `workers=2` 改为 `workers=0` 重跑。这两种情况都属预期范围，记录下实际可用值。

- [ ] **Step 4: 记录实测配置**

把冒烟测试可用的 `batch` 与 `workers` 值记录到 `configs/collect_plan.md` 末尾新增一节：

```markdown
## 6. 实测训练配置（由冒烟测试得出）
- 显卡：
- 显存：
- 可用 batch：
- 可用 workers：
- 冒烟测试日期：
```

- [ ] **Step 5: 提交**

```bash
git add scripts/smoke_test.py configs/collect_plan.md
git commit -m "test: Windows+CUDA 冒烟测试，提前暴露 DataLoader 与显存问题"
```

---

## Task 9: logo 分类器试点（5 店铺）

**Files:**
- Create: `scripts/train_cls.py`
- Create: `configs/logos.json`
- Create: `data/logos/{store_id}/.gitkeep`（5 店铺 + `unknown`）

**Interfaces:**
- Consumes: `data/logos/{store_id}/*.jpg`（ImageFolder 格式的平铺结构）
- Produces:
  - `runs/logo_v1/weights/best.pt` 与 `best.tflite`
  - `runs/logo_v1/eval_report.md`：每类准确率、混淆矩阵、`unknown` 误报率
  - CLI：`python scripts/train_cls.py --epochs 60 --imgsz 224`

> **两段式架构（spec §5）的第一段。** 本 Task 独立于主检测器，可并行推进，
> 不阻塞 Task 8/10/11 的训练进度。

---

- [ ] **Step 1: 创建 `configs/logos.json`**

```json
{
  "version": 1,
  "note": "store_id 必须与 data/logos/ 下的文件夹名一致；unknown 必须存在。",
  "unknown_id": "unknown",
  "confidence_threshold": 0.78,
  "stores": [
    { "id": "unknown",         "name_zh": "未識別店鋪", "role": "negative", "announced": false },
    { "id": "mcdonalds",       "name_zh": "麥當勞",     "role": "target",   "announced": true },
    { "id": "seven_eleven",    "name_zh": "7-Eleven",   "role": "anchor",   "announced": true },
    { "id": "watsons",         "name_zh": "屈臣氏",     "role": "anchor",   "announced": true },
    { "id": "wellcome",        "name_zh": "惠康",       "role": "anchor",   "announced": true },
    { "id": "hsbc",            "name_zh": "滙豐銀行",   "role": "anchor",   "announced": true }
  ]
}
```

**执行时必须先用实地核实结果替换 `stores` 列表**——彩明商场内实际存在哪些店以现场为准。
`unknown` 与目标店（麦当劳）必须保留。

- [ ] **Step 2: 创建目录骨架**

```bash
for s in unknown mcdonalds seven_eleven watsons wellcome hsbc; do mkdir -p "data/logos/$s"; touch "data/logos/$s/.gitkeep"; done
```

- [ ] **Step 3: 实现 `scripts/train_cls.py`**

```python
"""logo 分类器训练与评测包装（Windows 安全）。

用法：
    python scripts/train_cls.py --epochs 60 --imgsz 224 --batch 32
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
LOGOS_DIR = REPO_ROOT / "data" / "logos"
LOGOS_CFG = REPO_ROOT / "configs" / "logos.json"
RUNS_DIR = REPO_ROOT / "runs"
MIN_PER_CLASS = 30


def check_dataset() -> tuple[bool, list[str]]:
    problems: list[str] = []
    with LOGOS_CFG.open(encoding="utf-8") as f:
        cfg = json.load(f)
    expected = {s["id"] for s in cfg["stores"]}
    if cfg["unknown_id"] not in expected:
        problems.append("unknown_id 不在 stores 列表中")

    existing = {p.name for p in LOGOS_DIR.iterdir() if p.is_dir()} if LOGOS_DIR.exists() else set()
    missing = expected - existing
    if missing:
        problems.append(f"缺少店铺目录：{sorted(missing)}")

    counts: Counter[str] = Counter()
    for store in sorted(existing):
        n = sum(1 for p in (LOGOS_DIR / store).iterdir()
                if p.is_file() and p.suffix.lower() in (".jpg", ".jpeg", ".png"))
        counts[store] = n
        if n < MIN_PER_CLASS:
            problems.append(f"{store} 仅 {n} 张图，低于建议下限 {MIN_PER_CLASS}")

    print("各店铺图像数：")
    for store in sorted(counts):
        print(f"  {store}: {counts[store]}")
    return (not problems), problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--imgsz", type=int, default=224)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--name", default="logo_v1")
    ap.add_argument("--skip-check", action="store_true")
    args = ap.parse_args()

    ok, problems = check_dataset()
    if not ok:
        print("\n数据集检查未通过：")
        for p in problems:
            print(f"  - {p}")
        if not args.skip_check:
            print("\n修复后重跑，或加 --skip-check 强制继续（不推荐）。")
            return 1

    from ultralytics import YOLO

    model = YOLO("yolov8n-cls.pt")
    model.train(
        data=str(LOGOS_DIR),
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        workers=2,
        fliplr=0.5,
        hsv_h=0.015,
        hsv_s=0.7,
        hsv_v=0.4,
        erasing=0.3,
        scale=0.6,
        translate=0.15,
        project=str(RUNS_DIR),
        name=args.name,
        exist_ok=True,
    )

    metrics = model.val()
    top1 = float(getattr(metrics, "top1", 0.0))
    print(f"\ntop1 = {top1:.4f}")

    save_dir = Path(getattr(metrics, "save_dir", RUNS_DIR / args.name))
    report = save_dir / "eval_report.md"
    report.write_text(
        "# logo 分类器评测\n\n"
        f"- top1 准确率：{top1:.4f}\n"
        f"- 类别数：{len(model.names)}\n"
        f"- 类别：{list(model.names.values())}\n\n"
        "## 待人工补充\n"
        "- 混淆矩阵中 known 被误判为其他 known 的样本\n"
        "- unknown 被误判为 known 的样本（**最关键指标**）\n",
        encoding="utf-8",
    )
    print(f"report -> {report}")
    print("\n下一步：导出 TFLite（见 Task 11 的导出命令，把 weights 换成本次 best.pt）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: 采集 5 店铺试点数据**

按 `spec §5.5` 要求拍摄，存入 `data/logos/<store_id>/`：
- 麦当劳：60 张（含纯图形 logo 与带文字招牌两种）
- 4 个锚点店：各 40 张
- `unknown`：**300 张非目标店铺门面 + 其他品牌 logo**

拍摄覆盖：3 距离 × 3 角度 × 2 光照。

- [ ] **Step 5: 运行数据集检查**

Run: `python scripts/train_cls.py --skip-check --epochs 1`
Expected: 打印各店铺图像数。若某店 < 30 张会报警告。**先确认 `unknown` ≥ 300 张**，否则返回补拍。

- [ ] **Step 6: 正式训练**

Run: `python scripts/train_cls.py --epochs 60 --imgsz 224 --batch 32`
Expected: 训练完成，打印 `top1 = 0.xx`，生成 `runs/logo_v1/eval_report.md`。

**判定标准：** `unknown` 被误判为 known 的比例必须 < 5%。若不达标：
1. 增加 `unknown` 样本量；
2. 提高 `configs/logos.json` 的 `confidence_threshold`；
3. 检查是否某个 known 店样本中存在大量 `unknown` 混入。

- [ ] **Step 7: 提交**

```bash
git add scripts/train_cls.py configs/logos.json
git commit -m "feat: logo 分类器训练脚本与 5 店铺试点配置"
```

---

## Task 10: 自举预标与人工复核（数据生产）

> **本 Task 无代码交付，产出是数据集本身。** 它产出 2,500+ 张已标注图像，
> 是 Task 11 正式训练的唯一输入。Steps 中的具体命令依赖 Task 8 的 v0 模型。

**Files:**
- Modify: `data/dataset/labels/`（新增大量标注文件）
- Modify: `data/golden/seed_300/quality_review.md`
- Create: `data/dataset/labeling_log.md`

**Interfaces:**
- Consumes: `data/dataset/images/`、`data/golden/seed_300/`、`runs/smoke/weights/best.pt`
- Produces: 完整标注的 `data/dataset/labels/`；更新后的 `manifest.csv`

---

- [ ] **Step 1: 人工精标种子集 300 张**

在 X-AnyLabeling 中按 `configs/annotate_spec.md` 标注 300 张，覆盖全部 16 类
（含 ≥60 张 `ambiguous_vertical`），导出到 `data/dataset/labels/`。

**同时在 `data/golden/baseline_200/` 存入 200 张纯人工精标结果**——
按 `spec §6.1`，这 200 张**永不参与训练**。对应的图像同时复制到 `data/dataset/images/`，
但其标签文件在训练前必须被排除（见 Step 5 的清单过滤）。

- [ ] **Step 2: 训练 v0 模型**

```bash
python scripts/make_manifest.py
python scripts/split_dataset.py --ratios 0.8 0.1 0.1 --seed 42
python scripts/check_labels.py
```

确认致命错误为 0 后：

```bash
yolo detect train model=yolov8n.pt data=datasets/pathguide.yaml ^
  epochs=80 imgsz=640 batch=8 workers=2 ^
  project=runs name=pg_v0
```

> **Windows 注意：** 上面使用 `^` 续行。若在 Git Bash 中执行，改为 `\`。

Expected: `runs/pg_v0/weights/best.pt` 生成。

- [ ] **Step 3: 用 v0 做半自动预标**

导出 v0 为 ONNX 供 X-AnyLabeling 加载：

```bash
yolo export model=runs/pg_v0/weights/best.pt format=onnx imgsz=640 opset=12
```

在 X-AnyLabeling 中：
1. 加载 `runs/pg_v0/weights/best.onnx`；
2. 对剩余 2,000–2,500 张执行「一键预测所有图像」；
3. 开启 SAM 自动修框（把预测框吸附到目标边界）；
4. 导出 YOLO 格式覆盖到 `data/dataset/labels/`。

- [ ] **Step 4: LocateAnything-3B 裁剪验证复核**

对预标产生的每个框裁剪后送入 VLM 询问是否为目标类别，剔除误检。

> **实现说明：** 这一步在 PC 上以批处理脚本离线执行，不属于 M0–M2 的交付代码
> （它是一次性的数据处理作业）。若 GPU 时间紧张，**可降级为人工抽查前 200 张预标结果**：
> 统计误检率，若 < 15% 则直接进入人工复核，不单独跑 VLM 环节。
> 该降级不影响 M2 的出口条件，只影响论文中"AI 辅助标注"章节的方法论描述完整性。

- [ ] **Step 5: 争议样本分流与人工复核**

1. 计算 v0 与 VLM 结果的 IoU，**阈值取 0.5**（按 `spec §6.1` 放宽，减少人工量）；
2. IoU < 0.5 或类别不一致者导入 X-AnyLabeling 的「已检查」流程；
3. 人工仅做 Accept / Reject 与边界微调，不从零画框；
4. 记录处理量到 `data/dataset/labeling_log.md`：日期、处理张数、接受数、剔除数、平均耗时。

- [ ] **Step 6: 排除黄金集基线，重建 manifest 与划分**

确认 `data/golden/baseline_200/` 的 200 张图**不在** `data/dataset/images/` 中参与训练：

```bash
python scripts/make_manifest.py
python scripts/split_dataset.py --ratios 0.8 0.1 0.1 --seed 42
python scripts/check_labels.py
```

**验证：** 打开 `data/dataset/dataset_report.md`，确认：
- 致命错误 = 0；
- 16 类全部有标注框（`ambiguous_vertical` 也不例外）；
- `footbridge_entrance` 框数 ≥ 250。

**若天桥入口不足 250**：返回 Task 2 补采集，**不要**用其他类别凑数。

- [ ] **Step 7: 提交**

```bash
git add data/dataset/manifest.csv data/dataset/split.json data/dataset/labeling_log.md
git add -f data/dataset/dataset_report.md
git commit -m "data: 自举预标 + 人工复核完成，数据集 v1 就绪"
```

---

## Task 11: 正式训练、评测与 TFLite 导出

**Files:**
- Create: `scripts/export_tflite.py`
- Create: `datasets/pathguide_eval_B.yaml`
- Create: `data/dataset/route_B.txt`（由命令生成，非手写）

**Interfaces:**
- Consumes: `datasets/pathguide.yaml`（Task 6）、`data/dataset/` 完整标注（Task 10）、黄金集 `data/golden/baseline_200/`
- Produces:
  - `runs/pg_v1/weights/best.pt`
  - `runs/pg_v1/best.tflite`（INT8）
  - `runs/pg_v1/eval_final.md`：每类召回率表 + 量化前后对比 + 路线 B 泛化评测
  - `app/assets/models/detector.tflite`

---

- [ ] **Step 1: 正式训练**

```bash
yolo detect train model=yolov8n.pt data=datasets/pathguide.yaml ^
  epochs=100 imgsz=640 batch=8 workers=2 patience=25 ^
  mosaic=1.0 hsv_h=0.015 hsv_s=0.7 hsv_v=0.4 degrees=5.0 ^
  cls=0.7 box=7.5 ^
  project=runs name=pg_v1
```

> `batch=8` 依据 Task 8 记录的实测值调整。`cls=0.7` 提高分类损失权重以提升召回率
> （按 `spec §7`，毕设硬指标是召回率）。

Expected: 训练 100 epoch（或 patience=25 提前停止），`runs/pg_v1/weights/best.pt` 生成。

- [ ] **Step 2: 每类召回率评测**

```bash
yolo detect val model=runs/pg_v1/weights/best.pt data=datasets/pathguide.yaml split=test
```

读出每类召回率，重点核对：
- `footbridge_entrance` 召回率 **> 70%**
- `pedestrian` / `street_obstacle` / `step` / `glass_door` 召回率 **> 70%**

**若天桥入口召回率 < 70%，按顺序尝试：**
1. 对该类样本过采样（在 `datasets/pathguide.yaml` 的 train 清单中重复列出该类图像）；
2. 提高输入尺寸到 `imgsz=768`（代价：真机延迟上升，必须重新测基准）；
3. 升级到 `yolov8s.pt` 重训（代价：模型体积与延迟显著上升）。

**每次调整后必须重新评测并记录到 `eval_final.md`，不得只保留最好结果。**

- [ ] **Step 3: 路线 B 泛化评测**

创建 `datasets/pathguide_eval_B.yaml`：

```yaml
# 路线 B 泛化评测：仅使用 route_B 数据，不参与任何训练
path: <在此填入 data/dataset 的绝对路径>
train: test.txt   # 占位，Ultralytics 要求非空
val: route_B.txt
nc: 16
names:
  0: footbridge_entrance
  1: stairs
  2: escalator_outdoor
  3: elevator
  4: ramp
  5: footbridge_railing
  6: pedestrian
  7: street_obstacle
  8: step
  9: glass_door
  10: tactile_paving
  11: zebra_crossing
  12: shop_front
  13: escalator_indoor
  14: glass_door_indoor
  15: ambiguous_vertical
```

生成 `route_B.txt`（仅含 `manifest.csv` 中 `route == route_B` 的图像）：

```bash
python -c "import csv,pathlib; rows=[r for r in csv.DictReader(open('data/dataset/manifest.csv',encoding='utf-8-sig')) if r['route']=='route_B']; pathlib.Path('data/dataset/route_B.txt').write_text('\n'.join('images/'+r['image_name'] for r in rows)+'\n', encoding='utf-8'); print(len(rows))"
```

```bash
yolo detect val model=runs/pg_v1/weights/best.pt data=datasets/pathguide_eval_B.yaml split=val
```

**记录结果**：路线 A 训练的模型在路线 B 上的召回率下降幅度，是论文泛化能力章节的核心数据。

- [ ] **Step 4: 实现 `scripts/export_tflite.py`**

```python
"""导出 INT8 TFLite，并用黄金集复测量化前后精度损失。

用法：
    python scripts/export_tflite.py --weights runs/pg_v1/weights/best.pt --imgsz 640
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = REPO_ROOT / "data" / "dataset"
GOLDEN_BASELINE = REPO_ROOT / "data" / "golden" / "baseline_200"
APP_MODELS = REPO_ROOT / "app" / "assets" / "models"
MAX_ACCURACY_DROP = 0.015  # 1.5%


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", required=True)
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--data", default=str(DATASET_DIR / "route_B.txt"),
                    help="量化校准用图像清单")
    args = ap.parse_args()

    weights = Path(args.weights)
    if not weights.exists():
        print(f"未找到权重：{weights}")
        return 1

    calib_list = Path(args.data)
    if not calib_list.exists():
        print(f"未找到校准图像清单：{calib_list}")
        print("提示：校准集应取自训练域（不含黄金集基线），约 200-500 张。")
        return 1

    from ultralytics import YOLO

    print("== INT8 导出 ==")
    model = YOLO(str(weights))
    export_path = model.export(format="tflite", imgsz=args.imgsz, int8=True, data=str(calib_list))
    tflite_path = Path(export_path)
    print(f"导出：{tflite_path} ({tflite_path.stat().st_size / 1e6:.2f} MB)")

    print("\n== 导出后评测 ==")
    fp_model = YOLO(str(weights))
    fp_metrics = fp_model.val(data=str(REPO_ROOT / "datasets" / "pathguide.yaml"), split="test", verbose=False)
    fp_map = float(getattr(fp_metrics.box, "map50", 0.0))
    print(f"FP32 mAP@0.5 = {fp_map:.4f}")

    APP_MODELS.mkdir(parents=True, exist_ok=True)
    target = APP_MODELS / "detector.tflite"
    shutil.copy2(tflite_path, target)
    print(f"已复制到 Demo 资产目录：{target}")

    print(
        "\n手动步骤（必须执行）：\n"
        "  1. 在 Python 中加载该 tflite，对数据集 test 折推理，得到 INT8 的 mAP@0.5；\n"
        "  2. 与上面的 FP32 mAP 比较，若下降 > "
        f"{MAX_ACCURACY_DROP:.1%}，回退到 FP16：\n"
        "     yolo export model=<weights> format=tflite imgsz=640 half=True\n"
        "  3. 把两个 mAP 值填入 runs/pg_v1/eval_final.md。\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

> **为什么不自动完成 INT8 精度复测：** Ultralytics 的 `val()` 不直接支持 TFLite 后端推理，
> 需要自己用 `tflite_runtime` 跑一遍前向。这是一次性工作（约 30 行），
> 但**不做这一步就不知道量化损失，真机精度崩塌时无从排查**——因此列为强制手动步骤。

- [ ] **Step 5: 执行导出并按需回退**

Run: `python scripts/export_tflite.py --weights runs/pg_v1/weights/best.pt --imgsz 640`
Expected: 生成 `runs/pg_v1/weights/best_saved_model/best_int8.tflite`，打印模型体积，并复制到 `app/assets/models/detector.tflite`。

按 Step 4 的提示手动完成 INT8 精度复测。若损失 > 1.5%，执行 FP16 回退：

```bash
yolo export model=runs/pg_v1/weights/best.pt format=tflite imgsz=640 half=True
```

- [ ] **Step 6: 汇总评测报告**

创建 `runs/pg_v1/eval_final.md`，包含：

```markdown
# M2 最终评测报告

## 1. 训练配置
- 模型：YOLOv8n
- epochs / imgsz / batch：
- 数据集规模：train / val / test
- 实际使用 seed：

## 2. 每类指标（test 折）
| id | 类别 | Precision | Recall | mAP@0.5 |
|---|---|---|---|---|
（16 行）

## 3. 出口条件核对
- [ ] footbridge_entrance Recall > 0.70
- [ ] pedestrian Recall > 0.70
- [ ] street_obstacle Recall > 0.70
- [ ] step Recall > 0.70
- [ ] glass_door Recall > 0.70
- [ ] 整体 mAP@0.5 在 0.60–0.70 区间

## 4. 路线 B 泛化评测
- 路线 B Recall（整体）：
- 相对路线 A test 折的下降幅度：

## 5. 量化对比
| 精度 | 模型体积 | mAP@0.5 |
|---|---|---|
| FP32 | | |
| INT8 | | |
- 精度损失：
- 是否触发 FP16 回退：

## 6. 失败案例分析
（列出 5–10 个典型漏检/误检案例，附文件名与原因判断）

## 7. 调参记录
（记录每次为提高天桥入口召回率所做的尝试与对应结果，含未采用的方案）
```

- [ ] **Step 7: 提交**

```bash
git add scripts/export_tflite.py datasets/pathguide_eval_B.yaml
git add -f runs/pg_v1/eval_final.md
git commit -m "feat: 正式训练、每类召回率评测、路线B泛化评测与 TFLite INT8 导出"
```

---

## Task 12: M2 出口验收

**Files:**
- Create: `docs/superpowers/plans/M2-acceptance.md`

**Interfaces:**
- Consumes: `runs/pg_v1/eval_final.md`、`runs/logo_v1/eval_report.md`、`runs/env_report.json`
- Produces: `docs/superpowers/plans/M2-acceptance.md`，即 M3（Flutter Demo）的输入契约

---

- [ ] **Step 1: 逐项核对出口条件**

```markdown
# M2 出口验收

日期：
执行人：

## 主检测器
- [ ] `best.tflite` 已生成并复制到 `app/assets/models/detector.tflite`
- [ ] 模型体积 < 10 MB，实测：___ MB
- [ ] footbridge_entrance Recall ≥ 0.70，实测：___
- [ ] pedestrian / street_obstacle / step / glass_door Recall 均 ≥ 0.70
- [ ] 整体 mAP@0.5 在 0.60–0.70
- [ ] 量化后精度损失 ≤ 1.5%
- [ ] 路线 B 泛化评测已完成并记录
- [ ] 16 类全部有标注框，无一类为零

## logo 分类器
- [ ] 5 店铺试点 top1 已记录
- [ ] `unknown` 被误判为 known 的比例 < 5%
- [ ] `best.tflite` 已导出

## 数据
- [ ] 黄金集 baseline_200 未参与任何训练（已核对 split.json）
- [ ] `dataset_report.md` 致命错误 = 0
- [ ] 划分校验无泄漏

## 环境
- [ ] `runs/env_report.json` 中 cuda 为 OK
- [ ] 实测可用 batch 与 workers 已记录

## 遗留问题
（列出未达标项、原因、处置计划）
```

- [ ] **Step 2: 检查黄金集确实未泄漏**

Run:
```bash
python -c "import json,csv,pathlib; s=json.load(open('data/dataset/split.json',encoding='utf-8')); base={p.stem for p in pathlib.Path('data/golden/baseline_200').rglob('*.txt')}; used=set(s['train'])|set(s['val']); leaked=sorted(base & {n.rsplit('.',1)[0] for n in used}); print('泄漏的基线图像数:', len(leaked)); print(leaked[:10])"
```
Expected: `泄漏的基线图像数: 0`

- [ ] **Step 3: 提交验收文档**

```bash
git add docs/superpowers/plans/M2-acceptance.md
git commit -m "docs: M2 出口验收记录，作为 M3 Flutter Demo 的输入契约"
```

---

## 后续里程碑（M3–M6，另行编写计划）

本计划在 M2 结束。以下内容在 M3 计划中展开，**此处仅登记输入契约，不展开任务**：

| 里程碑 | 周期 | 输入契约（来自本计划） | 主要产出 |
|---|---|---|---|
| **M3** App 骨架与可见 Demo | 第 5 周 | `app/assets/models/detector.tflite`、`configs/classes.json`、`configs/logos.json` | 可演示 APK：相机 + 检测框 + 粤语播报 + 阈值滑条 + 视频回放 |
| M4 决策核心 | 第 6–8 周 | M3 的 `VisionSource` 抽象、`Instruction` 类型 | 纯 Dart 规则状态机、交叉校验、离线回放测试集、`RouteProvider` 可插拔接口 |
| M5 天桥专项 + 室内 | 第 9–12 周 | 彩明商场节点图（依赖实地核实） | 全链路联调、室内节点图与 PDR |
| M6 评测与交付 | 第 13–16 周 | M4 的规则测试集 | 实地任务完成率测试、论文、演示视频 |

**M3 计划需要注意的已决事项（写入 spec §9）：**
- 推理走 **Kotlin 平台通道**，不使用 `tflite_flutter`；
- 推理在 `Isolate` 中执行，主线程只画框；
- 抽帧推理（每 2–3 帧一次）；
- 相机分辨率 640×480 或 1280×720，与训练输入对齐；
- 打包 Noto Sans CJK 子集，避免中文显示方块。

---

## 自审记录

**Spec 覆盖度核对：**

| Spec 章节 | 覆盖任务 |
|---|---|
| §3 架构（Dart/Kotlin 分层、决策层可单测） | Task 1（骨架）；M3–M4 计划展开 |
| §4 类别表 16 类 | Task 1（`classes.json` + 9 项测试）、Task 7（分布检查） |
| §4.2 合并与删除决定 | Task 1 类别表内容 |
| §5 两段式 logo 架构 | Task 9 |
| §5.4 `unknown` 生死线 | Task 9 Step 3（检查）、Step 6（误报率判定） |
| §5.6 四条误检规则 | M4 计划展开（本计划仅登记为输入契约） |
| §6.1 自举流程 | Task 10 |
| §6.2 三个工程决定 | Task 3（视频抽帧为主）、Task 6（分组划分）、Task 7（质量门禁） |
| §6.3 目录结构 | Task 1 Step 5、Task 4、Task 5 |
| §6.4 数据量目标 | Task 2（采集计划表）、Task 10 Step 6（核对） |
| §7 模型与部署 | Task 8（冒烟）、Task 11（训练与导出） |
| §8 决策引擎 | M4 计划展开 |
| §9 Demo 切片 | M3 计划展开（本计划 Task 12 登记输入契约） |
| §10 里程碑 | 文末"后续里程碑" |
| §11 风险登记 | 各 Task 的判定标准与回退路径（天桥样本、泄漏、量化损失、显存） |
| §12 不在范围 | 文末"后续里程碑"与 Global Constraints |

**未在本计划覆盖、已显式登记为 M3/M4 输入契约的项：** 四条 logo 误检规则、决策引擎规则与单测、
Flutter Demo 全部实现、导航 API 集成。这是刻意的——本计划的范围是 M0–M2（数据与模型），
按 `spec §10`，M0–M2 是不依赖任何导航 API 的前置关键路径。

**类型与命名一致性核对：**
- `configs/classes.json` 的 16 个 `name_en` 在 Task 1 定义，Task 6 `load_class_names()`、Task 7 `load_classes()`、Task 11 的 `pathguide_eval_B.yaml` 三处引用，值一致。
- `manifest.csv` 的 8 个列名在 Task 5 定义（`MANIFEST_COLUMNS`），Task 6 `load_manifest()`、Task 12 Step 2 的校验脚本按同名读取。
- `split.json` 的键为 `seed` / `ratios` / `counts` / `train` / `val` / `test`，Task 6 写入，Task 12 读取 `train`/`val`。
- 函数名核对：`frame_filename` / `is_sharp`（Task 3）、`hamming` / `is_duplicate`（Task 4）、`parse_source_meta` / `read_label_summary`（Task 5）、`assign_folds` / `validate_no_leakage`（Task 6）、`validate_line` / `parse_box`（Task 7）——各测试文件 import 的名称与实现一致。

**已知的诚实局限（不回避）：**
1. Task 6 的 `assign_folds` 在"类别分层"与"折间比例"之间存在天然冲突，本实现以分层优先。若实际运行后发现 train/val/test 比例明显失衡（例如 val 超过 25%），可调整桶内轮转步长（当前固定为 i==1→val、i==2→test），**但不得为了比例而牺牲 val 的类别覆盖**。
2. Task 10 Step 4 的 VLM 复核被标注为"可降级"，因为它在 GPU 时间紧张时不影响 M2 出口条件。
3. Task 11 Step 4 的 INT8 精度复测列为手动步骤，原因是 Ultralytics 不直接支持 TFLite 后端 `val()`。
4. Task 9 的 `configs/logos.json` 中 5 家店铺为**占位示例**，必须以彩明商场实地核实结果替换。这是本计划中唯一已知的内容占位，已在 Task 9 Step 1 显式标注。
5. Task 11 Step 3 的 `pathguide_eval_B.yaml` 中 `path:` 字段需由执行者填入环境绝对路径（Ultralytics 要求绝对路径，无法预知宿主机布局）。
