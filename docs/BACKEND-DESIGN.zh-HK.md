# 領路通 PathGuide 後端與雲端資料流程方案

更新：2026年10月28日。唯一Backend文件；[Frontend](FRONTEND-DESIGN.zh-HK.md)管理App，[Dataset Review](DATASET-REVIEW.zh-HK.md)管理資料與品質。功能／接口／部署改動必須同一提交同步更新本檔，不另開交接。

**後端把已同意的錯誤場景，經覆核、訓練與評估，轉成可回退的私人模型。** 上傳成功只代表收到照片，不代表已學會、變準或可以更新。

## 開發階段與目前進度

三份文件共用S0–S7階段編號。狀態只表示可追溯證據：**已有程式**不等於已部署；**待實測**不等於通過；**受阻**需先解依賴；**未開始／未來研究**不是現有功能。沒有足夠工作量與驗收資料前不編造完成百分比或日期。

S5的圖示訓練可與S2、S4並行準備；私人訓練必須先有S0品質基準及S2核准資料，S6整合驗收通過後才擴大S7範圍。當前主線仍是改善準確度，室內畫面不可取代品質驗收。

| 階段 | 本階段後端工作 | 目前進度 | 完成標準 | 下一步／依賴 |
|---|---|---|---|---|
| S0 工程基線與版本保存 | 固定契約、權限、設定、模型發佈及回退 | 1.4.0+5沿用原模型；分支＋不可變tag／prerelease已核對，之後安裝／啟動成功，舊版保留，場測未齊 | 可由tag＋相符模型重建；配置／密鑰不進Git | 覆核共用版本並以遠端commit／asset核實 |
| S1 現有App核心功能 | Google身分／聯絡與Android路線代理 | 帳號已有程式與使用者回報；Routes有程式但未接通／驗證 | 本人權限、重新驗證刪除與平台導航服務驗收 | 保留iPhone MapKit獨立；補部署及真機證據 |
| S2 照片收集與管理員覆核 | 私人上傳、同意、配額、清理與管理員標註 | 上傳／清理程式已有，本機關閉；管理員覆核服務未接通 | 同意→同幀照片→核准標註可追溯；越權／撤回被拒絕 | 先測試專案部署與權限，再接覆核工具 |
| S3 私人訓練與模型更新 | 快照、排隊、worker、評估、registry、下載 | 未接通；付費GPU預算未定 | 模擬完整流程、真實工作受配額控制、合格模型可本人下載／回退 | 先mock worker、資料接口與取消／刪除，再開付費執行 |
| S4 室內近距離感知與引導 | 只供版本／設定；不把即時深度送雲端推理 | 1.4.0+5同幀辨識與測距在iPhone記憶體處理；無室內雲端服務 | 離線空間感知不依賴後端；無深度／姿態上傳副作用 | 與Frontend確認接口，保留原照片用途界線 |
| S5 圖示／文字與設施理解 | 保存共用B版本／評估及相容性 | 只有本地／Drive實驗產物；正式run中斷，未核准發佈 | B合格後有獨立namespace、映射與手機相容發佈包 | Dataset完成來源／格式／逐類評估；不把失敗當ready |
| S6 HKDI整合驗收與試用發佈 | 日誌、預算、排程、權限／刪除與版本回退 | 完整學習閉環未部署／驗收 | 各種失敗可定位／重試，費用受控、遠端備份先於安裝 | 結合Frontend真機、Dataset品質及角色驗收 |
| S7 多場地、多樓層與平台擴充 | 場地圖／地標版本、選填同步、provider連結 | 本機typed graph／觀察原型已有；雲端及真實場地服務未實作 | 依場地／UID授權與版本相容性分階段驗收 | 先S6限定場景，未核准場地不開精確室內路由 |

## 各功能計劃如何實現

本節接口名稱若寫「新增」即尚未實作，不能當成目前已可呼叫的API。

| 功能／階段 | 目前狀態 | 實現方法與輸入／輸出 | 依賴／完成標準 |
|---|---|---|---|
| B01 帳號、角色與私人聯絡／S1–S2 | Google／聯絡規則已有；覆核角色未接 | 驗證token取得UID，以可重試交易建profile；聯絡資料保持獨立。新增覆核角色由受權Admin設定custom claims，服務端驗證，不接受前端自報admin或ownerUid | 本人／覆核者／一般訪客權限分開；角色變更與token刷新／撤銷有測試 |
| B02 照片同意與提交／S2 | callable已有，未啟用 | 沿用get／setPhotoConsent與submitPhoto；檢查UID、epoch、配額／尺寸，解碼重編碼、綁photoId／objectGeneration，再原子更新validated／pending。sourceSha與清理後sha分開 | 前端F05同幀資料；重試冪等、無效App Check／舊epoch拒絕，不改成公開Storage |
| B03 管理員覆核／S2 | 未接通 | 新增受權覆核操作，輸入photoId、版本、完整annotations與coverage及核准／拒絕理由；先提供可匯入覆核清單與原圖檢視的內部工具，服務端寫reviewedBy／time／version。模型預測另存，不能覆寫人工答案 | Dataset D02；不能只改狀態approved，全圖答案／來源／雜湊須有效；延遲AI寫入不破壞核准版本 |
| B04 私人快照匯出／S3 | 未接通 | 依ownerUid＋仍有效用途查核准版本，合併獲授權基礎回放，固定影像／標註版本、場景split、coverage與SHA，輸出不可變manifest；重送同一請求沿用snapshot ID | Dataset D03／D07；同實物不跨split，其他UID資料不得混入，資料變動建新snapshot |
| B05 排程、去重與佇列／S3 | 未實作 | 每日03:00香港時間檢查新核准資料與獨立驗證條件；以UID＋snapshot＋config建唯一job，交易取lease，綁GPU預算／單次時限。建立GCP Batch工作，記provider job ID，狀態由受權事件／查詢更新 | 缺預算不提交；同UID單工作、重複事件不重開；UTC照片配額日界保持不變 |
| B06 GPU訓練worker／S3 | 現有Colab實驗；服務未實作 | 容器固定工具／權重／設定，最小IAM讀指定snapshot，執行preflight→smoke→正式run；每輪備份checkpoint／optimizer／CSV及心跳。相同快照中斷才resume，改資料開新run；逾時／取消不發佈 | Dataset提供D04／D05／D07腳本；先mock成功／失敗／重試，再配置GPU；不把免費Colab當可靠無人服務 |
| B07 品質門檻與獨立評估／S3 | 只有本地A／B評估工具 | worker產生候選與現用模型的同資料逐類比較、樣本量、export parity及手機結果；核准服務驗完整報告並套版本化門檻，不能由worker一句success直接寫ready | Dataset第3節為門檻唯一來源；目標無真值或其他類別退化則不核准；測試集不拿來反覆調參 |
| B08 Registry與發佈包／S3–S5 | 未實作 | 新增不可變模型record：ownerUid／shared scope、job／snapshot、A或B namespace、權重／manifest SHA與大小、taxonomy、App相容性、評估與狀態；核准才設可下載，發布指標另指向可回退版本 | A／B映射不得互換；現行內置format:1不無聲改義；共用模型與私人模型有不同存取範圍 |
| B09 本人下載、自動更新與回退／S3 | 未接通 | 新增本人模型offer與限時下載授權；發票前重驗身分／用途／刪除狀態，URL只指向核准物件且不記完整URL日誌。App下載暫存、核對offer、SHA與映射後在任務停止時切換；保留上一版／內置版 | Frontend F08；逾時重取授權，跨UID／不相容／損壞拒絕。已簽網址有有效期，撤回後仍須處理過期窗口與物件清理 |
| B10 撤回、取消、帳號刪除與到期／S2–S3 | 第四階段清理已有；訓練資源未覆蓋 | 沿用tombstone／deleting，先禁止新上傳／job／下載，取消並等待或隔離worker，再按清單刪照片、annotations、snapshot、外部副本及私人模型，最後Auth；每步可重試並拒絕遲到重建 | 擴充現有deletePhotoAccountData；基礎共用資料不因單UID刪除而誤刪，處理中狀態可理解 |
| B11 Android搜尋／步行代理／S1 | computeWalkingRoute已有，未部署／驗證 | App Check驗應用，訪客可用；固定Google Routes WALK、HK／繁中與回傳欄位，Secret Manager供金鑰，逾時／配額分類；不接受任意網址代理、不持久保存軌跡 | Google配置、預算、簽署限制及真機；iPhoneMapKit不改走此代理 |
| B12 發佈、診斷與預算／S0–S6 | 1.4.0+5工程／簽署建置與遠端核對通過；之後安裝及啟動成功，舊版保留，場測待補 | 記匿名request／job ID、階段、耗時與錯誤類別，監察心跳、清理積壓、評估失敗與花費；提交前配額／worker時限與預算配置缺一拒絕。App發佈依第7節先GitHub再安裝 | 日誌無照片／私人位置／憑證；告警不等於硬性花費上限；回退演練與版本報告可追溯 |
| B13 室內即時資料邊界／S4 | 1.4.0+5辨識框與深度已本機處理，無雲端服務 | 深度／pose／網格留手機，不新增即時雲端避障API；只提供相容模型與設定。若日後要上傳序列，需獨立用途、保留／刪除及安全設計，不能沿用照片同意 | Frontend F09–F12與Dataset D09；關閉網絡不影響已載入的本機感知 |
| B14 拓撲graph、觀察序列與場地版本／S7 | 1.2.0+3本機Dart模型／樣例已有，無雲端API | IndoorGraph／IndoorNode／LandmarkObject／LandmarkObservation以固定ID、內容版本、scope與有界queue表達；手動node／edge先驗證；永久地圖、node內容與行程觀察分開版本化，圖片只產生候選對照。不吻合先保留未知與待覆核，核准後才更新地圖；量測座標／幾何校準及樓層連接後續加入 | F14／D09；不用GPS猜樓層，無場地資料不提供指定課室；場地更新不破壞舊App |
| B15 路線錄製／場景摘要同步／S7 | 後續構想 | 先本機功能；自願同步才新增UID版本化路標序列與刪除。場景摘要預設本機有效證據，不自動新增雲端影像描述或追蹤紀錄 | F17；另行確認用途與授權，不能因訓練照片同意便錄影／上傳路線 |
| B16 Apple／電話連結與跨平台／S7 | Google現行；其他未接 | 使用Firebase明確provider linking，在驗證後維持原UID與私人資料，處理已有帳號衝突，不以同電郵猜合併；Android與iOS使用各自App／簽署設定 | F18；重新登入、登出、刪除與相同UID恢復有雙平台證據 |

管理員角色依據：[Firebase custom claims](https://firebase.google.com/docs/auth/admin/custom-claims)；GPU工作／時限依據：[Batch GPU工作](https://docs.cloud.google.com/batch/docs/create-run-job-gpus)、[工作時限](https://docs.cloud.google.com/batch/docs/create-run-basic-job)。這些是規劃所用平台能力，未表示本專案服務已部署。

## 1. 已有程式與缺口

| 項目 | 現況 |
|---|---|
| 帳號 | Google Auth、本人 profile、選填聯絡人及規則已有程式；聯絡資料不加入訓練 |
| 照片 | getPhotoConsent、setPhotoConsent、submitPhoto、listPhotoProgress 已實作；本機照片開關關閉 |
| 清理 | deletePhotoAccountData、expirePhotoCandidates、removeLatePhotoObjects 已實作；既有文件記錄未部署，本輪未查詢雲端部署清單 |
| 導航 | computeWalkingRoute 已有 Google Routes 代理程式，與照片同意獨立；iPhone MapKit不依賴它 |
| 私人學習 | 管理員覆核、快照匯出、排程、GPU worker、registry及下載授權未接通 |

活動程式來源為 [Functions](../backend/functions/index.js)、[照片政策](../backend/functions/photo_policy.js)、[規則](../backend/firestore.rules)。舊firebaseCode-2的signed URL原型只作歷史參考，不是目前App接口。

## 2. 現行照片流程與資料

獨立照片同意 → 同幀JPEG與預測 → 綁定project／UID／consent epoch的加密待傳 → Wi-Fi callable提交 → 伺服器驗證與重編碼 → 私人儲存與待覆核進度。

- 單張JPEG最多2 MiB，沒有signed URL分配。相同UID＋photoId＋來源雜湊與epoch重試不重複扣額，物件禁止覆寫。
- 驗證Google身分、App Check、帳號狀態、同意epoch、解碼／大小及配額。移除EXIF／GPS／XMP；sourceSha256與最終雲端sha256分開。
- 配額以UTC計日：總候選100、自動50、場景10；自動至少相隔30秒、場景至少60秒。香港時間的訓練排程不更改UTC配額日界。
- 本機最多50張／50 MB、七日到期；未覆核雲端圖預設三十日，按小時每批最多200張清理。須監察錯誤與積壓。
- 本人只讀進度，不能寫核准標註、訓練或發佈狀態。預測可空、零分合法，不假造未知class。

| 資料 | 位置／狀態 |
|---|---|
| 照片同意 | 現行 users/{uid}/private/photoConsent |
| 照片／配額 | 現行 users/{uid}/photos/{photoId}、photoQuotas/{UTC日期} |
| 未確認JPEG | 現行私人 unconfirmed_photos/{uid}/{photoId}.jpg |
| 覆核／快照 | 規劃受權覆核服務寫入的版本化核准記錄 |
| 工作／registry | 規劃以ownerUid綁定，App只讀本人進度 |
| 私人模型 | 規劃 personal_models/{uid}/{modelVersion}/，僅授權相符UID |

## 參考體驗對後端的影響（方案分析，未部署）

公開產品列項與證據限制集中在Frontend「瞰見聆境」節；以下是我們的設計推論，不宣稱第三方後端採用相同架構。

- **路線內容改善：** B14／B15為graph／route另存node ID、內容版本、註記類型、來源、確認時間與有效期；臨時施工可失效／撤銷，店名變更保留位置身份。私人路標與場地共用變更分開授權，不能由一次觀察自動改公共地圖。
- **權重改善：** 維持B04–B09的UID快照、回放、獨立評估與模型registry；新增路線註記不直接觸發GPU或宣稱模型已學會。路線／內容／權重各有可回退版本。
- **同一旅程的多能力：** 導航、感知、查詢可共用session／mapVersion／modelVersion與過期檢查，但深度及即時障礙仍在手機。伺服器回覆慢時不能補播舊方向或覆寫新位置。
- **場景模型及下載：** 現行首版仍用本機有效證據摘要。若後續採雲端或大型本機模型，需另外確認供應商、圖片用途／保留、預算、下載相容性與斷網回退；本輪未開任何雲端影像服務。
- **聲音、手勢及背景：** F19／F22預設裝置端運算，不建立頭部追蹤上傳。F23若開發背景導航，需另定定位／音訊狀態與隱私說明；不把鎖屏路線語音等同背景鏡頭感知。
- **驗收及發佈：** 先用mock狀態驗證權限、版本、遲到事件與取消，再做HKDI實機／離線測試；競品的宣傳不作我們的品質門檻或驗收證據。

## 室內graph與照片序列資料設計（討論方案，待驗證）

先做手動graph＋模擬observation的原型，再接AI；不需要先完成大型VPS或向量資料庫。以下是設計分層，不是現有API／Firestore已支援的格式：

| 資料層 | 保存內容 | 更新規則 |
|---|---|---|
| graph | building／floor、mapVersion、node ID、實際通路edge及限制 | 只有核准的地點／連通性變更才發新版本 |
| node內容 | 同位置的objects、店名／別名、參考圖片、特徵版本、有效時間與證據 | 改店名不換位置ID；動態物件只作觀察，不當永久錨點 |
| 觀察queue | session、seq、capturedAt、圖片／特徵及候選node／可信度 | 是行程序列，按拍攝順序，不按Server回覆先後或預測node排序 |
| 配對結果 | matched／uncertain、候選、證據、mapVersion、觀察時間 | 低信心保留未知；不存在的精準位置／朝向不填假值 |
| 地圖變更候選 | 新地標、店名疑似改變、封閉或不吻合證據 | 覆核後才升格；模型自己猜的結果不直接變地圖真值 |

最小node示例（尚未量測的位置保留null）：

```json
{"id":"L1_N03","floor":"L1","position":null,"objects":[{"type":"shop","name":"店面A"}],"referenceImages":[],"contentVersion":1}
```

渲染用的示意layout與真實公尺座標分開；若加入x,y，必須同時記原點、座標系、單位及量測來源。edge先驗實際連通，同層雙向用無向邊；單向、封閉、樓梯與升降機後續獨立屬性，不一律當雙向。

定位處理流程：觀察入queue → 用最後可信node／樓層／路線選graph鄰域 → 比較最近多筆候選與允許轉移 → matched或uncertain → 需要時擴大搜尋。保留停留、跳node、倒行和分岔，遲到回應不能覆蓋新位置；不確定時不強制選「預測的下一個node」。

每5秒上傳屬新增的定位用途，不能直接套私人訓練照片API：現有自動照片冷卻30秒、場景60秒且有日額。後續若採Server定位，須獨立同意／session／限流／短保留策略；定位圖片預設不加入私人訓練或共用地圖，地圖建庫與私人模型亦非同一批資料。

後續AI可加入全局檢索、局部特徵及OCR；純圖片鄰近node只能支持拓撲候選，精確PnP仍要已知3D點與相機內參，不能由node ID直接求得公尺級pose。[OpenCV PnP](https://docs.opencv.org/4.x/d5/d1f/calib3d_solvePnP.html)；完整3D建圖／匹配路線可參考 [hloc](https://github.com/cvg/Hierarchical-Localization)。iPhone沒有通用Wi-Fi掃描API，因此初版粗篩先用使用者選定場地／樓層與可信起點，不把任意SSID指紋當既有能力。[Apple Wi-Fi API說明](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview)

## 3. 管理員覆核與自動批次（待實作）

管理員透過受權限保護的工具補漏修框；原始預測與人工答案分開。保存覆核者、時間、定義、授權及影像／標註雜湊。只有核准且用途仍有效的資料可進快照；流程依 [Dataset覆核](DATASET-REVIEW.zh-HK.md)。

每天香港時間03:00檢查：每UID至少50張新增核准圖、三個場景及獨立驗證資料；滿足才建立不可變快照及工作。資料不足、未同意或預算未設定時不提交GPU。

採Firebase記錄／排程、私人Cloud Storage及GCP Batch容器GPU worker。首版私人微調限相容十類A與獲授權基礎資料回放，不混別人的私人照片；B保持獨立共用模型。

工作保存jobId、ownerUid、快照、基礎權重、設定／容器版本、run ID、checkpoint、心跳、取消旗標、評估及錯誤。以UID＋快照＋設定去重，交易取得lease；同UID不得同時訓練兩份。恢復使用同一快照，資料改動另建run。

狀態區分資料不足、待覆核、queued、running、evaluating、ready、failed、cancelled；評估不合格不能寫ready。門檻見Dataset覆核，不憑訓練成功自動發佈。現用十類gate=false只屬試驗，不自動升格為已核准基礎模型。

**GPU預算待定，付費提交預設關閉。** 先完成模擬worker的成功、失敗、重試與取消。部署前設定專案、可用區域／GPU、單次時限、每日額度、併發及預算；缺設定即拒絕提交，不能用告警冒充停止計費。

## 4. 私人發佈、自動更新與回退（待實作）

訓練 → validation比較 → 凍結候選／獨立驗收 → 格式及映射檢查 → 核准registry → 本人授權下載。不合格保留原版本，報告同時寫改善與退化。

發佈記錄含ownerUid、jobId、snapshot、模型與manifest雜湊／大小、taxonomy、相容App及評估版本。私人發佈envelope與現行內置format:1分開，不假稱目前parser已支援新欄位的完整驗證。

使用者可另行預先同意自動更新；未同意則手動選擇。僅App前景且辨識／導航等相機任務停止時下載至暫存，驗UID／雜湊／映射／相容性，試載入後原子切換。保留上一個私人版本與內置備援，失敗回退。此決定取代「每次都必須手動啟用」。

App／共用模型完成後先推GitHub commit、tag／Release並核對，再安裝交付。私人照片、權重及含私人資訊報告留在受權限保護的儲存，不進共用repo；私人registry保留歷史版本供本人回退。完整版本程序見本檔第7節。

### 1.2.0+3本機graph資料邊界

目前只增加App內的typed Dart資料與樣例，不部署Firestore、Storage、callable或Server定位服務。`IndoorGraph(id, version, floor, nodes, edges)`保存不可變node與開放／封閉無向edge；`IndoorNode`保存固定ID、名稱、contentVersion與objects，各object的已核准aliases先正規化再配對；同一node的不同object不可共用匹配key，避免同一個詞被當成兩份證據。畫圖layout另存，不是可輸出米數的x,y。

`LandmarkObservation`含sessionId、sequence、capturedAt、graphId、mapVersion、floor與landmarks；樣例`ReplayEvent.receivedAt`模擬回覆收到時間。GraphReplaySession最多保留50筆、拒絕跨session更新、忽略較舊序號；scope／時間不符撤回目前位置。未知或改名候選不會寫入永久圖。版本欄位和N08別名只示範資料分層，沒有實作地圖編輯、審批、雲端registry或自動升版服務。

本機回放無帳號、無照片／GPS擷取、無影像／路徑／深度上傳，也不讀取現有私人照片佇列。5秒是樣例capture時間間隔；自動顯示每秒一筆，兩者都不是新增拍攝API。未來實拍／Server adapter需另訂用途、配額與授權，不能沿用訓練照片同意。付費GPU仍停用。

## 5. 撤回、刪除與失效

- 關閉收集停止本機擷取／待傳；另提供個人訓練及自動更新控制，worker在排隊、取資料、續跑與發佈前重驗授權。
- 刪除先建保護、停止新工作／下載，取消並等待或隔離worker，再清理照片、標註、快照、第三方匯出及私人權重，最後移除身分。遲到事件不得重建資料。
- 現有deletePhotoAccountData只涵蓋第四階段；加入worker／registry後必須擴充，不能假稱已涵蓋未有資源。
- 室內深度、姿態、網格留本機；照片同意不擴大為持續影片、GPS或軌跡上傳。方向短片另行授權。

## 6. 後端驗收

- [ ] 身分／App Check、跨UID、舊epoch、影像及額度會拒絕；重送不重複照片或工作。
- [ ] AI不能覆寫人工答案；未核准／拒絕／授權不明的資料不入快照。
- [ ] 缺預算不提交；lease、逾時、心跳失效、checkpoint續跑及取消有測試。
- [ ] 不合格不發佈；本人下載、閒置切換、損壞回退與切帳號正確。
- [ ] 刪除與訓練／下載競爭不復活舊資料；私人產物不進GitHub。
- [ ] 共用版本遠端備份完成才交付，舊tag與對應模型可重建。

## 7. 部署、設定與版本回退

帳號與照片服務分開配置；目前本機照片開關關閉，既有紀錄未部署照片服務，本輪未讀取雲端清單，不以文件代替部署驗收。

- iOS：啟用Google provider並註冊相符bundle ID，取得手機端GoogleService-Info.plist。在app目錄執行下方設定工具；不用管理員私鑰，不能把本機設定提交Git。

```sh
python3 tool/configure_firebase_ios.py /完整路徑/GoogleService-Info.plist
./tool/run_iphone.sh
```

- 上傳：先確認計費／預算、Storage bucket、Functions區域（現有callable為asia-east2）及App Check，再覆核Firestore／Storage規則與索引。測試用debug attestation只限測試；正式版不發佈debug token或放寬規則。部署與實際測試通過前PHOTO_UPLOAD_ENABLED保持false。
- 在backend/functions安裝依賴後執行pnpm test；backend根目錄的pnpm test跑Firestore／Storage Emulator，需Node22、Java21及pnpm。Emulator與真實專案分開，呼叫handler的測試不代表雲端App Check閘道已通過。
- Android：需Java17與Android SDK、Google Play服務、相符Firebase Android App及簽署SHA、Maps／Places受限金鑰，設定範本在app/config/navigation.android.example.json。現有SDK固定Maps19.2.0、Places5.1.1、Location21.3.0，實際建置仍待驗證。
- Google Routes憑證放Secret Manager，代理設定GOOGLE_ROUTES_API_KEY；只在服務與App Check驗證後啟用NAVIGATION_GOOGLE_ENABLED。iPhone MapKit不需Google Routes部署。Google路線只顯示在Google地圖，Apple路線在Apple地圖。
- 正式公開導航前，補營運者／聯絡方式及可用政策網址，設定NAVIGATION_PRIVACY_URL與NAVIGATION_TERMS_URL。下方草稿重點不能當已發佈政策。

每個App／共用模型版本：完成檢查 → 增加App版本／build → 提交程式、lockfile、對應模型／映射及三份文件更新 → 建不可變tag（v版本+build）／Release → 推送並核對遠端 → 才安裝交付。Release記錄模型SHA、評估、限制與重裝方法；實驗版標prerelease，不覆寫tag、不force push。

倉庫為https://github.com/actiondarr/pathguide，既有工作分支feature/cross-platform-navigation。小型共用模型隨Git，過大共用產物用Release asset並記SHA及精確版本；私人照片／權重不得進共用repo。保留舊tag、模型及相容資料；回退App需重建並有效簽署，必要時用新的遞增iOS build號。私人模型則由本人授權registry保留上一版。

文件整併的歷史提交不冒充新App還原點。本輪1.1.0+2包括中英文與導航／辨識共用語音、當前試用模型及manifest，247項Flutter測試與未簽署iOS編譯通過。不可變tag `v1.1.0+2`；歷史源碼／模型還原點 `v1.0.0+1-baseline` 指向 `f9dfb494ac3bc9a470337d15cde6a5c67018aac9`（舊hkdi10 pilot模型，不冒充已重新驗收版本）。遠端分支／tag核對與Release狀態另存verification的機器紀錄。

版本發佈使用正常Git推送，以及有效的gh登入或GitHub已登入網頁流程；不從OS憑證庫抽出Git token作API登入。Release列模型SHA、試驗限制、測試、重建與回退方法；現有本機Firebase設定不入Git。CLI登入無效時，本版用正常GitHub網頁建立prerelease。

## 8. 導航資料與使用說明（發佈前草稿重點）

導航只在使用者啟動與App前景取得位置；暫停、背景或結束停止定位，不建立／上傳行走軌跡。Apple／Google會收到完成搜尋及路線所需查詢、起點／目的地；代理不持久保存完整座標／路線，診斷避免私人位置。

語音按鈕才收音；優先裝置端，線上服務先取得本次同意，不把導航或錄音加入模型訓練。收藏／最近十個地點在本機安全儲存，可清除，不跟帳號同步；Google項目以Place ID、使用者標籤與時間保存，再查地點。

路線可能有誤差、延遲或入口不符，不保證樓梯／升降機可用，不提供過路時機、室內樓層或鎖屏導航。接近終點仍需確認入口，資訊不代替白杖、導盲犬或定向技能。Android需已配置服務、網絡與適當權限。

供應商參考：[Google Maps條款](https://maps.google.com/help/terms_maps/)、[Google私隱](https://policies.google.com/privacy)、[Apple地圖條款](https://www.apple.com/legal/internet-services/maps/terms-en.html)、[Apple私隱](https://www.apple.com/legal/privacy/)。正式政策需補聯絡及變更通知方式，不能以本章冒充已公開條款。

## 9. 維護紀錄

2026-10-27：帳號／照片契約、部署、隱私草稿重點、訓練／更新及GitHub回退整合於此。本輪沒有部署、開收集、提交GPU或改App功能。每次功能／接口／部署變更直接更新本檔現況、設定、驗證與限制。


2026-10-27階段化補充：加入S0–S7分工及B01–B16實現路線，標示現有callable與待新增的覆核／快照／worker／registry／場地服務，列明輸入、輸出、依賴與驗收。下一輪先S2權限／部署與覆核，再用mock完成S3；預算未定不提交付費GPU。本次沒有部署或改接口程式。

2026-10-27 graph討論補充：為B14定義graph、node內容、observations queue及覆核變更的分層；5秒Server定位需另立用途與配額，不能冒充既有照片服務。新增schema僅供概念驗證，本輪未實作／部署。

2026-10-27參考產品補充：將路線內容、私人權重、session與模型下載分開設計，保留本機即時感知與用途界線；新功能仍屬候選，不新增上傳／背景服務或改部署狀態。

2026-10-27整合版：App語言只在本機SharedPreferences保存；導航中的辨識不建立照片／observations／深度上傳或新增Cloud API。照片上傳仍關閉，付費GPU仍停用。1.1.0+2包含已核對共用模型；以正常Git備份分支／tag、GitHub網頁建立prerelease，未安裝交付；工程驗證不代表真機／模型精度已通過。

2026-10-27發佈核對：App源碼commit `687d40188c117e7764cd71b063e834b23763682d` 已推至既有分支；以 `git ls-remote` 核對分支及兩個tag的實際commit。[1.1.0+2試用Release](https://github.com/actiondarr/pathguide/releases/tag/v1.1.0%2B2)及[整合前還原點](https://github.com/actiondarr/pathguide/releases/tag/v1.0.0%2B1-baseline)均經正常GitHub網頁建立並核對，沒有抽取憑證。產物含相符源碼／模型與manifest；無簽署IPA，未安裝手機。機器收據：verification/release-receipts/app-1.1.0+2.json。後續文件核對提交不移動App tag。

同日交付核對：GitHub核對後才簽署，包內1.1.0+2、模型SHA與manifest相符；正常系統信任服務簽章驗證、CoreDevice安裝及啟動成功。無IPA公開下載；裝置ID、安裝路徑及簽署資料不寫入公開收據。見verification/release-receipts/app-1.1.0+2.json；App tag與權重沒有變動。

2026-10-28 graph版：1.2.0+3加入純本機graph／內容／觀察資料模型與回放，雲端服務、UID資料及GPU均沒有變動。274項Flutter測試及簽署iOS建置通過；版本備份包含同一mixed10試驗模型與manifest，舊1.1.0+2保留。先核對遠端tag／prerelease，再安裝；收據放verification。

2026-10-28 graph版發佈核對：正常Git推送及ls-remote核對分支／tag指向 `95d7cdae1a97adf255a73e19cbc58994bc3c36f0`，[v1.2.0+3 prerelease](https://github.com/actiondarr/pathguide/releases/tag/v1.2.0%2B3)由正常網頁建立並核對；不移動舊tag。先備份後才嘗試裝機，CoreDevice首次回報手機仍鎖住／太久未解鎖；使用者解鎖後，重試安裝及啟動成功，沒有改裝置安全設定。去識別化收據保存於verification/release-receipts/app-1.2.0+3.json。

2026-10-28 graph版交付完成：先核對本機包1.2.0+3及相同模型SHA，再依既有GitHub備份安裝；使用者解鎖後CoreDevice安裝及啟動成功。收據已更新，App源碼tag仍為95d7cda，沒有移動tag或重訓／部署雲端服務。

2026-10-28 測距試驗版：1.3.0+4的hk.pathguide/depth方法／事件通道只在iPhone本機，start帶session識別，回傳狀態；事件帶同session、單調幀時間、ageMs、狀態，可信時另帶rangeM（徑向）、planeZM、accepted／total及spreadM。不是Cloud API，不持久保存影像／深度／pose／行走序列，沒有呼叫訓練照片上傳或改用途。本機PHOTO_UPLOAD_ENABLED仍關閉；無GPU／訓練／registry部署。版本、相同模型及三份文件依第7節先GitHub分支／tag／prerelease核對，再安裝。尚無物件融合、空間音效或真實graph定位；構建／安裝不代表實地精度。

同輪1.3.0+4工程核對：294項Flutter、12項原生數值檢查、analyze及iOS簽署建置通過；包內版本與模型manifest／SHA相符。verification/app-1.3.0+4.json保存構建證據，後續GitHub與裝機收據另記，App tag不移動。

同日1.3.0+4發佈交付核對：正常Git推送後，ls-remote核對分支與v1.3.0+4均指向6a0e65203dd1804f5682bae2d8a88116f769795a；GitHub網頁建立並核對[試用Release](https://github.com/actiondarr/pathguide/releases/tag/v1.3.0%2B4)的標題／tag／commit。先備份再安裝；首次鎖機受阻，使用者解鎖後成功安裝及啟動。去識別收據在verification/release-receipts/app-1.3.0+4.json，公開內容不含裝置ID／安裝路徑／簽署資料。App tag不移動，後續文件提交只更新交付證據。

2026-10-28 物件距離版：1.4.0+5延伸本機hk.pathguide/depth契約，start帶objects模式、threshold、已校驗的內置權重cache路徑／SHA／bytes／classIds／classes／inputSize；原生再次核對才建立模型。不是外部下載／私人模型offer，不新增Cloud API。靜態內置權重快取放App support的PathGuideDepth，以SHA命名；只寫共用模型，沒有照片／深度／pose／UID資料。背景停止會作廢尚未完成的準備或啟動。

物件事件status=objects，附同session／timestamp／ageMs、viewWidth／viewHeight／rotation及最多5個objects：專案class id、score、已裁切預覽box、reason，可用時另帶rangeM／planeZM／accepted／total／spreadM。score是物件模型分數，不是距離可信度或正確率；rangeM是框內代表表面的徑向米數。短時track ID只在Dart當次session作配對，不寫永久graph／觀察資料庫。原有sample準星事件保留，兩種模式不能混用米數。資料不持久保存／上傳；訓練照片用途／同意／配額及PHOTO_UPLOAD_ENABLED=false不變，無付費GPU工作。

本版依既有先GitHub分支／不可變tag／試用Release核對、後安裝的程序保存；最新構建及交付收據見verification/app-1.4.0+5.json、verification/release-receipts/app-1.4.0+5.json。保留v1.3.0+4與舊版，沒有移動tag、部署室內服務或修改雲端訓練。

同輪1.4.0+5工程核對：完整314項Flutter、11項iOS原生XCTest、25項距離／座標／色彩數值檢查通過，analyze無問題，最終iOS簽署建置、系統簽章及包內版本／模型相符。verification/app-1.4.0+5.json記錄構建快照；發佈／裝機由收據更新。不是實地辨識、量尺精度或VoiceOver驗收。

同日1.4.0+5發佈交付核對：正常Git推送／ls-remote核對分支與tag指向26fa41eeca58b9554efd81d964455bb652628004，正常GitHub網頁建立及核對prerelease。備份後CoreDevice安裝／啟動成功，收據verification/release-receipts/app-1.4.0+5.json；公開資料不含裝置ID、安裝路徑或簽署憑證。文件／收據提交不移動App tag，沒有新雲端部署或費用。

2026-10-28 1.4.1+6修正版：物件本機事件新增samplePoint（當次預覽normalized座標）、validDepth／depthTotal與細分reason；前端展示原因與點數，不把它們當正確率。深度信心／量程／混合表面／過期門檻不變，僅改框內局部取樣選擇及遮擋檢查；取樣位置改變重新累積時序證據。本機不新增影像／深度記錄或Cloud API、照片上傳仍關閉，無GPU／訓練工作。使用者提供測試截圖未放GitHub／dataset。318項Flutter與33項數值檢查的構建證據見verification/app-1.4.1+6.json，最新GitHub／手機狀態由release-receipts記錄；舊tag保留。

同輪1.4.1+6最終核對：318項Flutter、33項原生數值檢查、analyze、簽署建置、系統簽章及包內版本／原模型SHA通過。先保存GitHub分支／tag／prerelease，再交付；最新裝機狀態由verification/release-receipts/app-1.4.1+6.json記錄，未將合成回歸當真機問題已解決。
