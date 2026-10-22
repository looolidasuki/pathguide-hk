# 上游分支 `actiondarr/pathguide` 比對與合併評估

**評估日期：** 2026-10-23
**評估對象：** <https://github.com/actiondarr/pathguide>（下稱「上游」）
**本地檢出位置：** `.tmp/upstream-pathguide/`（`.tmp/` 已在 `.gitignore`，不入庫）
**本倉庫：** `looolidasuki/pathguide-hk`，`HEAD = 22d53d1`（2026-10-10）

> **這份文檔回答四件事：**
> 1. 上游和我們**差在哪裡**（逐項、帶數字）；
> 2. **能不能合併**（結論：不能直接 merge，只能選擇性移植）；
> 3. 上游 UI 裡**有沒有用得到的東西**（結論：「我的路線」「錄製新路線」是**零實現的佔位**）；
> 4. **UI 怎麼簡化**（結論：保持我們現在的兩模式首頁，不要引入三頁式）。

本文的每個數字都註明來源。「本機實測」指本次評估在同一台機器上跑出來的；
「上游自述」指上游文檔裡寫的，**本次未獨立驗證**。

---

## 0. 一句話

上游是我們的**下游分叉**（從我們 `classes.json` v4 分出來的），
它做了兩件有價值的事（**香港九類模型**、**類別表 v5/v6**）和三件我們不該跟的事
（**三頁式導航首頁**、**硬編碼繁體香港 locale**、**把開發面板搬回產品畫面**）。
**可以直接拿的只有「純追加的類別表」與幾份文檔／測試；模型換版是一個獨立決定，不是合併動作。**

---

## 1. 上游是什麼

| 項 | 上游 | 我們 | 來源 |
|---|---|---|---|
| 提交數 | **3**（全部 2026-10-20，訊息為 `Initial PathGuide app source` / `Initial commit` / `Merge GitHub repository setup with PathGuide source`） | 100+ | `git log` |
| 歷史 | **被壓平**（squash），看不出真實開發過程 | 完整 | 同上 |
| 追蹤檔案數 | **106** | **397** | `git ls-files \| wc -l` |
| 頂層目錄 | `app` 98 · `docs` 3 · `configs` 2 · `scripts` 1 | `app` 124 · `data` 107 · `scripts` 74 · `tests` 32 · `docs` 31 · `configs` 4 | 同上 |
| Python 流水線 | **沒有**（`scripts/` 只剩 `gen_dart_labels.py`） | 74 個腳本 + 32 個 pytest 檔 | 同上 |
| 數據集 | **沒有**（`data/` 不存在） | 107 個追蹤檔（含標註） | 同上 |

**結論：上游是一個「只帶 App 的交付包」，不是一個可繼續開發的倉庫。**
它把訓練／評測／數據那一側整套丟掉了 —— 所以在我們的倉庫裡，
**上游的一切都必須當成「外來的 App 片段」看待，不能當成上游主線。**

### 1.1 血緣：它確實是從我們分出來的

上游 `configs/classes.json` 的 `history` 陣列裡，v1–v4 四條記錄
**與我們的逐字相同**（含「删除伞类 street_obstacle(7)」「48 項清單對齊」
「Roboflow everyday-object-finder」「凍結索引」這些只可能來自我們倉庫的敘述）。
上游在此之上追加了兩條：

| 版本 | 日期 | 變更 |
|---|---|---|
| v5 | 2026-10-19 | 追加 `downstairs(50)`、`upstairs(51)`，對應香港九類資料集 |
| v6 | 2026-10-19 | 中文名「扶梯」統一改「扶手電梯」（**類別 ID、英文名、模型映射不變**） |

**推論：上游分叉點在我們的 v4（2026-10-02）之後、`bbb1540`（OCR／採集，2026-10-09）之前。**
證據：上游完全沒有 `text/`、`capture/`、`diag/`、`auth/`、`l10n/` 這五個模組。

---

## 2. 差異清單（雙向）

### 2.1 上游有、我們沒有的

| 項 | 內容 | 值不值得拿 |
|---|---|---|
| **香港九類模型** | `2026-10-19.hk9.1`，10,694,183 bytes，`sha256 8bbfa43b…e3c9`，輸入 **640**，9 類 | ⚠️ **要單獨決策**（見 §4） |
| **類別表 v5 / v6** | 追加 `downstairs(50)`／`upstairs(51)`；「扶梯」→「扶手電梯」 | ✅ **已採用（2026-10-23）**：純追加，不動既有 id；`gen_dart_labels.py` 已重生成 52 類 |
| `test/ios_demo_test.dart`、`platform_mapping_test.dart`、`flutter_tts_speaker_test.dart` | 三個測試檔 | ⚠️ **兩個已移植、一個未移植**（見 §3.2）。`platform_mapping_test.dart` 移植後**當場抓到一個真缺陷**（`isReady` 在模型與清單不符時仍報 true） |
| `docs/IOS-DEMO.md` | iPhone 安裝／簽署／驗收清單 | ✅ **已移植並改寫（2026-10-23）**：上游那版的驗收清單描述三 tab 殼與門檻滑桿，已按本倉庫的兩模式 UI 重寫 |
| `settings/app_settings.dart` + `shared_preferences` | 播報速度持久化（3 檔） | ✅ 小而獨立，但要評估是否值得多開一頁 |
| `ui/app_theme.dart` | 主題 token | ⬜ 中性，我們用 `ColorScheme.fromSeed` 已夠 |
| `ui/app_shell.dart`（918 行） | 底部三 tab：探索／導航／設定 + 導航首頁三張卡 + 設定頁 11 列（其中 6 列「未來功能」） | ❌ **不要**（見 §5） |

### 2.2 我們有、上游沒有的（**合併時會被刪掉的東西**）

| 模組 | 內容 | 我們的測試 |
|---|---|---|
| `auth/` + `ui/auth_page.dart` | 盲用優先登入 stub（`docs/A11Y-ENTRY-AND-AUTH.md`） | `auth_*_test.dart`、`auth_page_test.dart` |
| `l10n/` | 跟隨系統語言（en / zh / yue），`AppLocale.resolve()` | `app_locale_test.dart` |
| `text/` + `ui/read_text_page.dart` | ML Kit／原生識字（讀招牌、菜單） | `text_spotter_test.dart`、`text_read_result_test.dart` |
| `capture/` | 幀採集與上傳 sink | `frame_sampler_test.dart` |
| `diag/status_log.dart` | 可拉出的狀態檔（取代畫面上的診斷面板） | `status_log_test.dart` |
| `vision/vision_session.dart` + `ui/home_page.dart` | 兩模式首頁與跨模式共用相機 | `home_page_test.dart`、`product_ui_test.dart` |
| Android 快速設定磚 + 多語 `strings.xml` | `PathGuideTileService.kt`（80 行）、4 個語系字串檔 | — |
| `VisionPlugin.kt` | **1,931 行**（上游 **1,441 行**，少 490 行） | Kotlin 編譯檢查 |

### 2.3 兩邊都改了的（真正的衝突區）

`git diff --no-index app/lib .tmp/upstream-pathguide/app/lib` → **32 檔、+3,062 / −4,951 行**。

| 檔案 | 我們 | 上游 | 性質 |
|---|---:|---:|---|
| `ui/demo_page.dart` | 30,141 B | **58,255 B**（約 2,000 行差異） | **重寫**，且方向相反（見下） |
| `tts/announcer.dart` | 15,327 B | 8,911 B | 上游是舊版 |
| `vision/platform_vision.dart` | 20,996 B | 17,859 B | 我們多了 OCR／幀上報 |
| `vision/labels.dart` | 9,110 B | 9,459 B | 上游多 52 類中文名 |

**關鍵：`demo_page.dart` 的差異方向與我們的目的相反。**
我們在 `0d1a31c`（2026-10-09）刻意**移除**了門檻滑桿、FPS、推理耗時、
120 行診斷面板，理由寫在 `demo_page.dart` 的類註解裡（「門檻滑桿對全盲使用者沒有意義」）。
上游的 58 KB 版本**把這些全部保留**，並新增兩個滑桿（辨識信心門檻、語音播報門檻）。
**照搬等於把我們花一整天拆掉的東西裝回去。**

---

## 3. 能不能合併：**不能直接 merge**

### 3.1 為什麼

1. **沒有共同歷史。** 上游歷史被壓平，`git merge actiondarr/main` 會得到
   *refusing to merge unrelated histories*；即使加 `--allow-unrelated-histories`，
   git 也只能把「兩份樹」整個對撞。
2. **對撞的結果是雙向刪除。** 依 §2.2／§2.3，任何一次「全部取上游」會刪掉
   我們的 auth／l10n／OCR／採集／狀態檔與 1,931 行的 `VisionPlugin.kt`；
   「全部取我們」則會丟掉九類模型與類別表 v5/v6。**沒有自動解法。**
3. **兩邊產品方向不同。** 上游是「iPhone 演示包」：硬編碼 `zh-Hant-HK`、
   三 tab 殼、開發面板留在畫面上。我們是「跟隨系統語言、兩模式、無開發面板」。
   這不是同一個東西的兩個版本，是**兩個產品**。

### 3.2 能合併的只有「選擇性移植」

| 移植項 | 衝突風險 | 工作量 | 狀態 |
|---|---|---|---|
| `configs/classes.json` → v6 | **無**（純追加 50/51 + 改名） | 小：改表 + 跑 `gen_dart_labels.py` 重生成 `labels.dart`/`classes.txt` | ✅ **已完成**（52 類） |
| `docs/IOS-DEMO.md` | 無 | 小：搬入 + **按本倉庫 UI 重寫驗收清單** | ✅ **已完成**（`docs/IOS-DEMO.md`） |
| 三個測試檔 | 低（測平台契約，與我們的 UI 解耦） | 中：要對齊我們的 `platform_contract.dart`（我們 9,846 B，上游 6,939 B） | ✅ 兩個移植、一個不適用（見下） |
| `AppSettings` + `shared_preferences` | 低 | 中：要接進我們的 `VisionSession`／`Speaker` 而不是上游的 `DemoPage` | ❌ 不採用（§5.3） |
| **九類模型 640f32** | **高** | 大：原生 NCHW 分支 + 重測延遲 + 可重跑 val + 一致性門禁 | ⏳ **未做**（§4.4） |

**測試檔逐個說明：**

- `platform_mapping_test.dart` → **已移植**為 `app/test/platform_mapping_test.dart`（4 條）。
  改成從 `assets/models/detector.json` 讀期望映射（上游把九類的映射寫死在測試裡，
  換模型就得改測試才變綠——那正是它該防的事）。移植後**當場抓到一個真缺陷**：
  `initialize()` 在「模型與清單不符」時返回 `ok:false`，但 `isReady` 仍是 `true`。
- `flutter_tts_speaker_test.dart` → **已移植**為同名檔（7 條），三處按本倉庫契約改寫
  （語速固定 0.45、候選語言跟隨系統 locale、粵語缺失時退回英文並照樣發聲）。
- `ios_demo_test.dart` → **未移植**。它 `import` 上游的 `ui/app_shell.dart` 與
  `settings/app_settings.dart`（我們決定不採用，見 §5、§6），且 8 條測試裡有 5 條
  測的是三 tab 導航、設定頁語速選擇器、技術資料面板——都是本倉庫不存在的介面。
  剩下 3 條的**意圖**在本倉庫已有等價測試：語音開關即停 ↔
  `product_ui_test.dart`「關閉語音會立刻停掉正在說的那句」；Android 相機啟動路徑 ↔
  `vision_source_contract_test.dart` + `platform_mapping_test.dart`；慢速 stop 不阻塞啟動 ↔
  `announcer_test.dart`。**照抄會得到一份編不過的檔案，那不是移植。**

---

## 4. 端上模型：18 類 vs 九類（這是唯一真正的岔路口）

| 項 | 我們（`2026-10-02.stage2`） | 上游（`2026-10-19.hk9.1`） |
|---|---|---|
| 類別數 | **18** | **9** |
| 輸入 | 416 | **640** |
| 精度格式 | int8 | **float32** |
| 檔案 | 2,873,120 B（2.74 MiB） | **10,694,183 B**（10.2 MiB，**3.7×**） |
| 映射 | `[6,11,7,18,49,48,10,26,47,45,46,12,30,36,33,31,27,44]` | `[11,7,8,50,49,6,9,51,24]` |
| 類別內容 | pedestrian · bicycle · bin · …（含 obstacle/escalator 等泛化類） | bicycle · bin · **bollard** · **downstairs** · escalator · person · **traffic_cone** · **upstairs** · **wet_floor_sign** |
| 精度 | mAP50 **0.918**（清單記） | 源 PyTorch：test 620 圖／964 實例，**mAP50 0.839956、mAP50-95 0.568379** |
| 真機延遲 | **268 ms**（416 int8，Snapdragon 685，**實測**） | **未測** |

### 4.1 張量層實測（2026-10-23，`scripts/check_tflite_decode.py` + TF 2.19）

這一節是「換模型不只是換一個檔案」的**硬證據**，不是推論：

| | 我們現行端上模型 | 上游九類模型 |
|---|---|---|
| 輸入張量 | **`[1, 416, 416, 3]`（NHWC）** | **`[1, 3, 640, 640]`（NCHW）** |
| 輸出張量 | `[1, 22, 3549]` 通道優先（4+18 類） | `[1, 13, 8400]` 通道優先（4+9 類） |
| dtype | float32 | float32 |
| 檔案 | 2,873,120 B | 10,694,183 B（**3.7×**） |

**我們的原生側明確假設 NHWC**：

```kotlin
// VisionPlugin.kt（YoloDetector.init）
require(inShape.size == 4) { ... }
require(inShape[3] == 3) { "输入通道应为 3，实际 ${inShape[3]}" }   // ← NHWC
```

上游模型的 `inShape[3]` 是 **640**，所以把檔案換過去會**當場被 `require` 拒絕**。
好消息：這是**響亮的失敗**（`loaded=false` + 明確錯誤），不是「安靜地每幀標錯類」；
壞消息：要真的採用，必須先在 Kotlin 加 **NCHW 輸入分支**——
上游 `docs/MODELS.md` 也自述「iOS/Android 输入现支持 NHWC 与 NCHW」，
即他們同樣為此改過原生。

### 4.2 上游九類模型的問題（必須先講清楚）

- **轉換後沒有重測 mAP。** 上游自述：`0.839956` 是**源 PyTorch**的 test 結果；
  TFLite 轉換只驗了「灰圖／隨機 RGB 的原始輸出誤差 ≤ 1.74e-5」，
  **沒有重跑完整 test mAP**。所以端上那份 10.2 MB 的模型，
  **沒有任何一個屬於它自己的精度數字**。
- **P/R 不可直接引用。** `P=0.871664`、`R=0.790385` 是 Ultralytics 的 max-F1 點，
  不是我們的播報門檻 0.70 —— 與本項目 §7「比較模型指標必須寫明置信度閾值」那條決策直接相關。
- **延遲未測，而且可以預估會退。** 我們自己在 2026-09 於**同一機型**實測過
  整條路徑：`640f32 776 ms → 416f32 324 ms → 416int8 268 ms`。
  若沿用這個換算，九類 640f32 約落在 **776 ms／幀 ≈ 1.3 FPS**，
  對比現在的 **3.6–3.9 FPS**（3 類 int8 時代的實測）。**這是推估，不是本次實測**，
  但它用的是同一台機器、同一個 SDK、同一個 `litert:2.2.0`，
  所以「換上去會掉幀」的風險是**高的、可預期的**。
  另外輸入像素數本身也漲了 **2.37×**（640²/416²）。
- **不可復現。** 訓練在 Colab（`hk9_yolo11n_640_20261018_161146`，99 輪），
  資料集與權重都不在任何一個倉庫裡。我們這邊**沒有 val 可以重跑**。

### 4.3 上游九類模型的真實優點

它補上了**對視障使用者最關鍵的四類**：`upstairs`／`downstairs`（樓梯）、
`bollard`（柱）、`traffic_cone`（雪糕筒）、`wet_floor_sign`（小心地滑牌）。
這四類的**安全語義權重**遠高於我們 18 類裡多數的類 ——
「前面有樓梯」和「前面有垃圾桶」不是同一個量級的信息。
我們現有 18 類是靠 `obstacle(48)` 泛化兜底去近似樓梯，**語義上是弱一檔的**。

> 註：樓梯的**方向**類（50 `downstairs` / 51 `upstairs`）已隨類別表 v6 進入本倉庫，
> 但**端上模型還沒有這兩類**，要等換版才會出框。標註契約先立好、數據後補，
> 這是本項目「索引凍結、只增不減」的原則使然。

### 4.4 結論與換版前置（三件事，缺一不可）

**不在這次合併裡換模型。** 要換，依序付清這三筆：

1. **原生加 NCHW 輸入分支**（§4.1）。不改的話換過去只會得到「模型加載失敗」。
2. **真機測 640f32 延遲**。現在的 776 ms 是 3 類時代的實測外推，
   而且九類模型的層結構不同——必須實測，不能沿用。
3. **拿到可重跑的 val**。沒有 val 就沒有屬於這份模型的精度，
   只能引用「源 PyTorch」數字，而那不是端上模型。

順序建議：① 可重跑 val → ② 真機測延遲 → ③ 若延遲可接受，再談換版，
並同時說明「18 類換成 9 類」丟掉了什麼。

在此之前，**類別表先升到 v6（純追加 + 改名，零風險），模型不動**。
（本輪已執行完畢：`configs/classes.json` v6、`gen_dart_labels.py` 重生成 52 類。）

---

## 5. UI 功能評估：**「我的路線」「錄製新路線」是零實現**

### 5.1 證據

上游 `app/lib/ui/app_shell.dart` 的三張卡（`搜尋目的地`／`我的路線`／`錄製新路線`）
全部走**同一個** `_showComingSoon()`（第 68–124 行）：

```dart
title: '我的路線',
description: '未來可儲存常用路線，快速開始語音導航。',   // ← 未來式
// 彈出一個 bottom sheet，內含 _DevelopmentBadge()（文字就是「開發中」）
```

- **零資料模型**：整個上游 `app/lib` 的 `geolocator`／`location`／`polyline`／
  `sqflite`／`path_provider` 命中數 = **0**。
  唯一命中的三行全部是 UI 字串：「錄製 GPS 軌跡並加入路標」「未來可記錄 GPS 軌跡」
  「目前沒有接入地圖、GPS 或路線服務」。
- **零依賴**：上游 `pubspec.yaml` 的新增依賴只有 `shared_preferences`（給播報速度用）。
- **零儲存**：沒有路線資料結構、沒有序列化、沒有檔案。

### 5.2 值不值得拿：**不值得，而且對目標使用者是負值**

1. **對全盲使用者，佔位入口比沒有入口更糟。** 每一次焦點移動都有成本；
   滑到「我的路線」→ 雙擊 → 彈出「未來可……」→ 關掉 → 重新找位置。
   **我們在 `docs/A11Y-*.md` 的驗收原則裡寫的是「按了之後沒反應」最嚴重，
   而「按了之後告訴你還沒有」是它的變體。**
2. **它掩蓋真實進度。** 上游 `IOS-DEMO.md` 的驗收清單第 1 條就是
   「首次啟動顯示導航首頁，三張未來功能卡均標示為『開發中』」——
   這等於把「我們還沒做導航」做成首頁的第一印象。
3. **它不屬於 UI 工作。** 錄製路線 = GPS 取樣 + 座標壓縮 + 路標資料模型 +
   重放引擎 + 與偵測的時序仲裁。對應本項目 §5 難點 **#3「導航決策與視覺融合」**
   （目前完全沒有）。**先做導航決策，再談路線錄製的 UI。**

### 5.3 上游 UI 裡唯一值得考慮的：播報速度

`AppSettings.speechSpeed` + `shared_preferences` 是上游唯一**有真實行為**的設定：
它會改變 `flutter_tts` 的語速並在重啟後保留。
**但我們不建議現在加**（理由見 §6.3）：單獨為它開一頁設定，
會讓「首頁 2 顆按鈕」變成「首頁 2 顆 + 一個設定入口」，
而 TalkBack／VoiceOver 本身就有語速控制，且**我們的系統語言切換已經解決了
更重要的那個變量**。

---

## 6. UI 簡化：現狀與建議

### 6.1 我們現在有幾個可操作控件（實測自原始碼）

| 畫面 | 控件 | 數 |
|---|---|---|
| `home_page.dart` | 引導 · 讀字 | 2 |
| `demo_page.dart`（引導） | 開始引導 · 關閉語音 · 停止 | 3 |
| `read_text_page.dart`（讀字） | 再讀一次 · 返回 | 2 |
| **合計** | | **7** |

> 引導畫面原本有 **4** 個控件（多一顆「採集」），於 **2026-10-23 移除**，
> 見 §6.2 第 2 項。**7** 是移除後的實測值。

對照上游：**底部 3 tab + 導航首頁 3 卡 + 設定頁 11 列（其中 6 列標「開發中」）
+ 探索頁 2 個門檻滑桿、來源切換、播報／標籤開關與設定按鈕**。
**我們的 8 個控件已經是上游的一半以下。**

**所以在「簡化 UI」這件事上，最該做的第一件事是「不要合併上游的 UI」。**

### 6.2 建議的簡化（按收益排序）

| # | 動作 | 收益 | 風險 |
|---|---|---|---|
| 1 | **不引入三 tab 殼**（探索／導航／設定） | 少 2 次 tab 切換 + 少 3 個死路卡 + 少 6 列「開發中」 | 無 |
| 2 | **把「採集」從引導畫面移出** | ✅ **2026-10-23 已執行（整顆移除）**。引導畫面 4 → **3** 個控件；它是**研究用的資料留存**開關，卻與「結束引導」並排，是該畫面上最容易誤觸的一顆 | 已處理：`FrameSampler`／`captureFrame` 留在程式庫，UI 入口移除；`flutter test` 224 全過、`flutter analyze` 0 問題 |
| 3 | **不加設定頁** | 少一層跳轉；語速交給系統 TTS 設定 | 低 |
| 4 | **路線功能在導航決策引擎完成前，UI 不放任何入口** | 不製造「按了才發現沒有」 | 無 |

> 第 2 項是本文唯一建議**改程式碼**的項目，但它改的是既有的刻意決定，
> 所以**先問**再動（見 §7）。

### 6.3 反過來說：不要為了「簡化」把已有的東西砍掉

`read_text_page.dart` 的兩顆按鈕（再讀一次／返回）與 `demo_page.dart` 的
「關閉語音」都不是冗餘：前者解決「讀不到時分不清是沒字還是壞了」，
後者解決「按了關閉卻還在說話」。**簡化的對象是「使用者不需要的選擇」，
不是「使用者需要的出口」。**

---

## 7. 待決事項

| # | 問題 | 選項 | 結論 |
|---|---|---|---|
| 1 | 類別表要不要升到 v6（追加 50/51 + 扶手電梯改名）？ | 升／不升 | ✅ **2026-10-23 已升**：`configs/classes.json` v6、`class_aliases.json` 同步、`gen_dart_labels.py` 重生成 52 類；`pytest` 436 全過 |
| 2 | 端上模型換不換九類 640f32？ | 換／不換／先測再定 | **先測再定**（§4.4）。硬前提：原生 NCHW 分支 + 真機測延遲 + 可重跑 val |
| 3 | 「採集」按鈕留在引導畫面還是移出？ | 留／移出／改成隱藏入口 | ✅ **2026-10-23 已決：整顆移除**（§6.2 第 2 項） |
| 4 | 要不要拿 `shared_preferences` 的播報速度設定？ | 拿／不拿 | **不拿**（§5.3） |
| 5 | `docs/IOS-DEMO.md` 與三個測試檔要不要移植？ | 要／不要 | ✅ **2026-10-23 已移植**：`docs/IOS-DEMO.md`（改寫）+ `platform_mapping_test.dart`（4 條）+ `flutter_tts_speaker_test.dart`（7 條）。`ios_demo_test.dart` **未移植**，理由見 §3.2 |

---

## 8. 附：本次評估的可複現命令

```powershell
# 取得上游（.tmp/ 已 gitignore，不入庫）
git clone https://github.com/actiondarr/pathguide .tmp/upstream-pathguide

# 血緣證據（比對 classes.json 的 history）
git diff --no-index .tmp/upstream-pathguide/configs/classes.json configs/classes.json

# 規模／差異
git -C .tmp/upstream-pathguide ls-files | Measure-Object -Line      # 106
git ls-files | Measure-Object -Line                                  # 397
git diff --no-index --stat app/lib .tmp/upstream-pathguide/app/lib   # 32 檔 +3062/−4951

# 「我的路線」是否真的沒有實現
Select-String -Path .tmp/upstream-pathguide/app/lib/**/*.dart `
  -Pattern 'geolocator|polyline|sqflite|path_provider'                # 0 命中

# 張量層：輸入是 NHWC 還是 NCHW（換模型前必看，見 §4.1）
.\.venv-export\Scripts\python.exe scripts\check_tflite_decode.py
.\.venv-export\Scripts\python.exe scripts\check_tflite_decode.py `
  --tflite .tmp\upstream-pathguide\app\assets\models\detector.tflite
#   -> 現行： input=[1,416,416,3] NHWC, output=[1,22,3549], classes=18
#   -> 上游： input=[1,3,640,640] NCHW, output=[1,13,8400], classes=9
#   -> 我們 VisionPlugin.kt 有 require(inShape[3] == 3)，NCHW 會被當場拒絕

# 我們自己的門禁（2026-10-23 實測）
.\.venv\Scripts\python.exe -m pytest -q                              # 436 passed
. .\.env.flutter.ps1; cd app; flutter analyze                        # No issues found!
flutter test                                                         # 235 passed
```
