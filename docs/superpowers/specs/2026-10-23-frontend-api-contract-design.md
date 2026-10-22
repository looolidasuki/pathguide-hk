# 前端 API 契約與訪客/登入門禁 — 設計（Spec 1）

**日期：** 2026-10-23
**狀態：** 待審閱
**範圍：** 前端（`app/lib`）的接口層、訪客/登入門禁、上傳隊列、雲端契約。
**不在範圍：** 兩級識別（Spec 2）、GPS 與路線導航（Spec 3）、雲端 VLM 問答（Spec 4）、
對話式目的地規劃（Spec 5）、訓練流水線本身（Spec 6）。它們的**契約形狀**在本文件先定，
以免 Spec 1 的接口層將來要重塑。

---

## 0. 一句話

把「哪些能力要登入、哪些 API 叫什麼、失敗怎麼辦」釘成一份可測的契約，
讓**後端還沒寫**就能把前端接到完整：UI 只依賴 `PathGuideApi` 抽象，
真後端就緒時換一個實現 + 一個 `baseUrl`，界面一行不改。

## 1. 不可違反的不變量

1. **核心識別、讀字、播報一律不走網絡。** 模型在 APK 裡，推理在端上。
   任何 API 失敗都**不得**降級核心功能，也不得阻塞啟動。
2. **登錄不得擋路**（`docs/A11Y-ENTRY-AND-AUTH.md` §1）。
   訪客可完整使用引導與識字；登入只解鎖雲能力。
3. **不引入新依賴，除非先證明它能構建。** 本倉庫路徑含空格，
   任何拉入 `objective_c` 的依賴會在所有平台上讓構建失敗
   （`app/pubspec.yaml` 的硬約束；`docs/A11Y-ENTRY-AND-AUTH.md` §5.1）。

## 2. 分層

```
UI（HomePage / SettingsPage / 帳號頁 / 讀字頁的「問問題」入口）
  └─ FeatureGate ── 能力判定（訪客 vs 已登入），不碰網絡
       └─ PathGuideApi ── 抽象介面（本文件的唯一事實源）
            ├─ LocalOnlyApi   訪客/離線：全本機，永不發請求
            ├─ HttpApi        真 HTTP，baseUrl 可配
            └─ UnavailableApi 未實作的 Spec 4/5 端點（明確報「未提供」，不假裝成功）
                 └─ HttpTransport（可注入）
                      ├─ HttpClientTransport → dart:io HttpClient
                      └─ FakeTransport      → 契約測試
```

**HTTP 用 `dart:io` 的 `HttpClient`**，不引入 `dio`／`http`——為的是不碰 §1.3 的地雷。

## 3. 訪客與登入的門禁規則

| 能力 | 訪客（未登入） | 已登入 |
|---|---|---|
| 引導／識字／讀字（端上 18 類模型） | ✅ 完整 | ✅ |
| 播報速度等本機設定 | ✅ 本機保存 | ✅ |
| 上傳未識別障礙物／錄製路線素材 | ❌（點了才提示，並說明解鎖方式） | ✅ |
| 跨端同步設定 | ❌ | ✅ |
| 雲端 VLM 問答（Spec 4） | ❌ | ✅ |
| 對話式目的地規劃（Spec 5） | ❌ | ✅ |

**明確不做**：點「識字/餐牌」強制登入。首次啟動只播一句
「訪客模式可完整使用識別」，之後不再自動提。

`FeatureGate` 的判定只有兩種狀態（`guest` / `authenticated`）＋一個
`isOnline` 修飾位。**不引入第三種「部分登入」狀態**——那種狀態沒人測得完。

## 4. API 契約（v1）

所有端點回 `application/json`；錯誤統一 `{code, message, retryable}`。

### 4.1 Spec 1 實作

| # | 端點 | 請求 | 回應 | 訪客 |
|---|---|---|---|---|
| 1 | `POST /v1/auth/guest` | `{installId, platform, locale}` | `{guestId, token, expiresAt}` | ✅ |
| 2 | `POST /v1/auth/login` | `{method, credential}` | `{userId, token, expiresAt}` | — |
| 3 | `POST /v1/auth/refresh` | `{token}` | `{token, expiresAt}` | — |
| 4 | `POST /v1/frames` | multipart：`frame`(jpeg)、`capturedAt`、`modelVersion`、`routeId?`、`gps?` | `{frameId, status}` | ❌ |
| 5 | `GET /v1/models/latest` | — | 模型清單（與 `detector.json` 同 schema ＋ `downloadUrl`＋`sha256`） | ✅ |
| 6 | `GET /v1/settings` ／ `PUT /v1/settings` | `{settings}` | `{settings}` | ❌ |

**訪客 token 端上可離線生成**（UUID v4 + 本機簽名佔位），`POST /v1/auth/guest`
只在有網時用於換取伺服器端 guest 記錄。**沒有網也能當訪客**，這是 §1.2 的必然結果。

### 4.2 已定形狀、未實作（Spec 4–6）

| # | 端點 | 說明 |
|---|---|---|
| 7 | `POST /v1/vision/query` | 雲端 VLM 問答（見 §7） |
| 8 | `POST /v1/plan` | 對話式目的地規劃（見 §8） |
| 9 | `GET /v1/routes/{id}/status` | 路線素材的訓練狀態與各類數量（見 §6） |
| 10 | `PATCH /v1/review/{frameId}` | 人工審查（後端／後台用） |

## 5. 上傳隊列（Spec 1 的核心工程）

- 採集素材**先落盤**（應用私有目錄，原生 `writeFile` 通道已有）。
- 入隊 → 有網且已登入才送出 → 成功刪本地 → 失敗保留並退避重試。
- **去重**：以**檔案相對路徑**為鍵，同一張不會重送。
  （原稿寫 `sha256(檔案)`，但 `dart:core` 沒有 sha256，實作時改用路徑——
  檔名由我們自己產生，路徑本身唯一；若之後允許引入 `crypto`，只換去重鍵即可。）
- **上限**：隊列最多 `kUploadQueueMax = 500` 張、單張 `≤ 2 MB`；
  超過時**丟最舊的**並在狀態檔記一筆（不彈窗）。
- **絕不在啟動關鍵路徑上送**：只在已進入引導/讀字之後、且屏幕亮著時送。

## 6. 錄製路線素材的訓練狀態（你的要求 1）

**訓練不是採集完就發生**，中間有數量門檻與人工審查。狀態機（後端權威，前端只顯示）：

```
captured → queued → review_pending → review_pass ─┐
                          └────────→ review_fail   ├→ training_pool → trained
                                    （永不進訓練集） ┘
```

規則（寫進契約，避免「看起來在推進、實際沒有」）：

1. **數量門檻**：某一類別在 `review_pass` 狀態的樣本數 ≥ `minPerClass`
   （預設 **250**，與 `docs/PROJECT-STATUS.md` 的 250/類 標註規劃一致）
   才允許進入 `training_pool`。
2. **人工審查是硬門**：`review_pass` 之前的樣本**不得**用於訓練，也不得用於評測。
3. **狀態由後端回報**，前端只讀 `GET /v1/routes/{id}/status`：
   `{routeId, perClass:[{classId, captured, reviewPass, threshold, eligible}], state}`
4. 前端要能回答使用者的問題：「我錄的這些有沒有用？」
   → 播報一句「目前已通過審查 N 張，同類需要 250 張」。

> 這條同時補上了 `PROJECT-STATUS.md` §4.2「上傳觸發判據未定」的空白：
> 上傳的**觸發條件是人主動錄製一條路線**，不是「偵測到未識別障礙物」——
> 後者被實測推翻（98% 的街景幀都有檢出）。

## 7. 雲端 VLM 問答（你的要求 2，Spec 4）

**情景**：使用者在讀字模式對著餐牌問「有沒有乾炒牛河」。

```
讀字頁 →「問一個問題」按鈕（語音或既有輸入）→ 截當前幀 JPEG
      → POST /v1/vision/query {imageSha256, question, locale, modelVersion}
      → 200 {answerable, answer, confidence, evidence:[{text, bbox}], refusalReason?}
      → TTS 播報 answer（句長受 §9 的 3 秒規則約束）
```

契約要點：

- **`answerable: false` 是正常回應，不是錯誤**。模型看不到該菜式時必須能說
  「這張餐牌上沒看到」，而不是編一個答案。`refusalReason` 供除錯。
- `evidence` 帶回原文與 bbox，讓低視力使用者與陪護者能核對；**全盲使用者只聽 `answer`**。
- **隱私**：上傳整幀畫面是對既有「畫面不上傳」承諾的**例外**。因此：
  只在已登入、且使用者**明確按下該按鈕**時發生；每張都記入狀態檔；
  設定頁要有一句可聽見的說明「問問題會把這一幀上傳到雲端」。
- 回答必須是**繁體中文/粵語**，且不得依賴方位描述（無「左邊」「下方」）。

## 8. 對話式目的地規劃（你的要求 3，Spec 5）

**情景**：AI 問「今天你要去什麼地方」，使用者用語音回答，AI 直接規劃。

```
POST /v1/plan {utterance, locale, origin?, preferences?}
  → 200 {understood: true, destination: {label, lat, lng}, route: {...}, narration: [...], confirmRequired: bool}
  → 200 {understood: false, clarifyingQuestion: "是「彩明商場」還是「彩明苑」？"}
```

契約要點：

- **必須支援 `clarifyingQuestion`**：香港地名同音/近名極多（彩明苑 vs 彩明商場），
  猜錯會把盲人帶錯地方，所以「聽不懂就問」是契約的一部分。
- `narration` 是**給 TTS 用的短句序列**，不是一大段文字（沿用逐句唸的既有約束）。
- 端上需要 **ASR（語音轉文字）**——這是新的依賴風險，Spec 5 開工前必須先驗證構建。
- 依賴 Spec 3（GPS/路線）與「導航決策引擎」（難點 #3，尚未開始）。
  **在此之前 Spec 5 不可能完整**：AI 可以規劃，但沒有導航決策就無法沿途引導。

## 9. 播報長度與錯誤處理

- 任何 API 錯誤**不彈窗**：寫狀態檔 + 一句「暫時用不到雲功能，識別照常」。
- TTS 單句上限沿用既有規則（約 3 秒唸完），長答案切句。
- 錯誤分類：`AuthExpired`（靜默重取 token 一次）、`Network`（重試一次→標離線）、
  `Server`（記錄，不重試）、`NotAvailable`（Spec 4/5 未實作，明確說「此功能尚未提供」）。

## 10. 儲存

- `shared_preferences` 存：`guestId`、`token`、`installId`、本機設定（含播報速度）。
- 素材與隊列存應用私有目錄（沿用既有原生 `writeFile`／`fileSize` 通道）。
- **驗證前置**：先 `flutter pub get` + `flutter build apk --debug`，
  失敗則退回「檔案儲存 + 自製 key-value」，**不冒險**。

## 11. 測試計畫（不碰真網）

| 測什麼 | 怎麼測 |
|---|---|
| 契約形狀 | `FakeTransport` 斷言方法／路徑／必需欄位／狀態碼映射（每個端點 ≥ 1 條） |
| 訪客門禁 | 未登入呼叫 4/6 端點 → 被 Gate 拒絕且**提示可操作**（不是靜默）；已登入 → 通過 |
| 離線 | `isOnline=false` 時核心功能全綠、雲功能標「暫時不可用」、**不彈窗** |
| 上傳隊列 | 入隊→恢復連線→送出→失敗保留→以**檔案路徑**去重不重送 |
| 回歸 | 既有 235 條 Flutter 測試＋436 條 pytest 必須全綠；識別邏輯一行不動 |
| 無障礙 | 帳號頁與「問問題」入口：每個可操作項有動作+結果 label、無裸 Icon、200% 字級不截斷 |

## 12. 風險

| 風險 | 處置 |
|---|---|
| `shared_preferences` 踩 `objective_c`／空格路徑 | 先構建驗證；失敗退回檔案儲存 |
| 後端契約與前端漂移 | 契約測試 + 本文件是唯一事實源；後端就緒時先跑契約測試再接 UI |
| 上傳破壞「畫面不上傳」承諾 | 只在明確按鈕、已登入時發生；設定頁有可聽說明；寫狀態檔 |
| Spec 5 依賴未開始的導航決策 | 明寫「Spec 5 在此之前不可完整」，不要假裝能做 |
| ASR 依賴（Spec 5） | 開工前先做構建驗證，同 `shared_preferences` 的流程 |

## 13. 驗收清單

- [ ] `flutter analyze` 0 問題、`flutter test` 全綠、`pytest` 全綠
- [ ] 未登入可完整引導＋識字（真機驗證，這是最重要的一條）
- [ ] 未登入點「上傳」→ 一句可操作提示，不彈窗、不阻塞
- [ ] 飛航模式下啟動、識別、播報全正常
- [ ] 每個端點都有契約測試，且測試裡沒有真實網絡
- [ ] `PathGuideApi` 之外沒有任何地方出現 URL 字串
- [ ] 切換 `LocalOnlyApi` ↔ `HttpApi` 不需要改任何 UI 檔案

## 14. 分階段落地（Spec 1 內部）

| 階段 | 內容 | 可獨立驗證 |
|---|---|---|
| 1 | 依賴驗證（`shared_preferences` + 構建） | `flutter build apk --debug` 通過 |
| 2 | `PathGuideApi` 介面 + 資料模型 + `FakeTransport` 契約測試 | `flutter test` |
| 3 | `LocalOnlyApi`（訪客本機）＋ `FeatureGate` ＋ 門禁測試 | `flutter test` |
| 4 | `HttpApi` + `HttpClientTransport`（真 HTTP，指向可配 baseUrl） | 對 `localhost` 假伺服器可跑，或用 `FakeTransport` |
| 5 | 上傳隊列 + 去重 + 退避 | `flutter test` |
| 6 | 帳號頁（簡單版：登入／登出／刪除帳號） | widget 測試 + 真機 TalkBack |

> 「問一個問題」的入口屬 Spec 4（§7），本 spec 只把 `PathGuideApi` 的方法與
> `NotAvailable` 行為備好，**不做那個界面**。

**階段 1 沒過就不往下寫**——這是 `docs/A11Y-ENTRY-AND-AUTH.md` §5.1 的教訓。
