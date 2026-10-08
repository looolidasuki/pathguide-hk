# 第三方數據來源與署名 / Third-Party Data Attribution

> **這份文件必須在倉庫裏而不是在 `data/` 裏**：`data/` 是 gitignore 的，
> 隨數據集下載的 README 會丟，而 CC BY 系列許可**要求保留署名**。
> 丟了署名就等於違反許可。

最後更新：2026-10-02

---

## 1. 使用狀態

| 數據集 | 用途 | 許可狀態 | 引用位置 |
|---|---|---|---|
| Everyday Object Finder v3（Roboflow Universe，`chris-law/everyday-object-finder`） | `pedestrian`/`bicycle` 及 16 個類（含新增的 `obstacle`/`escalator`）的訓練數據（**僅訓練集**，不進驗證集） | ✅ 聲明 **CC BY 4.0**（但有來源疑點，見 §2） | 本文件 §2 |
| People Detection v1（Roboflow Universe，`chris-law/people-detection-o4rdr-nlryq`） | `pedestrian` / `bicycle` 訓練數據（**僅訓練集**） | ⚠️ **僅限研究用途**，見 §3 | 本文件 §3 |
| Wikimedia Commons 抓取（`data/raw/external/`） | 候選素材，**尚未使用** | CC BY / CC BY-SA / CC0，逐張記於 `data/raw/external/attribution.jsonl` | 本文件 §4 |

---

## 2. Everyday Object Finder v3（**主用**）

**URL：** https://universe.roboflow.com/chris-law/everyday-object-finder/dataset/3
**導出格式：** YOLOv8，**5060 張**（train 4282 / valid 654 / test 124）
**導出時間：** 2026-10-02
**聲明的許可：** **CC BY 4.0**（見 `data.yaml` 與 `README.dataset.txt`）
**該項目自帶 README 未列出任何上游項目**（與 §3 那份 14 項目拼盤不同）。

### 2.1 使用方式

- **只用於訓練集，絕不進入驗證集**（`build_multiclass_dataset.py --add-multi-train-only`）。
  已逐幀核對：`data/dataset_poc5` 的 103 張 val **全部**來自香港來源，
  且 15 個第三方獨有的類在 val 裏**全部零框**。
- 進入 `dataset_poc5` 的規模：**4812 張**（5060 減去 248 張真灰度圖，見 §2.3）、
  **6746 個映射上的框**。

### 2.2 ⚠️ 來源疑點（必須寫進論文）

該數據集**聲明** CC BY 4.0，但其圖像看起來**大量來自網絡抓取**，而非拍攝者自攝：

- 文件名含素材站編號形態，例如 `1000_F_220334286_53z6aJnh72XgyxQjsDahg2IEoaItSiJO`
  （Shutterstock 式 ID）、`686311476354-Water-filled-Barrier.jpeg`（產品目錄照）；
- `escalator` 類的文件名前綴含 **Singapore / Changi / Marina / China / Otis**
  —— 即**新加坡、樟宜機場、濱海灣**等地，不是香港；
- **CC BY 4.0 是上傳者聲明的**。對於抓取來的圖片，上傳者未必持有轉授該許可的權利。

因此本項目的處理是：**照「聲明為 CC BY 4.0」使用並署名，
同時在論文的數據來源一節如實寫明上述疑點**，不聲稱已核實每一張圖的原始權利。
這與 §3 那份「僅限研究用途」不同 —— 那份是**聚合導出自身聲明 `Private`** 且含未聲明許可的上游，
這一份至少有一個明確的 CC BY 4.0 聲明。

### 2.3 已排除的內容

**248 張 `_grayscale` 真灰度圖已排除**（抽查 62/62 確認三通道差 0.00）。
理由：本項目按顏色判類（交通錐橙、水馬紅白、盲道黃），
灰度圖進訓練集是域污染。全庫真灰度僅 3.8%，基本就集中在這批。

### 2.4 類別映射（18 個映上，4 個跳過）

| Roboflow 類 | 本項目 id | 框數 |
|---|---|---:|
| `bicycle` | 11 bicycle | 2272 |
| `barrier` | **48 obstacle（v4 新類）** | 2156 |
| `escalator` | **49 escalator（v4 新類）** | 1980 |
| `person` | 6 pedestrian | 172 |
| `water_filled_barrier` | 10 barrier_water | 44 |
| `door` + `fire_door` | 18 door | 39 |
| `rubbish_bin` | 7 bin | 25 |
| `fence` / `streetlight` / `scooter` / `sign_post` / `bucket` | 26 / 45 / 12 / 46 / 47 | 各 15 / 15 / 6 / 5 / 6 |
| `power_distribution_box` / `billboard` / `cycle_path` / `cardboard` / `goods` / `barrier_fencing` | 30 / 36 / 44 / 33 / 31 / 27 | 各 3 / 3 / 2 / 1 / 1 / 1 |

**跳過（理由記錄在 `data/raw/roboflow_everyday_v3/_class_override.json`）：**

| 跳過 | 框數 | 理由 |
|---|---:|---|
| `tree` | 86 | 不等價：`tree` 是「樹」，本項目 `broken_tree`(42) 是「樹木（倒/斷）」 |
| `signage` | 25 | 待定：可能是 `sign_pictogram`(20 指示牌) 也可能是 `billboard`(36 廣告看板) |
| `toilet` | 3 | 本項目類別表裏沒有這一類 |
| `brige` | 1 | 不等價 + 拼寫錯誤：bridge ≠ `footbridge_entrance`(0 天橋入口) |

（合計 115 框，與導入 dry-run 的統計一致。）

### 2.5 域與預期（避免高估）

| 指標 | 本數據集 | People Detection（§3，實測零收益） |
|---|---:|---:|
| 框高佔圖比中位 | **0.501** | 0.183 |
| 框長寬比中位 | **0.913**（近正方形） | 0.281 |
| 正方形圖佔比 | **65%** | — |

即這是**近景實物照**為主，而部署場景是街景（目標小、雜亂）。

**但標註質量看起來是可信的** —— 這幾個類的框幾何完全貼合實物形狀：
`person` 長寬比 0.315（豎長條）、`streetlight` 0.146（細長杆）、
`fence` 1.633（橫向）、`signage` 高佔圖僅 0.042（薄片）。

**因此本項目不假定它有用**：與前一份第三方數據同樣處理 ——
先在**同一份香港 val** 上實測，再用數字決定是否採用。

---

## 3. People Detection v1（Roboflow Universe）

**URL：** https://universe.roboflow.com/chris-law/people-detection-o4rdr-nlryq/dataset/1
**導出格式：** YOLOv8，7261 張（train 5070 / valid 1431 / test 760）
**導出時間：** 2026-10-01
**聚合導出自身聲明的許可：** `Private`（見 `data.yaml`）

### 3.1 使用限制聲明（重要）

**本項目將該數據集的使用限定為學術研究（FYP 畢設），不用於任何商業用途，
也不重新分發其圖像。** 理由：

1. 聚合導出自身聲明 `license: Private`；
2. 其中一個上游項目（`MOT17-03-DPM`）**未聲明許可證**，
   而 MOT17 是行人跟蹤基準，其條款通常為僅限研究、需註冊同意；
3. Roboflow 導出會抹掉來源身份（文件名只保留 `原名_jpg.rf.<哈希>`），
   **因此無法從導出物重建「哪張圖來自哪個上游」，也就無法精確排除那一個上游**。

上述第 3 點已實測確認（見 `docs/superpowers/plans/2026-10-02-roboflow-dataset-provenance.md`）：
曾試圖按 6 位數字幀名排除 MOT17，但該子集裏出現了 MOT17 官方標註中不會有的
`Stopper` / `Signboard` / `helmet` 類別，且分辨率混雜 —— 説明**數字命名並非單一來源**，
按文件名排除是**不可靠**的。

### 3.2 上游項目與許可（按數據集自帶 README 轉錄）

本數據集由 Roboflow Universe 上以下項目"curated"而來：

| 上游項目 | 許可 |
|---|---|
| [First Pedestrian Test](https://universe.roboflow.com/safer-strides/first-pedestrian-test) | CC BY 4.0 |
| [person_camera_security1](https://universe.roboflow.com/chinh/person_camera_security1) | CC BY 4.0 |
| [Human Action Recognition 2000](https://universe.roboflow.com/skripsi-u18dy/human-action-recognition-2000) | CC BY 4.0 |
| [People Detection](https://universe.roboflow.com/chris-kydks/people-detection-2csbw) | CC BY 4.0 |
| [contador-de-gente teste 3](https://universe.roboflow.com/mackleaps/contador-de-gente-teste-3) | CC BY 4.0 |
| [OD3](https://universe.roboflow.com/object-detection-tuphv/od3-fq4yp) | CC BY 4.0 |
| [Person Detection](https://universe.roboflow.com/illimited/person-detection-gbuka) | CC BY 4.0 |
| [MOT17-03-DPM](https://universe.roboflow.com/bhu-ykklm/mot17-03-dpm-udorc) | ⚠️ **未聲明** |
| [The Curve](https://universe.roboflow.com/people-8gcmt/the-curve-02) | CC BY 4.0 |
| [pedestrain safety](https://universe.roboflow.com/intel-9horw/pedestrian-safety-obyfo) | CC BY 4.0 |
| [People Detection](https://universe.roboflow.com/jmedel/people-detection-f0fgt) | CC BY 4.0 |
| [people、rabish](https://universe.roboflow.com/cpk-wow-k5nlf/people-rabish) | CC BY 4.0 |
| [Pascal VOC 2012](https://universe.roboflow.com/jacob-solawetz/pascal-voc-2012) | CC BY 4.0 |
| [Person Detection (General)](https://universe.roboflow.com/mohamed-traore-2ekkp/people-detection-general) | CC BY 4.0 |

（以上鍊接與許可是數據集自帶 `README.dataset.txt` 的轉錄。`MOT17-03-DPM` 一項在該 README 中確實沒有許可字段。）

### 3.3 類別使用情況

該數據集聲明 53 個類別（`data.yaml` 的 `names`；Roboflow API 報 63 個，以導出物為準），
本項目只映射其中 2 個真實類：

| 本項目類 | id | 該數據集裏的寫法 |
|---|---:|---|
| pedestrian | 6 | `person` `persons` `people` `Pedestrian` `Pedestrians` `Persona` `Pessoa` |
| bicycle | 11 | `bicycle` `bicycle` `Bicycle` `bike` `Bike` |

其餘 43 個類別的框**顯式跳過並打印**（不是靜默丟棄）。
其中 `Cyclist` **故意不映射**：那是「騎車的人」，不是本項目的 `bicycle`（單車，一個障礙物）。

### 3.4 對本項目方法論的影響（必須寫進論文）

- 該數據**只用於訓練集，絕不進入驗證集**。它自帶逐圖隨機劃分，
  同一段視頻的相鄰幀會跨 train/val；混進 val 會讓 val 既不代表性、又有泄漏，
  從而使所有驗證指標失去意義。
- 因此本項目報告的驗證指標**全部來自香港實拍數據**，不含該數據集。
- 該數據域為通用場景（實測：灰度圖 1.7%、框長寬比中位 0.281 即全身標註、
  框中心縱向 0.453），與香港行人視角**不完全一致**，存在域偏移。

---

## 4. Wikimedia Commons（`data/raw/external/`）

901 張，16 個類別，逐張署名與許可記錄在
`data/raw/external/attribution.jsonl`（字段：`title` `artist` `license` `license_url`
`class_or_target` `tier` `local_file`）。

許可分佈：CC BY-SA 4.0（499）· CC BY-SA 3.0（132）· CC0（76）· CC BY 2.0（45）·
CC BY-SA 2.0（37）· Public domain（36）· CC BY 3.0（26）· CC BY 4.0（22）· 其它（8）。

**狀態：尚未用於訓練。** 它們是整圖單物件照片、**沒有框**，
需先走老師預標鏈出框。

**注意**：`attribution.jsonl` 被 .gitignore 顯式放行（見 `.gitignore` 第 36 行），
因為它是 CC BY/SA 許可要求保留的署名，且體積小、不可再生。

---

## 5. 訓練用模型的預訓練權重

| 權重 | 來源 | 許可 |
|---|---|---|
| `yolo11n.pt` | Ultralytics YOLO11，COCO 預訓練 | AGPL-3.0（Ultralytics） |
| `yolov8s-world.pt` | Ultralytics YOLO-World | AGPL-3.0 |
| `sam2.1_t.pt` | Meta SAM 2.1 | Apache-2.0 |
| `IDEA-Research/grounding-dino-tiny` | IDEA-Research Grounding DINO | Apache-2.0 |
| `nvidia/LocateAnything-3B` | NVIDIA | **NVIDIA License §3.3：僅限非商用**（見下） |

> ⚠️ **Ultralytics 是 AGPL-3.0。** 畢設若以源碼形式發佈到此倉庫，
> 需注意 AGPL 的傳染性；若只發布論文與演示，通常不構成分發。
> 這一點建議在論文的"工具與許可"一節寫明。

> ⚠️⚠️ **`nvidia/LocateAnything-3B` 是非商用許可，比 AGPL 更硬的限制。**
> 原文（倉庫內 `LICENSE` §3.3，已下載核對）：
>
> > 3.3 Use Limitation. The Work and any derivative works thereof only may be used or
> > intended for use **non-commercially**. … "non-commercially" means for
> > **research or evaluation purposes only**.
>
> 對本項目的含義：
> 1. 用在 FYP（研究）裏**可以**；作為演示、寫進論文**可以**。
> 2. 它**只能當標註階段的老師**，絕不能隨 App 下發 —— 這一點本來就已經滿足
>    （端上跑的是我們自己的 TFLite，`docs/MODELS.md` §3 明確"不下發"）。
> 3. **灰色地帶**：用它產出的標籤去訓練自己的模型，訓練出來的模型算不算
>    "derivative work"？許可沒有明確説到這裏。**不要聲稱已經釐清**；
>    若將來要商用化，最乾淨的做法是換一個許可寬鬆的 VLM 當老師。
>    這條已記在 `docs/PROJECT-STATUS.md` §6 的選項 B。

