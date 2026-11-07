# Backend：PathGuide 資料、服務契約與交付

更新：2026年11月6日。只維護資料／服務／部署規格；使用者流程與導航主線集中在[Frontend整體規格](FRONTEND-DESIGN.zh-HK.md)，模型品質集中在[Dataset Review](DATASET-REVIEW.zh-HK.md)。
**2026-11-06現況：Codex直接開發及驗收，保留較早DSH失敗歷史而不再派模型。1.8.0+15自動草稿及樓層來源／必要確認已通過516項Flutter、54項原生、analyze及兩軸覆核；最終簽署建置／模型與App程式雜湊及不可變GitHub tag／prerelease核對後，iPhone更新安裝／正常啟動成功，資料保留。1.7.0+13曾獲使用者回報卡住；新版真人複測仍待回報，沒有新增雲端部署、訓練或同步。**
**2026-11-06新增規格：** [已錄路標持續改善規格](https://github.com/actiondarr/pathguide/issues/19)已確認及發布；路標改善候選、真正權重訓練及更新閉環仍未實作／驗收。原有A／B、雲端與手機交付狀態不因此升格。


**狀態用語：**「已確認需求」是產品決定；「待定」是尚未有答案；「已有程式／工程已驗」不代表真機或產品驗收；「已交付」須有版本收據。研究／候選能力不因列入文件就成為本輪實作或付費授權。

閱讀順序：[責任](#service-scope) → [現況](#service-state) → [資料流／契約](#data-contracts) → [驗收](#service-acceptance) → [依賴](#service-plan) → [部署／版本](#release-process)。

<a id="service-scope"></a>
## 1. 服務目標與責任

後端把已同意的問題，經覆核、修正與獨立評估，轉成可追溯、可回退的改善。共用模型與私人微調分開授權及驗證；上傳成功只代表收到資料。

| 資料／能力 | 邊界 |
|---|---|
| 基本辨識及已錄室內路線 | 本機優先，不以帳號、雲端問答或私人訓練為前置 |
| 私人路線 | 已走路標／有向路段及版本；不自動同步或加入訓練 |
| 雲端看圖 | 另取用途同意，只送必要內容；provider／預算／保留政策待定 |
| 問題回報及覆核 | UID／同意版本／角色隔離；核准資料不等於模型改善或發佈許可 |
| 模型更新 | 獨立品質及相容性通過後提供；保留閒置切換及回退 |

<a id="service-state"></a>
## 2. 現況與已確認限制

<a id="1-已有程式與缺口"></a>

### 已有程式與缺口

| 項目 | 現況 |
|---|---|
| 帳號 | Google Auth、本人 profile、選填聯絡人及規則已有程式；聯絡資料不加入訓練 |
| 照片 | getPhotoConsent、setPhotoConsent、submitPhoto、listPhotoProgress 已實作；本機照片開關關閉 |
| 清理 | deletePhotoAccountData、expirePhotoCandidates、removeLatePhotoObjects 已實作；既有文件記錄未部署，本輪未查詢雲端部署清單 |
| 導航 | computeWalkingRoute 已有 Google Routes 代理程式，與照片同意獨立；iPhone MapKit不依賴它 |
| 人工覆核 | 七個問題／覆核callable與本機工作台已有；有分頁待辦及修訂歷史，預設關閉；真實人員／容量／部署未驗收 |
| 私人學習 | 快照匯出、排程、GPU worker、registry及下載授權未接通 |

活動程式來源為 [Functions](../backend/functions/index.js)、[照片政策](../backend/functions/photo_policy.js)、[規則](../backend/firestore.rules)。舊firebaseCode-2的signed URL原型只作歷史參考，不是目前App接口。

下一版三任務驗收不依賴新增私人訓練服務。現有15個Functions export中，新增七個涵蓋問題接收、本人進度／撤回、人工覆核、分頁待辦及修訂歷史；均未部署、預設關閉。本機工作台已完成合成操作驗證，容量／抽覆／爭議裁定、修正案例後半段及私人模型拒用／撤回仍是規劃；既有照片上傳開關保持關閉。

<a id="route-landmark-learning"></a>
### 已錄路標私人批次訓練契約（2026-11-06，規格已確認／未接通）

服務現況不變：[已錄路標持續改善規格](https://github.com/actiondarr/pathguide/issues/19)已發布，路標訓練、快照／worker／registry／更新尚未實作或部署。新增路標用途獨立於A物件認錯／漏認，不能直接擴用現有照片同意、十類coverage或A／B模型namespace。基本本機路線不依賴此服務，普通重行不累積影像；只有明確改善模式才留有界候選，真人行程後核實。

擴充時沿用UID／App Check、purpose及consent epoch、request／revision、SHA／generation、到期／撤回／刪除契約；提交另綁route／version、trip、candidate及review revision。只收另同意的必要已核實資料，不自動上傳全部記憶或影片，不跨UID混訓。原預測與人工答案分離；覆核A物件的現有API不冒充路標真值服務。

先人監督的單批實驗與效益比較，再接排隊／worker。不可變快照及owner＋snapshot＋config去重，單owner有效lease、取消／恢復及預算檢查需可驗；不套用舊A模型03:00／50張三場景規則。真實provider、限額、時限及並發未配置不提交付費GPU，本次也未開啟任何服務。

核准registry／offer綁本人scope、模型／index／profile SHA、訓練來源及獨立評估。若特徵空間變更，先由合法原始關鍵幀重建相容索引；缺資料保留舊組合。導航停止後完整驗證並原子切換model＋index＋profile；失敗回退完整舊組合，不將不同特徵空間互相比。撤回阻止新快照、在途發佈及新下載；受影響候選停用／回退，不聲稱已訓練權重可精確移除單張影響。離線副本限制明示。

服務驗收沿用Emulator外部權限／revision／重試／撤回先例，新增核實提交→snapshot→worker→評估→offer→App更新／回退的整合邊界；資料不足／不合格不出offer。模型hash改變、job完成或收到照片均不是品質證據。私人原圖、權重及評估內容不得上共享Git。

### 本輪核對的服務邊界

Functions現有15個export：原有computeWalkingRoute、getPhotoConsent、setPhotoConsent、submitPhoto、listPhotoProgress、deletePhotoAccountData、expirePhotoCandidates、removeLatePhotoObjects，加上submitPhotoIssue、getPhotoIssue、getPhotoReviewItem、submitPhotoReview、withdrawPhotoIssue、listPhotoReviewQueue、listPhotoReviewHistory。問題／覆核API及工作台只完成本機／合成驗證，預設關閉、未部署；容量／抽覆、snapshot、排程、GPU worker、registry及私人下載尚未接通。本機照片／Google導航開關未設，沿用false；iPhone MapKit獨立。

照片部署最近證據為[2026-10-23紀錄](../verification/baselines/2026-10-23.phase4-verification.json)，不能當今日雲端清單。每日03:00、50張／三場景是規劃條件，未有運行中的排程；付費GPU不提交是目前政策與未建服務的狀態，不能稱已有經驗收的預算阻擋器。

### 目前問題：A10改善流程與發佈界線（2026-10-31）

本機兩個4 epoch候選及免費T4的6 epoch候選均未通過品質比較；訓練／保存／評估可完成，不等於模型變準。現階段問題是資料及驗收證據不足，未有可發佈的新權重；沒有新registry／offer、App模型更新或私人訓練服務。詳細問題及數字見[Dataset目前問題總結](DATASET-REVIEW.zh-HK.md#目前問題總結2026-10-31)。

Colab在本次明確授權後掛載Drive，固定run `20261030T162638Z`已完成，候選、設定、evaluation及summary保存在原擁有者的`PathGuide/a10-repair-20261030-v1/runs`。只新增56張既有CC BY 2公開來源照片；私人legacy影像沿用已有壓縮檔，未重新上傳、未進共享Git。原run及B11未操作；這次掛載授權不等於私人訓練服務的永久授權。

後續先完成資料覆核與獨立驗收定義，再決定下一個修正實驗。Colab只作互動實驗，不能冒充B06可靠無人worker；付費GPU仍停用。LLM用量主要來自改程式、看圖及讀工具輸出，訓練迴圈不呼叫LLM；雲端運算不會自動減少token，採批量執行／最後摘要以減少中途讀取。本次review整理沒有新增訓練或部署。

開發工具的DSH隔離smoke已有工程證據，不代表App後端已部署。既有回報／工作台以本機及Emulator驗證為主，正式部署及真人閉環仍待確認。

<a id="data-contracts"></a>
## 3. 資料流與實作契約

### 路線錄製／跨樓層步行導航的本機契約與選填雲端（P0／P1本機已驗；真實整合待實作）

2026-11-05 P2-C已提供本機原生相機來源：request／session／generation、route／version、sequence及原生clock epoch／對映綁觀察。只在明確取幀時回長邊1280／512KiB有上限的正向JPEG及SHA；最新觀察僅含header，沒有逐幀JPEG、檔案或上傳。native工程幀齡1000ms且walkingValidated=false。這不是持久RoutePackage媒體schema、雲端endpoint或訓練用途同意；Flutter入口留P2-D，加密媒體及配額留P3。接口見Frontend P2-C節與[機器證據](../verification/codex-p2c-route-camera-20261105.json)。

個人路線以本機首次錄製／重行為主，跨樓層及行走期間障礙／語音是正式主線；首次錄製建立App未有的路線，不要求使用者預先熟悉地方。基本功能不要求帳戶或雲端，操作及兼容範圍以[Frontend完整方案](FRONTEND-DESIGN.zh-HK.md#route-memory-plan)為準。既有照片API／工作台仍只屬本機驗證，沒有因此部署。一般iPhone路線記憶不以新YOLO權重、訓練服務或LiDAR為前置；行走物件提醒仍須獨立通過模型品質。

2026-11-05需求對齊：基本辨識及已錄室內路線重行採本機處理，複雜看圖問答可另取同意選用雲端；分析照片不自動取得問題回報或訓練用途授權，各用途分開。完整產品新增陌生室內逐段探索方向，以現場線索及確認推進，不把雲端文字回答當目的地座標／已核實路段。探索可在另行確認保存後形成私人路線記憶，並非自動加入訓練或同步；其搜尋／失敗策略仍在對齊，本輪未新增endpoint或部署。

正式裝置端契約以P0合成邊界為起點，完整格式於P1–P4補齊：RouteMemory保存路線ID／版本、起終點、已錄方向及有向路段；LandmarkNode保存穩定位置ID，RouteObservation另存session／sequence／捕捉時間、候選node、影像特徵產生器／revision／前處理版本及確認來源。Observation與node、路線版本分開，無公尺量測時不填假座標；既有class ID與無向樣例graph不直接當新路線記憶格式。MatchResult最少區分matched／unknown／ambiguous，只有符合當前session、路線／特徵版本、時間及方向的結果可交導航控制器；AI自由文字不能直接變方向指令。

N0現碼為RouteMemory／LandmarkNode與ObservationTicket＋RouteMemoryController，固定synthetic-v1特徵revision及recorded方向；票據包含session／sequence／routeId／routeVersion／capturedAt，拒絕錯版本／未來／超過15秒或非預期路標。這些只支援合成互動，尚不是完整RouteObservation或SceneAnalyzer的真實影像契約；P2接相機前需再凍結生成器／前處理、確認來源與正式儲存格式。

N0仍為記憶體mock；P1另立本機加密樣例庫，可保存／重開／回退／刪除合成路線結構，沒有正式雲端endpoint、照片或影片。自動候選不改已確認穩定路線，清理路線不影響照片佇列或帳戶。未來自願備份／同步另定UID隔離、保留與刪除，不沿用照片收集同意或默認公開地圖。平常重行不按次保存影像；錄路／明確更新才留有大小、數量及總庫上限的必要關鍵幀／特徵，實際媒體由P2–P3接入。

SceneAnalyzer以本機實作／mock先驗證；可選雲端只做必要關鍵幀的場景描述與候選核對。provider、金鑰管理、授權／配額、每次／每session費用上限、保留及失敗策略確認後才接真實服務；目前未選provider、未給視覺API預算，DSH程式派工的US$0.10不是雲端看圖費用授權。明確同意後才送圖，撤回／取消後丟棄晚到結果，不把私人路線相片默認加進既有training photo流程。

N0、P0及P1是獨立付費包，各已耗用兩張票據。P1經使用者明確選擇US$0.10／兩次／20分鐘後派發；DSH頁面／測試均經主控修正，原稿不直接當已驗收。下一包P2相機狀態UI，範圍及費用另定；不接帳戶、不開公網服務或自動部署／裝機。使用者指定先功能、後系統優化，主控先接相機／錄路／障礙語音，沒有額外訓練／模型授權。

#### DSH後續實作責任與主控驗收（2026-11-05）

使用者最新要求DSH負責後續全部實作／測試／修正，Codex只做詳細計劃、接口驗收、diff覆核及機械整合；包含相機、語音、媒體儲存及整合，取代舊「Sol寫關鍵程式」分工。已有P0／P1作者與證據不改。完整P2–P5包的實際檔案allowlist、命令、完成／停止及交付要求見Frontend「DSH實作、主控審核的詳細執行計劃」及`configs/planning/dsh-functional-execution-20261105.json`。

目前橋接只有固定文字diff，工具被禁；DSH不能自行操作檔案／Xcode／測試，主控執行驗收時保留程式作者及真實exit/log，不冒稱worker自行測過。每包task/session、contract／prompt／runtime／dirty source SHA、票據及終態獨立；原稿只為delivered_unreviewed。主控可機械正規化diff／格式化，不改功能語意，失敗附反例回DSH。兩次無進展即停，不用新包洗掉同一錯誤的重試上限。

P2四個依賴包各兩次／US$0.10／20分鐘，整階段US$0.40／八次候選仍待批准；P3–P5及視覺雲端費用未授權。獲批後只在上限內綁前包接收SHA逐包派發，不接管Desktop已有session，不讀key、不部署／開公網。P1加密及catalog規則是不可退化依賴；P3 captured schema須保留synthetic v1、驗媒體引用／時鐘／feature profile及總quota，不以放鬆schema把合成結果當真路線。Keychain／OS備份政策、UID隔離及刪除跨blob競態列交付覆核；雲端仍另取同意。

#### P1本機加密版本庫（2026-11-05，合成結構已驗）

使用App support下獨立`route_memory_v1`及`pathguide.route_memory.library.aes.v1`裝置金鑰，與照片佇列／UID及其清理規則分開。AES-256-GCM的AAD綁device-local用途、catalog或routeId／version；路線名稱／樓層及catalog內容加密，版本檔另核cipher SHA及明文manifest SHA。RouteDocument schema1固定synthetic／recorded方向；draft可缺floor，完整結構需building、樓層、有向連接及確認旗標齊備，仍不是實地核准。P1當時只存合成結構；真實媒體由下節P3-A schema2擴充，不改標schema1。

同目錄temp寫入、flush、rename後最後切加密catalog；不可變版本與active／draft pointer分開。CAS revision防止舊列表覆寫新內容；epoch綁定store owner，刪除另作廢同route舊寫入。持久刪除紀錄先於清檔；重開只信catalog，不掃孤兒檔恢復路線。catalog損壞不自動倒回舊catalog，避免恢復已刪路線；單一版本損壞保留並可明確回退至核實版本。寫入結果未知只重新讀取，不自動重送；金鑰遺失不重建覆蓋原資料。

P1當時每份JSON256 KiB、每route8版本、整庫32 MiB，P3-A擴為下節有界媒體政策；均連暫存計算；超限拒寫，清理須明確操作，保留active／一個有效回退／當前draft，不重用舊version號。actor在同一main isolate按實體路徑串行，另用非阻塞OS檔鎖拒絕其他process；不支援不同isolate獨立writer。[Dart檔鎖](https://api.dart.dev/dart-io/RandomAccessFile/lock.html)在POSIX是process層級，不能當isolate互斥；[rename](https://api.dart.dev/dart-io/File/rename.html)要求同檔案系統的流程，真機斷電耐久性尚未驗證。OS備份排除／Keychain真機行為亦未驗；目前只證明本機故障注入及fake vault重開，不承諾重裝／跨裝置還原。

21項store／adapter、6項controller、6項UI、2項screen及全App415項通過，analyze無問題。未新增endpoint、App雲端上傳、訓練資料或權重；見[P1證據](../verification/dsh-p1-route-store-20261105.json)。

### #18 樓層上下文及必要位置確認（2026-11-06，1.8.0+15候選）

在#17自動草稿上，明確按樓層按鈕會補拍有身份的確認點；其後候選只「沿用上下文」，與此點確認、整段核實及未知分開。確認面板開啟時只取最近10秒內分析完成的最多5個樓層文字候選作快照；G／1F／2F／3F快捷按鈕、其他樓層選填及「唔肯定繼續草稿」均可讀屏，未接App語音輸入。轉層入口可選升降機／樓梯／扶手電梯補拍；入口之後撤回目前上下文，到出口須明確再確認。文字矛盾（即使相片重複）、未知、暫停、背景、保存或重開均不沿用目前樓層；過往證據保留作歷史，不等於現在位置。

保存採captured schema3，記floorEvidence（unknown／confirmed／inherited／segmentConfirmed）、floorAnchor及確認點角色。schema1／2仍可讀，沒有來源的新舊語意不混用；舊App拒讀schema3，不能靜默丟掉來源後變完整路線。沿用或整段核實必須引用較早的有效確認點、相同樓層身份／標籤，不能跨非步行設備；未知來源／自指／缺anchor／不符樓層拒絕。schema1／2帶新來源欄位亦拒絕，避免降格丟資料。原加密、媒體配額、CAS、舊版／回退及刪除不變；新版本引用舊照片的捕捉版本不改義。

沿用樓層的點仍不完整。站定暫停後可明確核實「由確認點起這一段全部同層並按錄製方向實際走過」，只核實該界線內的步行段，保留整段確認來源；不核准其他確認點以外的未知段或轉層連接。轉層連接仍須明確修正確認，不能只憑出口樓層自動認證設備／路徑。改名不改樓層來源；更改確認點／中間點的樓層或路段種類會令相關沿用資料及確認失效。這是錄路上下文，不是已定位或每點真值。

本輪516項Flutter、54項原生、analyze及兩軸覆核已通過；涵蓋G確認→自動沿用→未核實不能啟用→整段核實→schema3加密保存／重開、轉層／矛盾／未知撤回、修改來源點失效、舊格式及錯誤新格式，以及中英文320×568兩倍字體實際樓層／設備按鈕流程。簽署及交付狀態見verification/floor-context-20261106.json；1.8.0+15已通過簽署建置／簽章／模型雜湊核對，分支及不可變tag／prerelease核對後已更新安裝／正常啟動。場地／無LiDAR／VoiceOver真人及自動取樣覆蓋、物件提示／VLM／P4語音仍未驗收，不把本片當#16全完成。

### #16／#17 自動草稿錄路第一片（2026-11-06，來源候選，未交付手機）

使用者已確認：樓層無法確認時繼續未確認草稿，稍後補資料。#17先接開始一次→試驗每5秒候選→光線／細節篩選及去重→自動編號候選路標→結束命名→明確保存／重開。本片所有自動樓層及路段保留未知／未確認，不能啟用為完整重行路線；相似度不是位置證明。品質screen只在最長邊64px評估曝光15–240及鄰接亮度差≥4，與上一保留特徵distance<2或同JPEG則略過；這些是未校準工程參數，不是已凍結選幀政策、清晰度或轉角覆蓋保證。

沿用單相機／單工作、取消與世代隔離；不追補忙碌期間取樣。自動最多48視角，沿用原64上限並預留16視角手動補記；達上限明示停止自動取樣。手動表單及待重試輸入暫停自動取樣，背景／離頁／暫停／保存／dispose停止排程，失敗停下供明確繼續；沒有自動刪除／上雲。僅保留選中候選JPEG／特徵，重行仍不存新照片。自動名稱非AI語意名稱，正式路標／必要事件與繼承樓層證據介面仍屬#16後續；重要轉角／轉層仍須手動補記。不是只增加Timer便稱自動建路完成。

本片已過498項Flutter、analyze及兩軸覆核，僅保存來源檢查點；尚未發布App，手機仍為1.7.1+14修正版，該版真人複測仍待回報。S4／F17（Backend B15）自動草稿為來源候選；尚未有連續樓層上下文、必要確認語音、實地轉角覆蓋、模型比較或本地VLM性能證據。未下載模型、訓練、採集私人資料或部署服務。驗證詳見verification/automatic-draft-20261106.json。

#### P3-B特徵及候選資料契約（2026-11-05，工程及手機fixture已驗）

P3-B原生核心產生真正Vision feature print revision1，固定upright JPEG／scaleFit；有界secure archive外包schema1、featureRevision=vision-featureprint-v1、preprocessRevision=upright-jpeg-v1及Vision revision，整包≤64KiB。比較驗包內／呼叫版本及VN observation實際revision，損壞或不相容不回部分結果；距離不是正確率。P3-A仍把完整feature blob作opaque bytes加密並綁SHA，未更改已存synthetic v1或金鑰。

OCR按runtime版本／語言能力提供有界文字候選，永不直接寫actual floor。Dart核心把同building/floor/node多視角合併後判斷未知／歧義／錯層；需fresh ticket加明確樓層與方向確認；跨層出口還要綁定已錄exit node／connector role，房間路標不能代替出口。工程門檻8／gap2／5秒不代表行走可靠，caller須傳保守frameAge；camera／store／平台通道及旅程UI接線由P3-C處理。沒有新endpoint、雲端服務、私人照片採集或訓練。驗證及硬件fixture結果見[P3-B證據](../verification/codex-p3b-landmarks-20261105.json)。

#### P3-A媒體版本、容量與裝置政策（2026-11-05）

新增schema2 captured及獨立加密JPEG／feature blob，schema1 synthetic、原目錄／路線金鑰／既有AAD保持可讀，既有route身份不改source。node/view引用綁明文SHA及byte count、JPEG實際尺寸、保存UTC、捕捉來源元資料與feature/preprocess revision；catalog綁每個版本／blob的cipher SHA，媒體AAD另綁route/version/media SHA。Feature在本票視為有revision的有界opaque bytes，尚未接Vision提取或定位；結構啟用不等於可實地導航。

明確錄製／更新才寫媒體，重行read/readMedia不增加影像。先作完整引用／JPEG／SHA及配額預檢，再寫各加密暫存／版本，最後切catalog；中斷、取消、刪除及未知提交結果沿用CAS／epoch／tombstone語意。刪除涵蓋所有媒體版本；明確歷史清理保留active／有效fallback／draft的blob引用，損壞但仍被引用的檔案不靜默清走。

固定JPEG512KiB、feature64KiB、node4視角、route64視角、JSON256KiB、route8版本；route磁碟64MiB、整庫256MiB，連加密開銷、草稿／歷史／暫存／catalog計算。整庫上限內留最多2MiB供catalog維護；額滿保留穩定pointer、拒絕新增，沒有自動上雲或刪歷史。凍結設定見[媒體儲存政策](../configs/planning/codex-p3a-storage-20261105.json)。

iOS原生通道只接受App support路線／隔離probe命名空間及已知檔名，拒絕路徑穿越、symlink、任意穩定檔覆寫及超大寫入。新檔建立即Complete保護，寫入／rename後重設備份排除，既有P1只補政策不改密文。金鑰沿用WhenUnlockedThisDeviceOnly／不同步；資料屬裝置本機且排除OS備份，不承諾重裝／跨裝置還原。依據Apple [檔案加密與保護](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)及[備份排除屬性](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup)，仍須用真機檢查實際屬性，不用Simulator不可用的保護等級冒充通過。

工程probe只用人工生成JPEG及opaque feature fixture，目錄與Keychain purpose均獨立，分app process寫入／重開／刪除後清理probe；只回報屬性／計數及結果，不讀取或上傳私人照片／金鑰。此票沒有endpoint、雲端部署、照片訓練或新權重。實際結果見[P3-A證據](../verification/codex-p3a-route-media-20261105.json)，完整錄路／定位／導航及人手驗收留P3-B～P5。

#### 跨樓層步行導航資料與服務契約（P0合成子集已實作）

本節是Frontend P0–P6的資料及生命周期邊界；下表完整格式仍不是雲端API或已完成的持久schema。N0的RouteMemory／LandmarkNode保持無floor，獨立P0新增FloorRef／FloorNode／FloorEdge／FloorRoute、FloorObservation、PerceptionFrame、GuidanceEvent與CrossFloorController。FloorRoute只接受building一致的相鄰有向邊，walk不能跨floor，其他邊需connectorId；不推斷反向。觀察分location／perception序列，綁journey／generation／routeId/version／clockEpoch及單調捕捉時間；跨session、版本、方向、未來／過期回覆被拒。P0固定p0-synthetic-v1，沒有圖像blob、模型推論或真確認來源；正式序列化／加密／ownership於P1、取幀與來源版本於P2–P3、真播音於P4補齊。不能把mock的version=1當正式持久格式。

P0分開expected／candidate／actual floor；先確認fresh樓層候選，再確認fresh出口及方向才更新actual。轉層撤回舊樓層及事件；障礙優先級3覆蓋路線級2，過期frame轉perceptionUnavailable，不復播舊指令。缺有效深度不允許米數；分類與深度信心未接真模型。背景／暫停／刪除作廢兩支序列，前景只刷新控制，不恢復導航；子頁owner dispose亦作廢。2秒／500ms只是合成測試窗，畫面時鐘凍結，不能接真實行走輸入。沒有讀帳戶、寫磁碟或新增endpoint。27項P0／全App380項及analyze通過，見[P0覆核](../verification/dsh-p0-cross-floor-20261104.json)。

| 規劃資料 | 最少欄位／規則 |
|---|---|
| RoutePackage | schemaVersion、routeId／routeVersion、device-local owner scope、buildingId、路線名稱、起終點、方向變體、nodes／edges／observations索引、feature／preprocess版本、draft或可重行範圍、manifest SHA。穩定版不可變，active pointer另存 |
| FloorRef | buildingId＋穩定floorId、顯示名稱、確認來源與時間；未知為null／unconfirmed。G、M、UG、B1等只是標籤，不按字串／高度自動排序 |
| LandmarkNode | 固定nodeId、FloorRef、名稱／固定objects、內容版本、不同方向／光線觀察引用；相似外觀但不同樓層不可合併 |
| RouteEdge | edgeId、from／to node、walk或stairs／elevator／escalator類型、實際已走方向、通行／關閉狀態、connectorId、來源／目的floor引用；實測長度可空。walk不能無聲跨floor，缺轉層端點的edge不得導航 |
| FloorTransition | connectorId、入口／出口node、來源／預期目的floor、目前已確認floor、設備類型、方向／可行性來源及版本。預期目的地與目前樓層分欄，升降機可跳層，樓梯平台不等於樓層 |
| RouteObservation | observationId、journey／session／generation、sequence、單調捕捉時間及clockEpoch、保存UTC、source／方向、routeVersion、frame／JPEG SHA、feature request revision／preprocess／尺寸、OCR候選、可選pose／tracking／相對高度；自動候選不寫成確認答案 |
| MatchResult／FloorEstimate | matched／unknown／ambiguous、候選node與floor、不同來源證據、當前版本／時間／方向、有效期／失效原因。跨樓層續行需已確認floor及出口路標；路線先驗不壓過相似樓層歧義 |
| PerceptionFrame | 同幀session／seq／捕捉時間、模型SHA／profile、detections及短時track、可選深度／pose及其有效性；分類score不是深度信心。缺距離為null，不使用未知class ID代填 |
| GuidanceEvent | eventId、journey／generation／routeVersion、eventKind、priority、目標node／floor／track、來源seq、monotonic expiry、reasonCode及本地化參數。文字由受控規則產生；AI自由文字不直接成步行指令 |

轉層狀態：walkingOnFloor→approachingConnector→transitioning→awaitingFloorConfirmation→relocalizingExit→walkingOnFloor；任一步可到unknown／paused／cancelled。離開設備不代表到達預期層；錯層、相似出口、AR重設、氣壓漂移或OCR衝突（包括路線未錄但有明確樓層格式的字樣）會阻止續行。原則上可在已確認的中途路標重定位，不把N0回起點mock變成正式跨層恢復策略。回程需另驗視角／方向，不能默認所有連線雙向可靠。

原生CameraCoordinator管理取用權；新增RouteObservationSource與WalkingPerception adapter，但不是另開競爭相機。現有VisionFrame只有偵測結果，新的原生觀察契約另建，保持舊辨識／菜單／測距方法語意。Swift處理最新幀偵測／可用深度及節流後關鍵幀OCR／features，Flutter只接必要精簡事件；session、取消、時序與停止屏障由Sol負責。普通ARKit與LiDAR分開能力檢查；無AR／無Motion授權時仍可明示路標及樓層確認。

旅程級GuidanceArbiter接路由及感知：有效急需障礙／感知失效提示優先於當前轉層／轉彎，再到一般環境。每次派發及播出前重驗來源、世代、版本與有效期；停止／背景／新路線作廢舊事件，恢復後不補播queue。VoiceOver／TTS擇一路，現有僅environment／navigation的coordinator需擴充而不能宣稱已具危險優先。

##### 本機保存、刪除與資料用途

- 選App私有route-memory命名空間，以已裝path_provider、cryptography的AES-GCM及flutter_secure_storage／Keychain作裝置端版本保存；路線金鑰與照片佇列分開。此為新store，不直接複製目前會刪無效照片的queue實作。
- 新版本先寫暫存blob與manifest，核SHA／schema／引用完整性，最後原子切換active pointer；中斷保留最後穩定版。draft未確認轉層不得顯示整條可導航。清晰關鍵幀與feature blob只保存用途必要部分，原始影片／持續音訊不預設保存。
- feature revision／前處理不符時拒比；可從仍獲授權的本機關鍵幀明確重建features為候選新版本，不能無聲改永久node、floor或路線。無法重建時提示補錄，不猜相容。
- 刪除先作廢route epoch及所有observer／語音／儲存回覆，再移active pointer及路線檔案；原子寫入／回退／刪除操作串行，晚到寫入不能復活。重啟不得將殘存暫存檔當可用路線；不刪不相干照片、收藏、模型或其他路線。
- 訪客基本版是明示的本機路線庫，不綁Google登入，不因登入自動遷移／上傳。若日後提供UID私人同步，須獨立owner namespace、授權及登出／刪除規則；不複用現有personal_model_photos同意。裝置金鑰遺失／重裝恢復限制要在P1驗證並說明，不能默認已可iCloud／跨裝置還原。
- 本輪不新增Firebase endpoint、VPS、藍牙信標、LLM每幀推理或付費GPU。可選雲端仍依原同意／provider／配額計劃；已建立本機路線不以雲端回覆作繼續行走前置。室外新搜尋／重新規劃斷網能力另驗，不因室內本機運作而承諾整個MapKit流程離線。

##### 派工與可審查交付

P0先由Sol固定types／狀態／取消與floor信任邊界；DSH只承接最多兩個新檔案的小UI或fixture包，優先完整來源文字回收、由主控產生diff及SHA，避免模型手算hunk。若改交付格式，先改本機閘門的提示規則並跑離線測試，不能忽略既有diff-only guard。每包綁base＋dirty依賴SHA、允許檔案、驗收命令、請求／費用／時間上限及停止條件；不用新paid smoke重做既有橋接往返。

本地統計／影像評估／重播用腳本，主控只看摘要／異常及必要樣本。相機、幾何、語音、版本及刪除由Sol主導；真人場地與視障驗收不能交AI自稱通過。同時最多兩位寫檔者，worktree或檔案範圍分隔；Xcode／裝機／同一GPU只一位負責。使用者此輪要求先完成規劃，以上工作包尚未開始。

<a id="2-現行照片流程與資料"></a>

### 現行照片流程與資料

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
| 問題／覆核 | 已有服務程式：users/{uid}/photoIssues/{reportId}及其revisions／requests；部署未啟用 |
| 快照 | 未實作；不能直接把approved回報當訓練或發佈許可 |
| 工作／registry | 規劃以ownerUid綁定，App只讀本人進度 |
| 私人模型 | 規劃 personal_models/{uid}/{modelVersion}/，僅授權相符UID |

<a id="3-管理員覆核與自動批次覆核api本機驗證部署排程未啟用"></a>

### 管理員覆核與自動批次（覆核API本機驗證；部署／排程未啟用）

管理員透過受權限保護的工具補漏修框；原始預測與人工答案分開。保存覆核者、時間、定義、授權及影像／標註雜湊。只有核准且用途仍有效的資料可進快照；流程依 [Dataset覆核](DATASET-REVIEW.zh-HK.md)。

#### 最小覆核工作台與問題追蹤

先指定受權管理員負責接件／初覆、複核角色負責抽查及爭議裁定；尚未指定處理者、沒有覆核容量或覆核定義不完整時，保持待處理。小型試驗可由同一管理員分兩次覆核並記限制，重要爭議需另人裁定；AI預標或Codex視覺篩查不等於human_approved。

工作台最低提供：私人原圖、拍攝時預測／模型與profile版本、問題主張、同源群組；修框／補漏／改類，逐類coverage及全圖檢查；退回／拒絕理由、編輯歷史、抽樣複核與待辦排序。只有來源／用途有效、幾何及映射有效、指定覆蓋類別全圖標完、無待裁爭議、reviewer及版本齊備才可核准。不能只把pending改approved。資料充分性與品質gate仍由Dataset判定。

| 規劃狀態／操作 | 規則、責任及失敗後去向 |
|---|---|
| submitted→pending_review | 驗證成功才入待辦；以UID＋reportId冪等，傳送成功只顯示已收到。照片現有validated／pending不等於已完成人工覆核 |
| in_review→needs_information／disputed | 編輯綁expectedRevision，衝突回報並重讀，不覆蓋他人結果；歧義列明缺甚麼證據。使用者不補資料可保留待評估或撤回，不影響基本辨識 |
| in_review→approved／rejected | 核准固定annotationRevision、coverage、定義、reviewer／time；拒絕用可理解理由。晚到AI預測不能覆寫人工答案，修訂核准版本需新revision並重驗引用快照 |
| approved→development→candidate→evaluated→device_retested→closed | 每一步保存issueId、資料／模型版本及證據連結；訓練完成不是問題已解決。不合格可回development，與無效／授權撤回的終止狀態分開 |
| retryable_failed／cancelled／withdrawn | 網絡失敗以原requestId重試，核准修訂用新版本；取消／撤回即阻止新快照／工作，晚到事件不能復活。需人工裁定／權限失敗不自動無限重試 |

問題callable首版只接reportKind=misclassified／missed，與原照片的samplingTrigger、預測結果分開；App尚未呼叫。距離不對／文字配錯仍是後續契約，現有submitPhoto繼續只支援manual_report／low_confidence／scene_sample。距離回報另附自願提供的裝置／讀數／量測真值來源，文字回報另附OCR與配對修訂；無真值只算待查主張。任何AR幀、深度、序列或菜單影像用途須另明定，不能無聲擴大現有JPEG照片同意或將產品截圖當訓練圖。

保存每張實際處理時間、待辦量／最老待辦時間、退回／爭議率、複核不一致率及抽樣漏標；用途到期、撤回及刪除與工作台清理相連。抽樣複核先涵蓋每位reviewer／各問題類型及高風險類別，比例與放行規則在試驗前固定，低一致性重開相關批次。啟用前按人手配置待辦上限與告警；積壓達上限可停自動抽樣，手動回報明示待處理，不承諾即時修復，也不影響核心辨識。這些服務與指標尚未運行。

#### 已實作的問題／覆核API及本機工作台（2026-10-29，預設關閉）

程式：[photo_review.js](../backend/functions/photo_review.js)、[review_policy.js](../backend/functions/review_policy.js)。B03的接件／覆核契約已接本機工作台；待辦與修訂歷史以相同權限檢查讀取。沒有實作容量／抽樣複核服務、訓練、模型更新或已解決案例。

| callable | 身分／主要輸入 | 行為與界線 |
|---|---|---|
| submitPhotoIssue | 本人Google＋App Check；expectedUid、reportId、photoId、consentEpoch、reportKind、appVersion、modelSha256、inferenceProfile | 綁現有validated且未到期的私人JPEG；UID＋reportId冪等，每照片限一件。只收misclassified／missed，空預測可收漏認；回pending_review／revision=0，沒有自動判定FP／FN |
| getPhotoIssue | 本人Google＋App Check；expectedUid、reportId | 讀目前status／revision、photoId／reportKind及退回理由，供重試／撤回；不回覆核者身份、標註草稿或原圖 |
| getPhotoReviewItem | 指定覆核人員；expectedUid、ownerUid、reportId、選填includeImage | 回拍攝預測／模型、回報主張及目前標註；includeImage=true才以base64回指定generation且SHA相符的私人JPEG，下載後再驗角色／同意／revision，沒有公開下載URL |
| submitPhotoReview | 指定覆核人員；ownerUid、reportId、requestId、expectedRevision、action、humanReviewed=true及expectedUid | start接件，save另存標註，needs_information／dispute／reject須理由，approve由另一位adjudicator複核。衝突回aborted及currentRevision，不能靜默覆蓋；AI無權透過預測欄位覆寫標註 |
| withdrawPhotoIssue | 本人Google＋App Check；expectedUid、reportId、requestId、expectedRevision | 撤回問題並作廢核准指標；舊請求重試只回目前狀態及原appliedRevision，不恢復舊approved狀態。另行撤回全部照片用途仍走setPhotoConsent |
| listPhotoReviewQueue | 指定覆核人員；expectedUid、status、limit（1–25）、選填cursor | createdAt／隨機queueKey最舊優先；每件在交易內重驗同意、照片及刪除guard，跳過撤回／過期／本人回報。游標只含時間、隨機key及status，不含UID／路徑；無效候選可能造成空頁，仍可繼續下一頁 |
| listPhotoReviewHistory | 指定覆核人員；expectedUid、ownerUid、reportId、limit（1–20）、選填beforeRevision | 由新到舊讀不可覆寫修訂及當時標註；每頁重驗角色、用途／epoch及期限，不因曾讀過原圖而略過檢查 |

服務須明確設定PHOTO_REVIEW_ENABLED=true才接請求，預設false。覆核者須同時具token及當前Auth的photoReviewer=true custom claim、未停用／撤銷登入，以及server-only的photo_review_operators/{uid}紀錄（enabled=true，role=reviewer或adjudicator）。紀錄及問題／revisions／requests由現有規則一律拒絕客戶端直讀／寫，角色只可由受權Admin設定；本輪未指定人員或開啟旗標。不得自覆本人的照片；此首版採兩位人員分工，尚未實作同一管理員兩次覆核的選項。

save的annotation含taxonomyVersion=pathguide.a.mixed10.v1、definitionVersion、sourceGroup、coverage（專案ID）、fullImageReviewed及annotations；每框只收projectClassId／cx／cy／w／h且須在原圖內。核准要求十類全coverage＋全圖人工確認、有效定義／來源群組欄位及不同標註者的複核角色。humanReviewed是受權操作者的聲明，服務不能自行證明人已逐圖檢查；來源定義、分組真實性及覆核抽查仍須人工驗收。爭議保持disputed，本輪無自動裁定；無development／candidate／closed操作，核准不等於已修正或可發佈。

每個變更以單一Firestore交易保存目前revision、不可覆寫的revisions/{revision}、requestId雜湊收據及照片進度；原圖generation／SHA、原預測與回報主張不改寫。重開已裁定結果須adjudicator及理由，產生新revision並撤銷當前核准指標，舊核准修訂保留。未實作snapshot引用失效服務，因此不能將這些記錄接入真實訓練。

全部回報只限既有personal_model_photos用途，sharedTrainingAllowed=false，核准scope=personal_development_only；不授予共用訓練權。模型SHA／inferenceProfile等新增拍攝資訊標為client_reported，不能作已驗證的手機執行證據。距離／文字回報、AR／菜單影像／深度、私人模型發佈另訂契約。

問題、修訂及重試收據沿用原照片30日expiresAt；核准不延長保存。每次讀／改先驗有效用途、epoch、帳號刪除guard、照片到期及generation／SHA綁定；到期工作遞迴刪問題及子記錄，再刪指定generation原圖及照片。帳號刪除沿用UID樹遞迴清理。撤回即阻止服務存取，實體資料按刪除／到期流程清理，不宣稱即時抹除所有副本。

本機測試證據見[backend-photo-review.json](../verification/backend-photo-review.json)。使用Firestore／Storage Emulator及合成JPEG，Auth當前角色查詢用測試替身；不代表真實App Check閘道、Auth撤銷傳播、真人覆核、工作台的真人操作、積壓控制或雲端部署已驗收。啟用前仍須指定人員／定義／capacity、完成真實角色／App Check／工作台及刪除驗收，再選一個真實問題由Dataset接續。

#### 本機覆核工作台的操作與連線

來源在backend/workbench/，沒有新增對外網站或Hosting部署。提供狀態篩選／最舊優先／分頁、私人原圖與唯讀預測框、拖曳新增框、數值改框／改類／刪框、同源群組與定義、逐類coverage及全圖確認、接件／退回／爭議／拒絕／雙人核准，以及分頁修訂歷史。不能由此直接訓練、關單或發佈模型。

在backend目錄，使用Node22、Java21與已安裝依賴：

```sh
pnpm workbench:build
pnpm workbench:demo
```

Demo只允許demo-pathguide-phase3及127.0.0.1的Firestore／Storage Emulator，啟動後於[本機工作台](http://127.0.0.1:4176/)提供三張明示合成JPEG及兩個模擬人員。它呼叫同一createPhotoReview服務，角色／Auth為測試替身，不修改真實PHOTO_REVIEW_ENABLED、不讀真實帳戶或照片；重開只重設workbench-demo專用UID的合成資料，不清整個Emulator。pnpm的esbuild安裝腳本保持false；由已安裝平台binary建置Firebase瀏覽器adapter已通過。

正式連線另用pnpm workbench:serve。須先在ignored的backend/workbench/config.local.json填Firebase Web公開設定（firebase.apiKey／authDomain／projectId／appId、選填messagingSenderId）及appCheckSiteKey，authDomain須為相符projectId.firebaseapp.com。server拒絕管理員私鑰或其他未知欄位；只供本機靜態頁，正式呼叫由瀏覽器Firebase SDK經Google登入及App Check直接送往asia-east2 callable，不經本機Admin代理。登入用inMemoryPersistence，沒有token貼上欄位，不把token、原圖、標註或草稿寫入localStorage／IndexedDB。

正式使用前仍須部署新增Functions及photoIssues的status／createdAt／queueKey複合索引、指定兩位人員、固定定義／抽覆規則及人手容量、登記正式Web App／App Check及核對IAM／授權網域，最後驗真人Google登入、App Check閘道及撤權。這些尚未執行；本機可操作不代表正式服務已可用。

儲存以原requestId重試不明結果；revision衝突保留本機草稿，重讀及比較後才明確再提交。換帳號／登出／離頁會清除原圖URL、狀態、標註及隱藏DOM；舊帳號的遲到回覆不套入新畫面。草稿及待確認請求只在記憶體，重開後不保證保留，須重讀伺服器；已取得的影像離線時不能保證即時得知遠端撤回。部分coverage可保存草稿，但工作台與服務均不讓它核准。

本機server只綁127.0.0.1，拒絕錯誤Host、跨站請求、非同源JSON寫入及超過256KiB的demo body；檔案使用白名單，回覆no-store及CSP。正式模式沒有demo寫入代理。瀏覽器已驗合成接件、完整coverage、數值修框保存、拖曳畫框保存、換人核准與固定歷史；390px畫面無水平溢出，1280px雙欄版面已目視。證據在verification/backend-photo-review.json及verification/ui/backend-review-workbench.jpg；這不是實拍人工覆核、資料獨立性或品質改善證據。

#### 先完成一個可追溯修正案例

首例可選「某類門經常漏認」，實際issue與資料尚未選定，不能宣稱已完成。人工回報→獨立真值覆核→同源分組→用途有效的開發快照→候選→與現用模型在另一批未訓練場景比較→手機重測；每步用上述ID及版本串起。私人資料預設只在本人授權範圍，若要共用模型使用須另有共用訓練授權；授權不足仍可做私人研究，不能混入共享產物。完整驗收方法見Dataset。

第一個案例先人工觸發及mock驗錯誤／取消／回退，證明流程有效後才接自動排程。私人微調另外先與現用及改善共用模型做對照；若額外效益不足或證據不確定，保持共用改善路線及本人資料隔離，不擴大每UID worker／registry服務。

#### 自動批次的後續啟用條件

每日香港時間03:00、每UID至少50張新增核准圖／三場景是後續規劃的排隊檢查起點，**不是樣本充分或可發佈的證據**。另須有Dataset預先固定的獨立實體／場景覆蓋、不確定範圍及任務指標規則；未達即資料不足／待評估。排程需在修正案例、私人效益、mock閉環、權限／刪除與預算驗收通過後才啟用，目前未運行。

採Firebase記錄／排程、私人Cloud Storage及GCP Batch容器GPU worker。首版私人微調限相容十類A與獲授權基礎資料回放，不混別人的私人照片；B保持獨立共用模型。

工作保存jobId、ownerUid、快照、基礎權重、設定／容器版本、run ID、checkpoint、心跳、取消旗標、評估及錯誤。以UID＋快照＋設定去重，交易取得lease；同UID不得同時訓練兩份。恢復使用同一快照，資料改動另建run。

狀態區分資料不足、待覆核、queued、running、evaluating、ready、failed、cancelled；評估不合格不能寫ready。門檻見Dataset覆核，不憑訓練成功自動發佈。現用十類gate=false只屬試驗，不自動升格為已核准基礎模型。

**GPU預算待定，付費提交預設關閉。** 先完成模擬worker的成功、失敗、重試與取消。部署前設定專案、可用區域／GPU、單次時限、每日額度、併發及預算；缺設定即拒絕提交，不能用告警冒充停止計費。

<a id="4-私人發佈自動更新與回退待實作"></a>

### 私人發佈、自動更新與回退（待實作）

訓練 → validation比較 → 凍結候選／獨立驗收 → 格式及映射檢查 → 核准registry → 本人授權下載。不合格保留原版本，報告同時寫改善與退化。

發佈記錄含ownerUid、jobId、snapshot、模型與manifest雜湊／大小、taxonomy、相容App及評估版本。私人發佈envelope與現行內置format:1分開，不假稱目前parser已支援新欄位的完整驗證。

使用者可另行預先同意自動更新；未同意則手動選擇。僅App前景且辨識／導航等相機任務停止時下載至暫存，驗UID／雜湊／映射／相容性，試載入後原子切換。保留上一個私人版本與內置備援，失敗回退。此決定取代「每次都必須手動啟用」。

#### 能載入、效果合格及使用者接受分開記錄

規劃registry分候選／評估通過／核准可提供／撤回版本，裝置另外記下載／試載入／啟用及使用者拒用狀態；載入成功不能改寫評估結果或滿意度。offer綁owner scope、modelVersion／SHA、evaluationProfile、資料／報告版本及有效期；宣稱改善必須對應Dataset同條件報告，更新說明列實際改動與限制。

| 失敗或回退情境 | 規劃處理與驗收 |
|---|---|
| 下載中斷／空間不足／SHA錯／不相容 | 保持原active pointer，暫存可清理／依版本重取；不重複排工作或假顯示已啟用。重開App核實最後有效版本 |
| 更新成功但體驗變差 | 讓使用者選回上一版或內置，在任務停止後原子切換；選填原因，未提供也可回退。記from／to SHA、profile、App版本、時間及結果；不要求上傳影像 |
| 拒用後再次輪詢／改名offer | App以UID安全保存scope＋SHA的拒用紀錄，呈現offer及啟用前均過濾；同內容換版本名仍不再自動提供／啟用，明確恢復才解除。服務端僅在本人另行同意同步偏好後過濾offer；本機無網絡亦可回退，未同步不保證跨安裝延續拒用紀錄 |
| 發佈者撤回版本 | 核准者提供原因與撤回版本；停止新offer／授權／重試，已下載裝置下次得知撤回時提示並停用受影響任務，閒置切到仍核准上版或內置。離線無法保證即時收到撤回，不宣稱已即時清除所有副本 |
| 切帳號／登出／授權失效 | 作廢下載與啟用世代，清UID私人快取，回內置；拒用及原因不跨UID。若同步偏好，另定本人存取、同意、到期與刪除，不新增默認行為日誌 |

拒用同一SHA只阻止該版本，不能自行判定所有後續候選失敗；新候選仍須獨立評估，不靠改名重新提供。模型回退與「部署、設定與版本回退」App程式的tag／重建／簽署回退分開。現有內置選擇器不等於此私人registry與撤回服務已實作。

App／共用模型完成後先推GitHub commit、tag／Release並核對，再安裝交付。私人照片、權重及含私人資訊報告留在受權限保護的儲存，不進共用repo；私人registry保留歷史版本供本人回退。完整版本程序見本檔「部署、設定與版本回退」。

#### 1.2.0+3本機graph資料邊界

目前只增加App內的typed Dart資料與樣例，不部署Firestore、Storage、callable或Server定位服務。`IndoorGraph(id, version, floor, nodes, edges)`保存不可變node與開放／封閉無向edge；`IndoorNode`保存固定ID、名稱、contentVersion與objects，各object的已核准aliases先正規化再配對；同一node的不同object不可共用匹配key，避免同一個詞被當成兩份證據。畫圖layout另存，不是可輸出米數的x,y。

`LandmarkObservation`含sessionId、sequence、capturedAt、graphId、mapVersion、floor與landmarks；樣例`ReplayEvent.receivedAt`模擬回覆收到時間。GraphReplaySession最多保留50筆、拒絕跨session更新、忽略較舊序號；scope／時間不符撤回目前位置。未知或改名候選不會寫入永久圖。版本欄位和N08別名只示範資料分層，沒有實作地圖編輯、審批、雲端registry或自動升版服務。

本機回放無帳號、無照片／GPS擷取、無影像／路徑／深度上傳，也不讀取現有私人照片佇列。5秒是樣例capture時間間隔；自動顯示每秒一筆，兩者都不是新增拍攝API。未來實拍／Server adapter需另訂用途、配額與授權，不能沿用訓練照片同意。付費GPU仍停用。

<a id="5-撤回刪除與失效"></a>

### 撤回、刪除與失效

- 關閉收集停止本機擷取／待傳；另提供個人訓練及自動更新控制，worker在排隊、取資料、續跑與發佈前重驗授權。
- 刪除先建保護、停止新工作／下載，取消並等待或隔離worker，再清理照片、標註、快照、第三方匯出及私人權重，最後移除身分。遲到事件不得重建資料。
- 現有deletePhotoAccountData只涵蓋第四階段；加入worker／registry後必須擴充，不能假稱已涵蓋未有資源。
- 室內深度、姿態、網格留本機；照片同意不擴大為持續影片、GPS或軌跡上傳。方向短片另行授權。

<a id="8-導航資料與使用說明發佈前草稿重點"></a>

### 導航資料與使用說明（發佈前草稿重點）

導航只在使用者啟動與App前景取得位置；暫停、背景或結束停止定位，不建立／上傳行走軌跡。Apple／Google會收到完成搜尋及路線所需查詢、起點／目的地；代理不持久保存完整座標／路線，診斷避免私人位置。

語音按鈕才收音；優先裝置端，線上服務先取得本次同意，不把導航或錄音加入模型訓練。收藏／最近十個地點在本機安全儲存，可清除，不跟帳號同步；Google項目以Place ID、使用者標籤與時間保存，再查地點。

路線可能有誤差、延遲或入口不符，不保證樓梯／升降機可用，不提供過路時機、室內樓層或鎖屏導航。接近終點仍需確認入口，資訊不代替白杖、導盲犬或定向技能。Android需已配置服務、網絡與適當權限。

供應商參考：[Google Maps條款](https://maps.google.com/help/terms_maps/)、[Google私隱](https://policies.google.com/privacy)、[Apple地圖條款](https://www.apple.com/legal/internet-services/maps/terms-en.html)、[Apple私隱](https://www.apple.com/legal/privacy/)。正式政策需補聯絡及變更通知方式，不能以本章冒充已公開條款。

### 裝置端深度契約（現行，非雲端服務）

2026-10-28 物件距離版：1.4.0+5延伸本機hk.pathguide/depth契約，start帶objects模式、threshold、已校驗的內置權重cache路徑／SHA／bytes／classIds／classes／inputSize；原生再次核對才建立模型。不是外部下載／私人模型offer，不新增Cloud API。靜態內置權重快取放App support的PathGuideDepth，以SHA命名；只寫共用模型，沒有照片／深度／pose／UID資料。背景停止會作廢尚未完成的準備或啟動。

物件事件status=objects，附同session／timestamp／ageMs、viewWidth／viewHeight／rotation及最多5個objects：專案class id、score、已裁切預覽box、reason，可用時另帶rangeM／planeZM／accepted／total／spreadM。score是物件模型分數，不是距離可信度或正確率；rangeM是框內代表表面的徑向米數。短時track ID只在Dart當次session作配對，不寫永久graph／觀察資料庫。原有sample準星事件保留，兩種模式不能混用米數。資料不持久保存／上傳；訓練照片用途／同意／配額及PHOTO_UPLOAD_ENABLED=false不變，無付費GPU工作。


2026-10-28 1.4.1+6修正版：物件本機事件新增samplePoint（當次預覽normalized座標）、validDepth／depthTotal與細分reason；前端展示原因與點數，不把它們當正確率。深度信心／量程／混合表面／過期門檻不變，僅改框內局部取樣選擇及遮擋檢查；取樣位置改變重新累積時序證據。本機不新增影像／深度記錄或Cloud API、照片上傳仍關閉，無GPU／訓練工作。使用者提供測試截圖未放GitHub／dataset。

### 自動模型調度的服務界線（新增方案，未實作）

意圖辨識與模型路由優先放裝置端，基本操作不新增雲端依賴。不同能力可由已下載的A／B／OCR／視覺語言模型執行；不要求使用者選模型名稱。現有服務沒有這個調度器或視覺語言模型下載服務。

模型包規劃另記能力、格式／runtime、語言、裝置相容性、SHA、大小及驗收profile。只向調度器提供已驗證且可用的能力；不可把A的class映射套到生成文字。大型模型首次下載顯示大小／可用空間，允許取消、重試及刪除；固定版本驗證後才啟用。具體模型／大小待選型，不能把第三方宣傳數字當本App需求。

自動選擇已載入的運算能力與私人模型自動更新是兩個操作：後者繼續遵守UID、同意、閒置原子切換與回退。路由失敗不默默轉雲端；若未來加入雲端，圖片用途及傳送另行同意。查詢影像預設僅暫存記憶體，不自動進照片訓練流程。

最小診斷記request/session、路由能力、版本、取消／超時／降級原因及耗時，不預設收集圖片／聲音／完整提問。驗收離線、未下載、損壞包、空間不足、遲到結果、切帳號及重啟；未接服務先mock，不開付費推理或GPU。

<a id="service-acceptance"></a>
## 4. 服務驗收規格

使用者已確認：服務／儲存邊界沿用外部行為驗收，與旅程功能及真機場地結果分開。優先覆蓋越權、同意epoch、冪等、撤回／刪除競態、逾時、損壞及回退；不以內部函式呼叫次數代替行為。

<a id="6-後端驗收"></a>

### 後端驗收

- [ ] 身分／App Check、跨UID、舊epoch、影像及額度會拒絕；重送不重複照片或工作。
- [ ] AI不能覆寫人工答案；未核准／拒絕／授權不明的資料不入快照。
- [ ] 缺預算不提交；lease、逾時、心跳失效、checkpoint續跑及取消有測試。
- [ ] 不合格不發佈；本人下載、閒置切換、損壞回退與切帳號正確。
- [ ] 刪除與訓練／下載競爭不復活舊資料；私人產物不進GitHub。
- [ ] 共用版本遠端備份完成才交付，舊tag與對應模型可重建。
- [ ] 覆核人員／完整性／coverage／revision衝突及抽樣複核有證據；積壓上限不影響核心辨識。
- [ ] 一個issue可追溯至獨立資料比較及手機重測；回報照片不冒充驗收集，未評估不關單。
- [ ] 斷網／空間不足／重開／切帳號後active版本正確；體驗變差能主動回退，同SHA拒用與發佈者撤回不被重試繞過。

<a id="service-plan"></a>
## 5. 開發階段與逐功能計劃

### 開發階段與目前進度

三份文件共用S0–S7階段編號。狀態只表示可追溯證據：**已有程式**不等於已部署；**待實測**不等於通過；**受阻**需先解依賴；**未開始／未來研究**不是現有功能。沒有足夠工作量與驗收資料前不編造完成百分比或日期。

S5的圖示訓練可與S2、S4並行準備；私人訓練必須先有S0品質基準及S2核准資料，S6對本次納入能力的整合驗收通過後才擴大S7範圍。當前主線為一般iPhone路線錄製、跨樓層步行導航及即時障礙／語音整合；Dataset／訓練工作仍暫停。S4包含基本跨樓層路線，S7才擴更多場地／複雜網絡與平台；ARKit追蹤與LiDAR深度分開，物件、定位及實地任務品質各自驗收。

| 階段 | 本階段後端工作 | 目前進度 | 完成標準 | 下一步／依賴 |
|---|---|---|---|---|
| S0 工程基線與版本保存 | 固定契約、權限、設定、模型發佈及回退 | 1.8.0+15來源／簽署建置／簽章／模型及App程式雜湊已核；不可變tag／prerelease及遠端分支核對後，iPhone更新安裝／正常啟動成功。516項Flutter、54項原生及兩軸覆核通過；真人／場地驗收待回報。舊版及原權重品質限制保留 | 可由tag＋相符模型重建；配置／密鑰不進Git | 覆核共用版本並以遠端commit／asset核實 |
| S1 現有App核心功能 | Google身分／聯絡與Android路線代理 | 帳號已有程式與使用者回報；Routes有程式但未接通／驗證 | 本人權限、重新驗證刪除與平台導航服務驗收 | 保留iPhone MapKit獨立；補部署及真機證據 |
| S2 照片收集與管理員覆核 | 私人上傳、同意、配額、清理與管理員標註 | 上傳／清理已有；問題／覆核API及本機工作台已有；Emulator與合成瀏覽器流程通過；預設關閉，正式部署／真人案例未接通 | 同意→同幀照片→核准標註可追溯；越權／撤回被拒絕 | 先測試專案部署與權限，再接覆核工具 |
| S3 私人訓練與模型更新 | 快照、排隊、worker、評估、registry、下載 | 未接通；私人效益未驗證，付費GPU預算未定；[已錄路標持續改善規格](https://github.com/actiondarr/pathguide/issues/19)已確認，未部署 | 私人／共用對照支持額外效益；mock工作及效果退化回退通過，真實工作受配額控制 | 先問題修正案例與對照，再mock；資料／權限／預算具備才開真實服務 |
| S4 室內近距離感知與引導 | 私人本機路線／觀察版本契約，選填雲端邊界 | 既有測距及12-node樣例已有，N0／P0離線mock及P1樣例儲存已有；P3-A媒體schema／加密儲存候選已有454項Flutter／49原生及analyze證據、真機儲存probe亦過；P3-B核心471項Flutter／51原生及analyze已過，手機fixture亦通過，P3-C旅程接線已有工程候選490項Flutter／53原生通過；雲端看圖未完成／部署  P2-A/B協調及P2-C原生取幀已過本機工程測試；P2-D基本操作／旁白已獲使用者無問題回報；P3-C新流程真人實測待完成。；1.8.0+15自動草稿／樓層來源及必要確認已裝機，516項Flutter／54原生已過，真人待驗 | 基本錄路／重行不需登入／雲端；觀察、模型特徵版本及用途隔離可驗 | 先P2真相機／P3錄路；同步及真實雲端另定授權與配額，不上傳即時深度 |
| S5 圖示／文字與設施理解 | 保存共用B版本／評估及相容性 | 只有本地／Drive實驗產物；正式run中斷，未核准發佈 | B合格後有獨立namespace、映射與手機相容發佈包 | Dataset完成來源／格式／逐類評估；不把失敗當ready |
| S6 HKDI整合驗收與試用發佈 | 日誌、預算、排程、權限／刪除與版本回退 | 完整學習閉環未部署／驗收 | 各種失敗可定位／重試，費用受控、遠端備份先於安裝 | 結合Frontend真機、Dataset品質及角色驗收 |
| S7 多場地、複雜樓層網絡與平台擴充 | 場地圖／地標版本、選填同步、provider連結 | 本機typed graph／觀察原型已有；雲端及真實場地服務未實作 | 依場地／UID授權與版本相容性分階段驗收 | 先S6限定場景，未核准場地不開精確室內路由 |

### 功能計劃索引（按依賴取用，不代表同時開工）

本節接口名稱若寫「新增」即尚未實作，不能當成目前已可呼叫的API。

| 功能／階段 | 目前狀態 | 實現方法與輸入／輸出 | 依賴／完成標準 |
|---|---|---|---|
| B01 帳號、角色與私人聯絡／S1–S2 | Google／聯絡規則已有；覆核API已有角色／當前Auth及server-only人員檢查，本機替身測試通過，未部署／指定真人 | 驗證token取得UID，以可重試交易建profile；聯絡資料保持獨立。新增覆核角色由受權Admin設定custom claims，服務端驗證，不接受前端自報admin或ownerUid | 本人／覆核者／一般訪客權限分開；角色變更與token刷新／撤銷有測試 |
| B02 照片同意與提交／S2 | callable已有，未啟用 | 沿用get／setPhotoConsent與submitPhoto；檢查UID、epoch、配額／尺寸，解碼重編碼、綁photoId／objectGeneration，再原子更新validated／pending。sourceSha與清理後sha分開 | 前端F05同幀資料；重試冪等、無效App Check／舊epoch拒絕，不改成公開Storage |
| B03 管理員覆核與問題追蹤／S2 | 七個API、本機工作台及版本／權限／到期測試完成；預設關閉、真人／容量／案例未完成 | 依「管理員覆核與自動批次」建立原圖／預測／修框工作台，指定接件與複核角色，驗全圖coverage；expectedRevision防覆蓋，疑義退回，固定核准版本。以issueId串開發快照／候選／獨立評估／手機重測，記處理時間與積壓 | Dataset D02；人工完整答案及抽覆有效、衝突可恢復、撤回不復活；未重測不關單，AI篩查不冒充人工核准 |
| B04 私人快照匯出／S3 | 未接通 | 依ownerUid＋仍有效用途查核准版本，合併獲授權基礎回放，固定影像／標註版本、場景split、coverage與SHA，輸出不可變manifest；重送同一請求沿用snapshot ID | Dataset D03／D07；同實物不跨split，其他UID資料不得混入，資料變動建新snapshot |
| B05 排程、去重與佇列／S3 | 未實作；先案例與效益驗證 | 通過「管理員覆核與自動批次」啟用條件後才設03:00排程；50張／三場景只作候選檢查，仍驗樣本充分性。以UID＋snapshot＋config唯一job及lease，綁預算／時限與GCP Batch ID | 修正案例、私人效益、mock／權限／刪除及預算先驗收；資料不足不排，重複事件不重開；UTC照片配額不變 |
| B06 GPU訓練worker／S3 | 現有Colab實驗；服務未實作 | 容器固定工具／權重／設定，最小IAM讀指定snapshot，執行preflight→smoke→正式run；每輪備份checkpoint／optimizer／CSV及心跳。相同快照中斷才resume，改資料開新run；逾時／取消不發佈 | Dataset提供D04／D05／D07腳本；先mock成功／失敗／重試，再配置GPU；不把免費Colab當可靠無人服務 |
| B07 品質門檻與獨立評估／S3 | 只有本地A／B評估工具 | worker產生候選與現用模型的同資料逐類比較、樣本量、export parity及手機結果；核准服務驗完整報告並套版本化門檻，不能由worker一句success直接寫ready | Dataset「訓練與改善判定」為門檻唯一來源；目標無真值或其他類別退化則不核准；測試集不拿來反覆調參 |
| B08 Registry與發佈包／S3–S5 | 未實作 | 新增不可變模型record：ownerUid／shared scope、job／snapshot、A或B namespace、權重／manifest SHA與大小、taxonomy、App相容性、評估與狀態；核准才設可下載，發布指標另指向可回退版本 | A／B映射不得互換；現行內置format:1不無聲改義；共用模型與私人模型有不同存取範圍 |
| B09 本人下載、自動更新與回退／S3 | 未接通 | 新增綁scope／SHA／profile的offer與限時授權，重驗用途及版本核准；閒置原子切換，保留上版／內置。依「私人發佈、自動更新與回退」加入主動回退、選填原因、同SHA拒用及發佈者撤回 | Frontend F08；驗斷網、重開、空間不足、切帳號、重複offer及撤回競爭；signed URL有效期／離線撤回限制須如實呈現 |
| B10 撤回、取消、帳號刪除與到期／S2–S3 | 照片及新增問題／修訂／重試收據的到期、刪除已本機驗證；訓練資源未覆蓋 | 沿用tombstone／deleting，先禁止新上傳／job／下載，取消並等待或隔離worker，再按清單刪照片、annotations、snapshot、外部副本及私人模型，最後Auth；每步可重試並拒絕遲到重建 | 擴充現有deletePhotoAccountData；基礎共用資料不因單UID刪除而誤刪，處理中狀態可理解 |
| B11 Android搜尋／步行代理／S1 | computeWalkingRoute已有，未部署／驗證 | App Check驗應用，訪客可用；固定Google Routes WALK、HK／繁中與回傳欄位，Secret Manager供金鑰，逾時／配額分類；不接受任意網址代理、不持久保存軌跡 | Google配置、預算、簽署限制及真機；iPhoneMapKit不改走此代理 |
| B12 發佈、診斷與預算／S0–S6 | 1.4.1+6工程／簽署建置與遠端核對通過；之後安裝及啟動成功，舊版保留，場景覆驗待補 | 記匿名request／job ID、階段、耗時與錯誤類別，監察心跳、清理積壓、評估失敗與花費；提交前配額／worker時限與預算配置缺一拒絕。App發佈依「部署、設定與版本回退」先GitHub再安裝 | 日誌無照片／私人位置／憑證；告警不等於硬性花費上限；回退演練與版本報告可追溯 |
| B13 室內即時資料邊界／S4 | 1.4.1+6辨識框與深度已本機處理，無雲端服務 | 深度／pose／網格留手機，不新增即時雲端避障API；只提供相容模型與設定。若日後要上傳序列，需獨立用途、保留／刪除及安全設計，不能沿用照片同意 | Frontend F09–F12與Dataset D09；關閉網絡不影響已載入的本機感知 |
| B14 個人路線記憶、觀察及場地版本／S4–S7 | 本機樣例已有，完整floor／connector／perception契約待實作；N0已有，無正式雲端API | Sol凍結RouteMemory／LandmarkNode／RouteObservation／MatchResult，路線、固定node、時序觀察與特徵revision分開；有向已走通路段不套用無向BFS假設，未知與歧義不出方向 | F14／D09；基本版本機無帳戶，floor／connector列P0主線，更多場地後續；不能把AI候選或GPS當樓層真值 |
| B15 路線錄製／場景理解與選填同步／S1–S4 | P2-C/D相機已接；P3-A schema2及有界加密媒體候選已有工程檢查，真機儲存probe已過；P3-B核心471項Flutter／51原生及analyze已過，手機fixture亦通過，P3-C旅程接線已有工程候選490項Flutter／53原生及analyze通過，手機實測未完成 ；#18樓層證據／必要確認已有516項Flutter工程候選，1.8.0+15已交付，真人複測待完成| 本機版本／draft、重開、回退／刪除與容量保護已驗；平常重行不累積影像，首次錄路／更新才存受限關鍵幀。圖像／opaque特徵blob已有有界本機候選；SceneAnalyzer／跨裝置備份／同步未接；選填路標訓練另立用途／快照／model-index交付，見持續改善契約；未接通 | F17；P3-C已接真相機／本機閉環，下一步真人實測及P4障礙／語音，優化後置；雲端另同意／預算，不默認錄影或公開路線 |
| B16 Apple／電話連結與跨平台／S7 | Google現行；其他未接 | 使用Firebase明確provider linking，在驗證後維持原UID與私人資料，處理已有帳號衝突，不以同電郵猜合併；Android與iOS使用各自App／簽署設定 | F18；重新登入、登出、刪除與相同UID恢復有雙平台證據 |

管理員角色依據：[Firebase custom claims](https://firebase.google.com/docs/auth/admin/custom-claims)；GPU工作／時限依據：[Batch GPU工作](https://docs.cloud.google.com/batch/docs/create-run-job-gpus)、[工作時限](https://docs.cloud.google.com/batch/docs/create-run-basic-job)。這些是規劃所用平台能力，未表示本專案服務已部署。

產品及導航派工只在[Frontend開發次序](FRONTEND-DESIGN.zh-HK.md#delivery-plan)與[現行DSH契約](FRONTEND-DESIGN.zh-HK.md#dsh-functional-execution-plan)維護。本檔的B項目保存服務依賴及驗收，不再複製整份N0–N3導航表。

<a id="release-process"></a>
## 6. 部署、版本保存與回退

<a id="7-部署設定與版本回退"></a>

### 部署、設定與版本回退

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

2026-11-05已確認保存頻率：每張工作票通過檢查及程式覆核後，先commit／push相關來源、文件及機器證據到feature/cross-platform-navigation並核對遠端，再標完成。這類原始碼檢查點不等於App交付，不要求每票增加App版本。P2-D、P3-C、P4-B及P5各準備手機prerelease；P3-A另安排Keychain、檔案保護／備份排除、重開及刪除的工程真機檢查。任何裝機均遵循上列版本程序，實測結果再更新收據及文件，不能以關閉Issue或推送成功代替人工驗收。

倉庫為https://github.com/actiondarr/pathguide，既有工作分支feature/cross-platform-navigation。小型共用模型隨Git，過大共用產物用Release asset並記SHA及精確版本；私人照片／權重不得進共用repo。保留舊tag、模型及相容資料；回退App需重建並有效簽署，必要時用新的遞增iOS build號。私人模型則由本人授權registry保留上一版。

文件整併的歷史提交不冒充新App還原點。本輪1.1.0+2包括中英文與導航／辨識共用語音、當前試用模型及manifest，247項Flutter測試與未簽署iOS編譯通過。不可變tag `v1.1.0+2`；歷史源碼／模型還原點 `v1.0.0+1-baseline` 指向 `f9dfb494ac3bc9a470337d15cde6a5c67018aac9`（舊hkdi10 pilot模型，不冒充已重新驗收版本）。遠端分支／tag核對與Release狀態另存verification的機器紀錄。

版本發佈使用正常Git推送，以及有效的gh登入或GitHub已登入網頁流程；不從OS憑證庫抽出Git token作API登入。Release列模型SHA、試驗限制、測試、重建與回退方法；現有本機Firebase設定不入Git。CLI登入無效時，本版用正常GitHub網頁建立prerelease。

<details>
<summary>已交付App版本對服務契約的影響</summary>

<a id="1438-相機前處理修正版github已保存iphone已安裝啟動"></a>

### 4.3+8 相機前處理修正版（GitHub已保存，iPhone已安裝／啟動）

裝置端共用前處理由最近鄰／截斷尺寸改為雙線性／取最近整數（恰半取偶數）的letterbox，影響普通辨識及ARKit同幀辨識輸入；模型SHA、bytes、十類ID、下載／上傳及後端契約不變。14項原生XCTest、328項Flutter、33項數值檢查、analyze及iOS簽署建置／包內核對通過；遠端版本／交付狀態另依[工程證據](../verification/app-1.4.3+8.json)及收據核對。自然圖仍大量漏門及誤認行人，不能把此版記作新共用權重或品質gate通過。

原十類checkpoint及原run資料紀錄已按限定授權經Drive連接下載到ignored本機目錄；來源checkpoint／訓練報告SHA與原匯出一致，42個自然圖PT↔TFLite對照通過，誤認存在於原權重。未進行雲端部署或私人資料傳送，亦未操作B11。D04／D08後續須完成覆核反例／修正候選的獨立比較，再依B08／S0保存模型＋manifest＋設定。前處理版source 7f1d270、不可變tag及prerelease核對後，已成功安裝／啟動iPhone，見[交付收據](../verification/release-receipts/app-1.4.3+8.json)。

<a id="1427-前端恢復修正的契約與版本已交付試用"></a>

### 4.2+7 前端恢復修正的契約與版本（已交付試用）

本輪只修正裝置端任務恢復：328項Flutter、12項原生XCTest、33項數值檢查、analyze及iOS簽署建置／包內核對通過。原生hk.pathguide/depth新增使用者明確按鈕觸發的openSettings→bool；從系統設定返回不自動啟動相機。Vision原生generation作廢晚到權限，菜單／辨識／ARKit開始前等待舊相機或picker釋放，Dart已dispose的來源拒絕舊初始化結果。這些是本機接口，不新增雲端API、模型下載、私人資料或同意用途。

模型／映射與1.4.1+6相同，PHOTO_UPLOAD_ENABLED及付費GPU設定不變；不部署現有未提交後端服務。本版source／lockfile／相同模型的Git樹、不可變tag與prerelease已保存並核對遠端，其後iPhone 15 Pro Max安裝／啟動成功；[本輪工程證據](../verification/app-1.4.2+7.json)，交付結果見[版本收據](../verification/release-receipts/app-1.4.2+7.json)。真機資源交接、讀屏及精度仍須實測，完整統一任務協調層尚未完成。

</details>

## 7. 範圍限制與待定事項

[已錄路標持續改善規格](https://github.com/actiondarr/pathguide/issues/19)確認私人已錄路標的批次訓練方向，不授權本次上傳、GPU或部署；供應商、可驗預算／配額、保留及清理期限與評估profile仍須落實。舊A十類私人微調條件不代替路標服務條件。

雲端問答的provider、預算、最少傳送欄位及保存期限尚未選定；分析、回報及訓練用途分開授權。陌生室內探索只接受方向，無線索時停定掃描及保留未知已確認，具體線索搜尋／定位及正式接口未定，不把自由文字回答轉成已確認位置。私人訓練及付費GPU沒有因本規格獲得啟動授權。

## 8. 研究、開發工具與歷史紀錄

<details>
<summary>候選場地graph、參考體驗及無障礙服務研究</summary>

### 室內graph與照片序列資料設計（討論方案，待驗證）

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

### 參考體驗對後端的影響（方案分析，未部署）

公開產品列項與證據限制集中在Frontend「瞰見聆境」節；以下是我們的設計推論，不宣稱第三方後端採用相同架構。

- **路線內容改善：** B14／B15為graph／route另存node ID、內容版本、註記類型、來源、確認時間與有效期；臨時施工可失效／撤銷，店名變更保留位置身份。私人路標與場地共用變更分開授權，不能由一次觀察自動改公共地圖。
- **權重改善：** 維持B04–B09的UID快照、回放、獨立評估與模型registry；新增路線註記不直接觸發GPU或宣稱模型已學會。路線／內容／權重各有可回退版本。
- **同一旅程的多能力：** 導航、感知、查詢可共用session／mapVersion／modelVersion與過期檢查，但深度及即時障礙仍在手機。伺服器回覆慢時不能補播舊方向或覆寫新位置。
- **場景模型及下載：** 現行首版仍用本機有效證據摘要。若後續採雲端或大型本機模型，需另外確認供應商、圖片用途／保留、預算、下載相容性與斷網回退；本輪未開任何雲端影像服務。
- **聲音、手勢及背景：** F19／F22預設裝置端運算，不建立頭部追蹤上傳。F23若開發背景導航，需另定定位／音訊狀態與隱私說明；不把鎖屏路線語音等同背景鏡頭感知。
- **驗收及發佈：** 先用mock狀態驗證權限、版本、遲到事件與取消，再做HKDI實機／離線測試；競品的宣傳不作我們的品質門檻或驗收證據。

### 無障礙整合的後端責任（研究規格，待實作）

VoiceOver／TalkBack、語意樹、讀屏焦點、系統縮放及快捷動作在裝置端，不為此新增AccessibilityService、雲端讀屏或強制帳號。系統是否開啟讀屏不作身分／能力判定，不預設上傳輔助科技使用狀態。

服務回覆提供結構化stage、reasonCode、可重試／可取消狀態及必要進度，由Frontend本地化成可理解文字；不把原始exception或百分比假進度直接播出。狀態以job／request／session及版本對應，重試不產生重複通知；過期下載／核准結果不得觸發舊任務播音。帳號驗證、刪除、模型下載、同意及撤回頁也須能用讀屏／替代輸入完成。

無障礙偏好預設本機，不能由「使用VoiceOver」推定同意上傳、常開麥克風或下載模型。診斷如需保存測試語音／畫面另取用途同意；共用報告只保存去識別結果。驗收錯誤碼／狀態映射、取消／斷網／重送與語言切換；官方研究與平台差異見Frontend「Android／iOS無障礙整合研究」。

</details>

<details>
<summary>開發工具／成本控制證據與舊W階段分配（現行責任以DSH契約為準）</summary>

### DeepSeek／Sol全專案執行分工（2026-10-31）

2026-11-02當時分工（後續以2026-11-05的DSH全實作指示為準）：DSH只承接前端UI、後端API及相關測試；Dataset暫擱置，不再委派資料工具、看圖、標註或模型品質判斷。既有資料／訓練分工表僅保留候選背景，不構成恢復授權。相機／語音時序、帳戶隔離、刪除競態、模型相容及跨模組整合仍由Sol把關；人工真值不得由AI核准。

此為成本導向的工作分配，不是兩模型在本專案已完成的能力比較；先以小工作包核實正確率、返工與總費用。DeepSeek Flash＋DS Harness為日常執行主力，Sol為整合與關鍵覆核；統計、訓練、評估由固定程式運行，標註真值與真機任務由人工驗收。完整階段排程及交接規則集中Backend同名章節，各領域分工在所屬文件。模型替換不改任何品質gate或人手核准要求。

#### Codex→DSH本機橋接（2026-11-04，有限CLI派工及N0整合已驗證）

Desktop 0.13.0內的Harness為0.2.1-rc.3。以安裝包既有CLI／headless執行隔離小任務，原生credentials服務直接使用已保存的API key；key不讀出、不複製、不寫入環境或證據。單次模型請求成功取得session ID、completed狀態及unified diff，由主控限制至solution.py後套用，三項固定測試通過。輸入216／輸出42 tokens，4.502秒；按[官方離峰價格](https://api-docs.deepseek.com/quick_start/pricing/)估算US$0.0000576，未讀帳單或餘額，不當作實扣收據。見[smoke證據](../verification/dsh-smoke-20261031.json)及[已完成的候選契約](../configs/planning/dsh-smoke-20261031.json)。

此次使用者批准上限US$0.10／120秒／一次模型請求。送出前限制官方Flash endpoint、思考關閉、無工具、最多512輸出token及保守輸入上界；峰值費用上界US$0.0022218。耐久one-use ticket在送出前落盤，失去回覆亦不自動重送；同key重送已驗只回原結果。smoke另以精簡系統提示及移除DSH session／套件附加欄位限制輸入，不能把這次低用量外推普通程式工作包。

執行中狀態、短deadline停止自有程序，以及ACP對指定執行中session的cancel／cancelled／close，已透過真實DSH控制流程＋完全不連外的假模型補驗。這不是上游真實推理／計費停止的驗收。通用專案改檔、多人worktree、登入帳戶路由、崩潰後自動恢復及真實模型在途取消仍待驗；SDK沒有已核實的指定session取消方法。各接口依安裝版help／source，不假設最新文件的權限旗標或final事件欄位已存在。

本機控制程式在`/Users/darr/Desktop/development/pathguide-dsh-bridge/`，原始合成證據及一次性登記留ignored `review_artifacts/2026-10-31/dsh-smoke/`；沒有新增MCP或監聽服務。此smoke授權已用一次並關閉後續連線；W1另獲US$0.10／20分鐘／最多兩次模型請求授權，兩輪DSH實作已交回；Sol於11月2日完成本機覆核與兩個新檔案整合，27項測試及6個獨立CLI案例通過。實包完整性仍fail，細節及限制見Dataset與[W1證據](../verification/dsh-w1-integrity-20261102.json)。兩次請求的輸入合計14,388、輸出20,900 tokens，按執行當日已核實離峰價估算US$0.0146982，非帳單回執；本包兩次額度已用完，不自動延伸付費派工。既有DSH任務、App／模型、B11及GPU政策不變。

2026-11-04依本對話指定使用桌面`/Users/darr/Desktop/DSH Desktop.app`。新增scoped_control.py綁定契約／prompt／runtime SHA、原子登記、啟動失敗與中斷未知狀態；不確定回覆不自動重送，已有session不接管。五項新保護測試通過。N0第一輪max-tokens失敗但留下來源骨架；第二輪回覆完成但diff context有誤，兩輪均未直接通過交付。Sol保留原稿並修正接口、UI／測試及既有入口回歸後本機整合；這不是DSH自行工具改檔或自行跑測試已驗證。官方Flash價格當日核對，兩請求各送出前峰值費用上界合計US$0.0462771；實際token按峰值價估算US$0.0235686，非帳單。兩票據已消耗，本包不再派第三輪；20分鐘約束模型派工，本機覆核／測試可在模型時限後完成。證據見[N0覆核](../verification/dsh-n0-ui-20261104.json)。

#### 工作環境與成本控制

保留一個Sol總控／整合對話，DSH只分Frontend、Backend工作範圍，Dataset暫停；先做導航本機mock，真實視覺理解及provider另作有預算的可行性驗證。平常同時最多兩個寫入任務，使用獨立worktree或嚴格檔案擁有權；Xcode／裝機／GPU工作每次只由一個執行者負責。各自讀AGENTS.md及相關主文件，不另開第四份計劃。worktree開始前檢查未提交／ignored資料與配置，不能假設已全部帶入。

DeepSeek常規整理用非思考模式，需設計或除錯才開思考；Sol通常Medium，權限／時序／模型相容及困難根因用High。這是起始策略，不承諾固定成本優勢。先以小包測實際token、工具費、耗時、返工及驗收結果，再決定擴大；費用上限由使用者設定，未設定不啟動長時間付費agent／GPU工作。

不要讓LLM逐張讀全資料集或逐epoch監看。腳本一次輸出完整機器報告，對話只讀摘要／異常及必要樣本。定額限制重試與搜尋；同一失敗兩次仍無新證據，交Sol診斷。新對話使用短任務契約，不反覆貼全部歷史／原始log。

#### 全專案階段排程

下表保留跨模組依賴，現行執行以P0–P6導航主線為準；舊W1／W4資料與訓練任務暫停，不向DSH派Dataset、看圖或品質裁定。

| 工作包／順序 | DeepSeek主責 | Sol主責 | 交付與過關條件 |
|---|---|---|---|
| W0 現況與接口固定，先做 | 盤點實際程式／配置／證據與未提交檔，列差異 | 決定此次範圍、檔案擁有權、接口及驗收 | 以現有1.4.3+8收據、本機及Colab三個候選拒用、已實作覆核API為基線；不重做、不假設雲端已部署 |
| W1 資料可信基準，與W2並行 | 腳本audit、來源／coverage／分組、凍結快照、批次報告 | 覆核類別／分組／argmax及手機一致性、比較設計 | 重現現有證據，未知分開；新test不作開發調參，人工核標註 |
| W2 無障礙核心操作 | 標籤／大字／文案、按凍結接口做UI與mock、回歸清單 | 語音優先、焦點／取消／生命週期、相機交接 | 停止可達、無過期補播；VoiceOver／TalkBack分平台真機驗收 |
| W3 本地看圖可行性，W0後小規模 | 收集官方相容資訊、原型UI、benchmark runner／結果整理 | iOS／Android runtime接入、資源生命週期、調度與降級 | 先站定單張離線問答；實測速度／記憶體／熱／錯答，再決定模型與B分工，不直接接導航 |
| W4 A改善／B續訓，依W1 | 依核准固定設定準備及執行既有腳本、收checkpoint／摘要 | 訓練變更與評估邏輯、退化解讀／候選放行覆核 | 有人工／獨立資料證據才更新；B先查活躍程序，不重啟健康run；GPU政策照舊 |
| W5 最小照片覆核與mock閉環，可先準備 | 已有API的測試補缺、工作台UI、狀態映射／mock | Auth／App Check／UID／epoch、核准版本、撤回與刪除競爭 | 本機與emulator通過；真實部署另核配置與授權；不用mock冒充服務已通 |
| W6 模型交付／更新，依W3或W4合格包 | 進度UI、下載失敗fixture、相容性報告 | manifest／hash／UID驗證、原子切換、重啟恢復／回退 | 不相容及損壞拒絕；版本更新在閒置；個人訓練另需對照效益與預算 |
| W7 整合發佈，每版執行 | 跑指定回歸、整證據及文件草稿 | review差異、跨模組整合、版本／Release／裝機統籌 | 人工真機驗收；commit／不可變tag／遠端核對先於安裝，未通過能力仍試驗或關閉 |
| W8 後續室內／平台擴展 | 合成graph／場景fixture、幾何可視化、資料工具、普通adapter | 真實定位、深度／追蹤／路徑、Android感測差異 | 每次一個任務獨立驗收；空間音效、燈號／頭部手勢後續；基本跨樓層按P0–P5導航主線 |

A10免費Colab修正run已完成且拒用；W4不是重跑該run，須先依Dataset「下一輪資料工作」完成錯例／定義及獨立資料覆核，再提出新的比較設計。B11狀態另依其交接節核對。

現按Frontend完整方案P0–P6先做跨樓層／行走感知契約mock，再接儲存、相機、定位及語音；N3雲端理解維持選填及另有同意／provider／預算條件。私人訓練、LiDAR、鳥瞰及新YOLO權重不作本機原型前置。

#### Backend具體責任

DeepSeek負責B03工作台、已凍結schema的表單／狀態UI、B04 manifest工具、B05–B09 mock與失敗fixture、部署指令草稿及既有測試補缺。B01–B02權限／同意、B03核准角色、B04隔離、B05 lease／配額、B08–B10授權下載／刪除競爭由Sol主導或逐差異覆核；安全邊界不因換執行者放寬。B11 Android路線adapter普通程式可交DeepSeek，金鑰／App Check／導航生命週期由Sol覆核。B12發佈由Sol總控；B13–B16場地／provider擴展待相應階段。

#### 任務契約、交接與升級

每包先寫：目標、允許修改路徑、禁止事項、輸入版本／SHA、接口、預期產物、驗收命令、費用／時限。交付：base commit與實際diff或commit、測試命令／exit code／摘要、產物路徑與SHA、未完成及風險、所改主文件。機器證據進verification，本地圖像／CSV進review_artifacts；人工裁定在原有覆核記錄，不另寫handoff文檔。

Sol優先看diff＋摘要＋關鍵原始證據；不為所有文案／格式工作全量重跑。原始證據不能因摘要方便而刪除。接口／taxonomy變更、品質下降、跨UID／刪除／回退、難以重現的相機／語音競爭、兩次無進展失敗需升級Sol；人工真值不足需人工補證，不是單純換更強模型。未獲任務授權不刪原圖、改split／class ID、換手機模型或提交訓練。

DS Harness、OpenCode、Codex選一個執行同一包；不用三套工具重做。雲端模型可讀取送出的內容，不因工具本機執行便推定照片留本地；私人影像／聲音／權重與密鑰不得默認傳第三方。以本地統計及獲授權樣本交付。保留現有staged／unstaged他人工作，不自動重置、提交全部或重跑活躍訓練。

</details>

### 維護紀錄

2026-11-06 /to-spec：使用者接受本聊天全部建議，已發布[已錄路標持續改善規格](https://github.com/actiondarr/pathguide/issues/19)及ready-for-agent標籤，連到整體規格。同步本文件負責的持續改善範圍、與記憶補強的區別、行程後核實、另行用途、批次真實訓練／獨立重行比較及完整版本回退。此為規格及文件檢查，沒有改App／服務、採集／上傳、訓練、部署或裝機；既有工程／真人驗收狀態保持。

2026-11-06 P3-C候選接通本機首次錄路與重行：RouteLandmark原生通道只收有界JPEG／feature，回覆綁requestId、SHA及revision；精確取消及單一工作排空。store新增batch讀取，完整核驗版本／所有媒體而只留所需特徵，重行不寫照片。沿用本機Keychain、保護／備份排除及容量；沒有新增API、同步、訓練或部署。490項Flutter、53項原生及analyze通過；兩軸覆核及簽署建置／模型雜湊已過；不可變tag／prerelease及遠端分支核對後，1.7.0+13已安裝／正常啟動，真人實測待完成，見[P3-C證據](../verification/codex-p3c-journey-20261106.json)。

2026-11-05 P3-B核心工程檢查：471項Flutter、51項原生Simulator及analyze通過，兩軸覆核指出的出口綁定已先紅後綠修正並重驗；1.6.1+12最終簽署建置／簽章／模型雜湊通過，不可變tag／prerelease遠端核對後已安裝及啟動；手機generated-fixture真實feature12902bytes、自距離0及zh-Hant／en-US OCR能力通過；正常模式已重啟，並非實地導航驗收。新增Vision feature print／版本封裝、runtime OCR能力及人工確認回退；樓層localizer區分預期／候選／實際，合併同node多視角，拒絕歧義、錯層、方向未確認及舊／過期回覆。相機、儲存與平台／UI接線留P3-C；本輪不稱已能實地導航，實際檢查及發布狀態見[P3-B證據](../verification/codex-p3b-landmarks-20261105.json)。

2026-11-05 P3-A工程候選：schema2／加密媒體引用、quota、原子切換／取消／刪除／回退及iOS檔案政策已接，保留P1 synthetic v1及原key／目錄。454項Flutter、49項原生Simulator及analyze通過；1.6.0+11不可變tag／prerelease遠端核對後已安裝，真機Keychain／Complete／備份排除及跨process重開／刪除獨立probe通過，不以Simulator缺少保護屬性當硬件通過。未新增endpoint、上傳、部署、訓練或權重。見[P3-A證據](../verification/codex-p3a-route-media-20261105.json)。

2026-11-05 1.5.0+9 prerelease published from immutable tag b620ec4, remote verified before iPhone install and launch (both succeeded). Human camera/VoiceOver results remain pending. [Release and installation receipt](../verification/release-receipts/app-1.5.0+9.json).

2026-11-05 P2-D: live Flutter camera entry passed 435 Dart tests, 45 native Simulator tests, clean analyze and signed 1.5.0+9 Release build. Fixed old event-subscriber interference and evicted captured-photo caches on stop/exit. Physical-device and VoiceOver acceptance remain pending. Evidence: [P2-D receipt](../verification/codex-p2d-camera-entry-20261105.json).

2026-11-05 P2-D本機相機入口：Flutter透過原生通道核對路線／請求／時鐘與影像契約，再交有界JPEG到頁面；停止、背景及離頁撤回回覆並清理圖片快取。沒有新增後端endpoint、媒體持久化、上傳或訓練用途；P3-A再定加密媒體／配額。手機候選1.5.0+9依既定tag／prerelease／遠端核對後才安裝，人工結果另記。

2026-11-05 GitHub checkpoint review: connected the shared camera coordinator to application background/foreground before registering camera plugins. Late background starts are blocked; foreground never resumes a camera automatically. All 44 native Simulator tests passed; the isolated source checkpoint also reproduced 415 Flutter tests and clean analyze. Historical P2-C receipt remains a snapshot of its earlier 43-test run. Evidence: [lifecycle check](../verification/codex-camera-lifecycle-20261105.json).

2026-11-05 保存／裝機節點確認：使用者接受逐票來源同步與P2-D／P3-C／P4-B／P5手機版節點，以及P3-A工程真機檢查。區分原始碼檢查點、已發布手機測試版及人工結果；不更改雲端部署、照片用途或模型放行條件。

2026-11-05 Codex完成P2-C原生來源：新增獨立AVFoundation錄路相機、native preview及能力／狀態／最新觀察／按需JPEG通道；不載入模型或啟動ARSession。只留一個最新buffer及最多一個JPEG工作，長邊1280／512KiB硬限，原生時鐘／新鮮度／方向及SHA綁實際bytes。17項新增錄路測試連既有共43項原生Simulator、415項Flutter及analyze通過。兩個同步重入反例先紅後綠；停止／背景／逾時不交舊幀或假稱硬件已停。Flutter入口留P2-D，真機／VoiceOver、持久影像及定位未驗收；未發布／裝機。見[本輪證據](../verification/codex-p2c-route-camera-20261105.json)。

2026-11-05 Codex接續P2-B：Vision／Depth／Menu統一取得精確相機lease，移除互相直接啟停；Vision以serial session／inference queue屏障、Depth以AR pause及model work屏障、Menu以picker dismissal completion確認交接。修正舊client提早釋放導致停機回覆遺失，舊版回歸probe可重現失敗，修正版30項核心檢查通過。26項原生Simulator、415項Flutter及analyze通過；只屬本機工程驗證，真機／VoiceOver及P2-C/D未完成。見[本輪證據](../verification/codex-p2b-camera-adapters-20261105.json)。

2026-11-05 DSH開發驗收結果：P2總上限US$0.40／八次請求已批准，P2-A獲額外一次修正而合共三次；三輪均未通過，主專案App程式未合併。第一輪檢查器執行失敗，第二輪檢查器編譯失敗；第三輪交接回覆修正，但檢查器仍呼叫不存在方法，獨立probe仍重現跨協調器令牌相等及外來令牌停止本機擁有者，且錯把CLI檢查器加入App Sources。保留原稿、diff、編譯及probe證據；P2-B–D因前置未驗收保持未派，餘下五次總請求未使用，沒有第四次P2-A授權。三次token按峰值價保守估算US$0.03327，非帳單；未宣稱相機／真機／VoiceOver通過。見[本包驗收](../verification/dsh-p2a-camera-ownership-20261105.json)。

2026-11-05 開發啟動需求確認：同步已確認的UI／VoiceOver單一路輸出及無線索保留未知；不新增雲端服務或擴大資料用途。實作交DSH、Codex只驗收；Dataset／B11及現有品質gate維持原狀。

2026-11-05 /to-spec規格重整：按服務責任重排資料流、契約、驗收與部署，刪除與Frontend完全相同的導航次序副本；保留S0–S7、逐功能依賴／驗收、既有版本與機器證據。需求、待定事項、工程／真機／人工狀態分層；Q4尚未回答，不推定無線索探索策略已確認。本輪只改文件，沒有啟動App實作、訓練或部署。

<details>
<summary>展開既有維護紀錄（依當時日期解讀，不作現行派工）</summary>

2026-11-05 grill-with-docs首輪需求對齊：同步統一任務入口、本機基本能力及選填雲端問答的用途分隔；陌生室內逐段探索列完整產品目標，與私人路線記憶／訓練資料分開。具體探索策略及接口未定，不把現有路線儲存或雲端模型回答當作已知目的地位置。本輪只更新文件。

2026-11-05 DSH全實作／主控審核：依使用者新指示取代後續Sol實作分配，完成P2-A至D、P3、P4、P5的依賴、檔案範圍、接口、反例／命令、停止及交付要求。DSH負責全部程式／測試／修正，Codex只審核及機械驗證整合；不再代寫功能修正。現橋接仍為工具禁用的文字diff模式，不能宣稱DSH自行跑Xcode。P2四包合共US$0.40／八次為未批准候選上限，P1額度已耗完；本輪僅計劃及不付費準備，未提交新模型、改App、啟動訓練或裝機。詳細計劃見Frontend與`configs/planning/dsh-functional-execution-20261105.json`。 工作規格及阻擋關係已依新Issue tracker規則發布至[總票#2](https://github.com/actiondarr/pathguide/issues/2)與十張子票，首包為[P2-A #3](https://github.com/actiondarr/pathguide/issues/3)；目前皆為待預算／未派模型。

2026-11-05 P1功能整合：新增獨立加密本機樣例路線庫、草稿／完整結構版本、重新開啟、明確回退、刪除及舊版本／暫存清理。21項儲存／adapter、6項controller、6項UI及2項screen測試，全App415項及analyze通過。DSH兩次文字草稿經Sol修正；估算US$0.0114939，非帳單，無第三次。實際相機／照片／語音及真機Keychain未驗，未發布／裝機／部署／訓練／換模型，B11及舊來源保留。使用者指定先完成功能，效能／耗電／容量調校留後；下一步P2真相機，再P3首次錄路／跨層及P4障礙／語音。見[P1證據](../verification/dsh-p1-route-store-20261105.json)。

2026-11-04 P0跨樓層離線整合：新增樓層／有向轉層、預期／候選／實際樓層分離、單調時間與雙支序列、障礙frame及提示仲裁。G→3F、錯層／相似出口、樓梯平台、障礙打斷、過期感知、3F手動重定位及背景／刪除晚到事件有合成回歸。DSH兩次文字交付均需主控修正，沒有第三次；11556 input／9071 output按當日峰值價估算US$0.014352（非帳單）。新增27項、全App380項Flutter及analyze通過，中英文320×568兩倍字體圖已核對。N0保留，P0只有離線mock；真相機、TTS、持久儲存及實地／人工核准未做，未發布、裝機、部署、訓練或換權重，B11不動。見[P0覆核](../verification/dsh-p0-cross-floor-20261104.json)。

2026-11-04 需求澄清／先完整規劃：使用者明確要求跨樓層，以及行走期間即時障礙偵測＋語音步行導航。移除「只可錄使用者熟悉路線」及「跨樓層延至後續」的範圍誤讀；區分首次錄製建資料與沿已有資料導航。補樓層／轉層、單相機並行感知、語音優先、工具／兼容、資料及驗收的完整方案。現有N0仍只有三個合成路標、沒有floor／transition或真實行走感知；353項歷史工程通過不代表新增需求已實作。此輪只改三份主文件及機器計劃／證據，不啟動實作、DSH模型請求、訓練、部署或裝機。

2026-11-04 N0本機整合：新增熟路錄製／保存／選路、起點及方向分別確認、模擬重行、未知／歧義／方向不符、暫停／重確認、到達確認與刪除；只用記憶體合成路標。主控處理session／sequence／版本／過期、背景及刪除晚到回覆；DSH兩輪文字交付均需修正，未直接採納原diff。20項N0測試及全App 353項Flutter通過，analyze無問題；中英文320×568兩倍字體與合成畫面已核對。這不是相機定位、真機VoiceOver或實地通過；未發布、裝機、部署、訓練或換模型，Dataset及B11不動。DSH用兩次請求，峰值價估算US$0.0235686，非帳單回執；沒有第三次請求。完整來源、差異及限制見[本輪證據](../verification/dsh-n0-ui-20261104.json)。

2026-11-03 導航主線更新：依使用者選擇改為一般iPhone自行錄熟路與穩定重行；路標比對為基本流程、普通ARKit可選、LiDAR與雲端理解另分層。更新現況／先後／S0–S7／逐功能計劃及N0–N3驗收；Dataset維持暫停。只改三份主文件及機器計劃證據，未派DSH、改App／模型、採集相片、訓練、部署或裝機。

2026-11-02 DSH W1整合：已完成真實專案工具的兩輪文字diff交付、獨立覆核及本機驗收，費用估算約US$0.0147（批准上限US$0.10）。原始DSH成果與Sol整合差異分開保留；圖包5項事件差異待修，不表示模型改善或Backend部署。

2026-10-31 DSH隔離smoke：API-key原生路由的一次真實Flash請求完成，diff回收及3項固定測試通過；重送無新請求。補無費用的DSH狀態／deadline／ACP指定取消控制測試，明列假模型與真實上游限制。僅更新本機工具／配置／機器證據與本文件，未派發專案實作、訓練、部署或裝機。

2026-10-31 A10基準同步：Dataset完成第一版逐圖strict基準（1,082圖；person 98／19／179、door 5／3／34、fence 0正例）；本輪只同步服務邊界及執行次序，未改後端程式、部署、訓練或App權重。

2026-10-31 跨對話review整併：核對本機修正對照JSON，統一Colab已完成且拒用的狀態，修正早期未完成交接；Dataset字典回置開頭，歷史audit與現況分開，下一輪待辦及DeepSeek／Sol排程同步。保留原數據、來源、B11交接及品質限制；本輪僅改文件，未重跑評估／訓練、部署或裝機。

2026-10-31 目前問題總結：依使用者要求先整理十類辨識／物件測距問題，分開已重現證據、假說及缺少的驗收。補入免費T4完整結果：新val召回無提升、誤報增加，候選拒用；前處理已交付但權重未修復。未新增訓練、權重發佈或B11操作。
2026-10-31 A10修正交接（已由完成結果更新）：本機control／repair及免費T4候選均拒用；27張新train／15張新val保持凍結，Colab run 20261030T162638Z已完成訓練及評估。詳細品質結果集中Dataset目前問題總結；無App權重更新、B11操作或付費GPU提交。
2026-10-30 1.4.3+8交付核對：GitHub分支／不可變tag／prerelease先核實，之後iPhone安裝／啟動成功；限定Drive來源下載及原PT自然圖對照亦完成。權重未替換、品質仍未過關，沒有雲端部署、私人訓練或B11操作；詳細證據見本版收據與Dataset。

2026-10-30 相機前處理版本同步：1.4.3+8只改iOS共用縮圖／letterbox與回歸測試，無後端接口／模型權重變動；自然圖仍未過品質驗收。限定Drive原產物下載未成功，B11及付費GPU不變；版本保存／裝機依本輪工程證據與收據分開確認。

2026-10-29 交付核對：1.4.2+7 source 66bc1d0、不可變tag與GitHub prerelease先核實，之後iPhone 15 Pro Max安裝及啟動成功；初次連線重設後重試成功。見[交付收據](../verification/release-receipts/app-1.4.2+7.json)。不把裝機當作量尺、多人場景、VoiceOver或跨任務真機驗收。

2026-10-29 前端恢復交付：1.4.2+7完成測距產品提示／診斷分層、過期撤回、菜單取消及原生相機交接工程修正；328項Flutter、12項原生XCTest、33項數值檢查、analyze與簽署建置通過。未改模型／訓練／部署，真機場測與版本交付依工程證據及收據分別記錄。

2026-10-29：依本機程式、1.4.1+6構建／交付收據及2026-10-28品質review重整流程。保留S0–S7與逐功能計劃，把執行次序、驗收條件、現況及研究候選分開，合併重複版本日誌。此次只整理文件，未重跑App測試、部署、裝機或訓練；雲端／Colab即時狀態未重新查詢。2026-10-27至28的詳細發佈歷程保留於Git及verification，來源影像／標註未改動。

同日任務閉環補充：加入覆核角色／完整性與revision衝突、積壓及抽覆、issue到手機重測的追蹤，將私人自動訓練設為先驗額外效益的後續選項；50張／三場景只屬排隊起點。補體驗退化主動回退、同SHA拒用及發佈者撤回／重試規則。此次規劃整理時均為待實作契約，當時未新增Functions、開照片收集、部署或提交GPU；當時8個export及私人服務未接通狀態不變，後續首輪API實作以下文為準。

2026-10-29簡潔操作補充：依使用者希望減少按鈕，加入意圖驅動的裝置端能力調度、固定常用操作、按需收音、取消／降級與跨任務恢復，以及對應模型包及評估規格。此為規劃，尚未加入本地視覺語言模型或改App介面；不更動現有class、B11訓練或交付驗收狀態。

2026-10-29 Backend實作：新增五個預設關閉的問題／人工覆核callable，完成本人冪等接收／進度／撤回、受權原圖讀取、全圖coverage與雙人核准、revision衝突／不可變歷史及到期／刪除連動。本輪本機測試詳見verification/backend-photo-review.json；無部署、角色授予、照片收集、GPU、App裝機或模型變更。真實案例、工作台與修正後半段未完成。

2026-10-29 Backend續作：新增受權分頁待辦／歷史，隨機queueKey游標不含撤回帳戶路徑；接上本機覆核工作台及合成Emulator試用。Node22工程測試59項通過，Firebase adapter建置通過；瀏覽器完成數值／拖曳改框、完整與部分coverage、換人核准及窄螢幕檢查。正式Google／App Check、真人覆核、容量／抽覆及部署未驗收；未開照片收集、GPU、訓練或App版本變更。

2026-10-29無障礙研究：核對Apple／Android／Flutter官方資料及現有語意／播音程式，加入跨平台整合、語言差異、Android公告干擾風險、替代操作及任務驗收。只更新方案；未改程式、切系統設定或執行真機／使用者測試。

2026-10-31成本分工：加入DeepSeek日常執行、Sol關鍵整合／覆核、本地腳本與人工真值的完整工作包、依賴及交接規則。依目前1.4.3+8／候選拒用／覆核API本機進度規劃，不重做歷史工作；僅修改三份文件，未安裝agent工具、傳送外部資料、開訓練或部署。

2026-11-02 DSH-W2-FP收尾：兩輪文字交付完成，11項生成器測試及27項既有測試通過，新包完整性pass。門FP事件8→3、person完整strict FP事件117→19，TP／FN未變；三份review CSV逐byte相同，原包24檔及三份輸入SHA保留。這是匯出修正，沒有模型改善或人工核准。生成器SHA由主控比對；檢查器既有producer_provenance仍為unknown。證據見[W2記錄](../verification/dsh-w2-fp-export-20261102.json)。

目前透過隔離HOME的DSH headless CLI派工，DSH僅回傳來源文字，Sol產生diff、套用及執行本機驗收；session不會同步到既有Desktop workspace。提交／session ID／狀態／收件已實跑；Desktop可見任務及DSH自行工具改檔／跑測試仍未驗證。本包兩次額度已用完：17,955輸入／17,170輸出tokens，按當日已核實離峰價估算US$0.01299525，非帳單回執。

2026-11-03 DSH前端派工收尾：文字請求兩輪完成；5項新教學及2項既有語言測試、analyze通過。產品驗收只用本機widget，不需使用者登入、帳戶、雲端或手機。後續依使用者指示自動按既有前端／後端計劃派工，每包維持US$0.10／20分鐘／最多兩請求，Dataset暫停。原始DSH與Sol小型整合差異分開保留，見[W3證據](../verification/dsh-w3-frontend-guide-20261103.json)。

</details>

2026-11-06 P3-C修正（#15）：使用者回報1.7.0+13首次相機後卡住、照片未保存，該版新流程真人驗收未通過。已重現busy指示器令預覽重建，以及對話框關閉期間controller過早釋放。候選修正保持預覽與捲動／暫停生命週期，native在開始完成才綁session、停止前解除；輸入controller等DialogRoute overlay移除才dispose。native等待上限8秒，舊start逾時不能停止新owner；停止未確認不假稱已停。inactive輸入不等於背景，真背景仍暫停，重新拍攝須明確操作。新增測試驗相機中斷→拍攝→兩路標→保存→重開；1.7.1+14完整檢查／覆核／發布及真人複測準備中，沒有清空本機資料或上傳私照。S4／F17（Backend B15）仍屬工程流程，實地品質未驗。

#15覆核修正：拍攝途中背景／native中斷時保留已提交名稱、樓層及確認資料；顯示尚未加入並提供明確重試／捨棄，不自動拍攝。對話框以DialogRoute.completed而非首個frame作釋放界線。

2026-11-06 #15交付：493項Flutter、54項原生、analyze及兩軸覆核通過，1.7.1+14簽署建置／簽章／模型雜湊核對後已commit/push、發布不可變tag/prerelease並核對遠端。裝機嘗試因CoreDevice連線重設失敗，待USB連接解鎖後更新；手機仍為舊版，沒有清空資料。見verification/codex-p3c-hotfix-20261106.json。

2026-11-06 #15裝機收據更新：首次連線中斷後，使用者接USB及解鎖；1.7.1+14更新安裝／正常啟動成功，本機資料保留，真人複測待回報。前述「尚未安裝」為第一次失敗嘗試歷史，不是目前交付狀態。

#17自動未知草稿已有來源候選：498項Flutter、analyze及兩軸覆核通過；未發布／裝機。完整#16的樓層上下文／必要確認及模型工作未完成。

2026-11-06 #16樓層分支已確認；#17自動未知草稿來源候選，未發布手機。

2026-11-06 #18：加入明確樓層確認點、沿用／整段核實來源及必要轉層操作；schema3與舊版拒讀邊界明示，516項Flutter及analyze已過；兩軸覆核已通過，1.8.0+15發布與真人驗收待完成。

#18覆核修正：手動補記留空樓層會沿用有效本段上下文；明確未知／不同樓層或非步行記錄撤回連續性，之後自動點仍可保存草稿。更改已知出口樓層會撤回其進入設備連接確認，需再明確確認；兩個反例先紅後綠。中英兩倍字體測試亦從實際表單補記並核對沿用來源。「結束錄路並命名保存」固定在底部操作區，避免錄到多個點後難以找到。

2026-11-06 #18交付：516項Flutter、54項原生、analyze及兩軸覆核通過；1.8.0+15最終簽署建置／簽章／模型與App程式雜湊已核，GitHub不可變tag／prerelease及分支核對後安裝、正常啟動成功。首次transport reset後重連成功；本機資料保留，新版真人實測待完成，不把工程通過當實地導航驗收。
