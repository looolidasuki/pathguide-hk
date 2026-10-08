# 外部數據現狀與一個把採集腳本弄壞的 BOM

**日期：** 2026-10-02
**起因：** 要補 `bicycle`（13 幀/15 框）與 `scooter`（唯一零檢出類）的數據，
先查 Roboflow 能不能下，結果查出兩件更要緊的事。
**結論：**
1. Roboflow 的 key 已被吊銷（HTTP 401），**不能下載**，需要換 key 或手工下 zip。
2. `data/raw/external/` 裏**已經有 901 張外部圖**（16 個類，含 bicycle 60 張、
   scooter 60 張），但**從未被任何數據集使用過**。
3. `configs/commons_sources.json` 帶 UTF-8 BOM，導致採集腳本
   `fetch_commons_by_class.py` **直接跑不起來**——已修，並加了測試。

---

## 1. Roboflow：確認吊銷，不是網絡問題

```
讀到 key：21 字符，以 KJsR… 開頭
鑑權結果：失敗 HTTP 401
  響應: {"error":{"message":"This API key does not exist (or has been revoked).",
         "status":401,"type":"OAuthException"}}
```

`api_key="unauthorized"` 是**佔位符**，不是真 key。三條出路（都需要你操作）：
換一把有效 key 填進 `.env.secret.ps1`；把 dataset 設為可協作訪問；
或手工下載 zip 丟進 `data/raw/` 再跑 `scripts/import_roboflow.py --zip <文件>`。

---

## 2. 已經有 901 張外部圖，而且沒用過

```
data/raw/external/
  banner 57   bench 60   bicycle 60   cardboard 59   cart_trolley 60
  chair 57    fire_hydrant 26   goods_on_street 45   scaffold 59
  scooter 60  sign_pictogram 60  step 68  table 55
  traffic_cone 60  tree 59  zebra_crossing 56
  attribution.jsonl（889 條）  fetch_summary.json
```

來源是 **Wikimedia Commons**（字段：`title` / `thumburl` / `artist` / `license` /
`class_or_target` / `tier`），許可證以 CC BY-SA 4.0（499）、CC BY-SA 3.0（132）、
CC0（76）為主。

**關鍵事實：沒有任何數據集的 `manifest.csv` 提到 `external`**——
即這 901 張圖抓下來之後**一直躺着**，沒有進過任何一次訓練。

`fetch_summary.json` 還停留在只記 3 個類（bicycle / bench / traffic_cone），
説明後續又抓了 13 個類但沒更新它——**這份 summary 不可作為現狀依據**。

### 但是：它們不能直接當訓練標籤用

這些是**整圖單物件**照片（一張圖一個物體，Commons 上給該物件拍的照片），
**沒有框**。所以：

- ❌ 不能直接丟進檢測訓練集；
- ⚠️ 也不能「整圖當一個框」——街景裏一圖多物，那樣訓出來的框是錯的；
- ✅ 正確用法是餵給**老師預標鏈**（GDINO 出框 → SAM 精修 → VLM 驗證 → 抽樣質檢），
  這正是 `scripts/pipeline/` 那三段，而它**目前接的還是 YOLO-World**（9 類零召回）。

### 還有一個域偏移問題，必須寫清楚

採集腳本自己就寫了「香港分類優先」，理由是全球圖街道風格偏移。
實測這次探針也印證了：

```
bicycle   3 張（香港 3 / 全球 0）
scooter   3 張（香港 0 / 全球 3）   ← scooter 在香港 Commons 裏幾乎沒有
```

所以 Commons 數據能**讓一個類存在**，但**不能保證它在香港街景裏可用**。
必須與實拍街景幀混着訓，並且**分開評測**，否則會得到一個
「在 Commons 上很好、在調景嶺不好」的模型。

---

## 3. 那個 BOM：一個配置文件被另存一次，採集腳本就全廢

`configs/commons_sources.json` 開頭有 `EF BB BF`（UTF-8 BOM），
而 `fetch_commons_by_class.py` 用 `encoding="utf-8"` 讀它：

```
json.decoder.JSONDecodeError: Unexpected UTF-8 BOM (decode using utf-8-sig):
line 1 column 1 (char 0)
```

**為什麼值得單獨記一筆**：這個報錯
① 不提 BOM，② 不提是編碼問題，③ 不提是哪個文件被誰怎麼改的。
看的人第一反應是「JSON 內容寫壞了」，於是會去翻內容——而內容根本沒問題。
實際原因只是某次編輯/`Set-Content -Encoding utf8` 順手加了 BOM。

**取證：全倉庫掃描帶 BOM 的文件，8 個**：

| 文件 | 有害？ |
|---|---|
| `configs/commons_sources.json` | ⚠️ **有害**：被 `json.load` 按 utf-8 讀 |
| 其餘 7 個（`.py` 源碼） | 無害：Python 3 容忍源碼 BOM，且實測 259 條測試全過 |

所以問題**只在「數據文件 + 嚴格解碼器」這個組合**上，不是「BOM 一律有害」。

### 修法：治本 + 兜底，兩個都要

- **治本**：把文件重新存成 UTF-8 無 BOM（並先 `json.loads` 驗證內容合法再寫回，
  避免把壞文件洗成另一個壞文件）。
- **兜底**：讀取方改成 `encoding="utf-8-sig"`——它對「有 BOM」和「沒 BOM」
  都能讀，是純收益。因為 Windows 上 BOM 會**再被加回來**
  （記事本、PowerShell `Set-Content -Encoding utf8` 都默認加）。

新增 `tests/test_config_encoding.py`：
① `configs/**/*.json` 一律不得帶 BOM 且必須能按普通 utf-8 解析（參數化，逐文件）；
② 採集腳本必須繼續用 `utf-8-sig` 讀那份配置。
這樣「配置文件被另存過一次」會**當場測試失敗**，而不是過幾天
「採集腳本神秘跑不動」。

驗證：修復後實跑探針，鏈路通了——

```
bicycle  3 張（香港 3 / 全球 0）
scooter  3 張（香港 0 / 全球 3）
```

---

## 4. 順帶確認的另一件事

`data/raw/external` 的存在説明**Commons 這條取數通道是可用的、不需要任何憑據**。
在拿到有效 Roboflow key 之前，這是唯一能立刻推進的補數據途徑
（配合 `--only <類名> --per-class <n>` 定向擴量）。
