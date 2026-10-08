# 里程碑：模型清單（把類別映射從代碼裏搬進模型）

**日期：** 2026-10-02
**目標：** 讓「模型是用哪些類別 id 訓的」這份信息**跟着模型走**，
而不是寫死在 App 源碼裏；並讓清單與模型不同步時**拒絕啓動**而不是猜。
**結論：** 已完成。清單 `detector.json` 與模型一起打進 APK，
Dart 側嚴格校驗後才建映射，原生側拿到 `classIds` 再解本地索引。
新增 13 條 Dart 測試 + 6 條 Python 測試守住這條不變量。

---

## 1. 為什麼要做：一個不報錯的錯

TFLite 文件裏**沒有**「這個模型是用哪些 class-id 訓的」這個元數據。
`model_class_map.dart` 裏那份映射是一個常量：

```dart
const List<int> modelClassIds = <int>[6, 11, 7]; // pedestrian, bicycle, bin
```

本地開發這樣沒問題：訓練和 App 在同一台機器上，改模型時順手改常量。
但只要模型能從服務器下發，就出現了一個**沉默的失敗**：

> 服務端換了一批類別訓練新模型 → App 還是舊的常量 →
> **每個框的名字都是另一個類** → 不崩潰、不報錯、不拋異常。

這和本項目此前踩過的六處解碼缺陷是同一類問題：**不崩，只是安靜地錯**。
所以處置方式也一樣——不是「小心一點」，而是**把不變量做成機器能檢查的東西**。

---

## 2. 設計：清單是模型的同伴，不是模型的附註

```
app/assets/models/detector.tflite   2,871,365 B
app/assets/models/detector.json       434 B     ← 必須一起走
```

| 字段 | 作用 |
|---|---|
| `format` | 清單格式版本，必須 `== 1`；**不認識就報錯，不忽略未知字段** |
| `version` / `trainedAt` | 版本比對，決定要不要下載 |
| `file` / `bytes` / `sha256` | 完整性：字節數 + 哈希，兩處都對才認 |
| `inputSize` | 輸入邊長 |
| `modelClassCount` / `modelClassIds` | **核心**：本地索引 → 項目 id |
| `map50` | 訓練/驗證指標，供人看 |

**`modelClassIds` 的來源不是手寫**，而是訓練數據集的 `classes.json`
（那份文件的 `original_id` 就是真實 id）。手寫就是又製造一個可以忘記改的地方。

### 空映射表只在一種條件下合法

`modelClassCount == kNumClasses`（48）時，本地索引就是項目 id，不需要映射。
其餘情況給空表 → **直接失敗**。這條規則的用意是：
**寧可起不來，也不要帶着錯誤的映射跑起來。**

---

## 3. 拒絕啓動，而不是降級

`platform_vision.dart` 的啓動順序改成了：

```
讀清單 → 嚴格校驗 → 失敗則 return 狀態(ok:false, message)
      → 成功則先用空映射加載模型，問出真實類別數
      → resolveMapping(declared: 清單裏的 ids)
      → 若不是恆等映射，用 ids 重新加載
```

失敗時界面顯示 **`模型清單有問題`** 或 **`模型與清單不符`**，而不是繼續跑。
兩個錯誤信息刻意寫得讓人能直接去查文件，而不是顯示一個錯誤碼。

**為什麼不用「猜一個」**：猜錯的代價是每一幀的標籤都錯，
而用户是視障人士——他會照着錯誤的名字**做動作**。寧可讓他知道現在不能用。

---

## 4. 刪掉的東西

`model_class_map.dart` 裏的 `const modelClassIds` **已刪除**。
這一點很重要：如果留着它作為「默認值」，清單壞了就會靜默回退到它，
於是這次改動等於沒做。

對應的測試也一併重寫：原來那條「當前聲明表與類別表一致（換模型時必須同步改這裏）」
測的是常量，現在映射的正確性由 `app/test/model_manifest_test.dart` 直接對
**內置清單文件**校驗（讀盤、比對內置模型的字節數）。

---

## 5. 順帶發現的一個真問題

`scripts/export_tflite.py` 的默認權重指向
`runs/pg_review_v0/weights/best.pt` —— 那是一個 **24 類**模型，
而類別表後來擴到 48 類、舊錶已作廢。

於是一條最普通的 `python scripts/export_tflite.py` 會導出一個
類別數與 `configs/classes.json` 對不上的模型，**而且不報錯**。
已改為指向當前發佈的 `runs/pg_poc3`（3 類），並加了一條測試：

```python
# tests/test_published_model.py
def test_默認導出源就是端上那一份():
    """DEFAULT_WEIGHTS 那次導出必須與打進 APK 的模型逐字節相同。"""
```

這條測試同時給出了一個**之前沒有的能力**：
能自動發現「重訓了、重導了，但忘了拷進 assets」這種漂移。

## 5.1 清單裏不放數據集路徑

第一版清單裏帶了 `"sourceDataset": "C:\\Users\\user\\..."`。
清單是要下發到手機上的資產，裏面出現開發機絕對路徑既沒意義又泄露布局，
已移除；追溯信息改為導出時打到日誌裏（`映射來源數據集：dataset_poc3`）。

---

## 6. 驗證

| 項 | 結果 |
|---|---|
| `flutter analyze` | **0 問題** |
| `flutter test` | **77 全過**（原 64，新增 13 條清單測試） |
| `pytest` | **254 全過**（原 248，新增 6 條發佈模型測試） |
| `check_kotlin_compiles.py` | 通過 |
| `check_tflite_decode.py` | 通過（佈局 ↔ Kotlin ↔ 座標換算三者一致） |
| APK | 構建成功（75.39 MB）；包內 `detector.json` 434 B + `detector.tflite` 2,871,365 B，**字節數與清單一致** |
| 逐類指標 | 重跑 val 落盤 `artifacts/metrics/pg_poc3_val.json`：總體 mAP50 **0.7445**（=清單裏的 0.744），pedestrian 0.790(242)、bin 0.948(19)、bicycle 0.496(**僅 2** 實例，不可引用) |
| 真機複測 | ⏳ **未做**（手機未連接）。清單改動前的真機 HUD 是 `classes=3 / 映射 [6, 11, 7] / invalid=0` |

### 修過的三個自查錯誤（記下來，別重犯）

1. **測試裏寫了 `String.replace`** —— Dart 只有 `replaceAll` / `replaceFirst`。
2. **`rootBundle` 從 `widgets.dart` 導入** —— 它在 `services.dart` 裏；
   改的時候把一個已有的 `services.dart` 導入搞成了重複導入，連帶
   `MethodChannel` / `EventChannel` / `PlatformException` 全部"未定義"。
3. **fixture 裏的 sha256 寫成了 66 位** —— 正則要求 64 位，
   於是四條「合法清單」的測試全掛。數字類 fixture 必須用程序生成、不能手敲。

---

## 7. 遺留

- **下發通道未建**：清單格式已定，但「服務器 → 手機」的下載路徑還沒有，
  當前模型是隨 APK 打包的。
- **真機複測待補**：手機連上後跑 `scripts/verify_on_device.ps1`，
  HUD 上應仍看到 `classes=3`、`映射 [6, 11, 7]`、`invalid=0`。
- 換模型的完整步驟見 `docs/MODELS.md` §5。
