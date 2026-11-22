# 領路通 PathGuide 後端與資料契約

核對日期：2026年11月20日。使用操作見[前端](FRONTEND-DESIGN.zh-HK.md)，類別、品質門檻及訓練證據見[資料與模型](DATASET-REVIEW.zh-HK.md)。

<a id="service-scope"></a>
<a id="service-state"></a>
<a id="1-已有程式與缺口"></a>

## 1. 服務現況

| 能力 | 工作區與最後有紀錄的狀態 |
|---|---|
| 帳號與私人聯絡 | 已接 Firebase Google 登入、本人 profile、選填聯絡人及帳號刪除流程。其他登入方式待接。 |
| 照片提交與覆核 | 客戶端與提交／清理 Functions 已有程式。七個問題／覆核 callable 及工作台已有本機合成驗證。照片上傳及覆核預設關閉，最後部署紀錄未涵蓋兩組服務。 |
| 場景描述 | 最近紀錄為 Firebase `pathguide-dev` 的 `describeScene` 部署，Qwen 端點為新加坡。最後有紀錄的試驗許可已在 2026-11-14 03:22:40（香港時間）到期。即時部署、額度及帳本狀態未查。 |
| 室內錄路 | `1.11.0+29` 的路標類型及方向已隨 App 交付，資料留在手機。場地及讀屏驗收待做。雲端同步與私人模型未接。 |
| Android 步行代理 | `computeWalkingRoute` 有程式，部署與真機待核。iPhone 戶外路線由 MapKit 處理。 |
| 訓練與模型交付 | iPhone 開發分支接通本機路標候選儲存及人工覆核。雲端快照、排程、GPU worker、registry 及私人更新未接。 |

現行 Functions 在工作區合計 16 個 export，其中包含七個工作區內的覆核 callable。 [Functions 入口](../backend/functions/index.js) · [照片開發紀錄](../verification/baselines/2026-10-23.phase4-verification.json) · [場景部署及許可](../verification/scene-100-five-days-20261109.json) · [手機交付收據](../verification/release-receipts/app-1.11.0+29.json)

<a id="data-contracts"></a>

## 2. 帳號、照片與人工覆核

帳號 UID 來自核實的 Firebase token。照片及場景 callable 另核 App Check、`expectedUid`、有效帳號及刪除 guard。本人 profile 與聯絡資料各有存取規則。訪客可用本機辨識及本機錄路。雲端描述、照片回報、訓練及路線同步各自按用途授權。 [Firestore 規則](../backend/firestore.rules) · [Storage 規則](../backend/storage.rules)

「閱讀文字」的相片與 OCR 結果預設只作本機工作階段暫存，可供同圖切換菜單查價，重拍、換相或退出時清除。這次閱讀的相片及結果留在裝置，使用者自行管理相簿原相。開發分支在同一張相片上分別執行本機通用 OCR 及菜單專用處理，回傳文字區域和菜單結果。一般閱讀使用整頁辨識區域及信心，菜單保留價錢候選及配對邏輯。重拍或離頁會作廢遲到回覆。

<a id="2-現行照片流程與資料"></a>

### 照片提交與保留

`getPhotoConsent`／`setPhotoConsent` 管理 `users/{uid}/private/photoConsent` 的通知版本與同意 epoch。客戶端取同幀 JPEG 與預測，按專案／UID／epoch 放入加密待傳佇列，有 Wi-Fi 時由 `submitPhoto` 傳送。伺服器驗相片格式、尺寸及配額，解碼重編碼移除 EXIF／GPS／XMP，分別記來源及清理後 SHA，再以 object generation 綁定私人 JPEG。相同 UID、photoId、來源 SHA 及 epoch 的重試沿用既有結果及配額，物件禁止覆寫。

| 項目 | 資料及界線 |
|---|---|
| 本機 | 待傳最多 50 張／50 MB，七日到期。離線撤回立即停止本機擷取及待傳，恢復連線後補交撤回。 |
| 雲端 | 記錄在 `users/{uid}/photos/{photoId}`，照片在 `unconfirmed_photos/{uid}/{photoId}.jpg`。每張 JPEG 上限 2 MiB，從 callable 提交。本人透過 `listPhotoProgress` 讀進度。 |
| 配額 | `photoQuotas/{UTC日期}` 每日總候選 100 張、自動 50 張、場景取樣 10 張。自動候選及場景取樣至少相隔 30／60 秒。觸發為 `manual_report`、`low_confidence`、`scene_sample`。 |
| 清理 | 未覆核照片及關聯問題預設三十日，核准問題沿用原到期日。`expirePhotoCandidates` 每小時每批最多 200 張，`removeLatePhotoObjects` 處理遲到物件。 |

[照片政策](../backend/functions/photo_policy.js) · [裝置待傳佇列](../app/lib/photos/encrypted_photo_queue.dart)

<a id="3-管理員覆核與自動批次覆核api本機驗證部署排程未啟用"></a>

### 管理員覆核

| Callable | 契約 |
|---|---|
| `submitPhotoIssue`、`getPhotoIssue` | 本人提交／查看 `misclassified` 或 `missed`，綁已驗證且未到期照片。每照片一件，以 UID＋reportId 冪等，空預測可作漏認。距離及文字回報仍待另訂契約。 |
| `getPhotoReviewItem` | 覆核者讀取回報、原預測及標註。明確要求時才傳指定 generation、SHA 相符的 JPEG，回傳前再驗權限、同意及 revision。 |
| `submitPhotoReview` | 接件、存稿、退回、爭議、拒絕或由另一名 adjudicator 核准。`expectedRevision` 防覆寫，交易同步寫狀態、修訂、requestId 收據及照片指標。 |
| `withdrawPhotoIssue` | 本人撤回並作廢核准指標。重試回目前狀態及原已套用版本。 |
| `listPhotoReviewQueue`、`listPhotoReviewHistory` | 待辦由最舊開始，歷史由最新修訂開始，逐頁重驗用途、權限及期限。待辦游標只有時間、隨機 queueKey 及狀態。 |

覆核權限同時核對 token、當前 Auth 的 `photoReviewer` claim 及啟用中的伺服器人員記錄。服務拒絕覆核者處理本人的回報。核准要求十類全圖 coverage、框及映射有效、定義與來源群組齊備，以及人工核實聲明。預測、回報主張、人工答案及修訂各自保存。`humanReviewed` 須配合抽覆。現有核准範圍為 `personal_development_only`，共用訓練另取同意。

本機工作台可用 `pnpm workbench:build`、`pnpm workbench:demo` 走合成接件、修框及雙人核准，使用 localhost Emulator、測試角色及合成 JPEG。正式模式 `pnpm workbench:serve` 從瀏覽器以 Google 登入及 App Check 直接呼叫區域 callable。本機設定在忽略追蹤的 `backend/workbench/config.local.json`。草稿與登入狀態留在記憶體，換帳號、登出或離頁清理相片與舊回覆。開通需部署覆核 Functions 與索引，指定人員、抽覆規則及待辦上限，驗真實 App Check、撤權及清理，再配置 `PHOTO_REVIEW_ENABLED`。工作台合成流程證據保留在工作區 `verification/backend-photo-review.json`。

<a id="5-撤回刪除與失效"></a>

### 撤回、刪除與失效

撤回令舊 epoch 失效，阻止新提交及覆核存取。`deletePhotoAccountData` 先核近期登入並建刪除 guard，再清理該 UID 的資料及物件。App 在清理後移除 Auth 身分。未啟用照片且沒有照片同意記錄的帳號，沿用原有本人資料刪除路徑。逾期刪除按 generation 清理，遲到事件不可重建記錄。實體副本需待清理流程，離線副本要重連才可得知撤回。加入 worker、快照或 registry 後，先封新工作及下載、取消或隔離在途工作，再逐項清理私人產物。 [帳號刪除客戶端](../app/lib/account/firebase_accounts.dart) · [刪除服務](../backend/functions/index.js)

<a id="scene-contract"></a>

## 3. 雲端場景描述

最近部署紀錄為 `asia-east2`、Node 22、40 秒、最多兩個 instances，使用新加坡 `qwen3-vl-plus` 及 Secret Manager。客戶端與後端的 `SCENE_DESCRIPTION_ENABLED` 預設關閉，需明確配置。手機行為及實測項目見[前端](FRONTEND-DESIGN.zh-HK.md)。

- **輸入與回覆。** 指定帳戶通過身分、App Check 及刪除 guard 後，只傳當前 JPEG（最多 512 KiB、長寬各不超過 1280）。後端剝 EXIF 並縮至最長邊 512px，模型、prompt、端點及金鑰由伺服器控制。v1 回兩至三句。v2 的 `overview` 回兩至三句，`update` 回一句，附有界 `observations`。完整核驗文字、分類、位置及細節才回有效內容。v2 prompt 要求最多三項重點，validator 上限六項。只接受指定分類和左／中／右位置。拒絕時以固定診斷分類記錄原因，無原文或補發修復請求。
- **用量與停止。** 先在交易內預留再呼叫供應商。v1 冷卻 45 秒，v2 三秒。同帳戶一個在途，重複 ID、到期或預留不足會停止。每次保守預留 2458 microUSD。用量不明保留估算並停止新請求。開關、登入及跨日沿用累計帳本。修改許可須明確批准及以 CAS 審計。
- **到期許可。** 最後有紀錄的試驗為累計 100 次、估算 US$0.50，窗口五天，於 2026-11-14 03:22:40（香港時間）到期。單次恢復授權另有一天上限。估算與供應商／Firebase 實際計費分開，歷史餘額只反映當時快照。
- **診斷與保存。** `operation:status` 只讀安全數值與最近三個固定結果，無取相、預留或推理。以頂層欄位替換結果，保留其他計數。遲到回覆再驗有效帳戶。App 和自家後端不長期保存相片／描述原文。供應商保留政策另核。場景資料不可加入訓練。

[場景 Function](../backend/functions/scene_function.js) · [回覆驗證](../backend/functions/scene_description.js) · [試驗帳本](../backend/functions/scene_trial.js) · [部署與到期紀錄](../verification/scene-100-five-days-20261109.json) · [拒絕分類證據](../verification/scene-content-detail-20261109.json)

<a id="local-route-contract"></a>

## 4. 本機路線、定位與深度

| 資料 | 讀寫契約 |
|---|---|
| 版本與媒體 | 錄製或明確更新時寫必要 JPEG／Vision feature，引用綁 SHA、尺寸、保存時間、擷取來源及特徵版本。普通重行只讀。先驗引用與配額，再寫暫存，最後原子更新 catalog。中斷或額滿保護穩定版本。刪除先立 tombstone 再清各版本與媒體。 |
| 帶標記路線 | `markType`（landmark／junction／door／stairs／lift／toilet）及 `markDirection`（junction 限 left／right／straight）自 schema 4 起支援，schema 5 加入 escalator／ramp／reception／sign。保存時按所含資料使用相容 schema，失敗紀錄最低需要 schema 6，文字備註需要 schema 7，錄音備註需要 schema 8。開發分支可讀 schema 1–8。`1.11.0+29` 可讀至 schema 4，前一個原始碼檢查點可讀至 schema 7。回退前須核對路線版本。沿用 `floorEvidence`、`floorAnchor`、`floorContextAnchor`。復原移除最近成功手動標記及未被引用的媒體，重接路段保持未確認。 |
| 失敗紀錄 | `markFailures` 跟當前草稿或路線版本加密保存。每筆只存標記類型、選填方向、UTC 嘗試時間及固定原因 `capture`／`capacity`，保留最近 64 筆。純失敗紀錄可存草稿。重行只用路標、有效媒體及路段，失敗紀錄供查看。刪除路線時跟隨原有版本清除。 |
| 文字備註 | schema 7 的 `textNote` 隨指定手動標記保存在本機加密路線版本，最多 240 個字元及 1 KiB UTF-8。更新或清空備註隨路線保存。舊版本按既有版本規則保留，刪除整條路線時一併清除。廢除標記同時移除當前版本的備註。備註作文字顯示及按需讀出，定位與路段判定沿用路標、樓層、面向及有效媒體。 |
| 錄音備註 | schema 8 的 `audioNote` 隨指定手動標記保存單聲道 16-bit PCM WAV。iOS 在記憶體收音和播放，路線版本沿用 AES-GCM、裝置檔案保護、原子保存及刪除。每段上限 10 秒及 1 MiB，單一路線版本原始錄音合計最多 4 MiB，加密版本檔案上限 8 MiB，iOS 原生寫入以路線版本用途套用此上限。目錄已存在時可再存新版本，並重新確認檔案保護。錄音編碼內容獨立計入容量，其他 JSON 沿用 256 KiB；磁碟配額計入整個加密檔案。catalog 與 JPEG／feature 的媒體索引沿用現行格式。播放使用該版本的錄音及有效位置確認，取相分析和語音辨識維持各自用途。 |
| 樓層與轉層 | 區分未知、明確確認、沿用及整段核實。沿用引用較早的有效同層確認點，須核實才可啟用。設備入口後作廢當前樓層，出口再確認。矛盾、暫停、背景、保存或重開均撤回當前上下文。有向邊只記已走方向，跨層須有入口、出口、設備及樓層來源。回程另驗。 |
| 觀察與提示 | 普通相機提供 Vision feature print 與 OCR 候選。路線版本、方向、時序及有效樓層共同約束匹配，錯層、相似出口、過期或特徵不相容時保留未知。正式跨層及障礙提示須按旅程、世代、版本、來源序列及有效期核驗。P0 合成結果適用於工程夾具。 |
| 裝置保護 | 路線用 AES-GCM 與獨立裝置金鑰，與待傳照片隔離。iOS 檔案 Complete 保護並排除備份，Keychain 為 WhenUnlockedThisDeviceOnly。重裝、遺失金鑰或換機後的復原無保證。 |
| 容量與選幀 | JPEG／feature 上限 512／64 KiB。每點四視角、每路線 64 視角、JSON 256 KiB、八版本。磁碟每路線 64 MiB、整庫 256 MiB，計入歷史及暫存。自動取樣試驗約五秒一次，最多留 48 視角並預 16 個手動位置。頻率及選幀門檻待實地校準。 |

[路線格式](../app/lib/route_memory/route_package.dart) · [加密版本庫](../app/lib/route_memory/encrypted_route_store.dart) · [媒體政策](../configs/planning/codex-p3a-storage-20261105.json) · [特徵證據](../verification/codex-p3b-landmarks-20261105.json) · [標記證據](../verification/route-mark-core-20261110.json)

路線版本的啟用條件目前核對資料完整度，供試行。真人重行驗收另按原路線版本與行進方向記證據，App 內的驗收狀態待實作。[重行驗收狀態](FRONTEND-DESIGN.zh-HK.md#route-replay-acceptance)

<a id="8-導航資料與使用說明發佈前草稿重點"></a>

### 地圖、語音與深度資料

- 戶外搜尋／步行路線向 Apple／Google 傳送必要的位置與查詢。路線定位只在前景由使用者啟動，暫停、背景或結束時停止。代理不保存完整座標、路線或軌跡。最近與收藏地點留本機，可清除。按掣才收音，優先裝置端，線上辨識須按當次同意。
- Android 代理僅接 Google Routes 的 WALK 查詢，由 App Check 保護，訪客可用。金鑰留在 Secret Manager。CSDI 是可選場地資料來源，首輪評估調景嶺站非付費區。查詢只傳必要位置。坐標、樓層映射、署名及快取待接入核對，不傳私人路線資料。驗室外至入口、室內起點及反向交接。 [導航代理](../backend/functions/navigation_routes.js) · [三地及接駁規格](https://github.com/actiondarr/pathguide/issues/16)
- 深度、姿態及局部幾何在手機處理。`hk.pathguide/depth` 接已核 SHA／bytes／類別映射的內置模型，回同 session／時間的框、取樣位置與有效性等。有有效量測才回 `rangeM`／`planeZM`。分數是分類信心，`rangeM` 是框內代表表面的徑向距離。深度不持久寫入路線或上傳。 [裝置端深度介面](../app/lib/depth/depth_session.dart)

<a id="route-landmark-learning"></a>

## 5. 待接的訓練與模型交付

1. **先完成一個可追溯案例。** 人工回報 → 獨立真值與來源分組 → 核准版本及有授權的快照 → 候選 → 獨立比較 → 手機重測 → 關單。每步保留 issue／資料／模型版本，評估失敗回開發。以每位覆核者、問題類別及高風險類別做抽覆。待辦到上限可暫停自動抽樣。私人微調先比較現用、改善共用及私人的額外效益。 [資料與模型驗收](DATASET-REVIEW.zh-HK.md)
2. **快照、排程及 worker。** manifest 固定用途、UID、影像／標註版本、split、coverage、設定及 SHA。用 UID＋快照＋設定去重，以交易取得 lease。A 首版以香港時間 03:00、至少 50 張新增核准圖／三場景作排隊檢查起點，另須達樣本及品質門檻。首版限 A 十類及獲授權回放，B 獨立。worker 固定容器及版本，記心跳、run、checkpoint、optimizer、取消及評估。相同快照才可續跑，改資料開新 run。先驗 mock、預算、時限、權限及取消，付費 GPU 待配置。
3. **已錄路標另有用途。** iPhone 開發分支按每趟開關重用位置比對的照片和特徵。候選用獨立 Keychain 金鑰、目錄及加密認證範圍，記旅程、路線版本、相機 session／sequence、圖像與特徵 SHA、特徵／前處理版本、原比對和使用者當時所選路標。覆核分開按修訂號保存，可核實、更正、待補資料或拒絕。每趟 12、每條路線 24、全庫 48 個，總量 64 MiB。七日到期即停止讀取，下一次新增或開啟覆核時清理。停用先作廢在途寫入再移除該趟資料。刪路線核對版本後先清除候選並寫刪除標記。普通重行不額外保存照片。記憶補強及另行授權的私人訓練待接。[需求 #19](https://github.com/actiondarr/pathguide/issues/19) · [工程證據](../verification/route-learning-integration-20261120.json)

<a id="4-私人發佈自動更新與回退待實作"></a>

### 私人模型更新與回退

- **模型登記與更新。** 獨立驗收及匯出相容通過後，登記 scope／UID、job、snapshot、模型與映射 SHA／大小、taxonomy、runtime、App 版本及評估版本。核准才提供綁本人、SHA、有期限的下載。裝置前景且相機任務停止時驗 UID、雜湊、映射及相容，試載入後原子切換。可選預先同意自動更新。路標模型特徵空間變更時須重建相容索引，再合併 profile 一起切換。缺合法原圖時保留舊組合。
- **回退與撤回。** 使用者可離線選上一版或內置版本及選填原因，以 UID／scope＋SHA 記拒用。改名的相同內容亦擋。發佈者撤回後停新 offer／下載。已下載裝置重連得知後切回核准版本。切帳號作廢遲到結果及清私人 cache。資料撤回阻止新快照、在途發佈及新下載。已訓練的單圖影響無法精確移除。載入、品質、使用者接受分開記錄。

未來裝置端意圖調度選已驗證能力，按模型包記格式、runtime、語言、SHA、大小與相容性。缺能力時明確降級，雲端途徑另取同意。大型包須顯示容量並可取消、重試及刪除。

<a id="service-acceptance"></a>
<a id="6-後端驗收"></a>

## 6. 驗收與開通條件

| 範圍 | 行為驗收 |
|---|---|
| 身分、照片及覆核 | 驗真實 App Check、跨 UID、舊 epoch、配額、generation、冪等、revision 衝突和撤權。兩名人員用真實案例走覆核、清理及修正閉環。Emulator 合成回歸及真人閘道結果分開。 |
| 本機錄路 | 注入取消、額滿、損壞檔、刪除競爭及前景恢復，核穩定版本和媒體引用。真機驗 Keychain、保護與備份排除。實地流程見前端。 |
| 場景 | 核當次有效許可、資格、重複 ID、用量不明、到期、刪除及遲到結果。狀態讀取無推理。實際語音和畫面品質以測試員結果記錄。 |
| 訓練與更新 | 驗快照用途、lease／重試、取消後無發佈、預算不足不排隊、獨立評估及映射相容。跑斷網、重開、空間不足、切帳號、撤回下載及主動回退。 |
| 可理解的服務狀態 | 回傳結構化 stage、reasonCode、可重試／取消及必要進度，由前端本地化與讀屏。輔助科技狀態和偏好只留本機。診斷記去識別 ID、固定錯誤與耗時。 |

<a id="release-process"></a>
<a id="deployment-rollback"></a>
<a id="7-部署設定與版本回退"></a>

## 7. 部署、版本與回退

- iOS 使用相符 Firebase App／bundle ID 及 Google 登入，以 `app/tool/configure_firebase_ios.py` 寫本機配置。正式 App Check 待驗。`app/tool/run_iphone.sh --build-scene-trial` 建私人 Profile 安裝包，載入本機 Firebase／App Check 設定及受版本管理的 `app/config/scene.ios-trial.json`；該 JSON 只含兩個場景開關。
- Android 使用相符 Firebase App／簽署 SHA、受限制的 Maps／Places 金鑰及 Google Play 服務。`NAVIGATION_GOOGLE_ENABLED` 待代理、App Check 及真機通過才開。公開導航前補營運者／聯絡、私隱及條款連結。 [Android 設定範本](../app/config/navigation.android.example.json)
- 照片與覆核部署先驗計費、儲存、規則、索引、App Check、人員與容量。`backend/functions` 的 `pnpm test` 驗 Functions，`backend` 的 `pnpm test` 跑 Firestore／Storage Emulator（Node 22、Java 21）。場景部署只選 `describeScene`，核 Secret 引用、區域、帳戶及有效許可。
- 工作票通過檢查及覆核 → 提交所涉來源、文件及證據 → 推送 `feature/cross-platform-navigation` 並核遠端 → 標完成。裝機及共用模型版本另提交版本、lockfile、模型與映射，建不可變 tag／Release，核遠端後才安裝／交付。實驗版用 prerelease。P2-D、P3-C、P4-B、P5 各準備手機 prerelease，P3-A 有本機資料保護真機檢查。 [版本規則](../AGENTS.md)
- 回退按 tag、lockfile、模型、資料相容及簽署重建，必要時新增遞增 iOS build。Release 附精確 SHA、驗收、限制及重裝方法。共用產物可存 Git／Release。私人照片、權重及報告留受權限保護的 UID scope，保留歷史版本供本人回退。

<a id="1438-相機前處理修正版github已保存iphone已安裝啟動"></a>
<a id="1427-前端恢復修正的契約與版本已交付試用"></a>

前處理與相機恢復的舊版契約可沿收據追溯。 [1.4.3+8](../verification/release-receipts/app-1.4.3+8.json) · [1.4.2+7](../verification/release-receipts/app-1.4.2+7.json) · [歷次交付收據](../verification/release-receipts/)

<a id="service-plan"></a>

## 8. 開發階段與逐功能計劃

裝機、部署及真人驗收各有證據。導航的任務與交付次序見[前端開發次序](FRONTEND-DESIGN.zh-HK.md#delivery-plan)。

| 階段 | 工作 | 有證據的現況 | 完成標準 | 下一步／依賴 |
|---|---|---|---|---|
| S0 工程基線與版本保存 | 來源、模型、資料相容與回退 | 1.11.0+29 有裝機及啟動收據。內置模型及映射與收據相符 | 來源、模型、相容資料及可回退版本均可追溯 | 回退前先核路線 schema 相容性 |
| S1 App 核心功能 | 即時辨識、菜單、戶外步行、場景描述及讀屏 | 已有主要流程。截圖卡住未定位，場景與讀屏待複驗 | 逐任務驗可用內容、停止、取消及恢復 | 核對真機故障、語音起音及讀屏 |
| S2 照片收集與人工覆核 | 同意、私人相片、標註及清理 | 覆核 API 和工作台已有本機合成驗證，功能預設關閉 | 權限、撤回、全圖覆蓋、修訂及獨立覆核可追溯 | 確認角色、部署及真人案例 |
| S3 私人訓練與模型更新 | 快照、worker、比較、registry 及回退 | iPhone 開發分支已有本機候選收集及覆核，補記憶及訓練閉環待接 | 相較共用模型或記憶補強有額外效益，預算、更新及回退可驗 | 先有核准資料及評估。付費 GPU 須有預算 |
| S4 室內錄路與引導 | 普通相機、樓層、轉層、重認、障礙及語音 | 自動取樣、標記、加密路線及逐點重認已有。方向播報及行走感知待接 | 錄製、保存重開及另趟重行，分報未知、錯層、漏報及恢復 | 補齊錄路餘項，驗 VoiceOver 及同層／跨層 |
| S5 圖示與設施理解 | B11、牌面 OCR 與箭嘴配對 | B11 最後有證據到第 22 輪，存取待核，未入 App | 正式 run、獨立留集、匯出及手機任務均通過 | 先核原 run 與 checkpoint |
| S6 限定場地整合驗收 | 三地路線、讀屏與資源交接 | 整趟實地驗收待做 | 獨立趟次核對定位、提示、操作、時效及恢復 | 彩明商場、調景嶺非付費區、HKDI 與選定接駁分驗 |
| S7 場地與平台擴充 | 更多場地、複雜路網與平台 | 擴充能力待實作及驗證 | 各功能有資料、相容性及獨立任務證據 | S6 通過後逐項擴展 |

| 功能／階段 | 實現方法、依賴及驗收 |
|---|---|
| B01 帳號與角色／S1–S2 | Google token → 本人 UID／profile → 獨立聯絡資料。由受權 Admin 賦權，驗訪客、跨 UID、token 刷新及撤權。 |
| B02 照片同意／S2 | epoch → 同幀 JPEG → 加密佇列 → 驗 UID、配額及格式 → generation 綁定。驗重送、登出與撤回。 |
| B03 人工覆核／S2 | 工作台＋七個 callable 保留原預測及修訂，雙人全圖 coverage 後核准。配置人員、索引、App Check 及容量後驗真人閉環。 |
| B04 私人快照／S3 | 用本人有效用途的核准版本及有授權回放，凍結來源分組、影像及標註 SHA。驗撤回與同源隔離，改資料建新快照。 |
| B05 排程及去重／S3 | 案例及效益通過後排程，以 UID＋snapshot＋config 去重並驗預算及充分性。測 lease、時限、重複事件。 |
| B06 GPU worker／S3 | 容器、權重與最小 IAM → 預檢、smoke、訓練、心跳及 checkpoint。先驗 mock、取消及超時。 |
| B07 品質門檻／S3 | 候選與現用逐類獨立比較、匯出 parity 及手機測試。核准服務驗版本化門檻，數值以 Dataset 為準。 |
| B08 Registry／S3–S5 | 核准後登記 scope、SHA、namespace、taxonomy、相容及評估。驗 A／B 映射與私人／共用隔離。 |
| B09 下載、更新及回退／S3 | 本人限時 offer → 驗 SHA／映射／端版本 → 閒置切換並留上一版。驗撤回競爭、改名同 SHA、登出及損壞。 |
| B10 撤回、刪除及到期／S2–S3 | epoch／tombstone 封存取再清原圖及問題。加入 worker 後連快照、外部副本、私人權重清理，驗遲到競態。 |
| B11 Android 步行代理／S1 | 固定 WALK／香港／繁中及 App Check、區域 Secret。驗簽署、逾時與配額，iPhone 走 MapKit。 |
| B12 發佈及預算／S0–S6 | 記安全 ID、版本、雜湊、階段、耗時及費用估算。驗遠端 tag／Release 方可裝機，另核真人結果。 |
| B13 室內即時資料／S4 | 同幀深度及物件留手機。按前端真機量尺、對位、失效驗收，序列上傳另取同意。 |
| B14 路線記憶及場地版本／S4–S7 | 有向路段、觀察、樓層來源及版本分開。驗重行位置與出口，場地圖與同步另驗資料、存取及離線。 |
| B15 路線錄製／S1–S4 | schema 4–8、加密媒體、失敗紀錄、文字／錄音備註、CAS 及容量／刪除互鎖。逐趟選填候選另用加密庫及獨立覆核修訂。驗重開、版本相容、下一趟重行、讀屏、收音及按需播放。同步待接。 |
| B16 額外登入／S7 | Apple／電話以 Firebase provider linking 維持原 UID。處理登入衝突，驗跨平台、刪除及同 UID 復原。 |
| B17 場景描述／S1 | Auth／App Check → 帳本預留 → 有界 JPEG → 完整驗證。驗有效許可、內容拒絕、取消、未知用量及讀屏起音。 |

## 9. 維護與追溯

2026 年 11 月 21 日補上私人場景 Profile 建置入口及共用開關配置。雲端試驗許可沿用既有獨立核准流程。

2026 年 11 月 20 日修正 iOS 既有版本目錄重用及加密錄音版本寫入，保留原有 catalog 原子切換和資料格式。

2026 年 11 月 20 日更新本機候選的上限、收集與覆核資料流、刪除互鎖及到期規則。[工程證據](../verification/route-learning-integration-20261120.json)

2026 年 11 月 20 日準備 `1.12.0+30` iPhone 工程預發版，內置模型及映射沿用 `1.11.0+29`。回退前須確認路線 schema 5–8 的相容性。

2026 年 11 月 20 日記錄通用 OCR 及菜單的同圖資料流與本機暫存。[工程證據](../verification/general-text-reading-20261120.json)

2026 年 11 月 20 日記錄 schema 8 的錄音格式、本機加密、容量及舊版讀取界線。[工程證據](../verification/route-audio-notes-20261120.json)

2026 年 11 月 20 日補記「閱讀文字」的本機暫存及清除條件。

2026 年 11 月 20 日記錄 schema 7 的文字備註與標記關聯、容量和讀取規則。[工程證據](../verification/route-text-notes-20261120.json)

2026 年 11 月 20 日記錄 schema 6 的失敗紀錄欄位及容量、草稿、刪除和舊版讀取規則。[工程證據](../verification/route-mark-failures-20261120.json)

2026 年 11 月 20 日記錄更多設施標記採 schema 5，以及舊版讀取界線。[工程證據](../verification/route-more-marks-20261120.json)

2026 年 11 月 20 日補記重行從現有 schema 4 讀取標記及方向的條件。重行沿用本機版本及媒體讀取契約。[工程證據](../verification/route-replay-marks-20261120.json)

2026 年 11 月 20 日補記路線版本啟用與真人重行驗收的關係。

2026-11-20 依程式、舊規格與最近收據整理。保留同意、覆核、保留期、路線相容、模型回退及發佈的有效規格。已到期的場景窗口按歷史許可標示。歷史逐版結果與診斷可從 Git 及 [verification](../verification/) 追溯。 [上一次整理證據](../verification/docs-current-cleanup-20261110.json)
