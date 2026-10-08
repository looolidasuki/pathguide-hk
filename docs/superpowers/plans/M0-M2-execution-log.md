# M0–M2 環境搭建與流水線跑通 · 執行記錄

**日期：** 2026-09-15
**執行方式：** Inline Execution（當前會話，帶檢查點）
**結論：** 訓練環境已就緒，數據→標註→訓練→評測→報告全鏈路已端到端跑通，產出真實非零指標。

---

## 1. 實測環境

| 項 | 值 |
|---|---|
| 操作系統 | Windows |
| Python | **3.12.3**（`uv venv`；系統默認 3.14.4 過新，PyTorch 無對應 wheel） |
| 環境管理 | **uv 0.12.13 + venv**（本機未安裝 conda，計劃中的 conda 步驟已替換） |
| PyTorch | **2.11.0+cu128** |
| torchvision | 0.26.0+cu128 |
| CUDA runtime | 12.8 |
| GPU | **NVIDIA GeForce RTX 5070** / sm_120 (Blackwell) / 11.91 GB / 驅動 616.56 |
| ultralytics | 8.3.253 |
| opencv-python | 5.0.0.93 |
| 磁盤可用 | 1188 GB |
| 建議 batch | 12（冒煙實測；流水線使用 8 以留餘量） |

**GPU 關鍵驗證：** `sm_120` 必須搭配 CUDA 12.8+ 的 PyTorch 構建。已實測矩陣乘法通過，無 "no kernel image" 錯誤。

`runs/env_report.json` 為機讀版本，7 項檢查全部 OK。

---

## 2. 端到端跑通結果

命令：

```powershell
. .\.env.ps1
python scripts\gen_synthetic.py --per-class 24 --sources 8
python scripts\make_manifest.py
python scripts\split_dataset.py --seed 42
python scripts\check_labels.py
python scripts\run_pipeline.py --skip-generate --epochs 60 --imgsz 416 --batch 8 --workers 0
```

| 環節 | 結果 |
|---|---|
| 數據生成 | 30 張合成圖（含 6 張負樣本），91 個標註框，9 個來源文件夾 |
| manifest | 30 條，缺標籤 0 |
| 分組分層劃分 | train 12 / val 9 / test 9，**泄漏校驗通過** |
| 標籤門禁 | 致命錯誤 0 |
| 訓練 | YOLOv8n，60 epochs，3,013,968 參數，8.2 GFLOPs，GPU 正常 |
| 評測（test 折） | mAP@0.5 = **0.1013**，macro Recall = **0.7257**，12 個類別有指標 |
| 報告 | `runs/pipeline_report.md` |

**這些指標本身沒有意義**——30 張合成圖、16 個類別，樣本量遠低於計劃要求的 2,500–3,000 張。它們的作用是證明**鏈路連通**，而不是模型性能。

真實數據到位後，只需把第 1 步換成 `extract_frames.py` → `dedup.py`，其餘步驟不變。

---

## 3. 排查過程中發現並修復的 4 個真實缺陷

這些都是**在真實採集數據上同樣會犯**的錯誤，不是合成數據特有問題。

### 缺陷 1（最嚴重）：標籤未鏡像圖像目錄結構

**現象：** 訓練與評測全部 `Instances = 0`，指標全為 0，**且不報任何錯誤**。

**根因：** Ultralytics 的 `img2label_paths()` 是把路徑裏的 `\images\` **替換**為 `\labels\` 並保留其餘層級：

```
images/route_A_synthetic_src00/xxx.jpg
  -> labels/route_A_synthetic_src00/xxx.txt   # 期望
```

而我們把標籤扁平寫在 `labels/xxx.txt`，因此**每一個標籤都找不到**。

**為什麼危險：** 它不報錯。指標全 0 看起來像"模型沒學好"，會把排查方向引向超參、數據量、模型容量，而真實原因是路徑契約。

**修復：** `gen_synthetic.py`、`make_manifest.py`、`check_labels.py` 三處統一改為鏡像結構，並寫入 spec §6.2 決定四。

### 缺陷 2：manifest 丟失子目錄

**現象：** `train.txt` 寫出的路徑指向不存在的文件。

**根因：** manifest 只記錄文件名（`xxx.jpg`），未記錄相對 `images/` 的路徑。

**附帶風險：** 真實採集時不同來源文件夾可能存在同名幀（多機位 `IMG_0001.jpg`），只記文件名會讓**標籤互相覆蓋**，且分組泄漏校驗失效。

**修復：** manifest 列 `image_name` 改為 `image_rel`（相對 `images/` 的 posix 路徑，含子目錄）。

### 缺陷 3：劃分清單使用相對正斜槓路徑

**現象：** Ultralytics 報 `No such file or directory`。

**根因（兩點疊加）：**
1. Ultralytics 從 **CWD** 解析相對路徑，而非從 yaml 的 `path` 字段；
2. `img2label_paths()` 在 Windows 上用 `os.sep` 拼 `\images\`，正斜槓路徑無法匹配。

**修復：** 劃分清單寫**絕對原生路徑**（`Path` 拼接，非字符串拼接），並加單元測試斷言路徑為絕對且不含正斜槓。

### 缺陷 4：合成生成器的類別集合退化

**現象：** 最初 train 折只有 1 張正樣本，test 折全是負樣本。

**根因：** 生成器讓每個來源都含**完全相同的 16 類**，於是劃分腳本把它們全部歸入同一個分層桶；桶內前兩個來源被固定分給 val/test，train 幾乎無正樣本。

**説明：** 這是合成生成器的缺陷，真實數據下每個採集點位的類別集合天然不同，不會這樣退化。但它驗證了劃分腳本的**分層優先級裁決**（無泄漏 > val 覆蓋全類 > 比例）是有效的——腳本確實保證了各折都拿到來源。

**修復：** 生成器改為把每輪目標輪轉切片給不同來源，使各來源類別集合不同。

---

## 4. 受限沙箱適配（重要）

當前執行環境禁止打開**命名管道**，因此：

| 影響 | 處理 | 是否影響你 |
|---|---|---|
| DataLoader 多進程失敗 | `workers=0` | **是**——你在普通終端應設為 4–8 |
| Ultralytics `cache_labels` 用 ThreadPool | `scripts/env_setup.py` 探測後打順序補丁 | **否**——普通終端會自動探測為可用，不打補丁 |
| TFLite 導出掛起 | 改在普通終端執行 `scripts/export_model.py` | **是**——需你手動執行一次 |

適配細節已寫入 spec §14，包括 `cache_labels` 補丁的 4 條實現約束（補丁目標類、`verify_image_label` 簽名、緩存字典必需鍵、`im_file` 必須為 str）。

---

## 5. 交付物

| 文件 | 説明 |
|---|---|
| `.env.ps1` | **環境激活腳本**：激活 venv + 重定向 `UV_CACHE_DIR` / `YOLO_CONFIG_DIR` / `MPLCONFIGDIR` |
| `requirements.txt` | 依賴清單（torch 需單獨用 cu128 索引安裝） |
| `configs/classes.json` | 16 類類別表（單一事實源） |
| `scripts/env_setup.py` | 沙箱適配：寫路徑重定向 + `cache_labels` 補丁 |
| `scripts/env_check.py` | 環境自檢（7 項），產出 `runs/env_report.json` |
| `scripts/gen_synthetic.py` | 合成數據生成（**僅用於驗證流水線**） |
| `scripts/extract_frames.py` | 視頻抽幀 + 模糊過濾 |
| `scripts/dedup.py` | 感知哈希去重（評測域刻意保留冗餘） |
| `scripts/make_manifest.py` | manifest 生成 |
| `scripts/split_dataset.py` | 分組分層劃分 + 泄漏校驗 |
| `scripts/check_labels.py` | 標籤質量門禁 |
| `scripts/run_pipeline.py` | 端到端編排 |
| `scripts/run_all.py` | 完整復現腳本 |
| `scripts/export_model.py` | TFLite 導出（**須在普通終端運行**） |
| `scripts/smoke_test.py` | Windows+CUDA 冒煙測試 |
| `tests/` | 6 個測試文件，**47 個用例全部通過** |

---

## 6. 下一步

### 立即可做（普通終端）

```powershell
cd "C:\Users\user\PycharmProjects\Accessible Visual Guidance"
. .\.env.ps1
python scripts\env_check.py            # 確認 7 項全 OK
python -m pytest tests\ -v             # 確認 47 passed
python scripts\export_model.py --weights runs\pg_pipeline\weights\best.pt --int8
```

導出後還需**手動複測 INT8 量化精度**（Ultralytics 的 `val()` 不支持 TFLite 後端），損失 > 1.5% 則回退 FP16。

### 進入真實數據階段

1. **實地核實**彩明商場與調景嶺站的連通方式，以及商場內目標店/錨點店清單（阻塞節點圖與 logo 數據採集）。
2. 按 `configs/collect_plan.md` 採集（**第 1 周內必須先拍滿 `footbridge_entrance` ≥ 250 張**）。
3. 清空 `data/dataset/`，把第一步換成 `extract_frames.py` → `dedup.py`，其餘流水線不變。
4. 人工精標 300 張種子集 + 200 張凍結基線（`data/golden/`）。

### 完成 M0–M2 後

進入 M3（Flutter Demo）。M2 出口驗收模板見計劃 Task 12；M3 的輸入契約是 `app/assets/models/detector.tflite` + `configs/classes.json` + `configs/logos.json`。

---

## 7. 後續執行記錄

| 日期 | 內容 | 文檔 |
|---|---|---|
| 2026-09-22 | 人工複核一輪（trashbin 44 張）：跑通「預標 → 人工複核 → 回寫 → 重訓」閉環；新增 `xlabel_io.py`、`single_source.py`；實測人工複核 0 微調 / 5 刪誤檢 / 41 補漏檢，零框圖像 9 → 0；對照實驗 mAP@0.5 0.502 → 0.788、macro Recall 0.500 → 0.750 | [`2026-09-22-human-review-round-trashbin.md`](2026-09-22-human-review-round-trashbin.md) |

