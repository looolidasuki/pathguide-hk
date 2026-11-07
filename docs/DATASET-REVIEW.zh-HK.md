# Dataset Review：PathGuide 類別、資料與品質驗收

更新：2026年11月6日。類別字典維持在前；產品及導航行為見[Frontend整體規格](FRONTEND-DESIGN.zh-HK.md)，服務與交付見[Backend](BACKEND-DESIGN.zh-HK.md)。
**2026-11-05執行責任更新：使用者已改由Codex直接開發及驗收，取代下方較早的DSH全實作限制。DSH三輪失敗證據保留，不再派模型。Codex相機協調器及lease／一次回覆助手已通過30項獨立工程情境；Vision／Depth／Menu及P2-C原生錄路來源已接入，45項原生Simulator測試、435項Flutter測試及analyze通過。P2-D Flutter入口已接入，1.5.0+9簽署建置通過；已推送不可變tag／prerelease並核對遠端，iPhone安裝及啟動成功；人工／VoiceOver驗收仍待完成。**
**2026-11-06新增規格：** [已錄路標持續改善規格](https://github.com/actiondarr/pathguide/issues/19)已確認及發布；路標改善候選、真正權重訓練及更新閉環仍未實作／驗收。原有A／B、雲端與手機交付狀態不因此升格。


**目前結論：A十類試驗模型的品質gate仍為false，修正候選拒用；B11未完成發佈／App整合。Dataset採集／標註／新訓練仍暫停。** 本機路線記憶及雲端看圖不等於訓練資料或人工真值。

閱讀順序：[字典](#class-dictionary) → [現況／基準](#quality-state) → [來源／覆核](#data-workflow) → [驗收／改善](#quality-acceptance) → [B11](#b11-handoff) → [工作清單](#dataset-plan)。

<a id="class-dictionary"></a>
## 1. 類別字典與映射

### Class dictionary：計劃幾多類、現在有幾多類

**現階段先做好 A 10類物件＋B 11類圖示；完整候選範圍是 A 23類＋B 12類，共35個跨兩個模型的候選輸出。** 35類是既有詳細提案的範圍，未全部核准／訓練；目前App只內置A十類試驗版及九類歷史比較版，B尚未入App。私人微調首版沿用A十類，不自行擴類。

| 層次 | 數量 | 用途／狀態 |
|---|---:|---|
| A：目前主物件模型 | 10 | 已內置試驗；品質gate未通過，不能把「有輸出」當準確可靠 |
| B：活動圖示訓練設定 | 11 | 正式run最後交接中斷；未完成發佈／App整合 |
| A：完整詳細候選 | 23 | 下表列全部候選；新增13類待定義、資料及驗收，不承諾一次加入 |
| B：完整候選 | 12 | 活動11類加延後的一般toilet_symbol |
| A：早期核心方案 | 20 | 道路車輛合成road_vehicle一類；詳細23類拆為car／motorcycle／bus／truck，故增加3類，兩份不可相加 |
| App標籤登記 | 52 | 顯示名稱／舊專案ID字典；登記不代表現有模型能辨識52類 |
| COCO來源參照 | 80 | 外部來源字典；詳細A提案只選其中6類，不代表保留全部COCO能力 |

#### A 主物件：完整23類候選與現用10類對照

「候選序號」只屬23類提案；「現用index」才是目前十類模型的輸出順序。專案ID為既有App映射，並非COCO ID或待議的正式字典ID。`—`表示未分配／不在目前輸出，不能拿候選序號直接接App。

| 候選序號 | canonical key | 中文 | 既有App專案ID | 現用A index | 現況 |
|---:|---|---|---:|---:|---|
| 0 | `person` | 行人 | 6 | 0 | 內置試驗 |
| 1 | `bicycle` | 單車 | 11 | 1 | 內置試驗 |
| 2 | `car` | 汽車 | — | — | 擴充候選，未納入現用模型 |
| 3 | `motorcycle` | 電單車 | — | — | 擴充候選，未納入現用模型 |
| 4 | `bus` | 巴士 | — | — | 擴充候選，未納入現用模型 |
| 5 | `truck` | 貨車 | — | — | 擴充候選，未納入現用模型 |
| 6 | `bin` | 垃圾桶 | 7 | 2 | 內置試驗 |
| 7 | `bollard` | 護柱 | 8 | 3 | 內置試驗 |
| 8 | `traffic_cone` | 交通錐 | 9 | 4 | 內置試驗 |
| 9 | `caution_slippery` | 小心地滑告示 | 24 | 5 | 內置試驗 |
| 10 | `stairs` | 樓梯 | 1 | 6 | 內置試驗 |
| 11 | `escalator` | 扶手電梯 | 49 | 7 | 內置試驗 |
| 12 | `temporary_barrier` | 臨時路障 | — | — | 擴充候選，未納入現用模型 |
| 13 | `fence` | 固定圍欄 | 26 | 8 | 內置試驗；缺獨立驗證真值 |
| 14 | `push_cart` | 載貨手推車 | 13 | — | 擴充候選，未納入現用模型 |
| 15 | `step` | 單級台階 | 14 | — | 擴充候選，未納入現用模型 |
| 16 | `elevator` | 升降機入口 | 3 | — | 擴充候選，未納入現用模型 |
| 17 | `ramp` | 斜道 | 4 | — | 擴充候選，未納入現用模型 |
| 18 | `tactile_paving` | 盲道 | 15 | — | 擴充候選，未納入現用模型 |
| 19 | `zebra_crossing` | 斑馬線 | 16 | — | 擴充候選，未納入現用模型 |
| 20 | `door` | 一般門 | 18 | 9 | 內置試驗；門辨識品質未過關 |
| 21 | `sign_pictogram` | 設施方向指示牌 | 20 | — | 擴充候選，未納入現用模型 |
| 22 | `fixed_pole` | 固定細柱 | — | — | 擴充候選，未納入現用模型 |

A定義重點：`person`對應App的`pedestrian`；`stairs`為現用合併樓梯類，`step`是待新增單級台階。`fence`與`temporary_barrier`須先統一固定／可移動邊界；`bollard`與`fixed_pole`須避免同一物件重複標註。`door`須統一門口／門板框法。`sign_pictogram`指整塊牌面，B辨識牌內符號；現用A未包含找牌能力。道路四類可在播報時合成road_vehicle，合併播報不等於模型只有一個車輛輸出。

#### B 牌內圖示：完整12類候選與活動11類對照

B用獨立namespace；不能套用A專案ID。一般洗手間圖示延後後，其後類別的活動index有前移，必須依活動設定讀取。

| canonical key | 中文 | 活動B index | 狀態／定義 |
|---|---|---:|---|
| `male_symbol` | 男士圖示 | 0 | 活動訓練類，未入App；設施牌內的男性符號；不是辨識真人性別 |
| `female_symbol` | 女士圖示 | 1 | 活動訓練類，未入App；設施牌內的女性符號；不是辨識真人性別 |
| `wheelchair_symbol` | 輪椅／無障礙圖示 | 2 | 活動訓練類，未入App；只辨識標記，不保證設施可用 |
| `toilet_symbol` | 一般洗手間圖示 | — | 延後，未列入本輪11類；不表示男或女；只有 WC／文字者交 OCR |
| `lift_symbol` | 升降機圖示 | 3 | 活動訓練類，未入App；牌內設備圖示，不是實體入口 |
| `escalator_symbol` | 扶手電梯圖示 | 4 | 活動訓練類，未入App；不推論實際運行方向 |
| `stairs_symbol` | 樓梯圖示 | 5 | 活動訓練類，未入App；不直接分上樓／落樓 |
| `exit_symbol` | 出口圖示 | 6 | 活動訓練類，未入App；出口人形等圖案；純文字 EXIT 交 OCR |
| `arrow_left` | 向左箭嘴 | 7 | 活動訓練類，未入App；依轉正牌面的二維朝向 |
| `arrow_right` | 向右箭嘴 | 8 | 活動訓練類，未入App；依轉正牌面的二維朝向 |
| `arrow_up` | 向上箭嘴 | 9 | 活動訓練類，未入App；不直接等於上樓或直行，須結合牌面語境 |
| `arrow_down` | 向下箭嘴 | 10 | 活動訓練類，未入App；不直接等於落樓或向後，須結合牌面語境 |

OCR讀出的店名、房號、菜名、價格及樓層文字不逐字新增物件class；箭嘴的畫面方向亦不直接等於樓層、通行方向或設備運行方向。B的exit資料稀少，列入訓練不代表成熟。

#### 字典來源與修改規則

- 現用A索引／專案ID：[模型manifest](../app/assets/models/detector.json)。
- 活動B順序：[11類設定](../dataset_pipeline/configs/sign-icon-demo11-v1.json)；[原12類設定](../dataset_pipeline/configs/sign-icon-v1.json)保留候選。
- 完整A23／B12名稱與正反例：[詳細字典提案](../configs/planning/class_dictionary.proposal.json)；[早期20類方案](../dataset_pipeline/configs/roadmap-20-v1.json)只作範圍對照。
- [App 52項標籤](../app/assets/labels.json)是舊專案登記；正式穩定字典ID仍待來源／團隊定義確認。本節整理現有資料，不改動正式字典、權重或映射。

<details>
<summary>展開全部52項App標籤登記（非目前已辨識類別）</summary>

| App專案ID | key | 中文 |
|---:|---|---|
| 0 | `footbridge_entrance` | 天橋入口 |
| 1 | `stairs` | 樓梯 |
| 2 | `escalator_outdoor` | 戶外扶手電梯 |
| 3 | `elevator` | 升降機 |
| 4 | `ramp` | 斜道 |
| 5 | `footbridge_railing` | 天橋欄杆 |
| 6 | `pedestrian` | 行人 |
| 7 | `bin` | 垃圾桶 |
| 8 | `bollard` | 護柱 |
| 9 | `traffic_cone` | 交通錐 |
| 10 | `barrier_water` | 水馬 |
| 11 | `bicycle` | 單車 |
| 12 | `scooter` | 滑板車 |
| 13 | `push_cart` | 手推車 |
| 14 | `step` | 台階 |
| 15 | `tactile_paving` | 盲道 |
| 16 | `zebra_crossing` | 斑馬線 |
| 17 | `glass_door` | 玻璃門 |
| 18 | `door` | 推拉門 |
| 19 | `escalator_indoor` | 商場扶手電梯 |
| 20 | `sign_pictogram` | 指示牌 |
| 21 | `glass_door_indoor` | 商場玻璃門 |
| 22 | `shop_front` | 店鋪門面 |
| 23 | `fork_in_road` | 分岔路口 |
| 24 | `caution_slippery` | 小心地滑 |
| 25 | `crowds_of_people_queuing` | 排隊人潮 |
| 26 | `fence` | 圍欄 |
| 27 | `barrier_fencing` | 工程圍網 |
| 28 | `scaffold` | 鷹架 |
| 29 | `road_excavation` | 掘路工程 |
| 30 | `power_distribution_box` | 配電箱 |
| 31 | `goods` | 街邊貨物 |
| 32 | `goods_rack` | 貨物架 |
| 33 | `cardboard` | 紙皮 |
| 34 | `table` | 桌椅 |
| 35 | `roll_up_banner_stand` | 易拉架 |
| 36 | `billboard` | 廣告看板 |
| 37 | `traffic_cone_connector_rod` | 交通錐連接杆 |
| 38 | `abrasion_resistant_steel_plates` | 鋪路鋼板 |
| 39 | `hand_truck` | 搬運手推車 |
| 40 | `pallet` | 唧車 |
| 41 | `pushchair` | 嬰兒車 |
| 42 | `broken_tree` | 樹木 |
| 43 | `tree_root_on_the_road` | 地面樹根 |
| 44 | `cycle_path` | 單車徑 |
| 45 | `streetlight` | 路燈 |
| 46 | `sign_post` | 標誌桿 |
| 47 | `bucket` | 水桶 |
| 48 | `obstacle` | 障礙物 |
| 49 | `escalator` | 扶手電梯 |
| 50 | `downstairs` | 落樓梯 |
| 51 | `upstairs` | 上樓梯 |

</details>

<a id="quality-state"></a>
## 2. 現況、品質問題與凍結基準

### 目前問題總結（2026-10-31）

**目前只能確認前處理一致性已改善，不能說十類模型已修好。三個修正候選均拒用；先整理問題及資料驗收，不再憑epoch數追加訓練。** 原App十類權重及gate=false維持不變，九類只作歷史比較。本輪另建立逐圖strict基準（見下節），量化門／person漏報及同源曝光；仍未訓練、換權重或部署。以下區分使用者回報、已重現證據與尚未證實的根因。

| 優先度 | 問題及證據 | 尚未確定／下一個判定點 |
|---|---|---|
| P0 | **來源權重本身誤認、漏認。** 使用者回報門→行人／圍欄；公開無人房間的床鋪也被原PT及TFLite認作行人。14張原門val圖的18個門，App預設conf0.7只找回2個 | 不是只換前處理便解決；尚未重現使用者原本那道門，不能把公開例子冒充原場景 |
| P0 | **物件測距更嚴重的確切原因仍未定位。** 這是使用者回報；普通辨識及ARKit同幀辨識共用縮圖修正 | 缺同一道門、同角度／距離、同門檻的兩路原始輸入與輸出比較；不能直接斷言ARKit、旋轉或距離計算就是主因 |
| P0 | **資料覆蓋及定義不足。** 混合來源只對已標註類給監督，其他類是unknown；門圖未標person／fence不等於它們不存在。已觀察到櫃、車／電器門等來源語義與入口門候選定義有差異 | 需覆核門／圍欄／行人的正例與確定負例、框定義及同源分組；目前只補少量反例，未證實哪項是主要根因，不能把全部unknown改成負例 |
| P0 | **舊評估與App取類方式不同。** 舊multi-label驗證可同時保留高分fence與次高door；App只取最高類，可能漏門。另有rect、NMS等設定差異 | 新增A10專用argmax驗證及同設定比較；歷史不同設定的P／R不可直接當改善幅度。B11原validator行為未改 |
| P0 | **目前修正實驗沒有泛化改善。** 本機補負監督能消除已參與訓練照片的誤報圍欄，但門val退化；Colab加入新門圖後召回仍無提升、誤報增加 | 不發佈候選、不以訓練診斷或較低loss代替獨立驗證；先查標註完整性、來源／場景偏差及錯誤類型，再決定下一實驗 |
| P0 | **留集及品質門檻仍不足。** 新val 15圖／21門框加原OID val共29圖／39框，標註為助手候選覆核；strict同源留集1,082圖，但person／door／fence仍缺足夠獨立正負例；舊legacy val有279張train近重複 | 不能給可靠整體準確率、圍欄召回或推算HKDI效果；原test與新test均未推理，須保留。先按新基準補獨立實體／場景，再做任務驗收 |
| P1 | **手機任務驗收仍缺。** 1.4.3+8已修雙線性／letterbox；單元、數值及格式對照通過。模型名稱、表面距離及失敗恢復是不同結果 | 仍需原門場景、量尺、等待／誤播／漏播、VoiceOver及跨任務切換真機驗收；詳見Frontend，不把工程通過當品質通過 |

#### 已排查及已修正的部分

十類模型SHA／bytes／輸出映射吻合，person→ID6、fence→ID26、door→ID18未見對調；42個自然圖輸入的原PT↔TFLite最大差2.65e-5，未見匯出造成上述誤認。原12,346張來源影像已逐張核SHA。iOS舊最近鄰／截斷尺寸已改為半像素雙線性／取最近整數，平均像素差0.015123→1.95e-7；這些證據排除了部分工程問題，並未證明剩餘誤認全屬某一項資料或訓練原因。

#### 修正實驗的實際結果

本機control／repair各4 epoch，固定來源十類best、回放及設定；repair只對18張train圖補person不存在，其中11張也補fence不存在。conf0.7，原18個門的TP／FP／FN為baseline **2／1／16**、control **1／0／17**、repair **0／0／18**。訓練診斷的fence誤報11張→0張，並未轉成門val改善；兩個候選均拒用。MPS非逐位確定、單seed、助手覆核，不作因果或品質通過聲明。

其後公開OID候選先按作者／pHash分組及排除原留集相近來源，在新模型預測前凍結27張train（29門框）／15張val（21門框）。保留署名及逐項修訂，正式taxonomy／ID未改。免費T4以原十類best、新run、舊類回放、凍結backbone／BN、不重排head完成6 epoch；訓練約205秒，baseline／candidate批量評估合計約93秒，訓練迴圈沒有LLM呼叫。

固定640 RGB letterbox、argmax、clipped boxes、class-aware NMS0.45、max100、GT匹配IoU0.5；下表為conf0.7，門指標只在已覆核／標註門類的14張原val及15張新val計算，legacy未標門的圖不當負例。

| 留集 | baseline TP／FP／FN | Colab candidate TP／FP／FN | 判定 |
|---|---|---|---|
| 原val：18門框 | 2／1／16 | 1／4／17 | 召回、誤報均退化 |
| 新val：21門框 | 3／2／18 | 3／3／18 | 召回無提升，誤報增加 |

兩組合併門AP50約0.1526→0.0848；原val舊八類最大AP50下降約3.88個百分點。新val中已確認無person的12圖、無fence的10圖，兩模型在conf0.7均無該類誤報，不能因此宣稱person／fence召回良好。此候選亦拒用，未匯出／替換App權重。checkpoint SHA `8847eb6265f0a6f4a0e39e26efb066f6f9121a8494bfc75527a4bdba65ca1ce7`；完整聚合證據見[修正對照](../verification/mixed10-coverage-repair-20261030.json)，[Colab notebook](https://colab.research.google.com/drive/1I5tvr1lTOHAeuHcg8YUjtwOs87iH6yg-)及原始產物留在擁有者Drive。

6項coverage、2項argmax／梯度、2項來源完整性／test不解壓測試通過。它們驗證程式及資料隔離，沒有驗證模型可交付。B11、原test、新test、App權重及付費GPU設定維持原狀。本次先完成review總結，不新增訓練。

<a id="1-實際基線"></a>

### 實際基線

目標是用新場景改善辨識，以獨立資料回答：哪些類別／場景變好、誤報與漏報有何變化、其他類別有沒有退步。

| 模組 | 已核對狀態 | 缺口 |
|---|---|---|
| A 主物件 | 2026-10-27.mixed10.experimental.1，十類；九類另作備援 | 門 precision 28.6%、recall 11.1%，僅18個小型外國驗證框；gate=false |
| A 其他類別 | person AP50 56.13%，baseline 61.01%；樓梯已合併 | 檢查遺忘；圍欄無獨立驗證，不填虛假準確率 |
| B 圖示 | sign-icon-demo11-v1，11類；2,301／469／557張 train／val／test | 正式run曾到22輪後中斷，Drive連接受阻；exit train僅13框，樣式／實體獨立性不足 |
| OCR | iPhone 菜單已有系統文字辨識 | 不能代替牌面、樓層及文字／箭嘴配對驗收 |
| 室內幾何 | 1.4.1+6已有同幀框內表面LiDAR試驗及聯合驗收方法；未有實測結果 | 距離、地面、落差及路徑另設真值，不由 A 的 mAP 推定 |

A 十類順序為 person、bicycle、bin、bollard、traffic_cone、caution_slippery、stairs、escalator、fence、door，專案 ID 為 `[6,11,7,8,9,24,1,49,26,18]`。私人首版不自行擴 class。

B 一般 toilet_symbol 延後，活動11類與原12類路線圖分開保存。現有 snapshot 只准實驗訓練；含插圖與來源增強，抽樣篩查不能寫成全量人工覆核。2026-10-27 17:10本機交接回報：12項本機測試與11圖CPU流程試跑、兩輪GPU smoke曾完成；正式run最後核實epoch22後中斷，Drive mount回報credential propagation失敗，尚未resume。這是交接證據，本輪未直接重讀Colab或新checkpoint，不能稱為正在健康訓練或已完成。

### A10逐圖可信基準（2026-10-31，只讀評估）

本輪把「十類模型錯在哪裡」由聚合分數改成可重跑、逐圖的基準；沒有訓練、換權重、部署或改App。程式：[a10_audit.py](../dataset_pipeline/a10_audit.py)、[a10_evaluate.py](../dataset_pipeline/a10_evaluate.py)、[a10_report.py](../dataset_pipeline/a10_report.py)。輸入為已取回的12,346筆來源records／coverage、27+15張凍結OID門候選及原十類PT（SHA `33e8eb1d…54946b7`；對應App TFLite `a6366b71…a4a0`，PT↔TFLite parity另見[42自然圖對照](../verification/mixed10-natural-parity-20261030.json)）。完整數字在[本輪證據](../verification/a10-baseline-20261031.json)；逐圖檔在ignored `review_artifacts/2026-10-31/a10-baseline/`。

設定：640 float RGB半像素雙線性letterbox、114填色、argmax、class-aware NMS0.45、max100、GT匹配IoU0.5；conf0.3／0.7；AP為101-point AP50。這是來源PT的離線評估，不是NV12相機、TFLite真機或任務成功率。

#### A10覆核圖包完整性工具（2026-11-02，DSH交付後整合）

既有ignored `review_artifacts/2026-10-31/a10-error-review/`已有29張門、53張person錯例及10張fence圖的覆核包，仍是`pending_human`。新增[只讀檢查器](../dataset_pipeline/validate_a10_review.py)及[合成測試](../dataset_pipeline/tests/test_validate_a10_review.py)，由DSH兩輪實作，Sol覆核格式、類別計數邊界及錯誤處理後整合；27項測試及6個獨立CLI案例通過。只讀manifest／CSV與來源JSON／SHA，圖頁只查存在，不讀原圖像素、不跑推理或重建圖包。

本機實跑三份來源輸入SHA均吻合，但完整性報告為**fail（exit1）**：1項門FP總數差異及4項逐圖事件差異。門review表TP／FP／FN為5／3／34，boxes表為5／8／34；GT39一致。person boxes覆蓋完整strict範圍（277GT、98TP／117個FP事件／179FN），53張selected review只有96GT（0TP／17個FP事件／96FN），兩種範圍明確分報，不能直接互減或把boxes的117當可信模型FP。來源generator現碼以整數pred_index比較prediction物件，可能將已配對prediction再次列為FP；現有manifest沒有generator SHA，故產物生成版本仍列unknown，不能以這個發現改寫既有模型品質基準。

這包交付的是能揭示不一致的工具；圖包錯誤及人工真值尚未修復。原圖、標註、CSV、split、class ID、模型及B11均未變；`human_approved=false`、quality gate仍未通過。下一個候選範圍是先確認並修正FP事件匯出、輸出新包再比對，不覆寫原包；目前沒有新增派工／訓練授權。摘要、費用、diff及SHA見[W1機器證據](../verification/dsh-w1-integrity-20261102.json)。

使用：`python3 dataset_pipeline/validate_a10_review.py --pack <既有圖包> --source-root <repo> --output <圖包外全新JSON路徑>`。exit0只代表所檢完整性項目通過，仍非人工核准；exit1為資料／引用／計數錯誤，exit2為CLI或輸出拒絕。拒絕已存在或位於圖包內的輸出；無法核實的producer版本保持unknown。

#### 同源與留集

- 12,388筆（12,346來源＋42 fresh）逐張核SHA；無跨split exact byte重複。1,403張val中，279張（19.9%）與train有pHash≤6候選、23張同video群組、0張exact SHA。
- 剔除後clean 1,124張；再剔除同source_key後strict 1,082張（1,053 legacy＋14 OID＋15 fresh）。strict正例：person 277、bicycle 274、bin 189、bollard 735、traffic_cone 270、caution_slippery 8、stairs 55、escalator 155、door 39、fence 0。
- 同源曝光會推高舊val分數：stairs AP50 0.834→0.588、caution 0.980→1.000但只剩8框；person 0.575→0.573穩定。舊「all val」的stairs／caution數字不可再當泛化基準。
- Macao／indoor 776張只在train，沒有留集；fence在val只有10張coverage、0正例，recall不可量度。

#### 逐類基準（strict，conf0.7）

| 類 | GT框 | TP／FP／FN | P | R | AP50 |
|---|---:|---:|---:|---:|---:|
| person | 277 | 98／19／179 | 0.838 | 0.354 | 0.573 |
| bicycle | 274 | 176／9／98 | 0.951 | 0.642 | 0.854 |
| bin | 189 | 160／2／29 | 0.988 | 0.847 | 0.884 |
| bollard | 735 | 373／12／362 | 0.969 | 0.507 | 0.842 |
| traffic_cone | 270 | 192／1／78 | 0.995 | 0.711 | 0.881 |
| caution_slippery | 8 | 8／0／0 | 1.000 | 1.000 | 1.000（樣本不足，不作穩定基準） |
| stairs | 55 | 16／5／39 | 0.762 | 0.291 | 0.588 |
| escalator | 155 | 90／11／65 | 0.891 | 0.581 | 0.758 |
| door | 39 | 5／3／34 | 0.625 | 0.128 | 0.156 |
| fence | 0 | — | — | — | 無正例，不可量度 |

#### 門的逐圖失敗

- 29圖／39框：5 TP／3 FP／34 FN；P 62.5%、R 12.8%（95% CI 5.6–26.7）、AP50 0.156。
- 原OID val 14圖／18框：2／1／16、AP50 0.198；fresh 15圖／21框：3／2／18、AP50 0.149。
- 27張有門正例的圖中，17張最高門分<0.30；6張≥0.70，但只有5個TP，另有2張是高分但定位／配對錯的FP；再另有1張無門負例被以0.845報門。
- 這39框只說明現用權重對公開門圖仍大量漏報，不能當HKDI效果或使用者原場景已完成。

#### 十類與九類

九類在7個可比較類別（clean留集）AP50全部略高：person 0.607 vs 0.573、bicycle 0.861 vs 0.854、bin 0.937 vs 0.884、bollard 0.869 vs 0.842、traffic_cone 0.891 vs 0.881、caution 0.987 vs 0.960、escalator 0.811 vs 0.758。但九類沒有door／fence／stairs，pipeline較舊，且可能用val選模；不是可靠回退，也不代表九類整體較好。它只指出十類新增類別沒有改善舊類。

#### 判定與下一步

- 這是baseline，不是quality gate通過；gate=false、App 1.4.3+8不變。
- 下一步資料：門至少100張獨立圖／框、20個以上來源群組，含細小、遠、玻璃、雙門、遮擋，每正例至少2個確定負例；person補床、鏡／倒影、袋、人偶、海報硬負例及0.5／1／2／3m正例；fence補正負例（目前0）。保留strict集，補資料後用同一腳本重跑，不先調參。
- 用戶原門場景、量尺及VoiceOver仍屬Frontend真機驗收，不由本節代替。

<a id="1438-前處理與自然圖重測權重未修復"></a>

### 4.3+8 前處理與自然圖重測（權重未修復）

使用者回報門會被認作行人／圍欄，物件及測距比普通辨識嚴重。十類TFLite SHA／bytes與manifest再次吻合；輸出順序person→ID6、fence→ID26、door→ID18未見對調。F02／測距共用前處理由最近鄰＋截斷尺寸改為半像素雙線性＋取最近整數（恰半取偶數）的尺寸；RGB、114填色、NCHW及normalized_xywh契約維持不變。D08本輪先完成手機輸入的一致性檢查，D04權重品質仍未過關。

以mixed-input-plan的14張OID **val**圖／18個來源門標註製成video-range BT.601及full-range BT.709 NV12，旋轉90度後走真實iOS前處理及內置TFLite runtime；沒有對test作推理，也沒有把驗證圖加入訓練。兩種格式共28案例仍只算14張圖，不能增加獨立實體／場景數，亦不是HKDI任務真值。獨立NumPy色彩還原＋OpenCV浮點RGB雙線性參考，平均絕對像素差0.015123→1.95e-7，最大差0.953759→2.45e-5。模擬器縮圖中位數約3.6–4.0ms→6.6–7.5ms，不代表iPhone效能。

固定640方形、argmax、class-aware NMS0.45、max100、GT匹配IoU0.5；另以App原生decoder／NMS核對56個輸出，max20及前5個可見框的本小集門計數亦相同。兩種NV12格式結果相同：

| 流程 | conf | 門TP／FP／FN | 解讀 |
|---|---:|---|---|
| 舊最近鄰 | 0.3 | 3／4／15 | 仍大量漏門 |
| 新雙線性 | 0.3 | 3／4／15 | 本小集未增加找回的門 |
| 舊最近鄰 | 0.7 | 2／2／16 | App預設分數下只找回2個 |
| 新雙線性 | 0.7 | 2／1／16 | 一個FP減少不足以證明泛化改善 |

這與舊Ultralytics rect／NMS0.7報告的P28.6%／R11.1%是不同設定，不能直接相減當改善。其他類別在OID圖未完整標註，不能計算person／fence的P／R。人工檢視公開`96b573942e14da60`無人房間：標準RGB輸入已把床鋪認作person約0.710，修正後兩種NV12約0.722–0.726；證明權重錯誤不依賴ARKit，但不能當作已重現使用者原本那道門。

模型版本仍2026-10-27.mixed10.experimental.1，SHA a6366b71e3bd8c2cc1adff8e8777dac03b08f1dbbefd67422bddcfed42a2a4a0、gate=false；沒有換九類或調高門檻掩蓋。限定Drive的candidate-best.pt／last、training-report、records及coverage已經連接下載；best SHA 33e8eb1d46c265796111bbb516ba4311e2de4bdddb401c65d99cde88254946b7與原匯出來源吻合。42個自然圖輸入的PT↔TFLite最大差2.65e-5，原PT同樣把床認成人，未見匯出造成此誤認。12,346筆原records與coverage一一吻合、類別／split／採樣次數可恢復；逐本機來源重建及12,346張SHA核對已完成。見[來源及自然圖對照](../verification/mixed10-natural-parity-20261030.json)。訓練反例挖掘／逐張候選覆核及負監督對照已完成，但候選未通過；Colab新資料重測亦未通過，下一步先依上節覆核資料與獨立驗收，未知不當負例，原驗證照片不加入訓練。新候選須對照舊類及獨立場景；不操作B11、不付費開GPU。

工程測試14項原生XCTest（兩種range／四向插值等）、328項Flutter、33項數值檢查及analyze通過，GitHub核對後已安裝／啟動iPhone，見[交付收據](../verification/release-receipts/app-1.4.3+8.json)。完整數字與檔案雜湊見[本輪證據](../verification/app-1.4.3+8.json)；本機來源／腳本／輸出留在ignored review_artifacts，未上傳私人影像。權重修正、獨立品質及真機門場景／深度任務驗收尚未完成。

<a id="1427-前端交付與品質證據界線"></a>

### 4.2+7 前端交付與品質證據界線

本輪只改可理解的未知／恢復提示、診斷分層、過期結果／語音撤回及相機交接；App十類與九類模型、映射、深度取樣及既有門檻均不變。內置十類SHA仍為a6366b71e3bd8c2cc1adff8e8777dac03b08f1dbbefd67422bddcfed42a2a4a0。

328項Flutter、12項原生XCTest、33項數值檢查與簽署建置／UI預覽只屬工程證據，見[本輪紀錄](../verification/app-1.4.2+7.json)。未新增標註、獨立留集、TFLite自然圖評估、量尺或多人原場景覆驗，不宣稱準確率改善；B11交接、私人效益對照及資料用途維持原狀。Frontend仍須把名稱正確、表面距離、未知率、恢復成功及VoiceOver任務完成分開驗收。

<a id="data-workflow"></a>
## 3. 資料來源、覆核與可重現性

<a id="7-來源授權與可重現資料"></a>

### 來源、授權與可重現資料

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

<a id="2-覆核工作流程"></a>

### 覆核工作流程

1. 只接收有同意、來源與 UID 可追溯的候選；保留拍攝時模型、原始預測與觸發原因。低信心不是新類別，高分也可能錯。
2. 檢查影像、授權、旋轉、重複與場景；同一門、牌、連拍、影片、裁圖及增強歸同組。獨立性不明時保守同組或只進 train。
3. 模型預標註後，由管理員逐張補漏修框；人工答案另存，記錄覆核者、時間、定義與標註版本，不覆蓋原始預測。
4. 私人首版要求十類全圖覆核；只有確認當次目標全部不存在的圖才作完整背景負樣本。
5. 外部部分標註資料只有在 coverage manifest 明確、遮罩損失／評估測試通過時才加入實驗。未知類別不當負樣本，也不在該來源評分；不可直接把 partial 改 approved。
6. 按 UID 與場景凍結 train／val／test，附影像／標註 SHA256、映射、來源授權及基礎資料版本。訓練開始後不再加入照片。

門需統一完整門口／門板框定義，單列木門、玻璃、半開、側視、逆光、遮擋及櫃門／窗反例。室內「未觀測」與「已觀測無障礙」分開記錄，不從沒有物件框推導可行走。

#### 問題回報與抽樣偏差（Backend認錯／漏認API已本機驗證；App／抽樣待接）

Backend已有submitPhotoIssue／getPhotoIssue／getPhotoReviewItem／submitPhotoReview／withdrawPhotoIssue／listPhotoReviewQueue／listPhotoReviewHistory及本機工作台，僅認錯／漏認私人JPEG；服務預設關閉、未部署，契約及限制以Backend「管理員覆核與自動批次」為準。人工草稿可partial，核准須十類coverage、全圖確認、定義版本、sourceGroup及另一位受權複核者；原預測與人工標註分開，保存revision與原圖SHA／generation。操作者的humanReviewed聲明不取代真人覆核抽查；群組字串不證明實體獨立，approved只屬personal_development_only，不構成共用訓練、獨立評估或發佈許可。未建立真實issue／快照／新模型，也未改B11或品質gate。

現版manual_report為一般手動回報，low_confidence依模型候選觸發；scene_sample已有定時交替抽樣，不是隨機抽樣，完整上傳服務仍未啟用。原生手動／scene_sample可在成功推理但預測為空時擷取JPEG；不能因為沒有框而拒收漏認回報。四類問題UI、隨機排程與分層成效報告均尚未接通。

| 規劃類型／取樣來源 | 覆核與分析規則 |
|---|---|
| 認錯／漏認 | reportKind是使用者主張，與trigger及預測分開；高分亦可認錯，無框也可漏認。保留拍攝時模型／score，覆核全圖答案後才定FP／FN |
| 距離不對 | 保留相機到哪個指定表面的真值定義、量尺來源、裝置／版本及自願提交的讀數；沒有獨立真值保持待查。單張JPEG／畫面截圖／深度點數不作米數真值，不直接作A分類訓練 |
| 文字配錯 | 保存自願提供的原圖、OCR區域／文字及人工菜名—價格或設施—箭嘴關係；與A物件labels分開，不把OCR錯誤當成door漏認 |
| 隨機場景對照 | 在前景、使用者另行同意且開啟收集後，於合資格時間窗按固定seed／機率抽少量幀，獨立於score／有無框；仍受既有30秒／場景60秒冷卻及日額／佇列／撤回限制。抽中時才請求下一成功推理幀，無可用幀記跳過，不假稱完全隨機的行走場景 |

抽樣profile事前固定合資格條件、機率／seed、時間窗、配額優先及去重規則；與模型觸發／手動樣本分開保存sample stratum。記各層可觀察的抽中／成功擷取／品質淘汰／重複／配額跳過數與覆核結果；僅保留用途必要的計數，不能為計分母額外拍照或默認上傳位置。隨機層仍受前景／持機／同意者偏差，模型觸發層及手動回報不能推算一般使用錯誤率。若沒有可靠抽樣機率及分母，分層報告而不合成無偏準確率。

私人照片同意不自動涵蓋AR影像／深度序列、菜單內容或共用模型訓練；新增證據用途與刪除需按Backend另訂契約。原始預測、使用者主張及人工真值三者分開，不以模型自評作完整覆核。

<a id="quality-acceptance"></a>
## 4. 驗收與模型改善決策

<a id="route-landmark-learning"></a>
### 已錄路標真實訓練與獨立重行比較（2026-11-06，規格已確認／未執行）

[已錄路標持續改善規格](https://github.com/actiondarr/pathguide/issues/19)確認以本人已錄常用路線、一個場地起步，行程後真人核實，再按另行用途同意作批次訓練。此目標擴充以往僅補強記憶的定義，但本輪沒有採集、標註、重訓、變更split／權重或啟動B11；A／B類別與品質gate保持。路標身份重認另立namespace，物件mAP不作位置改善證據。

真值包含固定node、實際樓層、錄製方向、connector／exit與來源／覆核revision；不確定資料不核准。新增角度／光線、未知／錯誤及代表性正常例子有取樣原因、trip及群組；AI猜測／自評或次序推進不能自批位置。候選保留及記憶更新與訓練快照分開授權。

三組比較為M0（現版及原記憶）、Mmemory（固定現版加已核實記憶）、Mtrained（相同增補記憶加真實訓練元件）；後兩組同gallery內容／容量與query，記錄資源差異。真正訓練須保存base／output權重SHA、可訓練參數、工具／前處理、設定／run／checkpoint及不可變snapshot；固定Vision特徵、加照片、改門檻或雲端描述均不算更新權重。

同一已知node可出現在不同獨立趟次，這正是本輪重認目標；同趟、近重複、裁圖、增強及相鄰幀不可跨train／val／test。用另一次未訓練行程驗不同光線／角度、相似走廊／樓層／出口、遮擋、錯方向及未知。validation選參數後凍結候選，test不反覆調參；不以已錄地標結果宣稱未見地標或跨場地泛化。

正式訓練前先凍結趟次／條件覆蓋、分母、充分性／不確定範圍、改善幅度、錯認／退化及資源限值；先導只用於估計規模。報正確／錯誤確認、漏認、拒答、錯樓層／出口、等待p50／p95、獨立趟次／node、任務完成／協助／恢復及手機資源；按趟次成組估計差異。不能只比較成功樣本或以全部拒答提高表面準確率。

Mtrained須比Mmemory有事前定義的額外效益，並通過舊路線退化、錯位置及手機／runtime驗收才可發布；未定profile、樣本不足或沒有改善保留現版。舊A的50張／三場景、P／R數字不直接套用路標。先人監督證明效益，再考慮自動worker；軟件可先用合成資料驗快照隔離及失敗／回退，不冒充真人導航驗收。

### 路線錄製／跨樓層步行導航的證據邊界（2026-11-04，完整規劃／Dataset暫停）

使用者最新目標為一般iPhone首次路線錄製、跨樓層步行導航、行走期間即時障礙偵測及語音，完整方案見[Frontend導航主線](FRONTEND-DESIGN.zh-HK.md#route-memory-plan)。首次對App未知的路線應能開始建資料，不以使用者事前熟悉該地方為條件。N0現有20項工程測試沒有floor／connector或真實行走感知，不是新增目標的品質證據。本節只規劃資料及驗收；Dataset派工／採集／標註／訓練仍未重啟，不改class ID、split、權重或B11。既有12,346筆來源核對及拒用候選保留，不全量重做。

路線記憶是私人已走路標／有向路段及多次觀察，不是訓練集。node身份、關鍵幀／OCR／特徵、使用者確認與路線版本分開；連續相似幀不當獨立趟次，辨識到「門／圍欄」及AI自評信心不作位置／通行真值。新增觀察不自動變human_approved、不重訓模型、不覆寫穩定路線；未來若另獲資料授權才按地點／趟次／時間分組評估。

2026-11-05需求對齊新增陌生室內逐段探索為完整產品目標，與已錄路線重行分開驗收。讀到牌面／箭嘴只支持當下線索，不直接證明整條路、實際樓層或目的地位置；雲端描述亦不作人工真值。探索、錄製及重行的資料用途分開，雲端分析、問題回報及訓練各自授權。具體搜尋／失敗策略仍在訪談，不新增真值標註或恢復資料採集／訓練，也不把P0／P1合成測試當探索品質證據。

新截圖所見垃圾桶被報為圍欄、欄杆柱被報為門，是使用者提供的失敗例子，不足以推出整體準確率或多模態一定勝出；原圖留使用者原位置，本次不複製至Git、加入訓練或產生正式真值標註。YOLO輔助、多模態候選理解、本機影像比對／OCR與導航位置判定分開報效果，不能用調高門檻或語意描述取代定位驗證。

日後獲授權實測時，人工確認起終點、路口、方向／樓層及通路；分報錯誤位置確認、拒答、錯過轉彎、重新確認／需協助、路線完成及裝置資源結果。一般iPhone／Pro Max、不同光線與獨立趟次分開記；測試使用者與影像／錄音保留另行同意，未測不宣稱通過。

後續實作責任依2026-11-05最新指示由DSH承擔，Codex只審核；相機／定位／感知／語音及其測試不再由主控代寫。完整包見Frontend的DSH詳細計劃及`configs/planning/dsh-functional-execution-20261105.json`。這不恢復Dataset派工／採集／標註／訓練，也不把DSH變成人工真值來源。現模型gate=false、A10拒用、B11獨立及12,346筆既有核對均不重做。

驗收必須區分：DSH交付文字→隔離工程檢查→真機能力→人工場地／視障任務。P2-A lease fake測試不當實際相機互斥通過；P2 A–D組合才是取幀功能。P3 feature相似／floor候選不當真位置，P4功能接通不當障礙品質放行。由主控執行測試要如實署名與保留exit/log；AI不得自行宣稱human_approved。任何包無法提供有效反例或同一問題兩輪無新證據就停下，不能讓主控改預期令測試過關。

#### 跨樓層步行導航驗收矩陣（P0合成工程已驗；真實任務未執行）

P1新增35項本機工程驗證，全App415項及analyze通過；只保存合成結構並測重開、損壞、quota、金鑰遺失、回退、刪除／晚到寫入，未採集照片／影片或新增人工真值。平常重行不持續落盤；P2–P3另驗長時間重行的磁碟增量、錄製關鍵幀大小／數量／整庫硬限及額滿停止後穩定版保留。這些是資料生命周期／功能條件，不以UI樣例當模型／定位品質通過；使用者要求先功能、後效能／耗電及容量調校，必要的品質放行仍保留。見[P1證據](../verification/dsh-p1-route-store-20261105.json)。

| 範圍／情境 | 真值／測試輸入 | 必須觀察的結果與拒絕條件 |
|---|---|---|
| 首次建路線 | 空的本機路線庫、未存在的route／node；第一次錄製G→3F | 不要求先有features或已知路線才能開始；保存floor／轉層及draft，不能把新使用者當不可錄製 |
| 樓層與固定node | 人工場地／樓層／出口／方向清單，含外觀相同的不同樓層 | 位置身份按building＋floor＋node分開；同一位置多角度不增加真值node；不能靠路線預期強選相似出口 |
| 升降機跳層 | G→3F直達及中途停1F／錯出口；預期目的floor與實際floor分開 | 移動／開門／氣壓變化不自動當到3F；新鮮出口／樓層確認前不續播，錯層拒答另計 |
| 樓梯與平台 | G→1F→2F，含中間平台、轉身及相同樓梯間 | 平台數不當樓層數，入口／出口方向及實際floor有證據；行走障礙與轉層狀態各自有效 |
| 反向／重行 | 另錄回程視角及另一趟查詢，與建庫圖分開 | 回程不能只倒轉edge便視為通過；另一趟仍要能未知／拒答，不拿參考圖當獨立定位測試 |
| 缺感應器／追蹤 | 無AR、無氣壓／拒Motion、氣壓漂移、AR limited／重設及中斷 | 明示降為路標／樓層確認；沒有假高度、假樓層或假恢復位置，基本流程仍可結束／保存draft |
| 即時物件／幾何 | 人工全圖物件、指定表面量尺及實際行走事件；靜止／行人橫過／遮擋／多物件／玻璃／細物分層 | 模型TP／FP／FN、距離有效／未知及動態追蹤分報；點數、score及無框不當安全或通行真值 |
| 行走端到端時序 | 同步記曝光／分析／事件／實際語音開始時間；含慢推理、OCR忙、掉幀及過熱 | 報p50／p95、過期撤回、漏播／誤播與停止反應；初步5–10Hz／p95≤500ms只屬工程候選，未達不稱已可邊行邊用 |
| 語音競爭 | 導航轉彎遇有效急需障礙、VoiceOver探索、重讀、收音、耳機／來電 | 急需事件可撤回舊路線句；不雙播／重疊／補播已過轉彎，恢復時重評估。不能宣稱App完全控制系統讀屏queue |
| 中斷／刪除 | 轉層中暫停、背景、離頁、改路線、刪除後收到舊影像／floor／語音／儲存回覆 | 舊世代不能復活node、樓層、route或指示；新樓層可經確認的路標重定位，不強迫盲目回原起點 |
| 儲存／用途 | 原子寫入中斷、損壞manifest、空間不足、feature revision改變及裝置金鑰失效 | 穩定版可恢復，殘檔不假顯示已保存。路線影像不默認入A／B訓練，不因登入而上傳或混到照片佇列 |
| 裝置／OS／無障礙 | Pro Max及至少一部無LiDAR一般iPhone；實際OS／OCR語言能力、2x字及讀屏分別記錄 | iOS15不借用目前iOS16才開放的MenuOCR成功紀錄。缺裝置／語言／感應器就標未測，不外推 |
| 一趟完整步行 | 室外目的地→大樓入口確認→跨樓層→課室入口；實際可走路段由人工核實 | 報獨立完成／需協助、錯轉彎／錯層、拒答、恢復次數、等待／熱／耗電。全部同層通過不等於跨層或整趟通過 |

P0已完成19項核心、7項中英文UI及1項入口整合測試，全App380項、analyze及320×568兩倍字體圖通過。覆蓋G→3F、錯floor、相似出口、樓梯平台、方向／版本／單調時鐘、雙支序列、障礙打斷／過期轉感知不可用、背景／刪除晚到事件及3F明確重定位。這些是程式注入答案的工程案例，未採真實照片、步行或播音，不能標human_approved或把首次建路／實地放行改成通過；2秒／500ms與凍結時鐘不是正式行走profile，模型gate仍false。見[P0覆核](../verification/dsh-p0-cross-floor-20261104.json)。之後先導路線至少包含一條升降機跳層、一條樓梯跨層及重複外觀錯層情境；這是覆蓋清單，不是足夠樣本量或產品放行證據。

正式比較前凍結task profile：場地／路線／設備、錄製與query分組、最少獨立趟次／位置／樓層覆蓋、目標物件／距離定義、事件去重、可接受誤定位／漏障礙／誤警／延遲／恢復門檻、停止規則及不確定範圍。數字由先導證據估算後預先固定，不能看完結果才改到過關。controlled pilot出現錯層仍給續行指示、舊指示復活或停止不可達，該能力就不放行；小樣本零事故不推算一般環境零風險。

工程真值分開記：模型偵測對錯、幾何距離、目前floor／node、應播路線／障礙事件、實際語音及使用者是否能自行完成。物件模型的P／R不代替路線正確率，確認了樓層不代表前方無障礙；人工按下路線確認也不等於完成訓練資料全圖標註。

靜態模型批次評估沿用固定腳本及profile，優先重用已凍結基準，不重訓或全量重下載。行走資料需另行授權，按場地／實體／趟次／時段分組，不能把連續幀當獨立樣本。現用A品質gate=false仍是步行障礙功能的放行依賴；改模型／補標註／重新訓練均需另立授權範圍，不因本計劃自行啟動。

先由工程人員在受控、有人陪同的場景驗證，再由獲同意的視障使用者完成指定路段。人工負責實際樓層、連通性、障礙／量尺、讀屏及任務驗收；AI只能整理證據，human_approved不由AI自行設定。路線照片、測試錄音／影像與原始真值留受權範圍，不默認進Git或共用模型。

<a id="3-訓練與改善判定"></a>

### 訓練與改善判定

先完成可信基準與一個「問題→修正→重測」案例，再按小型對照選擇共用改善／私人微調。後續服務才是核准資料→充分性檢查→排隊→訓練→validation→凍結候選→獨立驗收→格式一致性→核准發佈。Colab保留作受人監督的實驗；雲端付費提交在預算設定前關閉。

以下是首輪工程預設，需記錄版本及限制，不是已驗證的產品準確率：

| 項目 | 規則 |
|---|---|
| 排隊 | 50張新增核准圖／三場景僅作後續排隊候選起點；仍須通過下文實體獨立性、逐類覆蓋與不確定範圍規則。樣本不足保持資料不足／待評估，不由張數直接啟動 |
| 回放 | 固定相同 taxonomy 的基礎權重與獲授權資料，不只訓練新圖，不混其他 UID 私人資料 |
| 比較 | 同一獨立資料、顯式版本化手機評估profile比較現用與候選；另保留conf0.30歷史診斷。match IoU0.50與NMS IoU分開記錄，逐類報TP／FP／FN、precision／recall、AP與樣本量 |
| 更新候選門檻 | 保留目標precision≥80%、recall≥70%、recall增加≥5pp，其他可評分類別P／R下降≤2pp；點估計達標仍需通過預先固定的樣本充分性、不確定範圍及任務驗收。這些規則未定／資料不足不能核准 |
| 證據不足 | 目標缺真值或不能獨立比較，不自動核准；只列候選／待驗收，不填零或宣稱改善 |
| test | validation選參數，test不參與訓練或選門檻；反覆開發消耗的test需另建保留集並記錄歷史 |
| 手機 | PyTorch／TFLite數值、映射與播報門檻一致；發佈前有延遲、耗電及任務驗收 |

有限樣本只支持該評估範圍。現用十類 gate=false，不得自動升格為核准基礎模型；後續訓練可作實驗，發佈仍需完整檢查。

#### 樣本充分性與使用者任務指標

每輪先凍結evaluation profile：目標使用範圍、類別／材質／光線／尺度分層、獨立實體／場景／趟次的最低覆蓋、可接受不確定範圍、效益門檻及停止收集規則。所需樣本量依這些條件估算並事前記錄，不以50張、三場景或大量相鄰幀取代。先導資料只用來估計所需規模；不能看到結果後改門檻／補到剛好過關。未定規則時只報探索結果。

報告同時列每類GT框數、圖數、獨立實體／群組與場景數、各層TP／FP／FN／P／R及不確定範圍；未標註類別保留不可評分。重複幀及同一門的多張照片以群組處理，不當獨立樣本；比較新舊模型用同一留集，規劃按實體／場景成組估計差異區間（如cluster bootstrap），方法及分組須事前固定。稀少群組或區間太寬時記證據不足，不能單靠高點估計核准；目前尚未建立這套充分性profile或新評估結果。

| 首輪任務 | 真值與分母 | 應報結果／失敗恢復 |
|---|---|---|
| 辨識並聽取目前物件 | 獨立人手記可觀察物件及應播事件／有效時間窗；連續同物件依事前事件規則去重 | 每段任務誤播／漏播、首次正確播報等待及p50／p95；未播／逾時另計，不只報成功等待。記能否重讀、停止或自行重新開始 |
| 站定測距 | 指定物件／表面與相機到表面量尺；每次開始至讀數／未知／退出為一筆，含沒有框的失敗 | 類別正確率、距離有效／未知／漏認、有效讀數誤差及「類別＋距離同時正確」；等待／重試次數及恢復成功率，不能剔除未知後只報漂亮誤差 |
| 菜單查價 | 獨立文字／菜名—價格關係及預設查詢；多價／缺價標為可拒答真值 | 錯配、漏答、不必要拒答、查詢等待、重拍／取消後自行完成；讀屏與純語音操作分開記錄 |

每個task profile先定開始／結束、何謂誤播／漏播、等待上限、恢復成功與可接受結果；由先導觀察決定並在正式比較前凍結。未設定或未達覆蓋即不宣稱任務通過。中英文、TTS／VoiceOver、裝置及App版本各有識別，Frontend的成功／失敗／跨任務場景對應到同一profile；戶外導航回歸另報，不混成一個平均準確率。

#### 私人微調是否有額外效益：小型對照（未執行）

先在授權的限定任務進行離線對照，無需先建每UID排程／worker／下載服務。以相同相容taxonomy及預先固定的手機profile比較：

| 對照組 | 訓練輸入與用途 | 要回答的問題 |
|---|---|---|
| M0：現用共用模型 | 固定目前權重／SHA，不因看過留集而再調參 | 未改善時的逐類及任務基準 |
| Mshared：改善共用候選 | 從同一基礎權重，以具共用訓練授權的開發資料＋舊類回放新fine-tune；私人圖未另同意共用不得加入 | 改善共用資料本身能否解決問題，代價及退化如何 |
| Mpersonal：本人候選 | 從同一基礎權重，以本人核准開發資料＋獲授權基礎回放；不混其他UID | 是否在本人未見實體／陌生趟次，較M0及Mshared仍有可重現的額外效益 |

先留出本人不同實體／趟次的驗收資料及獨立舊類保留集，再凍結三組輸入、基礎權重、資料／計算量預算、設定及seed；架構／前處理一致，實際資料量、來源與費用差異如實記錄。validation選參數後凍結候選，獨立test只作預先指定最終判定。重複實驗次數及可接受差異區間事前決定；單次／單人結果只作先導，不能宣稱跨使用者持續改善。

判定需同時符合：預先指定的陌生場景任務／逐類改善量、舊類不退化規則、樣本與不確定範圍、手機延遲／耗電，以及人工覆核／訓練／下載／回退的維護成本。若Mpersonal只改善剛收集的圖、優勢不確定或不及Mshared，保持共用改善優先，不擴展私人自動訓練。本人候選及影像留UID授權空間，對照不構成公開發布或付費GPU提交授權。

#### 一個問題→修正→重測案例的證據鏈

首例可選某類門漏認，尚未選定實際issue，以下是完成規格：先固定現用模型／task profile及重現情境→回報與人工全圖真值→同源群組→用途有效的開發快照→候選→與M0在另一批未入訓練的實體／場景比較→自然影像TFLite與手機任務重測→通過才關單／提供更新，失敗回開發階段並保留上版。回報圖及其裁圖／增強／相鄰幀全部留原群組，不能再當獨立驗收；舊模型已看過的來源也不能稱全新holdout。

Backend issueId須對應reviewRevision、sourceGroup、snapshot／coverage SHA、model SHA、profile及逐圖score／box／match／TP／FP／FN，另連手機實際播報、等待、未知與恢復結果。模型推理失敗、資料不足及候選退化同樣保存，不只記成功。共用資料用共用授權，私人資料維持本人用途；尚未取得完整mixed-run證據時明示可重現限制。先由人監督完成此案例及錯誤／回退mock，再考慮自動排程與付費worker；本輪沒有執行案例、訓練或重測。

<a id="4-每版報告與還原"></a>

### 每版報告與還原

保存現用／候選版本、目標類別、來源與獨立實體／場景數、split與分組雜湊、覆核範圍、抽樣層及可觀察分母、逐類比較／不確定範圍、任務誤播／漏播／等待／恢復、失敗例、格式檢查、真機結果、限制與發佈判定。以issueId串問題與修正；主動回退另記from／to SHA、profile及選填原因，不將一次回退自動當成有標註的模型錯誤。

共用 App／模型先完成 GitHub commit、tag／Release與遠端核對，再安裝交付；保留上一版模型、映射與安裝說明。私人照片／權重留在受授權私人儲存，不進共用repo。版本程序集中在Backend「部署、設定與版本回退」。

### 自動模型調度與通用看圖的評估（新增方案，未實作）

class dictionary仍管理A／B固定輸出；通用視覺語言模型的自由文字不自動加入字典、不當已核准標註。加入本地看圖候選不等於取消B或增加已驗收類別。

建立獨立任務集：日常物件、牌面、菜單、量距提問、無法辨認、非相關畫面，以及A完全沒有框的例子。每例由人工定義意圖、可接受能力、可確認答案、不能推論的內容與取消／恢復結果。分來源／實體／場景留集，避免以模型自己判斷的路由作真值。

比較OCR＋本地視覺語言模型、B＋OCR、B＋OCR＋本地模型；B尚未有合格產物時標待測，不能用假結果作結論。除辨識／文字／箭嘴配對與無依據陳述，另量錯誤路由、無故自動觸發、任務成功、等待、誤播／重播及VoiceOver操作負擔。閾值先用開發集校準再凍結，固定測試集不調參。

手機報告須記模型精確版本、量化／runtime、裝置、冷／熱啟動、記憶體、耗電／熱狀態及與導航／相機併用結果；模型能在手機載入不等於能持續並行。深度數字只來自量測，生成答案不作距離或通路真值。先驗按需提問，再評估自動觸發是否減少操作而沒有增加干擾。

### 無障礙任務評估（研究規格，尚未執行）

無障礙不是新物件class。建立與模型精度分開的任務紀錄，覆蓋VoiceOver／TalkBack開關、App語音與系統語音控制、最大字／顯示縮放、替代輸入、耳機／揚聲器與中斷恢復。詳細平台能力及官方來源由Frontend「Android／iOS無障礙整合研究」維護。

每筆記App／模型／OS／裝置／Flutter版本、讀屏／TTS／辨識語言、任務、輸入方式、預期與實際狀態、是否需協助、操作次數、焦點遺失、重複／過期播報、取消反應及恢復結果。分清模型認錯、內容正確但沒讀出、被系統語音蓋過，以及使用者找不到操作；不可合成單一模型準確率。

首輪先工程人員跑固定腳本，再邀有同意的視障／低視力使用者做站定任務與陪同路段；記樣本與限制。不能由健視者關屏測試宣稱已完成視障使用者驗收。Switch／點字設備沒有測就標未測；各OS／語言組合缺失不外推通過。測試錄音／影像另行同意及限制保留，不自動成為訓練資料或進GitHub。

<a id="b11-handoff"></a>
## 5. B11訓練交接

<a id="5-b11訓練交接持續在本節更新"></a>

### B11訓練交接（持續在本節更新）

| 欄位 | 最近已記錄證據 |
|---|---|
| 正式run | 20261027T055450Z-full，獨立YOLO11n預訓練起點 |
| 最近checkpoint | 交接於約14:11讀到epoch22/60，UTC 2026-10-27T06:07:54.643512+00:00；best.pt／last.pt／results.csv存在，尚未驗optimizer可否正確resume |
| 已完成smoke | 20261027T055254Z-smoke，兩輪及validation；不能當正式結果 |
| 正式設定 | Ultralytics8.4.182、640、batch16、最多60 epochs、patience12，不翻轉／旋轉 |
| Drive輸出 | MyDrive/PathGuide/sign-icon-models/sign-icon-demo11-v1/20261027T055450Z-full/，本人授權空間 |
| 跟進／阻礙 | 2026-10-27 17:10本機交接：Notebook無連線，Drive掛載credential propagation失敗；需在原Notebook恢復既有同帳戶連接，再核checkpoint與活躍程序。未resume、未部署，不能Run all |
| 尚未確認 | 正式完成、best.pt評估、獨立test及App整合，不部署未驗證B |

不要Run all、重跑launcher／force_remount、刪launcher-state或混用A／smoke結果。中斷先查活躍程序與checkpoint、optimizer、CSV、SHA及UTC，再確認正確resume；資料或taxonomy改變需新run。私人帳戶／Notebook識別只留既有受權跟進，不寫公開文件。

現行工具：dataset_pipeline/colab_train_sign_icons.py、coverage_training.py及evaluate_sign_icons.py；配置在dataset_pipeline/configs/sign-icon-demo11-v1.json。A變更資料後應從相容十類權重開始新fine-tune，不用resume改快照，也不套回舊HK9 head重排。只有相同資料／設定的中斷才續跑。

<a id="dataset-plan"></a>
## 6. 開發階段與逐功能工作清單

### 開發階段與目前進度

三份文件共用S0–S7階段編號。狀態只表示可追溯證據：**已有程式**不等於已部署；**待實測**不等於通過；**受阻**需先解依賴；**未開始／未來研究**不是現有功能。沒有足夠工作量與驗收資料前不編造完成百分比或日期。

S5的圖示訓練可與S2、S4並行準備；私人訓練必須先有S0品質基準及S2核准資料，S6對本次納入能力的整合驗收通過後才擴大S7範圍。當前主線為一般iPhone路線錄製、跨樓層步行導航及即時障礙／語音整合；Dataset／訓練工作仍暫停。S4包含基本跨樓層路線，S7才擴更多場地／複雜網絡與平台；ARKit追蹤與LiDAR深度分開，物件、定位及實地任務品質各自驗收。

| 階段 | 本階段Dataset工作 | 目前進度 | 完成標準 | 下一步／依賴 |
|---|---|---|---|---|
| S0 工程基線與版本保存 | 固定taxonomy、HKDI保留集、現用模型／映射與逐類基準 | 1.4.3+8前處理／42自然輸入PT↔TFLite對照通過；來源SHA與12346筆records／coverage已取回；A10逐圖strict基準已建立（1,082圖；person277、door39、fence0正例）；十類權重品質未通過；候選拒用 | 可在同一獨立資料重現新舊逐類比較，產物與SHA可還原 | 補門／person／fence獨立正負例及HKDI場景，先不開訓練 |
| S1 現有App核心功能 | 校準A、菜單OCR與播報門檻，提供真機測試樣本 | 有A來源評估／parity與工程回歸；缺完整手機實景評估 | 不把PyTorch／mAP當手機任務成功率；按場景公布誤報／漏報 | 補TFLite與HKDI／菜單真值，與Frontend實測對照 |
| S2 照片收集與管理員覆核 | 定義全圖答案、覆核清單、coverage、去重與場景 | 本地工具、Backend問題／覆核API及本機工作台已有；合成驗證通過、預設關閉，真人／App完整閉環未接 | 每張核准圖有來源／定義／答案／分組與審核版本，partial不冒充完整 | 先既有失敗場景試覆核，再接Backend角色與照片 |
| S3 私人訓練與模型更新 | UID快照、基礎回放、固定評估／門檻與匯出 | 未形成服務；私人相對效益未驗證，付費worker待預算與資料；[已錄路標持續改善規格](https://github.com/actiondarr/pathguide/issues/19)之路標分支已確認，未執行 | 對照共用改善後仍有額外效益，樣本／任務驗收足夠才可下載 | 先修正案例及小型對照，再mock；證據不足保持待評估 |
| S4 室內近距離感知與引導 | 保留路標位置／方向及任務真值規格；資料工作暫停 | N0／P0離線mock及P1樣例儲存、12-node合成樣例及表面測距工程試驗已有；真實錄路／重定位未驗收  P2-A/B協調及P2-C原生取幀已過本機工程測試；P2-D入口亦已過工程測試，手機人工驗收待完成。| 人工分報錯定位／拒答／轉彎／完成／資源，不以樣本數或物件class代位置真值 | 前後端先P2–P5；任何真實採集／測試影像與留集須另定用途，不重跑舊來源或訓練 |
| S5 圖示／文字與設施理解 | B11訓練／泛化、牌面OCR、圖示箭嘴配對 | B曾到epoch22後中斷；17:10交接Drive連接失敗，未resume／未部署 | 正式run／holdout／手機格式驗證完整，exit稀少如實標限制 | 先恢復同帳戶Drive、驗last.pt與optimizer，再正確resume；不Run all |
| S6 HKDI整合驗收與試用發佈 | 新舊模型與整體任務比較、資料／產物封存 | 完整室內＋學習閉環未驗收 | HKDI陪同測試、手機格式、舊類退化及回退皆有報告 | 提供Frontend／Backend相同模型及snapshot識別 |
| S7 多場地、複雜樓層網絡與平台擴充 | 新場地／新類別、設備時序及低光／透明細物 | 未來研究 | 場地／實體獨立、定義一致、相容映射與各任務驗收 | 先限定場景成熟，再擴展，不把更多類別當更準 |

### 功能計劃索引（按依賴取用，不代表同時開工）

| 功能／階段 | 目前狀態 | 實現步驟與產物 | 依賴／完成標準 |
|---|---|---|---|
| D01 類別定義與版本映射／S0 | A十類／B十一類活動版本已知 | 以實際manifest／profile凍結名稱、順序、專案ID、正反例與框邊界；保留原標註，輸出連續YOLO索引及對照。A物件／B牌內圖示／OCR文字各自namespace，不把52登記或20／23候選當已訓練 | F02／B08；同一輸出在訓練、匯出與手機有同義映射，樓梯合併與門框定義可追溯 |
| D02 問題回報、抽樣與人工覆核／S2 | 定時scene_sample／本地工具及Backend認錯／漏認API／本機工作台已有；A10覆核包完整性檢查器已整合，新包FP匯出已修正，人工覆核待完成。服務合成驗證、預設關閉未部署，真人／App四類與隨機抽樣待接 | 依「覆核工作流程」將reportKind／trigger／預測／人工真值分開，無框與高分錯誤可回報；獨立於score的有限隨機層保留分母與淘汰原因。管理員全圖修框與coverage核准，抽覆／版本衝突依Backend | B02–B03；低分／手動層不冒充無偏錯誤率，距離／文字不自動混入A訓練，partial不改approved |
| D03 去重、場景分組與快照／S0–S3 | 精確像素／pHash工具已有，實體獨立性未完全證實 | 以來源／影片／實體門牌分組，增強／裁圖回原組；精確重複合併，近似候選覆核，不確定保守同組。再分train／val／test、固定SHA、coverage、來源與版本 | B04；跨集合圖像／實體洩漏被擋，無法證獨立不作宣稱；test不進訓練 |
| D04 A模型門與舊類改善／S0–S1 | 本機／Colab候選拒用；先覆核資料與獨立留集 | 分析門FP／FN的材質／半開／尺度／光線與框定義，補不同門及櫃窗反例；固定新快照、回放舊類，短smoke後由相容十類best新fine-tune，逐類對照現用。不盲目加epoch／重排HK9 head | 先獨立門／圍欄驗證；新增資料須有coverage，person／舊類退化不以整體mAP掩蓋 |
| D05 B圖示與箭嘴／S5 | 正式run中斷、最新授權連接受阻 | 保留目前checkpoint與CSV，恢復後驗epoch／optimizer／names再續訓；不從seed重跑。完成報逐類AP與固定conf的TP／FP／FN，檢查複合牌、方向與未知圖示；原圖ROI保留座標來源，不用整圖分類假框 | F13／B08；exit僅12張train／13框，不能宣稱成熟；正式、smoke與A結果分開 |
| D06 菜單、牌面OCR與配對／S1–S5 | 菜單OCR有程式；牌面資料／整合未齊 | 系統OCR先作基線；保留逐字文字、多邊形、菜名／價格或設施／箭嘴關係真值。分菜單與牌面測，報文字錯誤、價格錯配、漏檢及拒答；錯誤證據充分後才規劃微調 | F07／F13；不為每個店名／房號新增物件class，不由menu測試推定sign任務成功 |
| D07 私人微調與品質比較／S3 | 未接通；必要性未經對照 | 先按「訓練與改善判定」對照M0／Mshared／Mpersonal；本人核准圖＋授權回放與陌生實體／趟次留集分開，固定profile及不確定範圍，報額外效益／舊類退化／成本。通過才擴mock與私人服務 | B04–B07；50張／三場景不作充分證據，無額外效益或資料不足不擴自動訓練；不跨UID、不自動擴class |
| D08 TFLite、模型包與手機驗證／S0–S6 | A前處理／42自然輸入PT↔TFLite對照通過；權重品質未過，B未完成 | 固定權重SHA→匯出TFLite→核shape／前處理／本地索引→同圖raw parity與偵測比較→完整手機格式評估→真機延遲／耗電／播報。封裝manifest、namespace、taxonomy、來源與限制 | F02／F08／B08；保留原權重與上版，不用降低檢查配合不相容輸出；共用版本先GitHub再交付 |
| D09 路標位置、觀察序列及室內幾何真值／S4–S7 | P0狀態mock／P1結構儲存已驗，真實影像定位未驗；Dataset派工暫停 | 固定node、floor／connector、多視角、有向通路及來源分開；重行不累積影片，明確錄路／更新才留有上限的必要關鍵幀。日後按地點／趟次／裝置驗位置，合成持久化不是位置真值；新增真實訓練與M0／Mmemory／Mtrained獨立趟次比較，未執行 | F14／F17、B14／B15；先P2相機／P3錄路／P4障礙語音，未授權採集訓練資料、標註或改split |
| D10 擴類、場地與新平台／S7 | 候選，未開放私人擴class | 先確認任務與定義、補足新舊類全圖標註及陌生場景，再版本化taxonomy／mapping與App相容性；舊輸出有實際資料才做遷移。Android／非LiDAR能力另外基準與限制 | F18／B14；不重用舊ID改義，不因有COCO權重便假設保留全部類別 |
| D11 扶手電梯、推拉與近身時序／S7 | 研究，未開始 | 受控授權序列包含同設備、上下端、移動／啟停、標誌、相機運動與真方向；門推拉另有文字證據。懸空／細障礙與相對運動另量測。分設備／場地／時段留集，報錯方向、拒答及過期清除 | F15–F16；單張箭嘴、門把或畫面位移不作實際方向真值，未知保留拒答 |
| D12 來源署名、資料與報告保存／S0–S6 | 來源表及機器證據已移到適當位置 | 逐圖保存作者／license／URL、影像／標註SHA、變換與審核歷史，模型報告引用同一snapshot。共用報告不含私人內容，私人權重／影像留UID範圍；保留舊版可重現所需配置 | 「來源、授權與可重現資料」來源不能因整併遺失；版本回退不靠單一模型檔，GitHub不收私人照片／權重 |
| D13 路口與電梯顯示資料／S5–S7 | 參考產品引出的研究候選，未建立 | 分開建立行人燈／車燈、對應通行方向／路口、斑馬線及狀態時序；電梯顯示器、按鈕文字與是否點亮分開標。按不同路口／設備／場地留集，包含反光、遮擋、未知與LED閃爍 | F20／F21；A十類不自動有新能力，物件／文字偵測分數不等於可過路或已確認樓層 |
| D14 聲音、手勢與背景任務驗收／S4–S7 | 未執行 | 先用已知位置／距離與人工情境，測左／右／前後辨別、反應時間、VoiceOver干擾、誤手勢、耳機斷線及鎖屏／恢復。記裝置、音訊方式、權限與耗電，核心模組與整體任務分開報 | F19／F22／F23；不用競品功能表當精度證據，不把感測缺失當正常輸出 |

<a id="6-下一輪資料工作依序交付"></a>

### 下一輪資料工作（依序交付）

**目前暫停執行。** 以下保留為日後另獲授權的資料工作，不是現行派工次序；當前只做Frontend／Backend導航契約及mock，不交DSH資料審計、看圖或訓練。個人熟路記憶不自動成為本節訓練資料。

本機control／repair及免費T4候選均已完成並拒用；以下是下一輪待辦，並非追加訓練授權。來源已取回，不再把下載checkpoint列為未完成主線。

| 次序 | 工作／主責 | 交付與進入下一步的條件 |
|---|---|---|
| 1 已有證據核對／DeepSeek＋腳本 | 只讀核對現用SHA、12,346筆records／coverage、三個拒用候選及固定profile；引用既有評估，不重跑訓練 | 缺失／不一致清單與可追溯報告；不要把來源完整性當獨立性 |
| 2 定義及錯例覆核／DeepSeek整理，Sol與人工裁定 | 按門、櫃／電器門、窗、圍欄、行人整理FP／FN及框定義；區分已知存在、確認不存在、unknown | 候選定義與正式taxonomy分開，保留原標註；人工核准前不寫human_approved |
| 3 獨立資料與任務基準／人工＋DeepSeek工具，Sol覆核設計 | 覆核作者／原圖／實體分組，補不同場景的門、圍欄正例與反例；凍結辨識／測距／菜單task profile | 新val僅15圖／21門框且為助手覆核，不能當充分證據；test不作調參，原留集曝光限制保留 |
| 4 下一實驗提案／Sol設計，DeepSeek準備 | 根據錯例選一個可檢驗假說，寫明資料版本、對照、舊類回放、預算及停止條件 | 資料與比較設計核准後才執行；改快照開新fine-tune，不resume舊run，不憑epoch追加 |
| 5 獨立比較及手機驗收／腳本＋Frontend＋人工 | 固定argmax／NMS等設定，存逐圖輸出與逐類指標；通過後才匯出、核手機一致性及真機誤播／等待／恢復 | 舊類退化與新場景分報；不通過不換權重。M0／Mshared／Mpersonal另作效益對照，不自動開私人訓練 |

B11依「B11訓練交接」獨立核對checkpoint與程序，不因A的Colab已完成就標成B完成。量尺與原門場景覆驗可並行；Frontend負責名稱、表面距離與恢復三項分開驗收。

完整導航流程及P0–P6依賴只在[Frontend開發次序](FRONTEND-DESIGN.zh-HK.md#delivery-plan)維護。本檔保留資料／模型品質的獨立完成條件；產品整合完成不自動放行未過gate的模型。

## 7. 範圍限制與待定事項

[已錄路標持續改善規格](https://github.com/actiondarr/pathguide/issues/19)僅確認已錄路標持續改善規格；Dataset實際工作仍未重啟。路標架構／權重授權、充分性、錯認／效益及手機profile需先導後固定；訓練不保證每版改善，無額外效益不擴服務。

陌生室內探索已確認無線索時停定掃描、仍未知則重掃／暫停／求助；可用線索的搜尋／定位策略仍待驗，不能將候選探索流程當已核真值或擴充既有P2–P5驗收。正式定位／障礙／延遲門檻須先導後預先固定；AI自評、重複幀及模型輸出不作獨立真值。路線、雲端分析、回報及訓練資料按用途分隔；B11依原交接核對，不重啟健康run、不Run all。

## 8. 歷史實驗、研究與維護紀錄

<details>
<summary>歷史品質audit與graph／參考產品研究</summary>

### 2026-10-28歷史品質 audit 與後續處理

本節保留當日發現，不代表最新狀態；目前結論及實驗結果以上方「目前問題總結」為準。來源records／coverage／checkpoint已取回並核對，42個自然輸入及手機前處理對照已補；同源洩漏、獨立真值及完整任務驗收仍未解決。

依[2026-10-28本機audit](../dataset_pipeline/review_artifacts/2026-10-28/model-quality-audit/report.json)；此路徑為本機ignored證據，clone未必有，關鍵結論保留如下。當日未重新訓練或重新取得雲端snapshot；後續取回來源及修正實驗另見目前問題總結。

| 發現 | 範圍與處理 |
|---|---|
| 舊split存在同源洩漏 | 560對跨集合pHash候選，329對train／val；抽查8對由Codex視覺確認同原圖變體，human_approved=false。不是全部560對已確認；exact mixed-run snapshot仍缺 |
| 資料完整性 | 12,351張來源圖與11,548份舊標註SHA吻合；完整性不等於split獨立 |
| 門與舊類 | 門TP2／FP5／FN16，18個GT；person AP50 61.01%→56.13%，基線是重排十類seed，並非已出貨HK9；欠逐圖預測，不能指定失敗原因 |
| 平均指標限制 | mAP50 78.25%只含9個有真值類別，fence無獨立真值；不能當十類手機準確率 |
| 手機設定未對齊 | 歷史conf0.30、match IoU0.50；原評分未顯式固定NMS／max_det／rect。現iOS NMS0.45，vision max100，depth max20；預設播報／物件測距conf0.70。評估須另分顯示、播報與測距端點 |
| 匯出證據不足 | parity僅均勻及隨機tensor；需自然影像完整TFLite評估、實際前處理及逐圖錯誤 |
| gate不可混用 | 舊實驗門檻TP≥5、P≥60%、R≥50%、舊類AP下降≤5pp；下文私人更新門檻較嚴格且未實作服務。現用gate=false仍有效 |

新評估profile須記模型SHA、資料版本、前處理、conf、NMS、max_det、match IoU及輸出端點；顯示0.30與預設播報0.70分報。下文私人更新門檻套用預先指定的產品端點，不能挑最好看的設定過關；樣本不足不核准。1.4.1+6改了取樣而非權重，測距有效點數也不是辨識準確率。

### 拓撲graph先行的概念驗證（本機樣例已執行，真實資料待驗）

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

日後獲授權的資料工作需：取得場地許可，核實同層及跨層node／樓梯與升降機連接，凍結參考圖；另外一趟次拍query與人手位置真值，再評估圖片特徵／OCR候選。必須報未知與錯分支，不把同一張參考圖拿來測定位。深度／空間音效另量尺與幾何真值；N08別名是預先核准示例，不證明AI能自行發現店名改變。

地圖內容隨覆核變好與A／B私人權重微調是兩條流程：改一間店的文字／地標版本不等於已重新訓練物件模型。每條流程各有獨立測試及回退版本。

### 參考產品轉成我們的驗收項目（未實測該App）

Frontend保存第三方公開列項；Dataset不推斷其內部模型、訓練資料或準確率。接下來要證明的是PathGuide自己的改善：

| 改善類型 | 我們應準備的真值／實驗 | 要報的結果 |
|---|---|---|
| 路線與地標更好 | 凍結route／graph內容版本，以另一趟次重走，包含臨時註記到期、改名、重複標記及錯node | 路標在正確位置觸發、漏播／誤播、過期註記、錯分支與回退；與未更新版本比較 |
| 辨識模型更好 | D04／D07的現用／候選同資料比較與陌生場景 | 逐類precision／recall、退化、樣本量及TFLite／手機差異；不以路線修正當權重提升 |
| 導航與感知配合 | 同一固定路段，測導航、辨識、查詢進出、語音取消及過期回覆 | 漏指示／過期指示、音訊重疊、相機恢復、任務成功與使用負擔 |
| 空間／近身資訊 | D09／D11獨立量測及已知方位，覆蓋透明／細物、頭部高度與持機變化 | 測距誤差、漏障礙／誤警、未知／撤回比例；視覺畫面好看不代替真值 |
| 新場景／輸入方式 | D06／D13／D14分任務獨立測；先受控情境，再與目標使用者及協作者評估 | 文字／關係錯配、聲音辨位、手勢誤觸、背景恢復與耗電，不混成單一準確率 |

對第三方實機的觀察可記錄流程／提示／失效例，只能支持「觀察到甚麼」；無源碼、模型及獨立實驗時，不能用來推定其VPS、個人訓練或安全表現。本輪未複製第三方程式、模型或資料。

</details>

<details>
<summary>已被現行DSH責任取代的Dataset分工背景</summary>

### DeepSeek／Sol全專案執行分工（2026-10-31）

2026-11-02當時分工（後續以2026-11-05的DSH全實作指示為準）：DSH只承接前端UI、後端API及相關測試；Dataset暫擱置，不再委派資料工具、看圖、標註或模型品質判斷。既有資料／訓練分工表僅保留候選背景，不構成恢復授權。相機／語音時序、帳戶隔離、刪除競態、模型相容及跨模組整合仍由Sol把關；人工真值不得由AI核准。

此為成本導向的工作分配，不是兩模型在本專案已完成的能力比較；先以小工作包核實正確率、返工與總費用。DeepSeek Flash＋DS Harness為日常執行主力，Sol為整合與關鍵覆核；統計、訓練、評估由固定程式運行，標註真值與真機任務由人工驗收。完整階段排程及交接規則集中Backend同名章節，各領域分工在所屬文件。模型替換不改任何品質gate或人手核准要求。

#### Dataset工作分配

| 範圍 | 主執行者與產物 | 覆核／過關條件 |
|---|---|---|
| D01字典／映射 | DeepSeek整理別名、來源及對照表；腳本核索引 | Sol覆核定義／相容性，人手裁定語意；不得自行擴class或重排head |
| D02／D03覆核與分組 | DeepSeek寫audit／預標工具；本地腳本跑SHA、幾何、coverage、近似候選 | 人工確認標註及同源；Sol覆核split隔離。低分／無框不直接標負例 |
| D04／D05／D07 A／B訓練 | DeepSeek按核准設定跑固定腳本、整理CSV／checkpoint；無需逐epoch LLM輪詢 | Sol覆核實驗設計及退化；人手核資料。健康run不重啟，B11交接仍唯一 |
| D06／D08 OCR與匯出 | DeepSeek準備fixture／批次比較／報告；腳本計metrics／hash | Sol覆核實際手機前處理、argmax／NMS、映射與parity；真機測延遲 |
| D09／D11／D13幾何／方向／場地 | DeepSeek整理量測記錄、可視化及合成測試 | 人工量尺／場地／時序真值，Sol驗座標與設計，不以模型生成答案代真值 |
| D10／D12擴類與來源 | DeepSeek維護來源鏈、授權欄位、候選資料統計 | 定義／用途不明保持待覆核；保留原來源，不因換模型自動核准 |
| D14與通用看圖評估 | DeepSeek整理任務集、路由／錯答／操作統計 | Sol覆核評分方案，人工及視障使用者驗收；無障礙結果與模型精度分報 |

A10本機control／repair及免費T4候選全部拒用，既有來源核對不重做。DSH W1完整性工具及W2 FP匯出修正均已完成本機整合，見既有verification記錄；不再把匯出修正排成下一包。Dataset後續暫停，B11維持獨立交接與原有狀態；當前先交前後端導航mock。原圖／標註／test用途及所有品質限制保留。

省費核心是腳本跑全量、AI看異常。DSH目前不承接看圖／資料裁定；任何AI都不能自稱human_approved，Sol也不能代替獨立人工真值。對比實際花費、返工及漏報，不預設廉價模型或昂貴模型一定正確。

</details>

### 維護紀錄

2026-11-06 /to-spec：使用者接受本聊天全部建議，已發布[已錄路標持續改善規格](https://github.com/actiondarr/pathguide/issues/19)及ready-for-agent標籤，連到整體規格。同步本文件負責的持續改善範圍、與記憶補強的區別、行程後核實、另行用途、批次真實訓練／獨立重行比較及完整版本回退。此為規格及文件檢查，沒有改App／服務、採集／上傳、訓練、部署或裝機；既有工程／真人驗收狀態保持。

2026-11-05 1.5.0+9 prerelease published from immutable tag b620ec4, remote verified before iPhone install and launch (both succeeded). Human camera/VoiceOver results remain pending. [Release and installation receipt](../verification/release-receipts/app-1.5.0+9.json).

2026-11-05 P2-D: live Flutter camera entry passed 435 Dart tests, 45 native Simulator tests, clean analyze and signed 1.5.0+9 Release build. Fixed old event-subscriber interference and evicted captured-photo caches on stop/exit. Physical-device and VoiceOver acceptance remain pending. Evidence: [P2-D receipt](../verification/codex-p2d-camera-entry-20261105.json).

2026-11-05 P2-D工程整合：Flutter錄路相機入口已接原生相機，核對同次路線／請求／時鐘、尺寸／方向及JPEG SHA；只作按需記憶體相片，停止／背景／離頁會清理。合成影像與Simulator／Widget證據不當人工真值，手機／VoiceOver結果另驗。沒有新資料採集到訓練集、標註、權重、class或品質gate變更；B11獨立交接保留。

2026-11-05 GitHub checkpoint review: connected the shared camera coordinator to application background/foreground before registering camera plugins. Late background starts are blocked; foreground never resumes a camera automatically. All 44 native Simulator tests passed; the isolated source checkpoint also reproduced 415 Flutter tests and clean analyze. Historical P2-C receipt remains a snapshot of its earlier 43-test run. Evidence: [lifecycle check](../verification/codex-camera-lifecycle-20261105.json).

2026-11-05 保存／手機驗收節點確認：每票檢查及覆核後同步相關來源、文件與證據到GitHub；P2-D、P3-C、P4-B、P5分輪人工實測，P3-A先做儲存工程真機檢查。合成／Simulator通過、手機工程檢查及使用者實地結果分開記；照片／私人評估不隨來源檢查點公開，模型品質gate及B11獨立交接維持原狀。具體流程見Frontend交付與驗收、Backend版本程序。

2026-11-05 Codex完成P2-C原生來源：新增獨立AVFoundation錄路相機、native preview及能力／狀態／最新觀察／按需JPEG通道；不載入模型或啟動ARSession。只留一個最新buffer及最多一個JPEG工作，長邊1280／512KiB硬限，原生時鐘／新鮮度／方向及SHA綁實際bytes。17項新增錄路測試連既有共43項原生Simulator、415項Flutter及analyze通過。兩個同步重入反例先紅後綠；停止／背景／逾時不交舊幀或假稱硬件已停。Flutter入口留P2-D，真機／VoiceOver、持久影像及定位未驗收；未發布／裝機。見[本輪證據](../verification/codex-p2c-route-camera-20261105.json)。

2026-11-05 Codex接續P2-B：Vision／Depth／Menu統一取得精確相機lease，移除互相直接啟停；Vision以serial session／inference queue屏障、Depth以AR pause及model work屏障、Menu以picker dismissal completion確認交接。修正舊client提早釋放導致停機回覆遺失，舊版回歸probe可重現失敗，修正版30項核心檢查通過。26項原生Simulator、415項Flutter及analyze通過；只屬本機工程驗證，真機／VoiceOver及P2-C/D未完成。見[本輪證據](../verification/codex-p2b-camera-adapters-20261105.json)。

2026-11-05 DSH開發驗收結果：P2總上限US$0.40／八次請求已批准，P2-A獲額外一次修正而合共三次；三輪均未通過，主專案App程式未合併。第一輪檢查器執行失敗，第二輪檢查器編譯失敗；第三輪交接回覆修正，但檢查器仍呼叫不存在方法，獨立probe仍重現跨協調器令牌相等及外來令牌停止本機擁有者，且錯把CLI檢查器加入App Sources。保留原稿、diff、編譯及probe證據；P2-B–D因前置未驗收保持未派，餘下五次總請求未使用，沒有第四次P2-A授權。三次token按峰值價保守估算US$0.03327，非帳單；未宣稱相機／真機／VoiceOver通過。見[本包驗收](../verification/dsh-p2a-camera-ownership-20261105.json)。

2026-11-05 開發啟動需求確認：同步標準VoiceOver操作先驗及無線索保留未知的需求；實際播音／焦點／任務由真機與人工驗收，不能以AI輸出當位置／通行真值。實作交DSH、Codex只驗收；Dataset／B11及現有品質gate維持原狀。

2026-11-05 /to-spec規格重整：將字典、品質結論、資料來源、獨立驗收及B11交接分區，刪除與Frontend完全相同的導航次序副本；保留S0–S7、逐功能依賴／驗收、既有版本與機器證據。需求、待定事項、工程／真機／人工狀態分層；Q4尚未回答，不推定無線索探索策略已確認。本輪只改文件，沒有啟動App實作、訓練或部署。

<details>
<summary>展開既有維護紀錄（依當時日期解讀，不作現行派工）</summary>

2026-11-05 grill-with-docs首輪需求對齊：同步陌生室內逐段探索方向及分析／回報／訓練分開授權；牌面線索、路線記憶、雲端回答與人工真值保持區別。探索策略／品質驗收待對齊，既有模型gate、Dataset暫停及B11狀態不變。本輪只更新文件。

2026-11-05 DSH全實作／主控審核：依使用者新指示取代後續Sol實作分配，完成P2-A至D、P3、P4、P5的依賴、檔案範圍、接口、反例／命令、停止及交付要求。DSH負責全部程式／測試／修正，Codex只審核及機械驗證整合；不再代寫功能修正。現橋接仍為工具禁用的文字diff模式，不能宣稱DSH自行跑Xcode。P2四包合共US$0.40／八次為未批准候選上限，P1額度已耗完；本輪僅計劃及不付費準備，未提交新模型、改App、啟動訓練或裝機。詳細計劃見Frontend與`configs/planning/dsh-functional-execution-20261105.json`。 工作規格及阻擋關係已依新Issue tracker規則發布至[總票#2](https://github.com/actiondarr/pathguide/issues/2)與十張子票，首包為[P2-A #3](https://github.com/actiondarr/pathguide/issues/3)；目前皆為待預算／未派模型。

2026-11-05 P1功能整合：新增獨立加密本機樣例路線庫、草稿／完整結構版本、重新開啟、明確回退、刪除及舊版本／暫存清理。21項儲存／adapter、6項controller、6項UI及2項screen測試，全App415項及analyze通過。DSH兩次文字草稿經Sol修正；估算US$0.0114939，非帳單，無第三次。實際相機／照片／語音及真機Keychain未驗，未發布／裝機／部署／訓練／換模型，B11及舊來源保留。使用者指定先完成功能，效能／耗電／容量調校留後；下一步P2真相機，再P3首次錄路／跨層及P4障礙／語音。見[P1證據](../verification/dsh-p1-route-store-20261105.json)。

2026-11-04 P0跨樓層離線整合：新增樓層／有向轉層、預期／候選／實際樓層分離、單調時間與雙支序列、障礙frame及提示仲裁。G→3F、錯層／相似出口、樓梯平台、障礙打斷、過期感知、3F手動重定位及背景／刪除晚到事件有合成回歸。DSH兩次文字交付均需主控修正，沒有第三次；11556 input／9071 output按當日峰值價估算US$0.014352（非帳單）。新增27項、全App380項Flutter及analyze通過，中英文320×568兩倍字體圖已核對。N0保留，P0只有離線mock；真相機、TTS、持久儲存及實地／人工核准未做，未發布、裝機、部署、訓練或換權重，B11不動。見[P0覆核](../verification/dsh-p0-cross-floor-20261104.json)。

2026-11-04 需求澄清／先完整規劃：使用者明確要求跨樓層，以及行走期間即時障礙偵測＋語音步行導航。移除「只可錄使用者熟悉路線」及「跨樓層延至後續」的範圍誤讀；區分首次錄製建資料與沿已有資料導航。補樓層／轉層、單相機並行感知、語音優先、工具／兼容、資料及驗收的完整方案。現有N0仍只有三個合成路標、沒有floor／transition或真實行走感知；353項歷史工程通過不代表新增需求已實作。此輪只改三份主文件及機器計劃／證據，不啟動實作、DSH模型請求、訓練、部署或裝機。

2026-11-04 N0本機整合：新增熟路錄製／保存／選路、起點及方向分別確認、模擬重行、未知／歧義／方向不符、暫停／重確認、到達確認與刪除；只用記憶體合成路標。主控處理session／sequence／版本／過期、背景及刪除晚到回覆；DSH兩輪文字交付均需修正，未直接採納原diff。20項N0測試及全App 353項Flutter通過，analyze無問題；中英文320×568兩倍字體與合成畫面已核對。這不是相機定位、真機VoiceOver或實地通過；未發布、裝機、部署、訓練或換模型，Dataset及B11不動。DSH用兩次請求，峰值價估算US$0.0235686，非帳單回執；沒有第三次請求。完整來源、差異及限制見[本輪證據](../verification/dsh-n0-ui-20261104.json)。

2026-11-03 導航主線更新：依使用者選擇改為一般iPhone自行錄熟路與穩定重行；路標比對為基本流程、普通ARKit可選、LiDAR與雲端理解另分層。更新現況／先後／S0–S7／逐功能計劃及N0–N3驗收；Dataset維持暫停。只改三份主文件及機器計劃證據，未派DSH、改App／模型、採集相片、訓練、部署或裝機。

2026-11-02 W1交付覆核：整合DSH兩輪產出的A10圖包只讀完整性檢查器；Sol處理all_missed仍可有FP、缺表結構化錯誤及精確路徑等契約邊界，27項單元及6個獨立CLI案例通過。實包3份來源SHA吻合但5項事件差異，報告fail、人工狀態不變；未修寫原包、重跑推理、訓練或換權重。

2026-10-31 A10逐圖可信基準：重跑12,388筆來源SHA／pHash同源審核，1,403 val中279張（19.9%）有train近重複、23張同video；strict留集1,082。原十類PT在640／argmax／NMS0.45／conf0.7下，person 98／19／179（P83.8／R35.4／AP50 .573），door 5／3／34（P62.5／R12.8／AP50 .156），fence無正例不可量度；九類在7可比較類別略高但無door／fence／stairs，不作回退。只讀評估，未訓練／換權重／部署；App 1.4.3+8不變。證據見[本輪基準](../verification/a10-baseline-20261031.json)。

2026-10-31 跨對話review整併：核對本機修正對照JSON，統一Colab已完成且拒用的狀態，修正早期未完成交接；Dataset字典回置開頭，歷史audit與現況分開，下一輪待辦及DeepSeek／Sol排程同步。保留原數據、來源、B11交接及品質限制；本輪僅改文件，未重跑評估／訓練、部署或裝機。

2026-10-31 目前問題總結：依使用者要求先整理十類辨識／物件測距問題，分開已重現證據、假說及缺少的驗收。補入免費T4完整結果：新val召回無提升、誤報增加，候選拒用；前處理已交付但權重未修復。未新增訓練、權重發佈或B11操作。
2026-10-31 A10修正交接（已由完成結果更新）：本機control／repair及免費T4候選均拒用；27張新train／15張新val保持凍結，Colab run 20261030T162638Z已完成訓練及評估。詳細品質結果集中Dataset目前問題總結；無App權重更新、B11操作或付費GPU提交。
2026-10-30 1.4.3+8交付及來源核對：前處理版已保存GitHub及安裝／啟動iPhone；限定Drive原產物下載成功，來源checkpoint／訓練報告SHA吻合，42個自然圖輸入PT／TFLite最大差2.65e-5，源權重已有同樣誤認。12346筆records／coverage結構吻合；後續負監督修正只用逐張覆核的訓練圖，不動val/test、B11或付費GPU。

2026-10-30 十類問題排查：核對模型／類別契約，修正兩條iOS路徑共用的縮圖／取整，完成14張OID val×兩種NV12的原生TFLite重測；漏門與床鋪誤認person仍存在，保留gate=false及原權重。限定Drive來源檔案已授權但下載未成功，未重訓／替換模型、未動B11或對test推理。工程一致性與模型品質分開記錄，不以本小集宣稱準確率改善。

2026-10-30 補充待重現問題：使用者回報背景袋被A辨識為行人。提供的App截圖只直接證明該幀一個人物框與0.7米顯示；袋的獨立誤框、預測分數及原始幀未取得，不當成已人工核准的負樣本或FP計數。鏡中倒影場景另須區分物件辨識與鏡面／實物表面距離，不用顯示米數當量測真值。前端person→ID6→行人映射核對未見改名錯誤，實際原因仍待原場景重現與逐幀輸出。未複製私人截圖入repo、未建立資料快照／訓練或更動品質gate；前端使用回報見Frontend同日維護紀錄。

2026-10-29 交付核對：1.4.2+7 source 66bc1d0、不可變tag與GitHub prerelease先核實，之後iPhone 15 Pro Max安裝及啟動成功；初次連線重設後重試成功。見[交付收據](../verification/release-receipts/app-1.4.2+7.json)。不把裝機當作量尺、多人場景、VoiceOver或跨任務真機驗收。

2026-10-29 前端恢復交付：1.4.2+7完成測距產品提示／診斷分層、過期撤回、菜單取消及原生相機交接工程修正；328項Flutter、12項原生XCTest、33項數值檢查、analyze與簽署建置通過。未改模型／訓練／部署，真機場測與版本交付依工程證據及收據分別記錄。

2026-10-29：依本機程式、1.4.1+6構建／交付收據及2026-10-28品質review重整流程。保留S0–S7與逐功能計劃，把執行次序、驗收條件、現況及研究候選分開，合併重複版本日誌。此次只整理文件，未重跑App測試、部署、裝機或訓練；雲端／Colab即時狀態未重新查詢。2026-10-27至28的詳細發佈歷程保留於Git及verification，來源影像／標註未改動。

同日任務閉環補充：新增四類回報／抽樣偏差、獨立實體與不確定範圍、任務誤播／漏播／等待及恢復規格，明確50張／三場景不代表充分。加入M0／Mshared／Mpersonal對照及一個問題修正案例的證據鏈，私人微調維持待驗證假設。既有品質gate、權重／映射與B11交接不變；本輪只修改計劃，沒有收集／改標資料、執行對照、訓練或填入新的驗收數字。

2026-10-29字典補充：將A23／B12完整候選、現用A10／活動B11索引及52項App登記放到開頭；釐清20→23的道路車輛拆分、B一般洗手間圖示延期與不同ID範圍。本輪未擴類、改設定或訓練。

2026-10-29簡潔操作補充：依使用者希望減少按鈕，加入意圖驅動的裝置端能力調度、固定常用操作、按需收音、取消／降級與跨任務恢復，以及對應模型包及評估規格。此為規劃，尚未加入本地視覺語言模型或改App介面；不更動現有class、B11訓練或交付驗收狀態。

2026-10-29 Backend覆核契約同步：D02新增本機驗證的認錯／漏認問題接收及雙人覆核API，服務預設關閉；核准revision、coverage及scope規則見Backend。不新增資料／標註真值、不訓練，真實修正案例、留集與手機重測未完成；合成JPEG工程測試不是模型品質證據。

2026-10-29 Backend工作台同步：受權待辦與不可變歷史已支援分頁，工作台可看原圖／原預測、修框、填coverage及換人核准；僅用三張合成圖和模擬人員完成工程驗證。沒有新增真實資料、人工核准真值、同源分組判定、獨立評估或模型改善；B11不變。正式人員、定義／抽覆規則及真實案例仍待建立。

2026-10-29無障礙研究：核對Apple／Android／Flutter官方資料及現有語意／播音程式，加入跨平台整合、語言差異、Android公告干擾風險、替代操作及任務驗收。只更新方案；未改程式、切系統設定或執行真機／使用者測試。

2026-10-31成本分工：加入DeepSeek日常執行、Sol關鍵整合／覆核、本地腳本與人工真值的完整工作包、依賴及交接規則。依目前1.4.3+8／候選拒用／覆核API本機進度規劃，不重做歷史工作；僅修改三份文件，未安裝agent工具、傳送外部資料、開訓練或部署。

2026-11-02 DSH-W2-FP收尾：兩輪文字交付完成，11項生成器測試及27項既有測試通過，新包完整性pass。門FP事件8→3、person完整strict FP事件117→19，TP／FN未變；三份review CSV逐byte相同，原包24檔及三份輸入SHA保留。這是匯出修正，沒有模型改善或人工核准。生成器SHA由主控比對；檢查器既有producer_provenance仍為unknown。證據見[W2記錄](../verification/dsh-w2-fp-export-20261102.json)。

2026-11-02當時分工（後續以2026-11-05的DSH全實作指示為準）：DSH只承接前端UI、後端API及相關測試；Dataset暫擱置，不再委派資料工具、看圖、標註或模型品質判斷。既有資料／訓練分工表僅保留候選背景，不構成恢復授權。相機／語音時序、帳戶隔離、刪除競態、模型相容及跨模組整合仍由Sol把關；人工真值不得由AI核准。

</details>
