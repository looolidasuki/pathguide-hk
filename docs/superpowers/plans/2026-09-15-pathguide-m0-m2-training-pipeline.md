# 領路通（PathGuide HK）M0–M2 實施計劃

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立可復現的數據→標註→訓練→導出流水線，產出 16 類主檢測器與店鋪 logo 分類器的量化模型（`best.tflite`），併為真機 Demo 提供已驗證的模型資產。

**Architecture:** 以 `data/dataset/` 為全流程單一事實源（images + labels + manifest.csv + split.json），所有腳本圍繞它做冪等變換。數據集劃分以"來源文件夾"為分組鍵防止視頻抽幀造成的泄漏。訓練與導出均以黃金集（`data/golden/baseline_200`）為不可污染的質量門禁。

**Tech Stack:** Python 3.11 / Ultralytics YOLOv8 / PyTorch CUDA / OpenCV / imagehash / pytest；Windows 本機 NVIDIA 顯卡。

**Spec:** `docs/superpowers/specs/2026-09-15-pathguide-thesis-design.md`

---

## Global Constraints

以下約束對**每一個** Task 生效，不再逐條重複：

1. **運行環境**：Windows + 本機 NVIDIA 顯卡（RTX 5070 / sm_120 / 11.91 GB）。所有訓練/導出命令必須先執行 `. .\.env.ps1` 激活虛擬環境。**不使用 conda**（本機未安裝），改用 uv + venv + Python 3.12。
2. **Windows 多進程**：任何使用 DataLoader 多進程的入口腳本必須置於 `if __name__ == "__main__":` 保護內。`workers` 起始值為 **2**，出現卡死或共享內存錯誤時降為 **0**。
3. **路徑**：倉庫內一律使用 `__file__` 推導的絕對路徑（`Path(__file__).resolve().parents[N]`），禁止硬編碼盤符，禁止依賴當前工作目錄。Python 代碼中路徑統一用 `pathlib.Path`，僅在傳給 cv2 時轉為 `str`。
4. **圖像讀取**：必須用 `cv2.imdecode(np.fromfile(path, dtype=np.uint8), cv2.IMREAD_COLOR)` 而非 `cv2.imread`，以支持中文路徑。
5. **編碼**：所有文件寫入顯式 `encoding="utf-8"`，CSV 使用 `utf-8-sig`（便於 Excel 打開）。控制枱打印避免 emoji 與非 GBK 字符（Windows GBK 控制枱會拋 `UnicodeEncodeError`）。
6. **隨機性**：所有涉及隨機劃分的腳本必須接受 `--seed`，默認 **42**，並在輸出中記錄實際使用值。
7. **類別表單一事實源**：`configs/classes.json`。任何腳本、測試、應用都不得硬編碼類別名或順序。類別順序**一經用於訓練即凍結**（YOLO 標籤以索引寫入，重排會導致標籤語義錯位）。
8. **黃金集不可污染**：`data/golden/baseline_200/` 在任何訓練、預標、增強流程中都必須被排除，僅用於評測對照。
9. **保存與提交**：每完成一個 Task 的最後一個 Step 執行一次 git 提交，提交信息使用該 Task 給出的原文。
10. **閾值與指標**：天橋入口召回率 > 70%、障礙物召回率 > 70% 為 M2 出口條件；量化後精度損失 > 1.5% 則回退 FP16。

---

## 文件結構

| 文件 | 職責 |
|---|---|
| `configs/classes.json` | **類別表單一事實源**：16 類 id / name_en / name_zh / group / priority / announced |
| `configs/collect_plan.md` | 採集計劃：目標點位、每類目標張數、覆蓋維度、現場清單 |
| `scripts/env_check.py` | 環境與 CUDA/顯存驗證，產出機器可讀報告 |
| `scripts/extract_frames.py` | 視頻抽幀 + 拉普拉斯模糊過濾 |
| `scripts/dedup.py` | 感知哈希去重（默認僅作用於訓練域，刻意保留評測集真實冗餘） |
| `scripts/make_manifest.py` | 掃描 `data/dataset/` 生成 `manifest.csv` |
| `scripts/split_dataset.py` | 分組 + 分層劃分，產出 `split.json` 與 `datasets/pathguide.yaml` |
| `scripts/check_labels.py` | 標籤質量門禁，產出 `dataset_report.md` |
| `scripts/train_cls.py` | logo 分類器訓練與評測包裝（含 Windows 保護） |
| `scripts/smoke_test.py` | 2 分鐘環境冒煙測試（YOLOv8n 預訓練權重 + 20 張圖，2 epoch） |
| `tests/test_extract_frames.py` | 抽幀質量判定與文件名生成的單元測試 |
| `tests/test_dedup.py` | 去重邏輯單元測試 |
| `tests/test_manifest.py` | manifest 列與元數據解析單元測試 |
| `tests/test_split.py` | 劃分無泄漏與分層保證的單元測試 |
| `tests/test_check_labels.py` | 標籤校驗規則單元測試 |
| `tests/test_classes.py` | 類別表自洽性單元測試 |
| `data/dataset/` | 單一事實源：images / labels / manifest.csv / split.json / dataset_report.md |
| `data/logos/` | logo 分類器 ImageFolder 數據集（`{store_id}/` 與 `unknown/`） |
| `datasets/pathguide.yaml` | 訓練配置（由 `split_dataset.py` 生成，不手工編輯） |

**邊界説明：** 所有 `scripts/` 下的腳本是**獨立的 CLI 工具**，彼此不 import；共享邏輯若出現重複（如路徑常量），寧可重複也不建立隱式耦合——因為流水線各步驟會被單獨重跑。唯一被多處引用的模塊是 `configs/classes.json`（以文件讀取方式，非 Python import）。

---

## Task 1: 工程骨架與環境驗證

**Files:**
- Create: `configs/classes.json`
- Create: `scripts/env_check.py`
- Create: `tests/test_classes.py`
- Create: `requirements.txt`
- Create: `.gitignore`
- Create: 空目錄佔位 `data/raw/route_A/.gitkeep` 等（見 Step 5）

**Interfaces:**
- Consumes: 無（起始任務）
- Produces:
  - `configs/classes.json`，結構為 `{"version": 1, "classes": [{"id": 0, "name_en": str, "name_zh": str, "group": str, "priority": str, "announced": bool}, ...]}`，共 16 項，`id` 從 0 連續遞增。
  - `scripts/env_check.py` 可執行，退出碼 0 表示環境可用，非 0 表示不可用。

---

- [ ] **Step 1: 創建目錄骨架與 `.gitignore`**

```bash
cd "C:/Users/user/PycharmProjects/Accessible Visual Guidance"
mkdir -p configs scripts tests datasets docs/superpowers/specs docs/superpowers/plans
mkdir -p data/raw/route_A data/raw/route_B data/frames data/dataset/images data/dataset/labels
mkdir -p data/golden/baseline_200 data/golden/seed_300 data/logos runs app
```

創建 `.gitignore`：

```gitignore
# Python
__pycache__/
*.py[cod]
.venv/
venv/
.pytest_cache/

# 數據（體積大，不入庫；raw/ 與 dataset/ 由外部備份盤維護）
data/raw/**
data/frames/**
data/dataset/images/**
data/dataset/labels/**
data/logos/**
!data/**/.gitkeep

# 訓練產物
runs/**
weights/
*.pt
*.onnx
*.tflite

# IDE
.idea/
.vscode/

# 臨時
*.tmp
~$*
```

- [ ] **Step 2: 寫 `tests/test_classes.py`（先寫測試）**

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

- [ ] **Step 3: 運行測試確認失敗**

Run: `pytest tests/test_classes.py -v`
Expected: FAIL —— `FileNotFoundError`，因為 `configs/classes.json` 尚不存在。

- [ ] **Step 4: 創建 `configs/classes.json`**

> **類別順序即標籤索引，一經訓練不得重排。**

```json
{
  "version": 1,
  "note": "類別順序即 YOLO 標籤索引，一經用於訓練即凍結，不得重排。",
  "classes": [
    { "id": 0,  "name_en": "footbridge_entrance", "name_zh": "天橋入口",   "group": "footbridge", "priority": "P0", "announced": true },
    { "id": 1,  "name_en": "stairs",              "name_zh": "樓梯",       "group": "footbridge", "priority": "P0", "announced": true },
    { "id": 2,  "name_en": "escalator_outdoor",   "name_zh": "户外扶梯",   "group": "footbridge", "priority": "P0", "announced": true },
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

- [ ] **Step 5: 創建佔位文件與 `requirements.txt`**

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

- [ ] **Step 6: 創建並驗證環境（uv + venv，實際採用方案）**

> **與原計劃的偏差説明：** 原計劃使用 conda，但本機未安裝 conda，且系統默認 Python 為 **3.14.4**
> ——PyTorch 尚無 3.14 的 wheel。實測改用 **uv + venv + Python 3.12.3**（`py -0p` 已存在該解釋器）。
>
> 另一處偏差：uv 默認緩存在 `%LOCALAPPDATA%\uv\cache`，被文件沙箱拒絕寫入。
> 因此必須把 `UV_CACHE_DIR` 指向工作區內（見 `.env.ps1`）。

```powershell
# 激活環境（已封裝為腳本）
. .\.env.ps1
```

該腳本等價於：

```powershell
uv venv --python 3.12 .venv
$env:UV_CACHE_DIR = "$PWD\.uv-cache"

# RTX 50 係為 Blackwell (sm_120)，必須用 CUDA 12.8+ 的 PyTorch 構建
uv pip install --python .venv\Scripts\python.exe torch torchvision `
  --index-url https://download.pytorch.org/whl/cu128

uv pip install --python .venv\Scripts\python.exe -r requirements.txt
```

**實測結果（2026-09-15）：** `torch 2.11.0+cu128` / `torchvision 0.26.0+cu128` / CUDA 12.8 /
RTX 5070 / sm_120 / 11.91 GB 顯存 / GPU 矩陣乘法通過。

- [ ] **Step 7: 寫 `scripts/env_check.py`**

```python
"""驗證訓練環境可用性。退出碼 0 = 可用，1 = 不可用。"""
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
        return {"name": "cuda", "ok": False, "detail": "torch 未安裝"}
    if not torch.cuda.is_available():
        return {
            "name": "cuda",
            "ok": False,
            "detail": "torch.cuda.is_available() == False；將退化為 CPU 訓練",
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
            print("\n警告：無可用 GPU，訓練將極慢。請先修復 CUDA 後再進入 Task 8。")
    return 0 if all(c["ok"] for c in checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 8: 運行環境檢查**

Run: `python scripts/env_check.py`
Expected: 輸出 5 行檢查結果，`cuda` 行顯示顯卡名與顯存，並給出 `recommended_batch`。

**若 `cuda` FAIL**：不要在 CPU 上繼續。先安裝匹配的 CUDA 版 PyTorch：
```bash
pip uninstall -y torch torchvision
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
```
然後重跑 `python scripts/env_check.py` 直到 `cuda` 為 OK。

**記錄 `recommended_batch` 的值**，Task 8 與 Task 11 的 `batch` 參數使用它。

- [ ] **Step 9: 運行類別表測試**

Run: `pytest tests/test_classes.py -v`
Expected: PASS（9 passed）

- [ ] **Step 10: 提交**

```bash
git add .gitignore requirements.txt configs/classes.json scripts/env_check.py tests/test_classes.py
git add -f data/raw/route_A/.gitkeep data/raw/route_B/.gitkeep
git commit -m "chore: 工程骨架、16 類類別表單一事實源、環境驗證腳本"
```

---

## Task 2: 採集計劃與標註規範

**Files:**
- Create: `configs/collect_plan.md`
- Create: `configs/annotate_spec.md`
- Modify: `configs/classes.json`（僅當實地核實後需要調整類別中文名；**不得變更 id 順序**）

**Interfaces:**
- Consumes: `configs/classes.json`（Task 1）
- Produces: 兩份人工規範文檔。`configs/annotate_spec.md` 中的"邊界判定規則"將在 Task 8 的人工標註與 Task 9 的 VLM 複核 Prompt 中被直接引用。

---

- [ ] **Step 1: 寫 `configs/collect_plan.md`**

內容必須包含以下章節，逐項填寫真實點位與數量（下表為模板，**採集前必須補全"實際點位"列**）：

```markdown
# 採集計劃

## 1. 兩條路線的分工
| 路線 | 角色 | 是否參與訓練 |
|---|---|---|
| A 調景嶺站 → 彩明苑天橋 → 彩明商場 | 主實驗區 | 是（train/val） |
| B 中環站 A 出口 → 中環天橋 → IFC | 泛化驗證集 | **否，僅 test** |

## 2. 採集方式要求（強制）
- 每個點位**視頻與照片同時錄製**：視頻用於抽幀（訓練集主力），照片用於補充稀有類別。
- 視頻：1080p / 30fps，每個點位連續錄製 ≥ 60 秒，緩慢平移 + 緩慢靠近。
- 照片：每點位 ≥ 30 張，覆蓋 3 距離 × 3 角度 × 2 光照。
- 目錄：`data/raw/route_A/<YYYYMMDD>_<點位名>/`，目錄名只用 ASCII 與下劃線。

## 3. 每類目標張數（抽幀去重後計）
| 組 | 類別 | 目標張數 | 實際點位 | 已完成 |
|---|---|---|---|---|
| 天橋專項 | footbridge_entrance | ≥250 | | |
| 天橋專項 | stairs | ≥180 | | |
| 天橋專項 | escalator_outdoor | ≥120 | | |
| 天橋專項 | elevator | ≥100 | | |
| 天橋專項 | ramp | ≥100 | | |
| 天橋專項 | footbridge_railing | ≥150 | | |
| 障礙物 | pedestrian | ≥300 | | |
| 障礙物 | street_obstacle | ≥200 | | |
| 障礙物 | step | ≥150 | | |
| 障礙物 | glass_door | ≥150 | | |
| 導航輔助 | tactile_paving | ≥200 | | |
| 導航輔助 | zebra_crossing | ≥150 | | |
| 室內 | shop_front | ≥250 | | |
| 室內 | escalator_indoor | ≥150 | | |
| 室內 | glass_door_indoor | ≥100 | | |
| 訓練專用 | ambiguous_vertical | ≥250 | | |
| 負樣本 | （無標註） | ≥300 | | |
| 路線 B | （全部類別） | ≥400 | | |

## 4. 關鍵硬約束
- **第 1 周內必須拍滿 footbridge_entrance ≥ 250 張**。天橋入口不是隨處可見的物體，
  樣本不足會直接拖垮 M2；不可留到第 3 周再補。
- `ambiguous_vertical` 必須在**正對扶梯口 / 正對樓梯口**的視角下采集，
  因該視角下難以區分，是安全關鍵類。

## 5. 隱私與合規
- 避免對可辨識面部特寫；行人類別以遠景、背影、側影、剪影為主。
- 商場內拍攝若被保安詢問，説明為學術研究用途；避免拍攝櫃枱內部與店員。
- 網絡補充圖片須在 `manifest.csv` 的備註列註明來源，論文中聲明。
```

- [ ] **Step 2: 寫 `configs/annotate_spec.md`**

```markdown
# 標註規範

## 1. 標註工具
X-AnyLabeling（YOLO 格式導出至 `data/dataset/labels/`，與圖像同名 `.txt`）。

## 2. 格式
每行：`<class_id> <cx> <cy> <w> <h>`，均為相對圖像寬高的歸一化浮點數，範圍 [0, 1]。
class_id 必須取自 `configs/classes.json`，不得臆造。

## 3. 邊界判定規則（核心，逐類）
| 類別 | 框住什麼 | 反例（不標） |
|---|---|---|
| footbridge_entrance | 天橋入口的**通道開口整體**（含上方標識牌） | 天橋全貌、遠處的橋身 |
| stairs | 可見的**階梯段整體** | 單級台階（標 step） |
| escalator_outdoor | 户外扶梯**含扶手帶與梳齒板的整體** | 樓梯、靜止的自動人行道 |
| elevator | 電梯**門與門框** | 電梯按鈕面板、樓層顯示器 |
| ramp | 坡道**斜面與兩側護欄圍成的區域** | 台階、平地 |
| footbridge_railing | 一段連續的欄杆 | 臨時圍欄（標 street_obstacle） |
| pedestrian | 人的**整個人形** | 海報/廣告牌上的人像 |
| street_obstacle | 圍欄、立柱、垃圾桶、施工物料等**佔據通行空間**的物體 | 正常擺放且不佔道的設施 |
| step | **單級或兩級**台階、路緣 | 大段階梯（標 stairs） |
| glass_door | 需要**穿越**的玻璃門 | 玻璃幕牆、玻璃窗 |
| tactile_paving | 盲道/觸覺引路帶的**可見段** | 普通地磚 |
| zebra_crossing | 斑馬線的**可見段** | 其他路面標線 |
| shop_front | 店鋪**門面整體**（含招牌區域），供後續 logo 裁剪 | 單獨的招牌、店內場景 |
| escalator_indoor | 商場內扶梯（同 escalator_outdoor 判定） | 樓梯 |
| glass_door_indoor | 商場內需穿越的玻璃門 | 玻璃隔斷 |
| ambiguous_vertical | **正對視角下無法判斷是樓梯還是扶梯**的畫面區域 | 任何能明確判定的情況 |

## 4. 強制規則
1. **遮擋處理**：遮擋 > 70% 不標；遮擋 30%–70% 標可見部分邊界（不外推）。
2. **最小框尺寸**：短邊 < 8 px 不標。
3. **`ambiguous_vertical` 優先級**：當無法確定是樓梯還是扶梯時，
   **只標 `ambiguous_vertical`，不得同時標 `stairs` 或 `escalator_*`**。三者互斥。
4. **玻璃門互斥**：户外場景標 `glass_door`，商場室內場景標 `glass_door_indoor`，
   **同一目標只標其一**。判定依據是拍攝時所處環境（室外/室內）。
5. **負樣本**：無任何目標類別的圖像，**生成同名空 `.txt` 文件**（不是不生成文件）。
   空標籤文件是有效的負樣本，`check_labels.py` 會區分"空標籤"與"缺標籤"。
6. **一致性優先於完美**：同一目標在不同圖像中的框選範圍必須一致。
   規範未覆蓋的情形，記錄下來並統一裁決，不要各自隨意處理。

## 5. 黃金集凍結
- `data/golden/baseline_200/`：200 張純人工精標，**永不參與訓練/預標/增強**。
  用於論文中"AI 輔助標註 vs 純人工標註"的對照實驗。
- `data/golden/seed_300/`：300 張人工精標，覆蓋全部 16 類，作為自舉種子。
```

- [ ] **Step 3: 運行類別表測試確認未被破壞**

Run: `pytest tests/test_classes.py -v`
Expected: PASS（9 passed）。若因修改 `classes.json` 而失敗，説明改動破壞了約束，須回退。

- [ ] **Step 4: 提交**

```bash
git add configs/collect_plan.md configs/annotate_spec.md
git commit -m "docs: 採集計劃與標註規範，含逐類邊界判定與互斥規則"
```

---

## Task 3: 視頻抽幀與模糊過濾

**Files:**
- Create: `scripts/extract_frames.py`
- Create: `tests/test_extract_frames.py`

**Interfaces:**
- Consumes: `data/raw/route_A|route_B/<source>/` 下的 `.mp4` / `.mov` / `.avi`
- Produces:
  - `data/frames/<route>/<source>/<source>_<視頻名>_<幀序號:06d>.jpg`
  - CLI：`python scripts/extract_frames.py --route route_A --fps 2 --blur-thresh 100`
  - 函數 `frame_filename(source: str, video_stem: str, frame_idx: int) -> str`
  - 函數 `is_sharp(gray: np.ndarray, threshold: float) -> bool`
  - 輸出末尾打印 `kept=N skipped_blur=M skipped_dup=K`，供人工核對

---

- [ ] **Step 1: 寫 `tests/test_extract_frames.py`**

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

- [ ] **Step 2: 運行測試確認失敗**

Run: `pytest tests/test_extract_frames.py -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'extract_frames'`

- [ ] **Step 3: 實現 `scripts/extract_frames.py`**

```python
"""從視頻中按固定時間間隔抽幀，並過濾模糊幀。

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
    """生成抽幀文件名：<source>_<video>_<六位幀號>.jpg"""
    return f"{source}_{video_stem}_{frame_idx:06d}.jpg"


def is_sharp(gray: np.ndarray, threshold: float) -> bool:
    """拉普拉斯方差 > threshold 視為清晰。"""
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
        print(f"  [WARN] 無法打開視頻：{video_path}")
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
    ap.add_argument("--fps", type=float, default=2.0, help="每秒抽取幀數")
    ap.add_argument("--blur-thresh", type=float, default=100.0)
    ap.add_argument("--max-frames", type=int, default=None)
    args = ap.parse_args()

    raw_route = RAW_DIR / args.route
    videos = find_videos(raw_route)
    if not videos:
        print(f"未在 {raw_route} 找到視頻文件。")
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
    print(f"輸出目錄：{FRAMES_DIR / args.route}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: 運行測試確認通過**

Run: `pytest tests/test_extract_frames.py -v`
Expected: PASS（5 passed）

- [ ] **Step 5: 在小樣本上實測抽幀**

先把 1 個短視頻放入 `data/raw/route_A/test_point/`，然後：

Run: `python scripts/extract_frames.py --route route_A --fps 2 --max-frames 20`
Expected: 輸出 `kept=20 ...`，且 `data/frames/route_A/test_point/` 下有 20 個 jpg。

人工抽查 5 張：確認畫面清晰、文件名含來源與幀號、無損壞文件。

- [ ] **Step 6: 提交**

```bash
git add scripts/extract_frames.py tests/test_extract_frames.py
git commit -m "feat: 視頻抽幀與拉普拉斯模糊過濾"
```

---

## Task 4: 感知哈希去重

**Files:**
- Create: `scripts/dedup.py`
- Create: `tests/test_dedup.py`

**Interfaces:**
- Consumes: 圖像目錄樹（`data/frames/<route>/<source>/` 與照片目錄）
- Produces:
  - `data/dataset/images/<source>/<name>.jpg`（去重後）
  - 重複文件移入 `data/dataset/_duplicates/<source>/`（不刪除，便於人工複核）
  - CLI：`python scripts/dedup.py --method phash --threshold 6 --scope train_only`
  - 函數 `hamming(a: int, b: int) -> int`
  - 函數 `is_duplicate(hash_bits: int, seen: list[int], threshold: int) -> bool`

> **職責邊界：** `extract_frames.py` 只做"抽幀 + 去模糊"，**不做去重**；
> 去重完全由本腳本負責。兩者職責分離，便於單獨重跑。
>
> **設計説明：** 去重的目的是消除"同一段視頻相鄰幀幾乎相同"造成的劃分泄漏。
> 但**刻意保留路線 B 的真實冗餘**——評測集若過度去重會偏樂觀，失去泛化度量意義。
> 因此 `--scope` 默認為 `train_only`，即只對路線 A 去重，路線 B 原樣保留。

---

- [ ] **Step 1: 寫 `tests/test_dedup.py`**

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

- [ ] **Step 2: 運行測試確認失敗**

Run: `pytest tests/test_dedup.py -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'dedup'`

- [ ] **Step 3: 實現 `scripts/dedup.py`**

```python
"""基於感知哈希的圖像去重。

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
# 路線 B 為泛化評測域，刻意保留真實冗餘，不去重
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
    ap.add_argument("--threshold", type=int, default=6, help="漢明距離閾值，<= 閾值判為重複")
    ap.add_argument("--scope", default="train_only", choices=["train_only", "all"])
    ap.add_argument("--with-photos", action="store_true", help="同時處理 data/raw 下的照片")
    args = ap.parse_args()

    src_roots: list[Path] = []
    for route_dir in sorted(p for p in FRAMES_DIR.glob("route_*") if p.is_dir()):
        if args.scope == "train_only" and route_dir.name in EVAL_ONLY_ROUTES:
            print(f"[跳過] {route_dir.name}（評測域，保留真實冗餘）")
            continue
        src_roots.append(route_dir)
    if args.with_photos:
        for route_dir in sorted(p for p in (REPO_ROOT / "data" / "raw").glob("route_*") if p.is_dir()):
            if args.scope == "train_only" and route_dir.name in EVAL_ONLY_ROUTES:
                continue
            src_roots.append(route_dir)

    if not src_roots:
        print("沒有找到可處理的圖像目錄。請先運行 extract_frames.py。")
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
                print(f"  [WARN] 無法讀取 {img.name}: {exc}")
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
    print(f"輸出：{DATASET_IMAGES}")
    print(f"重複件：{DUP_DIR}（未刪除，可人工複核）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: 運行測試確認通過**

Run: `pytest tests/test_dedup.py -v`
Expected: PASS（6 passed）

- [ ] **Step 5: 在實測抽幀結果上運行去重**

Run: `python scripts/dedup.py --method phash --threshold 6 --scope train_only`
Expected: 輸出每來源的 `kept/dup` 統計；`data/dataset/images/` 下出現圖像；`route_B` 被跳過（若已有數據）。

**人工抽查**：從 `data/dataset/_duplicates/` 隨機看 5 張，確認它們與保留幀確實高度相似。若發現被誤判為重複的不同場景，提高 `--threshold` 到 4 重跑（需先清空 `data/dataset/images/` 與 `_duplicates/`）。

- [ ] **Step 6: 提交**

```bash
git add scripts/dedup.py tests/test_dedup.py
git commit -m "feat: 感知哈希去重，評測域刻意保留冗餘以保證泛化度量有效"
```

---

## Task 5: manifest 生成

**Files:**
- Create: `scripts/make_manifest.py`
- Create: `tests/test_manifest.py`

**Interfaces:**
- Consumes: `data/dataset/images/<source>/*.jpg`、`data/dataset/labels/<name>.txt`
- Produces:
  - `data/dataset/manifest.csv`，列嚴格為：`image_name, source_folder, route, capture, has_label, has_positive, n_boxes, classes`
  - 函數 `parse_source_meta(source_folder: str) -> dict`，返回 `{"route": str, "capture": str}`
  - 函數 `read_label_summary(label_path: Path) -> tuple[int, list[int]]`，返回 `(框數, 類別 id 列表)`

> **`source_folder` 是劃分的分組鍵**，其命名必須能區分路線與採集方式。
> 約定：文件夾名以 `route_A` / `route_B` 前綴標識路線；`capture` 由文件名或子目錄名推斷（`video` / `photo`）。

---

- [ ] **Step 1: 寫 `tests/test_manifest.py`**

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

- [ ] **Step 2: 運行測試確認失敗**

Run: `pytest tests/test_manifest.py -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'make_manifest'`

- [ ] **Step 3: 實現 `scripts/make_manifest.py`**

```python
"""掃描 data/dataset/ 生成 manifest.csv，作為劃分與評測的依據。"""
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
    """從來源文件夾名解析路線與採集方式。"""
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
    """返回 (框數, 排序去重後的類別 id 列表)。文件缺失返回 (-1, [])。"""
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
        print(f"未在 {IMAGES_DIR} 找到圖像。請先運行 dedup.py。")
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

    print(f"圖像總數：{len(rows)}")
    for route, n in sorted(by_route.items()):
        print(f"  {route}: {n}")
    print(f"負樣本（空標籤）：{n_negative}")
    print(f"缺標籤文件：{n_missing}")
    print(f"manifest -> {MANIFEST_PATH}")
    if n_missing:
        print("\n注意：缺標籤表示尚未標註。完成標註後重新運行本腳本。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 運行測試確認通過**

Run: `pytest tests/test_manifest.py -v`
Expected: PASS（8 passed）

- [ ] **Step 5: 生成 manifest**

Run: `python scripts/make_manifest.py`
Expected: 打印圖像總數與各路線計數。此時 `缺標籤文件` 等於圖像總數（尚未標註），這是**預期狀態**。

用 Excel 打開 `data/dataset/manifest.csv`，確認中文無亂碼、列名正確。

- [ ] **Step 6: 提交**

```bash
git add scripts/make_manifest.py tests/test_manifest.py
git commit -m "feat: manifest 生成，含路線/採集方式解析與標籤摘要"
```

---

## Task 6: 分組分層劃分（防泄漏）

**Files:**
- Create: `scripts/split_dataset.py`
- Create: `tests/test_split.py`

**Interfaces:**
- Consumes: `data/dataset/manifest.csv`（Task 5）、`configs/classes.json`（Task 1）
- Produces:
  - `data/dataset/split.json`：`{"seed": int, "train": [image_name...], "val": [...], "test": [...]}`
  - `datasets/pathguide.yaml`：Ultralytics 訓練配置
  - 函數 `assign_folds(rows: list[dict], ratios: tuple[float, float, float], seed: int) -> dict[str, list[str]]`
  - 函數 `validate_no_leakage(split: dict, manifest: list[dict]) -> list[str]`，返回違規描述列表（空列表表示通過）

> **這是本計劃最關鍵的腳本。** 若採用隨機劃分，同一段視頻抽出的相鄰幀會同時進入訓練集與驗證集，**指標虛高 10+ 個百分點**，且論文結論不可信。

---

- [ ] **Step 1: 寫 `tests/test_split.py`**

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
    # 6 個來源各含 3 個類別，val 至少應出現全部 3 個類別
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

- [ ] **Step 2: 運行測試確認失敗**

Run: `pytest tests/test_split.py -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'split_dataset'`

- [ ] **Step 3: 實現 `scripts/split_dataset.py`**

```python
"""按來源文件夾分組、按類別分層的訓練/驗證/測試劃分。

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
    """按 source_folder 分組、按類別分層劃分。

    分層方式：以"來源包含的類別集合"為桶，桶內洗牌後在 (train, val, test) 三折間輪轉，
    val 與 test 只取桶內前兩個來源，從而保證每個類別都有來源進入 val/test。

    優先級裁決（依 spec §11 風險登記）：
        無泄漏 > val 覆蓋全類別 > train/val/test 比例精確性
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
                # 其餘來源按當前張數最少者優先，使比例接近 ratios
                fold = min(fold_order, key=lambda f: _count(by_source, fold_sources[f]))
                fold_sources[fold].append(source)

    # 兜底：任一折為空時，從最大的折遷出一個來源
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
    """返回違規描述列表；空列表表示通過。"""
    problems: list[str] = []
    src_of = {r["image_name"]: r["source_folder"] for r in manifest}

    folds = {fold: set(split.get(fold, [])) for fold in ("train", "val", "test")}

    for name in folds["train"]:
        if name in folds["val"] or name in folds["test"]:
            problems.append(f"圖像出現在多個折中：{name}")
    for name in folds["val"]:
        if name in folds["test"]:
            problems.append(f"圖像出現在多個折中：{name}")

    for a, b in (("train", "val"), ("train", "test"), ("val", "test")):
        shared = {src_of[n] for n in folds[a] if n in src_of} & {src_of[n] for n in folds[b] if n in src_of}
        if shared:
            problems.append(f"{a} 與 {b} 共享來源文件夾（泄漏）：{sorted(shared)[:5]}")

    assigned = folds["train"] | folds["val"] | folds["test"]
    unassigned = set(src_of) - assigned
    if unassigned:
        problems.append(f"{len(unassigned)} 張圖像未被分配到任何折，例如 {sorted(unassigned)[:5]}")

    return problems


def write_yaml(split: dict, class_names: list[str]) -> None:
    names_block = "\n".join(f"  {i}: {n}" for i, n in enumerate(class_names))
    content = (
        "# 由 scripts/split_dataset.py 自動生成，請勿手工編輯\n"
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
        print(f"未找到 {MANIFEST_PATH}。請先運行 make_manifest.py。")
        return 1

    rows = [r for r in load_manifest() if str(r.get("has_label", "")).lower() in ("true", "1")]
    if not rows:
        print("manifest 中沒有已標註的圖像。請先完成標註（Task 8）。")
        return 1

    total_ratio = sum(args.ratios)
    if abs(total_ratio - 1.0) > 1e-6:
        print(f"ratios 之和必須為 1.0，當前為 {total_ratio}")
        return 1

    split = assign_folds(rows, tuple(args.ratios), args.seed)
    problems = validate_no_leakage(split, rows)
    if problems:
        print("劃分校驗失敗：")
        for p in problems:
            print(f"  - {p}")
        return 1

    payload = {"seed": args.seed, "ratios": list(args.ratios),
               "counts": {k: len(v) for k, v in split.items()}, **split}
    SPLIT_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    write_yaml(split, load_class_names())

    print(f"seed={args.seed}")
    for fold in ("train", "val", "test"):
        print(f"  {fold}: {len(split[fold])} 張, {len({r['source_folder'] for r in rows if r['image_name'] in set(split[fold])})} 個來源")
    print(f"split -> {SPLIT_PATH}")
    print(f"yaml  -> {YAML_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

> **實現提示：** `assign_folds` 採用"類別集合分桶 + 桶內輪轉"策略：桶內第 2、3 個來源分別進 val 與 test，
> 其餘來源按當前張數最少者歸入，從而兼顧分層與比例。
>
> **裁決優先級（依 spec §11）：無泄漏 > val 覆蓋全類別 > 比例精確性。**
> 比例是 0.8/0.1/0.1 還是 0.75/0.13/0.12 無所謂，但 **val 中沒有 `footbridge_entrance`
> 就意味着 M2 無法產出該類召回率**，那才是必須修的問題。
>
> 執行 Task 6 Step 5 後必須人工確認：`val` 折的類別覆蓋是否包含全部 5 個 P0 天橋/障礙類。

- [ ] **Step 4: 運行測試確認通過**

Run: `pytest tests/test_split.py -v`
Expected: PASS（7 passed）

- [ ] **Step 5: 在真實數據上運行劃分**

Run: `python scripts/split_dataset.py --ratios 0.8 0.1 0.1 --seed 42`
Expected: 打印三折張數與來源數，無"劃分校驗失敗"，生成 `split.json`、`train.txt`、`val.txt`、`test.txt`、`datasets/pathguide.yaml`。

**人工核查**：打開 `datasets/pathguide.yaml`，確認 `nc: 16` 且 16 個類名與 `configs/classes.json` 一致。

- [ ] **Step 6: 提交**

```bash
git add scripts/split_dataset.py tests/test_split.py datasets/pathguide.yaml data/dataset/split.json
git commit -m "feat: 按來源分組、按類別分層的劃分，含泄漏校驗"
```

---

## Task 7: 標籤質量門禁

**Files:**
- Create: `scripts/check_labels.py`
- Create: `tests/test_check_labels.py`

**Interfaces:**
- Consumes: `data/dataset/images/`、`data/dataset/labels/`、`configs/classes.json`
- Produces:
  - `data/dataset/dataset_report.md`（人工閲讀）
  - 退出碼 0 = 通過，2 = 存在致命問題（越界框、非法類別 id、座標非數值）
  - 函數 `validate_line(line: str, n_classes: int) -> list[str]`，返回該行的錯誤列表（空 = 合法）
  - 函數 `parse_box(line: str) -> tuple[int, float, float, float, float] | None`

> **這是訓練前置門禁。** 標註錯誤在訓練時不會報錯，只會讓 mAP 莫名偏低，
> 然後耗費數日懷疑模型。必須先跑通本腳本。

---

- [ ] **Step 1: 寫 `tests/test_check_labels.py`**

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

- [ ] **Step 2: 運行測試確認失敗**

Run: `pytest tests/test_check_labels.py -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'check_labels'`

- [ ] **Step 3: 實現 `scripts/check_labels.py`**

```python
"""標註質量門禁：越界框、非法類別、極小框、類別分佈、空標籤統計。

用法：
    python scripts/check_labels.py
退出碼：0 通過；2 存在致命問題。
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

TINY_BOX_PX = 8.0          # 短邊小於該像素值視為極小框（警告）
MIN_IMAGES_PER_CLASS = 50  # 類別樣本下限（警告）


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
    """返回該行的錯誤列表，空列表表示合法。"""
    errors: list[str] = []
    parts = line.split()
    if len(parts) != 5:
        return [f"字段數應為 5，實際 {len(parts)}"]
    parsed = parse_box(line)
    if parsed is None:
        return ["存在非數值字段"]
    cid, cx, cy, w, h = parsed
    if not (0 <= cid < n_classes):
        errors.append(f"類別 id {cid} 超出範圍 [0, {n_classes - 1}]")
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
        print(f"未在 {IMAGES_DIR} 找到圖像。")
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
                f"類別 {class_names[cid]}(id={cid}) 僅 {n} 個框，低於建議下限 {MIN_IMAGES_PER_CLASS}"
            )
    for cid in range(n_classes):
        if class_counts.get(cid, 0) == 0:
            warnings.append(f"類別 {class_names[cid]}(id={cid}) 沒有任何標註框")
    if missing_labels:
        warnings.append(f"{missing_labels} 張圖像沒有對應標籤文件（標註未完成，或需生成空標籤作為負樣本）")
    if unreadable:
        warnings.append(f"{unreadable} 張圖像無法讀取")

    lines_out = [
        "# 數據集質量報告",
        "",
        f"- 圖像總數：{len(images)}",
        f"- 有標註的圖像：{len(images) - missing_labels - empty_labels}",
        f"- 空標籤（負樣本）：{empty_labels}",
        f"- 缺標籤文件：{missing_labels}",
        f"- 標註框總數：{total_boxes}",
        f"- 極小框（短邊 < {TINY_BOX_PX:.0f}px）：{tiny_boxes}",
        f"- 致命錯誤：{len(fatal)}",
        "",
        "## 類別分佈",
        "",
        "| id | 類別 | 組 | 框數 |",
        "|---|---|---|---|",
    ]
    for c in classes:
        lines_out.append(
            f"| {c['id']} | {c['name_en']} | {c['group']} | {class_counts.get(c['id'], 0)} |"
        )
    lines_out += [
        "",
        "## 框尺寸（歸一化）",
        "",
        f"- 寬：min={min(widths):.4f} mean={sum(widths)/len(widths):.4f} max={max(widths):.4f}" if widths else "- 寬：無數據",
        f"- 高：min={min(heights):.4f} mean={sum(heights)/len(heights):.4f} max={max(heights):.4f}" if heights else "- 高：無數據",
        "",
    ]
    if fatal:
        lines_out += ["## 致命錯誤（須修復後才能訓練）", ""]
        lines_out += [f"- {e}" for e in fatal[:200]]
        if len(fatal) > 200:
            lines_out.append(f"- ...另有 {len(fatal) - 200} 條")
        lines_out.append("")
    if warnings:
        lines_out += ["## 警告", ""]
        lines_out += [f"- {w}" for w in warnings]
        lines_out.append("")

    REPORT_PATH.write_text("\n".join(lines_out), encoding="utf-8")

    print(f"圖像 {len(images)} | 框 {total_boxes} | 空標籤 {empty_labels} | 缺標籤 {missing_labels}")
    print(f"致命錯誤 {len(fatal)} | 警告 {len(warnings)}")
    print(f"report -> {REPORT_PATH}")
    for e in fatal[:20]:
        print(f"  [FATAL] {e}")
    for w in warnings[:20]:
        print(f"  [WARN ] {w}")

    return 2 if fatal else 0


if __name__ == "__main__":
    raise SystemExit(main())
```

> **注意：** 本腳本只統計"文件級"錯誤，不做 IoU 重疊分析。
> 重度重疊（同一目標被標兩次）屬於標註質量範疇，在論文的"數據集質量"章節以人工抽樣方式説明即可。

- [ ] **Step 4: 運行測試確認通過**

Run: `pytest tests/test_check_labels.py -v`
Expected: PASS（9 passed）

- [ ] **Step 5: 在真實數據上運行門禁**

Run: `python scripts/check_labels.py`
Expected: 此時因標註未完成，會輸出大量 `缺標籤文件` 警告但**致命錯誤應為 0**。
打開 `data/dataset/dataset_report.md` 核對類別分佈表。

**這一步的判定標準：** 只有當 `致命錯誤 = 0` 時才可以進入 Task 8 的訓練。

- [ ] **Step 6: 運行全部單元測試**

Run: `pytest tests/ -v`
Expected: PASS（44 passed）

**分佈：** `test_classes.py` 9、`test_extract_frames.py` 5、`test_dedup.py` 6、`test_manifest.py` 8、`test_split.py` 7、`test_check_labels.py` 9。

若有用例失敗，**先修測試或實現，不要跳過**——這些用例保護的是"劃分無泄漏""標籤合法""類別表一致"三條不可回退的約束。

- [ ] **Step 7: 提交**

```bash
git add scripts/check_labels.py tests/test_check_labels.py
git commit -m "feat: 標註質量門禁，含越界/非法類別/極小框/分佈檢查"
```

---

## Task 8: 環境冒煙測試（Windows + CUDA 關鍵驗證）

**Files:**
- Create: `scripts/smoke_test.py`

**Interfaces:**
- Consumes: `datasets/pathguide.yaml`（Task 6，若尚未標註則使用內置的 20 張隨機圖臨時生成）
- Produces: `runs/smoke/` 下的短期訓練輸出，以及退出碼 0/1

> **為什麼必須有這個 Task：** Windows 上的 Ultralytics 訓練最常見的失敗是
> DataLoader 多進程與 CUDA 初始化問題，往往在長訓練跑到一半才暴露。
> 本 Task 用 **20 張圖、2 epoch、約 2 分鐘**把這類問題提前暴露。

---

- [ ] **Step 1: 實現 `scripts/smoke_test.py`**

```python
"""Windows + CUDA 冒煙測試：20 張圖、2 epoch，驗證訓練鏈路可用。

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
    # 8:2 劃分，樣本極少時至少保證 val 非空
    n_val = max(1, len(sample) // 5)
    for i, (img, label) in enumerate(sample):
        sub = "val" if i < n_val else "train"
        shutil.copy2(img, SMOKE_DIR / "images" / f"{sub}_{img.name}")
        shutil.copy2(label, SMOKE_DIR / "labels" / f"{sub}_{img.stem}.txt")

    SMOKE_YAML.write_text(
        "# 冒煙測試用，自動生成，勿手工編輯\n"
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
        print("torch 未安裝，請先 pip install -r requirements.txt")
        return 1

    if not torch.cuda.is_available():
        print("CUDA 不可用。請先修復 GPU 環境再運行冒煙測試。")
        return 1

    props = torch.cuda.get_device_properties(torch.cuda.current_device())
    vram_gb = props.total_memory / (1024 ** 3)
    print(f"GPU: {props.name} ({vram_gb:.1f} GB)")

    pairs = collect_labelled_pairs()
    if len(pairs) < 5:
        print(f"已標註圖像不足（找到 {len(pairs)} 對），無法構成冒煙集。")
        print("請先完成至少 5 張圖的標註（Task 8 之前的人工標註步驟）。")
        return 1

    yaml_path = build_smoke_dataset(pairs)
    print(f"冒煙集已構建：{SMOKE_DIR}（{min(N_SAMPLES, len(pairs))} 張）")

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
        print("冒煙測試失敗：未產出權重文件。")
        return 1

    print("冒煙測試通過。訓練鏈路（CUDA + DataLoader + 保存）均可用。")
    print("提示：Windows 下若出現卡死，請把 workers 改為 0 後重跑本腳本驗證。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: 先用 5 張圖手工標註作為輸入**

在 X-AnyLabeling 中標註 5 張圖，導出 YOLO 格式到 `data/dataset/labels/`。
（這一步是正式標註流程的預熱，同時為冒煙測試提供最小輸入。）

- [ ] **Step 3: 運行冒煙測試**

Run: `python scripts/smoke_test.py`
Expected: 打印 GPU 名稱與顯存，訓練 2 epoch 完成，輸出 `runs/smoke/weights/best.pt 存在: True`，末行 `冒煙測試通過`。

**若出現 CUDA out of memory**：把 `batch` 手動改為 2 重跑。
**若出現卡死無輸出**：把 `workers=2` 改為 `workers=0` 重跑。這兩種情況都屬預期範圍，記錄下實際可用值。

- [ ] **Step 4: 記錄實測配置**

把冒煙測試可用的 `batch` 與 `workers` 值記錄到 `configs/collect_plan.md` 末尾新增一節：

```markdown
## 6. 實測訓練配置（由冒煙測試得出）
- 顯卡：
- 顯存：
- 可用 batch：
- 可用 workers：
- 冒煙測試日期：
```

- [ ] **Step 5: 提交**

```bash
git add scripts/smoke_test.py configs/collect_plan.md
git commit -m "test: Windows+CUDA 冒煙測試，提前暴露 DataLoader 與顯存問題"
```

---

## Task 9: logo 分類器試點（5 店鋪）

**Files:**
- Create: `scripts/train_cls.py`
- Create: `configs/logos.json`
- Create: `data/logos/{store_id}/.gitkeep`（5 店鋪 + `unknown`）

**Interfaces:**
- Consumes: `data/logos/{store_id}/*.jpg`（ImageFolder 格式的平鋪結構）
- Produces:
  - `runs/logo_v1/weights/best.pt` 與 `best.tflite`
  - `runs/logo_v1/eval_report.md`：每類準確率、混淆矩陣、`unknown` 誤報率
  - CLI：`python scripts/train_cls.py --epochs 60 --imgsz 224`

> **兩段式架構（spec §5）的第一段。** 本 Task 獨立於主檢測器，可並行推進，
> 不阻塞 Task 8/10/11 的訓練進度。

---

- [ ] **Step 1: 創建 `configs/logos.json`**

```json
{
  "version": 1,
  "note": "store_id 必須與 data/logos/ 下的文件夾名一致；unknown 必須存在。",
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

**執行時必須先用實地核實結果替換 `stores` 列表**——彩明商場內實際存在哪些店以現場為準。
`unknown` 與目標店（麥當勞）必須保留。

- [ ] **Step 2: 創建目錄骨架**

```bash
for s in unknown mcdonalds seven_eleven watsons wellcome hsbc; do mkdir -p "data/logos/$s"; touch "data/logos/$s/.gitkeep"; done
```

- [ ] **Step 3: 實現 `scripts/train_cls.py`**

```python
"""logo 分類器訓練與評測包裝（Windows 安全）。

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
        problems.append(f"缺少店鋪目錄：{sorted(missing)}")

    counts: Counter[str] = Counter()
    for store in sorted(existing):
        n = sum(1 for p in (LOGOS_DIR / store).iterdir()
                if p.is_file() and p.suffix.lower() in (".jpg", ".jpeg", ".png"))
        counts[store] = n
        if n < MIN_PER_CLASS:
            problems.append(f"{store} 僅 {n} 張圖，低於建議下限 {MIN_PER_CLASS}")

    print("各店鋪圖像數：")
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
        print("\n數據集檢查未通過：")
        for p in problems:
            print(f"  - {p}")
        if not args.skip_check:
            print("\n修復後重跑，或加 --skip-check 強制繼續（不推薦）。")
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
        "# logo 分類器評測\n\n"
        f"- top1 準確率：{top1:.4f}\n"
        f"- 類別數：{len(model.names)}\n"
        f"- 類別：{list(model.names.values())}\n\n"
        "## 待人工補充\n"
        "- 混淆矩陣中 known 被誤判為其他 known 的樣本\n"
        "- unknown 被誤判為 known 的樣本（**最關鍵指標**）\n",
        encoding="utf-8",
    )
    print(f"report -> {report}")
    print("\n下一步：導出 TFLite（見 Task 11 的導出命令，把 weights 換成本次 best.pt）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: 採集 5 店鋪試點數據**

按 `spec §5.5` 要求拍攝，存入 `data/logos/<store_id>/`：
- 麥當勞：60 張（含純圖形 logo 與帶文字招牌兩種）
- 4 個錨點店：各 40 張
- `unknown`：**300 張非目標店鋪門面 + 其他品牌 logo**

拍攝覆蓋：3 距離 × 3 角度 × 2 光照。

- [ ] **Step 5: 運行數據集檢查**

Run: `python scripts/train_cls.py --skip-check --epochs 1`
Expected: 打印各店鋪圖像數。若某店 < 30 張會報警告。**先確認 `unknown` ≥ 300 張**，否則返回補拍。

- [ ] **Step 6: 正式訓練**

Run: `python scripts/train_cls.py --epochs 60 --imgsz 224 --batch 32`
Expected: 訓練完成，打印 `top1 = 0.xx`，生成 `runs/logo_v1/eval_report.md`。

**判定標準：** `unknown` 被誤判為 known 的比例必須 < 5%。若不達標：
1. 增加 `unknown` 樣本量；
2. 提高 `configs/logos.json` 的 `confidence_threshold`；
3. 檢查是否某個 known 店樣本中存在大量 `unknown` 混入。

- [ ] **Step 7: 提交**

```bash
git add scripts/train_cls.py configs/logos.json
git commit -m "feat: logo 分類器訓練腳本與 5 店鋪試點配置"
```

---

## Task 10: 自舉預標與人工複核（數據生產）

> **本 Task 無代碼交付，產出是數據集本身。** 它產出 2,500+ 張已標註圖像，
> 是 Task 11 正式訓練的唯一輸入。Steps 中的具體命令依賴 Task 8 的 v0 模型。

**Files:**
- Modify: `data/dataset/labels/`（新增大量標註文件）
- Modify: `data/golden/seed_300/quality_review.md`
- Create: `data/dataset/labeling_log.md`

**Interfaces:**
- Consumes: `data/dataset/images/`、`data/golden/seed_300/`、`runs/smoke/weights/best.pt`
- Produces: 完整標註的 `data/dataset/labels/`；更新後的 `manifest.csv`

---

- [ ] **Step 1: 人工精標種子集 300 張**

在 X-AnyLabeling 中按 `configs/annotate_spec.md` 標註 300 張，覆蓋全部 16 類
（含 ≥60 張 `ambiguous_vertical`），導出到 `data/dataset/labels/`。

**同時在 `data/golden/baseline_200/` 存入 200 張純人工精標結果**——
按 `spec §6.1`，這 200 張**永不參與訓練**。對應的圖像同時複製到 `data/dataset/images/`，
但其標籤文件在訓練前必須被排除（見 Step 5 的清單過濾）。

- [ ] **Step 2: 訓練 v0 模型**

```bash
python scripts/make_manifest.py
python scripts/split_dataset.py --ratios 0.8 0.1 0.1 --seed 42
python scripts/check_labels.py
```

確認致命錯誤為 0 後：

```bash
yolo detect train model=yolov8n.pt data=datasets/pathguide.yaml ^
  epochs=80 imgsz=640 batch=8 workers=2 ^
  project=runs name=pg_v0
```

> **Windows 注意：** 上面使用 `^` 續行。若在 Git Bash 中執行，改為 `\`。

Expected: `runs/pg_v0/weights/best.pt` 生成。

- [ ] **Step 3: 用 v0 做半自動預標**

導出 v0 為 ONNX 供 X-AnyLabeling 加載：

```bash
yolo export model=runs/pg_v0/weights/best.pt format=onnx imgsz=640 opset=12
```

在 X-AnyLabeling 中：
1. 加載 `runs/pg_v0/weights/best.onnx`；
2. 對剩餘 2,000–2,500 張執行「一鍵預測所有圖像」；
3. 開啓 SAM 自動修框（把預測框吸附到目標邊界）；
4. 導出 YOLO 格式覆蓋到 `data/dataset/labels/`。

- [ ] **Step 4: LocateAnything-3B 裁剪驗證複核**

對預標產生的每個框裁剪後送入 VLM 詢問是否為目標類別，剔除誤檢。

> **實現説明：** 這一步在 PC 上以批處理腳本離線執行，不屬於 M0–M2 的交付代碼
> （它是一次性的數據處理作業）。若 GPU 時間緊張，**可降級為人工抽查前 200 張預標結果**：
> 統計誤檢率，若 < 15% 則直接進入人工複核，不單獨跑 VLM 環節。
> 該降級不影響 M2 的出口條件，隻影響論文中"AI 輔助標註"章節的方法論描述完整性。

- [ ] **Step 5: 爭議樣本分流與人工複核**

1. 計算 v0 與 VLM 結果的 IoU，**閾值取 0.5**（按 `spec §6.1` 放寬，減少人工量）；
2. IoU < 0.5 或類別不一致者導入 X-AnyLabeling 的「已檢查」流程；
3. 人工僅做 Accept / Reject 與邊界微調，不從零畫框；
4. 記錄處理量到 `data/dataset/labeling_log.md`：日期、處理張數、接受數、剔除數、平均耗時。

- [ ] **Step 6: 排除黃金集基線，重建 manifest 與劃分**

確認 `data/golden/baseline_200/` 的 200 張圖**不在** `data/dataset/images/` 中參與訓練：

```bash
python scripts/make_manifest.py
python scripts/split_dataset.py --ratios 0.8 0.1 0.1 --seed 42
python scripts/check_labels.py
```

**驗證：** 打開 `data/dataset/dataset_report.md`，確認：
- 致命錯誤 = 0；
- 16 類全部有標註框（`ambiguous_vertical` 也不例外）；
- `footbridge_entrance` 框數 ≥ 250。

**若天橋入口不足 250**：返回 Task 2 補採集，**不要**用其他類別湊數。

- [ ] **Step 7: 提交**

```bash
git add data/dataset/manifest.csv data/dataset/split.json data/dataset/labeling_log.md
git add -f data/dataset/dataset_report.md
git commit -m "data: 自舉預標 + 人工複核完成，數據集 v1 就緒"
```

---

## Task 11: 正式訓練、評測與 TFLite 導出

**Files:**
- Create: `scripts/export_tflite.py`
- Create: `datasets/pathguide_eval_B.yaml`
- Create: `data/dataset/route_B.txt`（由命令生成，非手寫）

**Interfaces:**
- Consumes: `datasets/pathguide.yaml`（Task 6）、`data/dataset/` 完整標註（Task 10）、黃金集 `data/golden/baseline_200/`
- Produces:
  - `runs/pg_v1/weights/best.pt`
  - `runs/pg_v1/best.tflite`（INT8）
  - `runs/pg_v1/eval_final.md`：每類召回率表 + 量化前後對比 + 路線 B 泛化評測
  - `app/assets/models/detector.tflite`

---

- [ ] **Step 1: 正式訓練**

```bash
yolo detect train model=yolov8n.pt data=datasets/pathguide.yaml ^
  epochs=100 imgsz=640 batch=8 workers=2 patience=25 ^
  mosaic=1.0 hsv_h=0.015 hsv_s=0.7 hsv_v=0.4 degrees=5.0 ^
  cls=0.7 box=7.5 ^
  project=runs name=pg_v1
```

> `batch=8` 依據 Task 8 記錄的實測值調整。`cls=0.7` 提高分類損失權重以提升召回率
> （按 `spec §7`，畢設硬指標是召回率）。

Expected: 訓練 100 epoch（或 patience=25 提前停止），`runs/pg_v1/weights/best.pt` 生成。

- [ ] **Step 2: 每類召回率評測**

```bash
yolo detect val model=runs/pg_v1/weights/best.pt data=datasets/pathguide.yaml split=test
```

讀出每類召回率，重點核對：
- `footbridge_entrance` 召回率 **> 70%**
- `pedestrian` / `street_obstacle` / `step` / `glass_door` 召回率 **> 70%**

**若天橋入口召回率 < 70%，按順序嘗試：**
1. 對該類樣本過採樣（在 `datasets/pathguide.yaml` 的 train 清單中重複列出該類圖像）；
2. 提高輸入尺寸到 `imgsz=768`（代價：真機延遲上升，必須重新測基準）；
3. 升級到 `yolov8s.pt` 重訓（代價：模型體積與延遲顯著上升）。

**每次調整後必須重新評測並記錄到 `eval_final.md`，不得只保留最好結果。**

- [ ] **Step 3: 路線 B 泛化評測**

創建 `datasets/pathguide_eval_B.yaml`：

```yaml
# 路線 B 泛化評測：僅使用 route_B 數據，不參與任何訓練
path: <在此填入 data/dataset 的絕對路徑>
train: test.txt   # 佔位，Ultralytics 要求非空
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

生成 `route_B.txt`（僅含 `manifest.csv` 中 `route == route_B` 的圖像）：

```bash
python -c "import csv,pathlib; rows=[r for r in csv.DictReader(open('data/dataset/manifest.csv',encoding='utf-8-sig')) if r['route']=='route_B']; pathlib.Path('data/dataset/route_B.txt').write_text('\n'.join('images/'+r['image_name'] for r in rows)+'\n', encoding='utf-8'); print(len(rows))"
```

```bash
yolo detect val model=runs/pg_v1/weights/best.pt data=datasets/pathguide_eval_B.yaml split=val
```

**記錄結果**：路線 A 訓練的模型在路線 B 上的召回率下降幅度，是論文泛化能力章節的核心數據。

- [ ] **Step 4: 實現 `scripts/export_tflite.py`**

```python
"""導出 INT8 TFLite，並用黃金集複測量化前後精度損失。

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
                    help="量化校準用圖像清單")
    args = ap.parse_args()

    weights = Path(args.weights)
    if not weights.exists():
        print(f"未找到權重：{weights}")
        return 1

    calib_list = Path(args.data)
    if not calib_list.exists():
        print(f"未找到校準圖像清單：{calib_list}")
        print("提示：校準集應取自訓練域（不含黃金集基線），約 200-500 張。")
        return 1

    from ultralytics import YOLO

    print("== INT8 導出 ==")
    model = YOLO(str(weights))
    export_path = model.export(format="tflite", imgsz=args.imgsz, int8=True, data=str(calib_list))
    tflite_path = Path(export_path)
    print(f"導出：{tflite_path} ({tflite_path.stat().st_size / 1e6:.2f} MB)")

    print("\n== 導出後評測 ==")
    fp_model = YOLO(str(weights))
    fp_metrics = fp_model.val(data=str(REPO_ROOT / "datasets" / "pathguide.yaml"), split="test", verbose=False)
    fp_map = float(getattr(fp_metrics.box, "map50", 0.0))
    print(f"FP32 mAP@0.5 = {fp_map:.4f}")

    APP_MODELS.mkdir(parents=True, exist_ok=True)
    target = APP_MODELS / "detector.tflite"
    shutil.copy2(tflite_path, target)
    print(f"已複製到 Demo 資產目錄：{target}")

    print(
        "\n手動步驟（必須執行）：\n"
        "  1. 在 Python 中加載該 tflite，對數據集 test 折推理，得到 INT8 的 mAP@0.5；\n"
        "  2. 與上面的 FP32 mAP 比較，若下降 > "
        f"{MAX_ACCURACY_DROP:.1%}，回退到 FP16：\n"
        "     yolo export model=<weights> format=tflite imgsz=640 half=True\n"
        "  3. 把兩個 mAP 值填入 runs/pg_v1/eval_final.md。\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

> **為什麼不自動完成 INT8 精度複測：** Ultralytics 的 `val()` 不直接支持 TFLite 後端推理，
> 需要自己用 `tflite_runtime` 跑一遍前向。這是一次性工作（約 30 行），
> 但**不做這一步就不知道量化損失，真機精度崩塌時無從排查**——因此列為強制手動步驟。

- [ ] **Step 5: 執行導出並按需回退**

Run: `python scripts/export_tflite.py --weights runs/pg_v1/weights/best.pt --imgsz 640`
Expected: 生成 `runs/pg_v1/weights/best_saved_model/best_int8.tflite`，打印模型體積，並複製到 `app/assets/models/detector.tflite`。

按 Step 4 的提示手動完成 INT8 精度複測。若損失 > 1.5%，執行 FP16 回退：

```bash
yolo export model=runs/pg_v1/weights/best.pt format=tflite imgsz=640 half=True
```

- [ ] **Step 6: 彙總評測報告**

創建 `runs/pg_v1/eval_final.md`，包含：

```markdown
# M2 最終評測報告

## 1. 訓練配置
- 模型：YOLOv8n
- epochs / imgsz / batch：
- 數據集規模：train / val / test
- 實際使用 seed：

## 2. 每類指標（test 折）
| id | 類別 | Precision | Recall | mAP@0.5 |
|---|---|---|---|---|
（16 行）

## 3. 出口條件核對
- [ ] footbridge_entrance Recall > 0.70
- [ ] pedestrian Recall > 0.70
- [ ] street_obstacle Recall > 0.70
- [ ] step Recall > 0.70
- [ ] glass_door Recall > 0.70
- [ ] 整體 mAP@0.5 在 0.60–0.70 區間

## 4. 路線 B 泛化評測
- 路線 B Recall（整體）：
- 相對路線 A test 折的下降幅度：

## 5. 量化對比
| 精度 | 模型體積 | mAP@0.5 |
|---|---|---|
| FP32 | | |
| INT8 | | |
- 精度損失：
- 是否觸發 FP16 回退：

## 6. 失敗案例分析
（列出 5–10 個典型漏檢/誤檢案例，附文件名與原因判斷）

## 7. 調參記錄
（記錄每次為提高天橋入口召回率所做的嘗試與對應結果，含未採用的方案）
```

- [ ] **Step 7: 提交**

```bash
git add scripts/export_tflite.py datasets/pathguide_eval_B.yaml
git add -f runs/pg_v1/eval_final.md
git commit -m "feat: 正式訓練、每類召回率評測、路線B泛化評測與 TFLite INT8 導出"
```

---

## Task 12: M2 出口驗收

**Files:**
- Create: `docs/superpowers/plans/M2-acceptance.md`

**Interfaces:**
- Consumes: `runs/pg_v1/eval_final.md`、`runs/logo_v1/eval_report.md`、`runs/env_report.json`
- Produces: `docs/superpowers/plans/M2-acceptance.md`，即 M3（Flutter Demo）的輸入契約

---

- [ ] **Step 1: 逐項核對出口條件**

```markdown
# M2 出口驗收

日期：
執行人：

## 主檢測器
- [ ] `best.tflite` 已生成並複製到 `app/assets/models/detector.tflite`
- [ ] 模型體積 < 10 MB，實測：___ MB
- [ ] footbridge_entrance Recall ≥ 0.70，實測：___
- [ ] pedestrian / street_obstacle / step / glass_door Recall 均 ≥ 0.70
- [ ] 整體 mAP@0.5 在 0.60–0.70
- [ ] 量化後精度損失 ≤ 1.5%
- [ ] 路線 B 泛化評測已完成並記錄
- [ ] 16 類全部有標註框，無一類為零

## logo 分類器
- [ ] 5 店鋪試點 top1 已記錄
- [ ] `unknown` 被誤判為 known 的比例 < 5%
- [ ] `best.tflite` 已導出

## 數據
- [ ] 黃金集 baseline_200 未參與任何訓練（已核對 split.json）
- [ ] `dataset_report.md` 致命錯誤 = 0
- [ ] 劃分校驗無泄漏

## 環境
- [ ] `runs/env_report.json` 中 cuda 為 OK
- [ ] 實測可用 batch 與 workers 已記錄

## 遺留問題
（列出未達標項、原因、處置計劃）
```

- [ ] **Step 2: 檢查黃金集確實未泄漏**

Run:
```bash
python -c "import json,csv,pathlib; s=json.load(open('data/dataset/split.json',encoding='utf-8')); base={p.stem for p in pathlib.Path('data/golden/baseline_200').rglob('*.txt')}; used=set(s['train'])|set(s['val']); leaked=sorted(base & {n.rsplit('.',1)[0] for n in used}); print('泄漏的基線圖像數:', len(leaked)); print(leaked[:10])"
```
Expected: `泄漏的基線圖像數: 0`

- [ ] **Step 3: 提交驗收文檔**

```bash
git add docs/superpowers/plans/M2-acceptance.md
git commit -m "docs: M2 出口驗收記錄，作為 M3 Flutter Demo 的輸入契約"
```

---

## 後續里程碑（M3–M6，另行編寫計劃）

本計劃在 M2 結束。以下內容在 M3 計劃中展開，**此處僅登記輸入契約，不展開任務**：

| 里程碑 | 週期 | 輸入契約（來自本計劃） | 主要產出 |
|---|---|---|---|
| **M3** App 骨架與可見 Demo | 第 5 周 | `app/assets/models/detector.tflite`、`configs/classes.json`、`configs/logos.json` | 可演示 APK：相機 + 檢測框 + 粵語播報 + 閾值滑條 + 視頻回放 |
| M4 決策核心 | 第 6–8 周 | M3 的 `VisionSource` 抽象、`Instruction` 類型 | 純 Dart 規則狀態機、交叉校驗、離線回放測試集、`RouteProvider` 可插拔接口 |
| M5 天橋專項 + 室內 | 第 9–12 周 | 彩明商場節點圖（依賴實地核實） | 全鏈路聯調、室內節點圖與 PDR |
| M6 評測與交付 | 第 13–16 周 | M4 的規則測試集 | 實地任務完成率測試、論文、演示視頻 |

**M3 計劃需要注意的已決事項（寫入 spec §9）：**
- 推理走 **Kotlin 平台通道**，不使用 `tflite_flutter`；
- 推理在 `Isolate` 中執行，主線程只畫框；
- 抽幀推理（每 2–3 幀一次）；
- 相機分辨率 640×480 或 1280×720，與訓練輸入對齊；
- 打包 Noto Sans CJK 子集，避免中文顯示方塊。

---

## 自審記錄

**Spec 覆蓋度核對：**

| Spec 章節 | 覆蓋任務 |
|---|---|
| §3 架構（Dart/Kotlin 分層、決策層可單測） | Task 1（骨架）；M3–M4 計劃展開 |
| §4 類別表 16 類 | Task 1（`classes.json` + 9 項測試）、Task 7（分佈檢查） |
| §4.2 合併與刪除決定 | Task 1 類別表內容 |
| §5 兩段式 logo 架構 | Task 9 |
| §5.4 `unknown` 生死線 | Task 9 Step 3（檢查）、Step 6（誤報率判定） |
| §5.6 四條誤檢規則 | M4 計劃展開（本計劃僅登記為輸入契約） |
| §6.1 自舉流程 | Task 10 |
| §6.2 三個工程決定 | Task 3（視頻抽幀為主）、Task 6（分組劃分）、Task 7（質量門禁） |
| §6.3 目錄結構 | Task 1 Step 5、Task 4、Task 5 |
| §6.4 數據量目標 | Task 2（採集計劃表）、Task 10 Step 6（核對） |
| §7 模型與部署 | Task 8（冒煙）、Task 11（訓練與導出） |
| §8 決策引擎 | M4 計劃展開 |
| §9 Demo 切片 | M3 計劃展開（本計劃 Task 12 登記輸入契約） |
| §10 里程碑 | 文末"後續里程碑" |
| §11 風險登記 | 各 Task 的判定標準與回退路徑（天橋樣本、泄漏、量化損失、顯存） |
| §12 不在範圍 | 文末"後續里程碑"與 Global Constraints |

**未在本計劃覆蓋、已顯式登記為 M3/M4 輸入契約的項：** 四條 logo 誤檢規則、決策引擎規則與單測、
Flutter Demo 全部實現、導航 API 集成。這是刻意的——本計劃的範圍是 M0–M2（數據與模型），
按 `spec §10`，M0–M2 是不依賴任何導航 API 的前置關鍵路徑。

**類型與命名一致性核對：**
- `configs/classes.json` 的 16 個 `name_en` 在 Task 1 定義，Task 6 `load_class_names()`、Task 7 `load_classes()`、Task 11 的 `pathguide_eval_B.yaml` 三處引用，值一致。
- `manifest.csv` 的 8 個列名在 Task 5 定義（`MANIFEST_COLUMNS`），Task 6 `load_manifest()`、Task 12 Step 2 的校驗腳本按同名讀取。
- `split.json` 的鍵為 `seed` / `ratios` / `counts` / `train` / `val` / `test`，Task 6 寫入，Task 12 讀取 `train`/`val`。
- 函數名核對：`frame_filename` / `is_sharp`（Task 3）、`hamming` / `is_duplicate`（Task 4）、`parse_source_meta` / `read_label_summary`（Task 5）、`assign_folds` / `validate_no_leakage`（Task 6）、`validate_line` / `parse_box`（Task 7）——各測試文件 import 的名稱與實現一致。

**已知的誠實侷限（不迴避）：**
1. Task 6 的 `assign_folds` 在"類別分層"與"折間比例"之間存在天然衝突，本實現以分層優先。若實際運行後發現 train/val/test 比例明顯失衡（例如 val 超過 25%），可調整桶內輪轉步長（當前固定為 i==1→val、i==2→test），**但不得為了比例而犧牲 val 的類別覆蓋**。
2. Task 10 Step 4 的 VLM 複核被標註為"可降級"，因為它在 GPU 時間緊張時不影響 M2 出口條件。
3. Task 11 Step 4 的 INT8 精度複測列為手動步驟，原因是 Ultralytics 不直接支持 TFLite 後端 `val()`。
4. Task 9 的 `configs/logos.json` 中 5 家店鋪為**佔位示例**，必須以彩明商場實地核實結果替換。這是本計劃中唯一已知的內容佔位，已在 Task 9 Step 1 顯式標註。
5. Task 11 Step 3 的 `pathguide_eval_B.yaml` 中 `path:` 字段需由執行者填入環境絕對路徑（Ultralytics 要求絕對路徑，無法預知宿主機佈局）。
