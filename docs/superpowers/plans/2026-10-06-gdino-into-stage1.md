# 把 GDINO 接進 stage1（雙老師）+ VLM 段被網絡卡住

日期：2026-10-06
相關：`docs/PROJECT-STATUS.md` §6 步驟 ①、`docs/MODELS.md` §3

## 目標

`stage1_propose.py` 原來只支持 YOLO-World，而它對 9 個核心類（`stairs` 等）
零召回 ——「老師預標」這一環對結構性障礙物等於沒有。接上 GDINO 後
「老師預標 → SAM 精修 → VLM 驗證」三段式原型才成立。

## 做法

新增 `--teacher {yoloworld,gdino}`（**默認仍是 yoloworld**），兩個老師只負責
「出原始框」，**合併與寫出只有一條代碼路徑**：

```
detect(paths) -> [(raw_detections, w, h) | None]     ← 老師實現這一層
         ↓
類內 NMS 合併 → proposals.jsonl / proposals_stats.json / labels/    ← 唯一的一份
```

這麼切是為了讓兩條路**結構上不可能產出不同格式**。此前 `gd_detect.py` 裏
有一份獨立的 GDINO 實現，於是出現了第一處漂移（見下"踩到的坑"1）。

新模塊 `scripts/pipeline/gdino_teacher.py` 是唯一的 GDINO 實現，
`gd_detect.py` 與 `stage1_propose.py` 都 import 它。

兩處結構性差異（都是實測逼出來的，不是設計偏好）：

| | YOLO-World | GDINO |
|---|---|---|
| 推理次數 | 1 次出全部 prompt | **每類 1 次**（多 prompt 會產出 `##cala stairs` 破損標籤） |
| 閾值 | 全局 `--conf` | **逐類 `gdin_threshold`**（各類分值分佈差異極大） |
| 座標 | `orig_shape` | PIL 的真實 W/H |
| `n_prompts` 字段 | 命中的別名説法數 | **恆為 1**（每類只有一條提問詞） |

## 踩到的坑

### 1. 按 `label != query` 判異常 → 靜默丟掉 11% 的框

最初在 GDINO 分支裏這麼寫：返回標籤與提問詞不一致就 `continue`（丟框）。
2 張圖實測丟掉 17/153 個框。逐條查下來，**絕大多數不是破損**：

| query | 返回 label | 真相 |
|---|---|---|
| `water-filled barrier` | `water - filled barrier` | 連字符被插空格，同一句話 |
| `roll up banner` | `banner` | 匹配到的**子串** |
| `tree roots on the pavement` | `pavement` / `tree roots` | 匹配到的**子串** |

GDINO 的 `post_process_grounded_object_detection` 返回的是**提問句裏被匹配到的
那段 span**，不是整句 —— 這是它的正常行為。所以「不等於整句」在多詞提問詞上
**必然發生**，而多詞提問詞正是描述型障礙物類（`goods placed on the street`）
唯一能用的措辭。按 `!=` 判異常 = 專門冤枉這些類。

**證據**：修掉之後同一批圖 raw 框 136 → **153**，零框類從 7 個降到 **3** 個，
恢復的正是 `barrier_water` / `roll_up_banner_stand` / `tree_root_on_the_road` /
`broken_tree` —— 全是多詞提問詞的類。**丟掉的那部分有系統性偏向。**

改為四分類 `gdino_teacher.classify_label()`：
`ok` / `subspan`（正常） / `artifact`（含 `##`，真破損） / `mismatch`（可疑，需人看），
並且**框一律保留** —— 因為類別 id 來自**我們自己發出去的 query**，不是返回的 label，
label 再破也不會錯配到別的類（`gd_detect.py` 原本就是這麼做的，是我寫新分支時退化了）。

第一版四分類裏還寫錯了順序：先判相等、後判 `##`，而 `_normalize_label` 會把 `#`
當標點刪掉，於是 `##stairs` 歸一化後正好等於 `stairs` → 判成 `ok`。
**被新加的測試當場抓出來**（`tests/test_gdino_teacher.py::test_artifact_wins_over_subspan`）。

### 2. 順帶更正一條被引用的數字

`configs/class_aliases.json` 的 `gdin_prompt_note` 記着「單 prompt 後異常降至 12/792」。
那句當時用的就是上面那個過嚴的判定，所以 **12/792 是真破損的上界，不是破損數**。
多 prompt 會產出 `##cala stairs`（含 `##`，無法用子串解釋）是確實的，**結論不變**；
但別再把 12/792 當成破損計數引用。更正在 `gdino_teacher.py` 的模塊説明裏。

### 3. stage2 加載失敗，而我把它誤診成「網絡不通」（記錄這次誤診）

第一次跑 stage2 時它報：

```
OSError: nvidia/LocateAnything-3B does not appear to have files named
('model-00001-of-00002.safetensors', 'model-00002-of-00002.safetensors')
```

我當時的判斷是「緩存沒下完 → 網絡不通 → 要換鏡像」，並據此做了一串診斷：
`hf_xet` 安裝、`hf-mirror` 端點、多個主機可達性探測，還起了兩次後台下載。

**實際原因是我自己造成的**：為了讓 GDINO 離線加載，我在 shell 裏設了
`HF_HOME=<repo>/.hf`，而 `HF_HOME` 會**改道 `HF_HUB_CACHE`** ——
於是 stage2 去找工作區裏那份緩存，而 LocateAnything 的權重在**系統緩存**裏。

真相（已驗證）：

| 事實 | 證據 |
|---|---|
| 權重**完整**在系統緩存 | `~/.cache/huggingface/hub/models--nvidia--LocateAnything-3B/snapshots/<hash>/` 下兩個分片 **4959.6 MB + 2701.8 MB**（= 7.66 GB，與 Hub 元數據一致） |
| 默認解析能找到 | `snapshot_download('nvidia/LocateAnything-3B', local_files_only=True)` → 命中並列出兩個分片 |
| 環境裏本來沒有 HF 覆蓋 | `Get-ChildItem env: HF_*` 為空（只有 `APPDATA`） |

而且 `scripts/env_setup.py` 的 docstring 第 4 條**早就寫了這件事**：

> `nvidia/LocateAnything-3B`（7.3 GB）只在 `~/.cache/huggingface/hub`
> `IDEA-Research/grounding-dino-tiny`（~700 MB）只在工作區內 `.hf/hub`
> 兩處都**不可兼得** … **不要全局覆蓋 HF_HUB_CACHE。**
> 實測曾因此靜默重下 5.6 GB 並卡住 20 分鐘以上。

**我踩了項目自己寫下來的坑，還沒先讀它。** 教訓不是"網絡差"，而是：
**在一個已經記錄過環境變量陷阱的倉庫裏，改環境變量之前先讀那份記錄。**

順帶把自己造出來的殘骸清掉了：`.hf/hub/models--nvidia--LocateAnything-3B`
（221 MB 的 `.incomplete` 垃圾）—— 留着它正是下一次誤診的種子。

#### 修法：讓調用者不必再動環境變量

`gdino_teacher.local_snapshot()` 現在自己去找**工作區內**已下好的快照
（判據是快照目錄下有 `config.json`，不是隻看目錄在不在），找到就離線加載；
找不到才回落到 Hub 在線。於是：

- `stage1 --teacher gdino` **不再需要** `HF_HOME` 覆蓋 → 不會誤傷 stage2 的緩存；
- 已加測試釘死，含 `test_local_snapshot_ignores_empty_snapshot`
  （只有目錄、沒有 `config.json` 的空快照**不算**已下好 —— 那正是這次坑的樣子）
  與 `test_default_hub_root_is_the_in_workspace_one`。

> 注：`cdn-lfs.huggingface.co` 確實 **DNS 解析失敗**，Xet 通道也確實傳到 128 MB 就停滯 ——
> 這兩條觀測是真的，只是**與本次故障無關**。記在這裏以免以後又被當成結論。

### 4. 真正的攔路石：`trust_remote_code=True` 要寫工作區外的目錄

把上面的環境變量問題修掉之後，stage2 換了另一個錯：

```
PermissionError: [Errno 13] Permission denied:
  C:\Users\user\.cache\huggingface\modules\transformers_modules\
  nvidia\LocateAnything_hyphen_3B\<hash>\processing_locateanything.py
```

LocateAnything-3B 用 `trust_remote_code=True`，transformers 會把遠端自定義 `.py`
落盤到 `~/.cache/huggingface/modules/`。**工作區外不可寫**（受限文件策略），
於是加載在拷貝代碼那一步就失敗 —— 表現仍然是「模型加載不了」，
但和權重、和網絡都沒有關係。

修法：在 `env_setup.apply()` 裏設 `HF_MODULES_CACHE` 指向工作區 `.hf/modules`，
並在 `stage2_verify.py` 裏於 **import transformers 之前** apply
（該值是 transformers 的**模塊級常量**，晚了無效）。

★ 關鍵細節：**只設 `HF_MODULES_CACHE`，不設 `HF_HOME`/`HF_HUB_CACHE`。**
後者會連帶把模型緩存改道（= 上面第 3 條那個坑）。這兩個變量必須分開處理。

> 加載時還會刷一排 `Could not cache non-existence of file … Permission denied:
> …/.no_exist/…`。這是 transformers 想在工作區外寫「此文件不存在」的**標記**失敗，
> 它自己明確説 "Will ignore error and continue"，**無害**。記下來免得以後有人去追。

## 驗證到什麼程度

✅ 已完成並驗證：

- `--help`、兩個老師的參數與分派；`.venv` 與 `.venv-vlm` 各自語法編譯通過
- YOLO-World 路徑迴歸：嵌套子目錄輸入 4 張，標籤與圖像**逐級鏡像**對應
  （`images/sub_a/x.jpg` ↔ `labels/sub_a/x.txt`）
- GDINO 端到端出 `proposals.jsonl`：40 張 HK 天橋幀，**3414 框 → 合併後 3086 框**，
  **49/50 類非零**（只有 `scooter` 零檢出，與既有記錄一致），
  `label_kind = {ok: 3077, subspan: 337}` —— **0 個 `##` 破損、0 個可疑**
- 字段級契約檢查：逐框按 stage2 源碼裏的那幾處 deref 試一遍
  （`source` 可打開、`width/height` 為正整數、`class_id` 是 int、
  `bbox` 4 元且歸一化在 [0,1]、`conf` 在 [0,1]）→ 145 框全過
- **`stage2_verify.py` 實測跑通**：LocateAnything-3B 載入 25 s、SAM 0.5 s；
  2 張圖 6 次 VLM 調用，145 框 → 採納 95、VLM 拒絕 2、低置信丟棄 48
- **`stage3_arbitrate.py` 實測跑通**：95 候選 → 採納 21、複核 74、丟棄 0
- **40 張規模整鏈跑通**（第 1→2→3 段，數字見下節）
- `pytest 404 passed`（原 374 + 新增 30）

❌ 未驗證 / 待辦：

- 人工複核草稿的質量 —— **沒有人工核過就沒有真準確率**，這是當前最大的空白
- 因此**仍然不能説自動標註產出可用**：實測 62% 的候選要人工複核（見下節）

## 新發現：62% 的候選框要人工複核（而且成因不是我猜的那個）

40 張 HK 天橋幀跑完整條鏈：

| 環節 | 數字 |
|---|---|
| 第 1 段 | 3414 框 → 合併後 **3086**（77 框/圖），49/50 類非零 |
| 第 2 段 | 採納 2958；VLM **只驗證 320**，其中**拒絕 128（拒絕率 40%）** |
| 第 3 段 | 採納 **921**、需複核 **1820（62%）**、丟棄 34 |

複核 1820 個框很可能比從零畫 921 個更慢 —— **與「讓標註變快」的初衷相反。**

### 我猜錯了成因，實測把它推翻了

我原先的判斷是「通用類 `obstacle`(48) 與具體類撞車導致複核爆炸」。
於是去統計 `review.csv` 裏到底誰在撞誰。**結果否掉了我這個猜測**：

```
撞到的對手 top：fence 140 / barrier_water 120 / cycle_path 110 /
               obstacle 79 / shop_front 77 / tree_root_on_the_road 72 …
複核框中 obstacle 只佔 57（排第 6）
```

主因是**區域型類別**：`fence`、`barrier_water`、`cycle_path`、`footbridge_entrance`
這類「一整片區域」的概念，GDINO 會給出**近乎滿屏的框**，於是彼此 IoU≈1.0 地重疊
（另有 119 個被 stage3 標為「框面積異常大（疑似框滿全圖）」）。
通用類 `obstacle` **不是主因**。

> 教訓：類設計上的直覺（"通用類會撞車"）聽起來很有道理，但**聽起來有道理不等於對**。
> 花兩分鐘統計一下 `review.csv` 就翻案了。別把合理的故事當成結論。

### 第二個問題：「VLM 已驗證」名不副實

`--max-boxes-per-image` 默認 30，而 GDINO 約 77 框/圖。超出的框
**不丟棄、原樣保留、標 `vlm_verified=false`**。複核清單裏
**1755/1820 的 `vlm_verdict` 是空的** —— 也就是説這批"驗證過的"標籤，
96% 其實沒過模型。

已修：stage2 彙總行現在顯式報「未經驗證 N 個（佔採納 X%）」，
比例 >50% 時額外警告；`stage2_stats.json` 增 `unverified_kept` / `unverified_ratio`；
參數幫助裏寫明這個上限會**靜默降低驗證覆蓋率**（和 `--trust-above` 是同一個陷阱）。

### 待決定（這是設計決策，不該我一個人拍）

1. **提高 `--max-boxes-per-image`**（讓 VLM 真的看全）——代價是 VLM 調用量 ×10。
   但 VLM 拒絕率 40% 説明它確實在篩東西，**覆蓋不足等於把這 40% 的過濾能力浪費掉**。
2. **在仲裁前就砍掉「框滿全圖」的框**（stage3 現在只是標出來送複核）。
   GDINO 給出滿屏 `barrier_water` 是**失敗輸出**，不是檢測結果。
3. 更根本的一問：我們有若干**區域型類別**（`cycle_path`、`zebra_crossing`、
   `fork_in_road`、`tactile_paving`、`barrier_water`…）。檢測器給"一整片區域"出框
   本來就彆扭。**要不要把它們從"框檢測"裏拿出來，改成別的表示方式**，
   是類別設計層面的事，得單獨討論。

**注意**：40 張全是 `footbridge` 一類場景，同質。換成別的場景數字可能不同，
別把這組數當成全類別的結論。

## 下一步

1. **先決定上節那三個問題**（驗證覆蓋率 / 滿屏框 / 區域型類別的表示）。
   **在這之前不要擴類**：複核負擔已經 62%，再加類只會更重。
2. **那 30 幀人工核驗集**。現在所有精度數字都是「對老師標註的保真度」——
   沒有人工核過的樣本就拿不到真準確率，而閉環會**持續自我確認**（用老師標、又用老師評）。
   `--stage-images` 讓這一步變成"改框"而不是"畫框"：
   `label.cmd -Images <out>\images`。
3. 補 `scooter`（唯一零檢出的類）—— 三個老師都零檢出，只能靠實拍素材。
