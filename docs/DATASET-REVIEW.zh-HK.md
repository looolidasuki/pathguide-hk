# PathGuide Dataset 覆核與準確度改善

更新：2026年10月28日。唯一Dataset Review文件；[Frontend](FRONTEND-DESIGN.zh-HK.md)管理App，[Backend](BACKEND-DESIGN.zh-HK.md)管理服務與版本。資料、類別、模型或訓練進度改動必須同一提交更新此檔，不另開日期化狀態稿。私人訓練服務尚未接通。

## 開發階段與目前進度

三份文件共用S0–S7階段編號。狀態只表示可追溯證據：**已有程式**不等於已部署；**待實測**不等於通過；**受阻**需先解依賴；**未開始／未來研究**不是現有功能。沒有足夠工作量與驗收資料前不編造完成百分比或日期。

S5的圖示訓練可與S2、S4並行準備；私人訓練必須先有S0品質基準及S2核准資料，S6整合驗收通過後才擴大S7範圍。當前主線仍是改善準確度，室內畫面不可取代品質驗收。

| 階段 | 本階段Dataset工作 | 目前進度 | 完成標準 | 下一步／依賴 |
|---|---|---|---|---|
| S0 工程基線與版本保存 | 固定taxonomy、HKDI保留集、現用模型／映射與逐類基準 | A十類試驗已匯出；門gate失敗，圍欄無獨立val，HKDI基準不足 | 可在同一獨立資料重現新舊逐類比較，產物與SHA可還原 | 先整理門／行人失敗例與不同實體場景 |
| S1 現有App核心功能 | 校準A、菜單OCR與播報門檻，提供真機測試樣本 | 有A來源評估／parity與工程回歸；缺完整手機實景評估 | 不把PyTorch／mAP當手機任務成功率；按場景公布誤報／漏報 | 補TFLite與HKDI／菜單真值，與Frontend實測對照 |
| S2 照片收集與管理員覆核 | 定義全圖答案、覆核清單、coverage、去重與場景 | 本地工具已有，App私人照片完整覆核閉環未接 | 每張核准圖有來源／定義／答案／分組與審核版本，partial不冒充完整 | 先既有失敗場景試覆核，再接Backend角色與照片 |
| S3 私人訓練與模型更新 | UID快照、基礎回放、固定評估／門檻與匯出 | 未形成服務；付費worker待預算與資料 | 與現用模型同資料比較，合格才可下載，無證據不自動更新 | 先mock管線，核准資料不足保持收集 |
| S4 室內近距離感知與引導 | 距離、地面、障礙、未知／落差及路徑真值 | 1.4.0+5有同幀物件／表面距離工程試驗；未建實測聯合benchmark | 實際量測與F09–F12對齊，含拒答／撤線及效能結果 | 在HKDI固定路段收獨立授權測試序列，不混照片同意 |
| S5 圖示／文字與設施理解 | B11訓練／泛化、牌面OCR、圖示箭嘴配對 | B曾到epoch22後中斷；17:10交接Drive連接失敗，未resume／未部署 | 正式run／holdout／手機格式驗證完整，exit稀少如實標限制 | 先恢復同帳戶Drive、驗last.pt與optimizer，再正確resume；不Run all |
| S6 HKDI整合驗收與試用發佈 | 新舊模型與整體任務比較、資料／產物封存 | 完整室內＋學習閉環未驗收 | HKDI陪同測試、手機格式、舊類退化及回退皆有報告 | 提供Frontend／Backend相同模型及snapshot識別 |
| S7 多場地、多樓層與平台擴充 | 新場地／新類別、設備時序及低光／透明細物 | 未來研究 | 場地／實體獨立、定義一致、相容映射與各任務驗收 | 先限定場景成熟，再擴展，不把更多類別當更準 |

## 各功能計劃如何實現

| 功能／階段 | 目前狀態 | 實現步驟與產物 | 依賴／完成標準 |
|---|---|---|---|
| D01 類別定義與版本映射／S0 | A十類／B十一類活動版本已知 | 以實際manifest／profile凍結名稱、順序、專案ID、正反例與框邊界；保留原標註，輸出連續YOLO索引及對照。A物件／B牌內圖示／OCR文字各自namespace，不把52登記或20／23候選當已訓練 | F02／B08；同一輸出在訓練、匯出與手機有同義映射，樓梯合併與門框定義可追溯 |
| D02 新照片、預標註與人工覆核／S2 | 本地工具已有，私人服務未接 | 檢查授權／影像→模型預標→管理員全圖補漏／修框／改類→存原預測與核准答案／reviewer／version。私人首版十類全圖完成才核准；partial用coverage明確隔離 | B02–B03；低信心不當新類別，空框不當真負例，不能只把pending改approved |
| D03 去重、場景分組與快照／S0–S3 | 精確像素／pHash工具已有，實體獨立性未完全證實 | 以來源／影片／實體門牌分組，增強／裁圖回原組；精確重複合併，近似候選覆核，不確定保守同組。再分train／val／test、固定SHA、coverage、來源與版本 | B04；跨集合圖像／實體洩漏被擋，無法證獨立不作宣稱；test不進訓練 |
| D04 A模型門與舊類改善／S0–S1 | 門P28.6%／R11.1%，person退化 | 分析門FP／FN的材質／半開／尺度／光線與框定義，補不同門及櫃窗反例；固定新快照、回放舊類，短smoke後由相容十類best新fine-tune，逐類對照現用。不盲目加epoch／重排HK9 head | 先獨立門／圍欄驗證；新增資料須有coverage，person／舊類退化不以整體mAP掩蓋 |
| D05 B圖示與箭嘴／S5 | 正式run中斷、最新授權連接受阻 | 保留目前checkpoint與CSV，恢復後驗epoch／optimizer／names再續訓；不從seed重跑。完成報逐類AP與固定conf的TP／FP／FN，檢查複合牌、方向與未知圖示；原圖ROI保留座標來源，不用整圖分類假框 | F13／B08；exit僅12張train／13框，不能宣稱成熟；正式、smoke與A結果分開 |
| D06 菜單、牌面OCR與配對／S1–S5 | 菜單OCR有程式；牌面資料／整合未齊 | 系統OCR先作基線；保留逐字文字、多邊形、菜名／價格或設施／箭嘴關係真值。分菜單與牌面測，報文字錯誤、價格錯配、漏檢及拒答；錯誤證據充分後才規劃微調 | F07／F13；不為每個店名／房號新增物件class，不由menu測試推定sign任務成功 |
| D07 私人微調與品質比較／S3 | 未接通 | 僅本人核准圖＋獲授權基礎回放，按場景留獨立驗證；固定現用／候選／threshold報逐類差異，按第3節門檻判定，資料不足不排隊。先在mock流程測不合格／退化，再接GPU | B04–B07；不能跨UID或自動加入新class，訓練成功不等於更新成功 |
| D08 TFLite、模型包與手機驗證／S0–S6 | A已有匯出／raw parity，B未完成 | 固定權重SHA→匯出TFLite→核shape／前處理／本地索引→同圖raw parity與偵測比較→完整手機格式評估→真機延遲／耗電／播報。封裝manifest、namespace、taxonomy、來源與限制 | F02／F08／B08；保留原權重與上版，不用降低檢查配合不相容輸出；共用版本先GitHub再交付 |
| D09 拓撲node／觀察序列及室內幾何真值／S4–S7 | 12-node合成回放已執行；1.4.0+5同幀框內表面測距有工程檢查，實測聯合benchmark／圖片定位未完成 | 先人手定義位置node、實際通路與觀察對照，測重複／漏拍／倒行／分岔／改名，再接圖片特徵。公尺級幾何階段另量測距離／寬度／地標及授權RGB-D序列，按地點／時段／設備分集 | F09–F14；以陪同與量測判定，不讓模型輸出當導航真值；影片／姿態用途不能沿用照片同意 |
| D10 擴類、場地與新平台／S7 | 候選，未開放私人擴class | 先確認任務與定義、補足新舊類全圖標註及陌生場景，再版本化taxonomy／mapping與App相容性；舊輸出有實際資料才做遷移。Android／非LiDAR能力另外基準與限制 | F18／B14；不重用舊ID改義，不因有COCO權重便假設保留全部類別 |
| D11 扶手電梯、推拉與近身時序／S7 | 研究，未開始 | 受控授權序列包含同設備、上下端、移動／啟停、標誌、相機運動與真方向；門推拉另有文字證據。懸空／細障礙與相對運動另量測。分設備／場地／時段留集，報錯方向、拒答及過期清除 | F15–F16；單張箭嘴、門把或畫面位移不作實際方向真值，未知保留拒答 |
| D12 來源署名、資料與報告保存／S0–S6 | 來源表及機器證據已移到適當位置 | 逐圖保存作者／license／URL、影像／標註SHA、變換與審核歷史，模型報告引用同一snapshot。共用報告不含私人內容，私人權重／影像留UID範圍；保留舊版可重現所需配置 | 第7節來源不能因整併遺失；版本回退不靠單一模型檔，GitHub不收私人照片／權重 |
| D13 路口與電梯顯示資料／S5–S7 | 參考產品引出的研究候選，未建立 | 分開建立行人燈／車燈、對應通行方向／路口、斑馬線及狀態時序；電梯顯示器、按鈕文字與是否點亮分開標。按不同路口／設備／場地留集，包含反光、遮擋、未知與LED閃爍 | F20／F21；A十類不自動有新能力，物件／文字偵測分數不等於可過路或已確認樓層 |
| D14 聲音、手勢與背景任務驗收／S4–S7 | 未執行 | 先用已知位置／距離與人工情境，測左／右／前後辨別、反應時間、VoiceOver干擾、誤手勢、耳機斷線及鎖屏／恢復。記裝置、音訊方式、權限與耗電，核心模組與整體任務分開報 | F19／F22／F23；不用競品功能表當精度證據，不把感測缺失當正常輸出 |

## 1. 實際基線

目標是用新場景改善辨識，以獨立資料回答：哪些類別／場景變好、誤報與漏報有何變化、其他類別有沒有退步。

| 模組 | 已核對狀態 | 缺口 |
|---|---|---|
| A 主物件 | 2026-10-27.mixed10.experimental.1，十類；九類另作備援 | 門 precision 28.6%、recall 11.1%，僅18個小型外國驗證框；gate=false |
| A 其他類別 | person AP50 56.13%，baseline 61.01%；樓梯已合併 | 檢查遺忘；圍欄無獨立驗證，不填虛假準確率 |
| B 圖示 | sign-icon-demo11-v1，11類；2,301／469／557張 train／val／test | 正式run曾到22輪後中斷，Drive連接受阻；exit train僅13框，樣式／實體獨立性不足 |
| OCR | iPhone 菜單已有系統文字辨識 | 不能代替牌面、樓層及文字／箭嘴配對驗收 |
| 室內幾何 | 1.4.0+5已有同幀框內表面LiDAR試驗及聯合驗收方法；未有實測結果 | 距離、地面、落差及路徑另設真值，不由 A 的 mAP 推定 |

A 十類順序為 person、bicycle、bin、bollard、traffic_cone、caution_slippery、stairs、escalator、fence、door，專案 ID 為 `[6,11,7,8,9,24,1,49,26,18]`。私人首版不自行擴 class。

B 一般 toilet_symbol 延後，活動11類與原12類路線圖分開保存。現有 snapshot 只准實驗訓練；含插圖與來源增強，抽樣篩查不能寫成全量人工覆核。最新17:10本機交接回報：12項本機測試與11圖CPU流程試跑、兩輪GPU smoke曾完成；正式run最後核實epoch22後中斷，Drive mount回報credential propagation失敗，尚未resume。這是交接證據，本輪未直接重讀Colab或新checkpoint，不能稱為正在健康訓練或已完成。

## 2. 覆核工作流程

1. 只接收有同意、來源與 UID 可追溯的候選；保留拍攝時模型、原始預測與觸發原因。低信心不是新類別，高分也可能錯。
2. 檢查影像、授權、旋轉、重複與場景；同一門、牌、連拍、影片、裁圖及增強歸同組。獨立性不明時保守同組或只進 train。
3. 模型預標註後，由管理員逐張補漏修框；人工答案另存，記錄覆核者、時間、定義與標註版本，不覆蓋原始預測。
4. 私人首版要求十類全圖覆核；只有確認當次目標全部不存在的圖才作完整背景負樣本。
5. 外部部分標註資料只有在 coverage manifest 明確、遮罩損失／評估測試通過時才加入實驗。未知類別不當負樣本，也不在該來源評分；不可直接把 partial 改 approved。
6. 按 UID 與場景凍結 train／val／test，附影像／標註 SHA256、映射、來源授權及基礎資料版本。訓練開始後不再加入照片。

門需統一完整門口／門板框定義，單列木門、玻璃、半開、側視、逆光、遮擋及櫃門／窗反例。室內「未觀測」與「已觀測無障礙」分開記錄，不從沒有物件框推導可行走。

## 3. 訓練與改善判定

核准資料 → 條件檢查 → 排隊 → 微調 → validation → 凍結候選 → 獨立驗收 → 匯出一致性 → 私人發佈。Colab 保留作受人監督的實驗；雲端付費提交在預算設定前關閉。

以下是首輪工程預設，需記錄版本及限制，不是已驗證的產品準確率：

| 項目 | 規則 |
|---|---|
| 排隊 | 至少50張新增核准圖、三個場景，另有與 train 不同組的個人驗證資料；不足顯示資料不足 |
| 回放 | 固定相同 taxonomy 的基礎權重與獲授權資料，不只訓練新圖，不混其他 UID 私人資料 |
| 比較 | 同一資料、conf0.30／IoU0.50比較現用與候選，逐類報TP／FP／FN、precision／recall、AP與樣本量 |
| 更新候選門檻 | 目標類別precision≥80%、recall≥70%，recall至少增加五個百分點；所有可評分類別precision／recall均不得下降超過兩個百分點 |
| 證據不足 | 目標缺真值或不能獨立比較，不自動核准；只列候選／待驗收，不填零或宣稱改善 |
| test | validation選參數，test不參與訓練或選門檻；反覆開發消耗的test需另建保留集並記錄歷史 |
| 手機 | PyTorch／TFLite數值、映射與播報門檻一致；發佈前有延遲、耗電及任務驗收 |

有限樣本只支持該評估範圍。現用十類 gate=false，不得自動升格為核准基礎模型；後續訓練可作實驗，發佈仍需完整檢查。

## 4. 每版報告與還原

保存現用／候選版本、目標類別、來源與實體數、split與分組雜湊、覆核範圍、逐類比較、失敗例、格式檢查、真機結果、限制與發佈判定。先提供誤報／漏報，再提供平均mAP，不用單一「準確率」概括所有任務。

共用 App／模型先完成 GitHub commit、tag／Release與遠端核對，再安裝交付；保留上一版模型、映射與安裝說明。私人照片／權重留在受授權私人儲存，不進共用repo。版本程序集中在Backend第7節。

## 5. B11訓練交接（持續在本節更新）

| 欄位 | 最近已記錄證據 |
|---|---|
| 正式run | 20261027T055450Z-full，獨立YOLO11n預訓練起點 |
| 最近checkpoint | 交接於約14:11讀到epoch22/60，UTC 2026-10-27T06:07:54.643512+00:00；best.pt／last.pt／results.csv存在，尚未驗optimizer可否正確resume |
| 已完成smoke | 20261027T055254Z-smoke，兩輪及validation；不能當正式結果 |
| 正式設定 | Ultralytics8.4.182、640、batch16、最多60 epochs、patience12，不翻轉／旋轉 |
| Drive輸出 | MyDrive/PathGuide/sign-icon-models/sign-icon-demo11-v1/20261027T055450Z-full/，本人授權空間 |
| 跟進／阻礙 | 最新本機交接17:10：Notebook無連線，Drive掛載credential propagation失敗；需在原Notebook恢復既有同帳戶連接，再核checkpoint與活躍程序。未resume、未部署，不能Run all |
| 尚未確認 | 正式完成、best.pt評估、獨立test及App整合，不部署未驗證B |

不要Run all、重跑launcher／force_remount、刪launcher-state或混用A／smoke結果。中斷先查活躍程序與checkpoint、optimizer、CSV、SHA及UTC，再確認正確resume；資料或taxonomy改變需新run。私人帳戶／Notebook識別只留既有受權跟進，不寫公開文件。

現行工具：dataset_pipeline/colab_train_sign_icons.py、coverage_training.py及evaluate_sign_icons.py；配置在dataset_pipeline/configs/sign-icon-demo11-v1.json。A變更資料後應從相容十類權重開始新fine-tune，不用resume改快照，也不套回舊HK9 head重排。只有相同資料／設定的中斷才續跑。

## 6. 下一輪清單

- [ ] 建立 HKDI 不同門與走廊的分組基準，補暗光、玻璃、半開門與反例。
- [ ] 分析門 FP／FN及person退化，驗證新資料是否改善未見場景。
- [ ] 先恢復B既有Drive連接，核對epoch22後是否有新checkpoint／optimizer並正確resume；完成後評估coverage、exit及場景獨立性，不重跑已完成smoke或套A全域ID。
- [ ] 用模擬worker驗證私人覆核、訓練、發佈與回退；預算未定不提交付費GPU。
- [ ] 為室內距離、地面及路徑另建真值、失效與拒答案例。


## 參考產品轉成我們的驗收項目（未實測該App）

Frontend保存第三方公開列項；Dataset不推斷其內部模型、訓練資料或準確率。接下來要證明的是PathGuide自己的改善：

| 改善類型 | 我們應準備的真值／實驗 | 要報的結果 |
|---|---|---|
| 路線與地標更好 | 凍結route／graph內容版本，以另一趟次重走，包含臨時註記到期、改名、重複標記及錯node | 路標在正確位置觸發、漏播／誤播、過期註記、錯分支與回退；與未更新版本比較 |
| 辨識模型更好 | D04／D07的現用／候選同資料比較與陌生場景 | 逐類precision／recall、退化、樣本量及TFLite／手機差異；不以路線修正當權重提升 |
| 導航與感知配合 | 同一固定路段，測導航、辨識、查詢進出、語音取消及過期回覆 | 漏指示／過期指示、音訊重疊、相機恢復、任務成功與使用負擔 |
| 空間／近身資訊 | D09／D11獨立量測及已知方位，覆蓋透明／細物、頭部高度與持機變化 | 測距誤差、漏障礙／誤警、未知／撤回比例；視覺畫面好看不代替真值 |
| 新場景／輸入方式 | D06／D13／D14分任務獨立測；先受控情境，再與目標使用者及協作者評估 | 文字／關係錯配、聲音辨位、手勢誤觸、背景恢復與耗電，不混成單一準確率 |

對第三方實機的觀察可記錄流程／提示／失效例，只能支持「觀察到甚麼」；無源碼、模型及獨立實驗時，不能用來推定其VPS、個人訓練或安全表現。本輪未複製第三方程式、模型或資料。

## 拓撲graph先行的概念驗證（本機樣例已執行，真實資料待驗）

先用約8–12個人手位置node與已核實通路建立小圖，不先訓練特徵模型。node的身份是固定位置／地標，objects／店名／參考圖片是有版本內容；每次拍攝是observation，不是一張相片就新增一個node。沒有實測x,y時用拓撲真值，不能自製距離／朝向答案。

| 測試情境 | 真值／輸入應如何準備 | 合理結果 |
|---|---|---|
| 同一路線再行一次 | 第二趟獨立拍攝序列，保留時間與人手node對照 | 大致跟隨同一路線；每次仍可未知，不能把上次答案直接當新真值 |
| 停留／連續相似照片 | 多個observation同一位置 | 同node可重複，不為每5秒新增永久節點 |
| 行快／漏拍 | 真值序列跳過中間node | 容許可達的跳轉，不強行依序命中每個node |
| 倒行／折返 | 同路段反向，含不同視角 | 在允許雙向的edge反向匹配，不錯判成新場地 |
| 分岔／重複店面 | 圖中相似外觀與多條可達路線 | 用graph鄰域、最近序列與路線保留候選；不確定就拒答，不只array前後5項 |
| 店名更換／局部裝修 | 相同位置ID、不同內容版本，另留未改部分證據 | 先產生內容變更候選，覆核後更新；位置身份不因OCR字改變而自動替換 |
| 沒影過／錯場地／視角不足 | 未入圖或不可區分的觀察 | 回unknown並擴搜／要求補拍，不直接修改核准graph |
| 遲到Server回覆／斷網 | 故意打亂回覆時間與遺失請求 | 拍攝序列保持正確，舊回覆不覆蓋新位置，不補播過期轉向 |

先報node對照正確／錯誤／未知比例、錯分支次數、重新定位所需觀察數及延遲。這些只測拓撲推理；公尺位置／朝向／AR對齊與即時障礙另用幾何真值驗收，不把「graph概念可行」寫成整套室內導航已可靠。

接AI時先凍結地圖建庫照片，另用不同趟次／方向／時段測試query；同一張參考圖或相鄰影格不能同時當建庫與獨立測試。店名／牌／柱等穩定證據與行人／可移動物件分開標；保留原圖與人手真值，模型輸出只作待覆核候選。

1.2.0+3已執行的資料是**手動合成樣例**：`app/lib/indoor/replay_scenarios.dart`定義12個虛構node、12條edge（1條封閉）、10情境及47筆標註觀察。內容涵蓋順行、停留、漏拍、倒行、分岔、相似店面歧義、已核准／未知店名、未知／錯樓層、遲到／過期及遠處重新確認。沒有來源照片、GPS、實拍OCR或實際商場座標，不能把規則通過率叫做影像定位準確率。

重現方法：在app目錄執行 `dart tool/verify_graph_replay.dart ../verification/graph-replay-1.2.0+3.json`。trace記每筆拍攝／收到時間、狀態、目前／上次node、候選、路線與queue；21項graph單元測試另以人手預期ID／拒答狀態核對，6項UI測試檢查中英文大字、背景暫停、朗讀重設及入口資源。全部Flutter共274項通過。圖可表達這些例子，不表示已在HKDI重走或可量公尺。

下一個資料工作仍需：取得場地許可，手動核實真實單層node／連線，凍結參考圖；另外一趟次拍query與人手位置真值，再評估圖片特徵／OCR候選。必須報未知與錯分支，不把同一張參考圖拿來測定位。深度／空間音效另量尺與幾何真值；N08別名是預先核准示例，不證明AI能自行發現店名改變。

地圖內容隨覆核變好與A／B私人權重微調是兩條流程：改一間店的文字／地標版本不等於已重新訓練物件模型。每條流程各有獨立測試及回退版本。

## 7. 來源、授權與可重現資料

原始影像／標籤保留，不因文件清理而改成已覆核。類別字典、資料集本地索引、專案ID及外部COCO／Firebase ID分開映射；52項登記與20／23類候選不代表模型已支援。歷史提案僅供查考，不直接覆蓋活動映射。

| 來源 | 狀態／需保留的來源資料 |
|---|---|
| HK9原來源 | 準備後9,549 train／1,374 val／620 test；歷史split可能有場景重疊，不宣稱全獨立 |
| 新室內門 | 340圖／403原門框作實驗train，來源只宣告door覆蓋；不是340個獨立實體門 |
| 澳門圍欄 | 436來源圖作實驗；保留原框定義，沒有新獨立圍欄benchmark |
| Open Images門 | 27圖：14 val／13 test；逐圖作者與圖像CC BY2.0、框CC BY4.0資料隨來源保留；外國小樣本不是HKDI準確率 |
| [icons-wrs49/icons-vbuao v3](https://universe.roboflow.com/icons-wrs49/icons-vbuao/dataset/3) | B來源，聲明CC BY4.0；與其他來源按像素／相似群組隔離 |
| [arrowsicons/arrows_icons-pmnkv v2](https://universe.roboflow.com/arrowsicons/arrows_icons-pmnkv/dataset/2) | B既有偵測框來源，聲明CC BY4.0；不把分類標籤當整圖框 |
| [eyeway/subway-guide v10](https://universe.roboflow.com/eyeway/subway-guide/dataset/10) | B來源，聲明CC BY4.0；實體設施與牌內圖示分開 |
| [rne/pictogram_detection v2](https://universe.roboflow.com/rne/pictogram_detection/dataset/2) | B來源，聲明CC BY4.0；方向／別名需明確映射 |
| [Everyday Object Finder v3](https://universe.roboflow.com/chris-law/everyday-object-finder/dataset/3) | 歷史來源聲明CC BY4.0，但含網絡／素材來源疑點，不宣稱逐圖權利已核實；原用法只train，不把舊實驗統計當本輪結果 |
| [People Detection v1](https://universe.roboflow.com/chris-law/people-detection-o4rdr-nlryq/dataset/1) | 歷史聚合導出聲明Private、部分上游未聲明；保留研究限定與不重分發記錄，不因清理而自動核准新用途 |
| Wikimedia候選 | 歷史記錄901圖、16類、尚未用；CC BY／BY-SA／CC0等逐圖作者、license與URL必須隨資料保留，只有整圖標籤不作偵測真值 |

People Detection原附README的上游署名保留如下；這是來源記錄，不表示所有上游已重新核准或納入目前訓練：

| 上游项目 | 许可 |
|---|---|
| [First Pedestrian Test](https://universe.roboflow.com/safer-strides/first-pedestrian-test) | CC BY 4.0 |
| [person_camera_security1](https://universe.roboflow.com/chinh/person_camera_security1) | CC BY 4.0 |
| [Human Action Recognition 2000](https://universe.roboflow.com/skripsi-u18dy/human-action-recognition-2000) | CC BY 4.0 |
| [People Detection](https://universe.roboflow.com/chris-kydks/people-detection-2csbw) | CC BY 4.0 |
| [contador-de-gente teste 3](https://universe.roboflow.com/mackleaps/contador-de-gente-teste-3) | CC BY 4.0 |
| [OD3](https://universe.roboflow.com/object-detection-tuphv/od3-fq4yp) | CC BY 4.0 |
| [Person Detection](https://universe.roboflow.com/illimited/person-detection-gbuka) | CC BY 4.0 |
| [MOT17-03-DPM](https://universe.roboflow.com/bhu-ykklm/mot17-03-dpm-udorc) | ⚠️ **未声明** |
| [The Curve](https://universe.roboflow.com/people-8gcmt/the-curve-02) | CC BY 4.0 |
| [pedestrain safety](https://universe.roboflow.com/intel-9horw/pedestrian-safety-obyfo) | CC BY 4.0 |
| [People Detection](https://universe.roboflow.com/jmedel/people-detection-f0fgt) | CC BY 4.0 |
| [people、rabish](https://universe.roboflow.com/cpk-wow-k5nlf/people-rabish) | CC BY 4.0 |
| [Pascal VOC 2012](https://universe.roboflow.com/jacob-solawetz/pascal-voc-2012) | CC BY 4.0 |
| [Person Detection (General)](https://universe.roboflow.com/mohamed-traore-2ekkp/people-detection-general) | CC BY 4.0 |

模型來源記錄：YOLO11／YOLO-World為Ultralytics（原記錄AGPL-3.0），SAM2.1為Meta（Apache-2.0），Grounding DINO為IDEA-Research（Apache-2.0），LocateAnything依其模型卡。實際使用版本的授權與逐圖署名保留，不將歷史來源聲明當成新權利審查。

快照保留影像／標註SHA、授權、coverage、場景分組與split；LICENSE-SOURCES.json及audit.json跟snapshot。原docs內機器證據移到verification/，候選提案移到configs/planning/，本機覆核CSV／圖片等移到dataset_pipeline/review_artifacts/；工具新輸出不得再寫進docs。舊文件已移出工作閱讀區，Git內已提交版本可由歷史還原，本機未提交舊稿另有清理前備份。

## 8. 維護紀錄

2026-10-27：將訓練方案、類別審核、A／B狀態、來源署名與評估整合為本文件；修正B正式run已啟動的交接資訊。本輪未改模型、未重跑訓練，不把進度交接當成新checkpoint驗證。舊稿已刪，清理前原檔另有可恢復本機備份；資料／驗證檔移位後雜湊一致，資料工具路徑已同步調整且Python語法檢查通過。背景跟進的文件路徑更新因自動審批工具用量限制未執行，未繞過限制。後續結果直接覆寫現況並記日期、run、證據與限制，不再新增第四份文件。


2026-10-27階段化補充：加入S0–S7與D01–D12逐功能方法／產物／依賴／驗收；B11依本機17:10交接更新為epoch22後中斷、Drive連接受阻。保留當時證據時間，不宣稱本輪直接查到新進度。下一步先恢復連接及核checkpoint，同時建立A的HKDI獨立評估與S2覆核清單；本次不啟動訓練。

2026-10-27 graph討論補充：為D09加入手動圖／觀察序列驗證及地圖與query隔離規則，覆蓋停留、漏拍、倒行、分岔、改名、未知與遲到回覆；只屬待驗證計劃，本輪未生成資料或執行實驗。

2026-10-27參考產品補充：加入D13–D14新研究／驗收候選，將路線內容、辨識權重、跨任務與聲音互動分開測；沒有新增訓練資料、執行測試或改模型品質判定。

2026-10-27整合版資料核對：1.1.0+2保存現有 `2026-10-27.mixed10.experimental.1`，10,695,172 bytes，SHA256 `a6366b71e3bd8c2cc1adff8e8777dac03b08f1dbbefd67422bddcfed42a2a4a0`，映射 `[6,11,7,8,9,24,1,49,26,18]`；九類備援保留。此為既有試用產物，不是本輪重訓；gate=false、門弱、圍欄無獨立val等限制保留。247項Flutter測試只驗工程行為，中英文名稱不新增類別，導航辨識不儲存／上傳新資料，B11未重啟。

距離驗收D09補充：分開記錄相機平面Z深度、反投影後的徑向距離及地面前向距離；以獨立量尺／雷射真值檢查不同距離、角度、材質與光線，記有效樣本、未知、絕對誤差分位數與時間延遲。框與背景混合、玻璃／鏡面、邊界及動態物件要專門分層。沒有場測前不填精度數字；本輪仍未採集RGB-D、未驗證graph或建立空間音效基準。

同日版本備份核對：上述精確試用模型與manifest已隨App源碼commit `687d401` 及不可變 `v1.1.0+2` 保存GitHub，舊hkdi10 pilot對應 `v1.0.0+1-baseline`；兩個prerelease均已建立。這只保證可追溯還原，不改變品質gate或B11訓練狀態。

同日裝機核對：簽署App包內模型SHA及manifest再核對相符後，1.1.0+2已安裝／啟動iPhone 15 Pro Max。沒有收集新訓練資料、重訓或新增準確率證據，品質限制不變。

2026-10-28 graph版：完成上述合成graph規則回放與機器trace，不收集私人資料、不重訓A／B、不改B11。1.2.0+3沿用mixed10試驗權重，SHA與品質gate不變；274項工程測試不構成新模型精度證據。

同日1.2.0+3發佈核對：合成47筆trace與相符原試驗模型已隨 `95d7cda`／`v1.2.0+3` 保存GitHub。手機解鎖後安裝／啟動成功；未採集新影像／深度或進行場地定位評估，模型gate及B11狀態不變。

同日裝機核對：1.2.0+3安裝／啟動成功，仍沿用相同mixed10試驗模型及映射；沒有新的實拍資料、權重或品質指標。274項工程測試與裝機成功不代表真實室內定位已通過。

2026-10-28 測距試驗版：1.3.0+4新增ARKit中央5×5深度樣本的工程過濾與徑向距離顯示；原生12項合成檢查驗證Z／徑向換算、信心／coverage、混合表面、範圍及非有限值拒答，Flutter另檢查短時穩定、過期與生命週期。**沒有新增實拍／RGB-D資料、人工真值、訓練、模型權重或新的準確率數字**；mixed10模型SHA及失敗品質gate不變，B11未動。單純有數字不證明準確。

D09下一輪量尺驗收：固定單層實心目標，由後置鏡頭至準星所指表面以獨立量尺量0.5／1／2／3米，各距離與角度重複，另收玻璃／鏡面／細邊／遮擋／移動／低光。逐次記真值定義、距離讀數或未知、裝置與版本、表面／光線、等待時間；報絕對誤差分位數、偏差、有效率／未知率及過期撤回。手動記錄先獨立保存；本App不自動錄製或上傳。尚未有這批資料，不能給厘米精度、避障成功率或把通過合成測試當現場驗收。參考圖／query分開的graph定位工作仍待，量尺驗證不取代它。

同輪工程結果：294項Flutter測試與12項原生數值檢查通過，沒有實測距離誤差數字；1.3.0+4簽署包沿用相符mixed10試驗模型與未通過品質gate。

同日1.3.0+4交付：GitHub先保存相同mixed10權重／manifest，核對後安裝及啟動成功；沒有採集新照片或深度真值，未重訓／改品質gate，量尺誤差、實地定位及B11狀態均不因裝機而改為通過。

2026-10-28 物件距離版：1.4.0+5接現有A模型與同幀sceneDepth，新增框座標反轉、中央半區獨立像素、重疊拒答、短時唯一框配對及未知撤回。模型權重、SHA、class mapping、validationGatePassed=false與B11狀態不變，沒有採集實拍／RGB-D、重訓或新增準確率。物件模式用設定的播報門檻；既有外國val在conf0.30的門／行人指標不能當新版任務成功率。

D09聯合驗收：每筆獨立真值包含物件類別、影像框／表面對應、從後置鏡頭至指定表面的量尺距離、材質／光線／角度及未知標記。分開報類別誤認／漏認、距離有效率／未知率、有效讀數誤差，以及「類別與距離同時正確」比例；不能只算有米數的誤差而隱去漏認／拒答。特別覆蓋雙同類交換次序、人物交叉、門框背景、玻璃／鏡面、細小框、方向裁切、移動與舊幀。先實心物體0.5／1／2／3m，通過後才供空間音效／鳥瞰；框內代表表面不當整物體最近點或可通行真值。

D08輸入驗收補充：共享iOS前處理現在依420f／420v及601／709矩陣轉RGB，未知矩陣拒絕；新增實際CVPixelBuffer full／video range原生測試及合成紅／灰／黑白檢查，原生bundled shape／SHA按目前manifest核對。這是格式與幾何工程證據，前處理改變對真實辨識任務的影響仍需獨立測試，不因權重相同就宣稱精度不變或改善。

同輪1.4.0+5工程核對：完整314項Flutter、11項iOS原生XCTest、25項距離／座標／色彩數值檢查通過，analyze無問題，最終iOS簽署建置、系統簽章及包內版本／模型相符。verification/app-1.4.0+5.json記錄構建快照；發佈／裝機由收據更新。不是實地辨識、量尺精度或VoiceOver驗收。

同日1.4.0+5交付：相同mixed10權重／manifest隨不可變tag保存，遠端核對後安裝及啟動iPhone成功。未收集新實拍／量尺真值、未重訓或改B11／品質gate；314項工程回歸及裝機結果不能當聯合任務準確率。

2026-10-28 1.4.1+6故障回饋：使用者回報多人畫面物件米數全未知，但準星模式可量度；沒有取得原始RGB-D或量尺真值，不能標為感測器故障或精度失敗百分比。使用者截圖不加入共享資料或GitHub。新增合成曲面回歸，驗證跨大框分散點可混入不同表面而拒答，連續局部5×5在相同可信度門檻下可通過；另測局部遮擋避讓／完全遮擋拒答及原因／有效點回傳，318項Flutter與33項原生數值檢查通過。

D09現場下一步先對靜止單人／實心物體核對取樣圓點與指定表面的量尺距離，再測多人／椅背／衣服／背景。分開記拒答原因（缺深度、可信點少、混合表面、遮擋、小框、時序未穩等），不可只降低門檻來提高有讀數比例；有效點數不是距離正確率。局部區塊改善可用性仍待同場景覆驗，不把合成通過當人像測距已可靠。未收新訓練資料、未重訓／改A模型品質gate或B11狀態。

同輪1.4.1+6最終核對：318項Flutter、33項原生數值檢查、analyze、簽署建置、系統簽章及包內版本／原模型SHA通過。先保存GitHub分支／tag／prerelease，再交付；最新裝機狀態由verification/release-receipts/app-1.4.1+6.json記錄，未將合成回歸當真機問題已解決。
