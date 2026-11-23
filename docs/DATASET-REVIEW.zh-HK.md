# PathGuide 資料與模型品質

核對日期：2026 年 11 月 20 日。

**A10 仍是手機內置的試驗模型，品質門檻未通過。B11 尚未完成評估及發佈。資料採集、標註及新訓練仍暫停。**

| 項目 | 有證據的狀態 | 尚待核實 |
|---|---|---|
| A10 主物件 | 預設相機模型為 `2026-10-27.mixed10.experimental.1`，640 輸入、10 類，manifest 記錄 `validationGatePassed=false`。 | 門大量漏認，圍欄欠獨立正例，三個修正候選已拒用。 |
| HK9 比較模型 | App 隨附 `2026-10-19.hk9.1`，640 輸入、9 類。辨識頁可作歷史比較。 | 沒有 A10 的門、圍欄及合併樓梯輸出，作全面回退仍欠證據。 |
| B11 牌內圖示 | 活動 11 類設定與獨立快照已存在，正式 run 最後核實到第 22 輪後中斷。 | 原 run 存取、續訓、獨立測試、匯出與 App 整合。 |
| 已錄路標改善 | iPhone 開發分支已可逐趟選填收集及本機覆核。 | 真機覆核、記憶補強、私人訓練及獨立重行比較。 |

本輪逐一核對兩個 TFLite 及兩份 manifest 的 SHA-256，四項均與最近的裝機收據一致。現況依工作區及留存證據，Colab 執行狀態和真機任務未重新驗證。[相機模型入口](../app/lib/vision/platform_vision.dart) · [A10 manifest](../app/assets/models/detector.json) · [HK9 manifest](../app/assets/models/detector-hk9.json) · [1.11.0+29 收據](../verification/release-receipts/app-1.11.0+29.json)

[A10 基準](#quality-state) · [B11 交接](#b11-handoff) · [類別字典](#class-dictionary) · [資料來源及覆核](#data-workflow) · [驗收規格](#quality-acceptance) · [逐項計劃](#dataset-plan)

<a id="quality-state"></a>
<a id="1-實際基線"></a>
<a id="目前問題總結2026-10-31"></a>
## A10 凍結基準與修正結果

### 評估資料與設定

- 原十類 PyTorch 權重 SHA-256 為 `33e8eb1d46c265796111bbb516ba4311e2de4bdddb401c65d99cde88254946b7`，對應 App 的 A10 TFLite。基準核過 12,346 筆來源及 42 張新 Open Images 門候選的 SHA，原有與新增的 test 均保留未作推理。
- 原有及新 val 共 1,403 張。279 張與 train 有 pHash ≤ 6 的近似候選，23 張同影片群組，跨集合相同 SHA 為 0。剔除後 clean 有 1,124 張，再去除同 `source_key` 得 strict 1,082 張（1,053 legacy＋14 原 OID＋15 新 OID）。獨立性按實體及場景另外覆核。
- 離線設定為 640 RGB、半像素雙線性 letterbox（填色 114）、argmax、按類別 NMS 0.45、max 100、真值配對 IoU 0.50。下表為 conf 0.70，AP50 為 101 點。舊 Ultralytics 多類保留／rect 結果只供歷史比較。App 顯示、播報與測距的設定分開記。
- 原本的主模型稽核、批次評估及逐圖報告在產生基準的機器上可以重跑。輸入（來源索引、覆核紀錄、審計 CSV、PyTorch 權重）位於被 Git 忽略的 `review_artifacts/`，`a10_audit.py`／`a10_report.py` 匯入的 `common.py` 亦未入庫，其他機器現時無法重跑；替代量度見本倉庫 Android 維護紀錄的 Open Images test 評估包。[A10 基準證據](../verification/a10-baseline-20261031.json) · [來源稽核](../dataset_pipeline/a10_audit.py) · [評估](../dataset_pipeline/a10_evaluate.py) · [報告](../dataset_pipeline/a10_report.py)

### 逐類基準（strict，conf 0.70）

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

門的 29 圖／39 框只有 5 TP，召回 12.8%，95% 區間 5.6–26.7%。原 OID val 的 18 框為 2／1／16，新 OID val 的 21 框為 3／2／18。新樣本來自公開資料及助手候選覆核，HKDI 與使用者原門情境仍待人手核實。門、櫃／車／電器門、窗及固定圍欄的框定義有差異，部分來源的 person／fence 標註覆蓋未知。澳門圍欄及室內門的 776 圖只在 train。strict 留集欠圍欄正例，圍欄召回不可評。

HK9 在 clean 留集的七個可比類別 AP50 均略高，例如 person 0.607 對 A10 的 0.573。這批資料可能受歷史選模影響，結果只提示舊類退化風險。A10 manifest 的舊門 P 28.6%／R 11.1% 來自不同設定及樣本，並列時應保留各自的評估口徑。[A10 基準](../verification/a10-baseline-20261031.json)

<a id="1438-前處理與自然圖重測權重未修復"></a>
<a id="1427-前端交付與品質證據界線"></a>
### 已完成的排查與拒用候選

| 檢查 | 結果與判定 |
|---|---|
| 對照模型與匯出 | A10 的 person／fence／door 對應 ID 6／26／18。42 個自然輸入的 PyTorch 與 TFLite 最大差為 2.65e-5。兩者都把一張無人房間的床鋪認作行人，現有個案的誤認在來源權重已出現。 |
| iOS 相機前處理 | 14 張原 OID val 以兩種 NV12 格式經真實原生流程重測。雙線性縮圖及取整令平均像素差由 0.015123 降至 1.95e-7。conf 0.70 門 TP／FP／FN 由 2／2／16 變為 2／1／16。使用者回報測距頁較易誤認，仍欠同一道門、角度、距離及門檻的兩路比較。 |
| 本機 control／repair（各 4 epoch） | 同一原 val 的 18 框，原模型 2／1／16，control 1／0／17，repair 0／0／18。repair 的訓練圖圍欄誤報減少，獨立驗證的門召回退化。兩者拒用。 |
| 免費 T4 候選（6 epoch） | run `20261030T162638Z` 用預先凍結的 27 張新 train、15 張新 val，並回放舊類。原 val 2／1／16 → 1／4／17，新 val 3／2／18 → 3／3／18，合併門 AP50 約 0.1526 → 0.0848。候選拒用。 |
| 逐圖覆核包 | W1 檢出事件與報告不一致。W2 更正匯出，門 FP 8 → 3，person FP 117 → 19，TP／FN 及三份覆核 CSV 不變。新包通過完整性檢查，`human_approved=false` 及品質門檻仍維持。 |

1.4.2+7 驗過未知／恢復、診斷及過期結果撤回，兩個模型及前處理當時沿用原版。工程與裝機證據獨立於量尺、場景與讀屏驗收。[1.4.2+7 收據](../verification/release-receipts/app-1.4.2+7.json)

[自然圖對照](../verification/mixed10-natural-parity-20261030.json) · [1.4.3+8 前處理與裝機證據](../verification/release-receipts/app-1.4.3+8.json) · [修正對照](../verification/mixed10-coverage-repair-20261030.json) · [W2 摘要](../verification/docs-current-cleanup-20261110.json)

### 新一輪工作開始前

先覆核門、行人及圍欄的正例／確定反例與框邊界，再定獨立實體及場景覆蓋。門的資料規劃保留至少 100 張獨立圖、20 個以上來源群組及每正例至少 2 個確定負例。納入細小、遠距、玻璃、雙門、半開及遮擋。行人補床、人偶、倒影等相似反例及不同距離正例，圍欄補獨立正負例。此為下一輪規劃的起點，樣本充分性仍按預先凍結的評估規格判定。

<a id="b11-handoff"></a>
## B11 訓練交接

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

快照 `sign-icon-demo11-v1` 為 2,301／469／557 張 train／val／test，exit 的 train 只有 12 圖／13 框。資料含插圖與來源增強，抽樣檢查仍欠全量覆核，正式輸出須在獨立留集與牌面任務驗證。本機訓練套件 manifest 記錄 SHA-256 `445ff0f2a1714cf4da1864e5cf6f6515b705d262e2b0b25e461a5ace1111f1a2`。

本機保留的 2026-10-30 交接另記使用者已批准改用目標帳戶續訓，該帳戶的原 run 存取、檔案搬移及 resume 均未核實。跟進先釐清存取及查原 run。若需複製必要備份，保留原件並記 SHA／UTC。帳戶及 Notebook 識別依既有私人交接查閱。

<a id="class-dictionary"></a>
## 類別字典與映射

### 候選範圍與活動類別

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
- 工作區的 B 類別設定在 `dataset_pipeline/configs/sign-icon-demo11-v1.json`（活動 11 類）及 `dataset_pipeline/configs/sign-icon-v1.json`（原 12 類候選）。
- 完整 A23／B12 名稱與正反例見[詳細字典提案](../configs/planning/class_dictionary.proposal.json)。工作區的 `dataset_pipeline/configs/roadmap-20-v1.json` 為早期 20 類範圍對照。
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

<a id="data-workflow"></a>
<a id="7-來源授權與可重現資料"></a>
## 資料來源與覆核

下表記錄既有來源及其授權聲明。新用途須核實實際版本、逐圖來源、作者及授權。App 顯示名、資料集本地索引、專案 ID 及外部 ID 各自映射。

| 來源 | 狀態／需保留的來源資料 |
|---|---|
| HK9原來源 | 準備後9,549 train／1,374 val／620 test；歷史split可能有場景重疊，不宣稱全獨立 |
| 新室內門 | 340圖／403原門框作實驗train，來源只宣告door覆蓋；不是340個獨立實體門 |
| 澳門圍欄 | 436來源圖作實驗；保留原框定義，沒有新獨立圍欄benchmark |
| Open Images 門 | 原 14 張 val、13 張 test。新修正實驗另凍結 27 張 train、15 張 val。逐圖作者及影像 CC BY 2.0 留來源記錄，原來源框 CC BY 4.0。香港實地另驗。 |
| [icons-wrs49/icons-vbuao v3](https://universe.roboflow.com/icons-wrs49/icons-vbuao/dataset/3) | B來源，聲明CC BY4.0；與其他來源按像素／相似群組隔離 |
| [arrowsicons/arrows_icons-pmnkv v2](https://universe.roboflow.com/arrowsicons/arrows_icons-pmnkv/dataset/2) | B既有偵測框來源，聲明CC BY4.0；不把分類標籤當整圖框 |
| [eyeway/subway-guide v10](https://universe.roboflow.com/eyeway/subway-guide/dataset/10) | B來源，聲明CC BY4.0；實體設施與牌內圖示分開 |
| [rne/pictogram_detection v2](https://universe.roboflow.com/rne/pictogram_detection/dataset/2) | B來源，聲明CC BY4.0；方向／別名需明確映射 |
| [Everyday Object Finder v3](https://universe.roboflow.com/chris-law/everyday-object-finder/dataset/3) | 歷史來源聲明CC BY4.0，但含網絡／素材來源疑點，不宣稱逐圖權利已核實；原用法只train，不把舊實驗統計當本輪結果 |
| [People Detection v1](https://universe.roboflow.com/chris-law/people-detection-o4rdr-nlryq/dataset/1) | 歷史聚合導出聲明Private、部分上游未聲明；保留研究限定與不重分發記錄，不因清理而自動核准新用途 |
| Wikimedia 候選 | 歷史記錄 901 圖、16 類，尚未用。逐圖保留作者、URL 及 CC BY／BY-SA／CC0 等授權。只有整圖標籤的資料欠偵測真值。 |

<details>
<summary>People Detection 原附 README 的上游署名</summary>

| 上游項目 | 授權 |
|---|---|
| [First Pedestrian Test](https://universe.roboflow.com/safer-strides/first-pedestrian-test) | CC BY 4.0 |
| [person_camera_security1](https://universe.roboflow.com/chinh/person_camera_security1) | CC BY 4.0 |
| [Human Action Recognition 2000](https://universe.roboflow.com/skripsi-u18dy/human-action-recognition-2000) | CC BY 4.0 |
| [People Detection](https://universe.roboflow.com/chris-kydks/people-detection-2csbw) | CC BY 4.0 |
| [contador-de-gente teste 3](https://universe.roboflow.com/mackleaps/contador-de-gente-teste-3) | CC BY 4.0 |
| [OD3](https://universe.roboflow.com/object-detection-tuphv/od3-fq4yp) | CC BY 4.0 |
| [Person Detection](https://universe.roboflow.com/illimited/person-detection-gbuka) | CC BY 4.0 |
| [MOT17-03-DPM](https://universe.roboflow.com/bhu-ykklm/mot17-03-dpm-udorc) | **未聲明** |
| [The Curve](https://universe.roboflow.com/people-8gcmt/the-curve-02) | CC BY 4.0 |
| [pedestrain safety](https://universe.roboflow.com/intel-9horw/pedestrian-safety-obyfo) | CC BY 4.0 |
| [People Detection](https://universe.roboflow.com/jmedel/people-detection-f0fgt) | CC BY 4.0 |
| [people、rabish](https://universe.roboflow.com/cpk-wow-k5nlf/people-rabish) | CC BY 4.0 |
| [Pascal VOC 2012](https://universe.roboflow.com/jacob-solawetz/pascal-voc-2012) | CC BY 4.0 |
| [Person Detection (General)](https://universe.roboflow.com/mohamed-traore-2ekkp/people-detection-general) | CC BY 4.0 |

</details>

模型來源保留原記錄的版本與授權，包括 Ultralytics YOLO11／YOLO-World（AGPL-3.0）、Meta SAM2.1（Apache-2.0）、IDEA-Research Grounding DINO（Apache-2.0）及 LocateAnything（依模型卡）。快照保留影像／標註 SHA、作者／授權／URL、coverage、分組、split、轉換與版本。`LICENSE-SOURCES.json` 及 `audit.json` 隨快照。共用報告除去私人資料，原圖、權重與私人評估留在授權的 UID 範圍。

<a id="2-覆核工作流程"></a>
### 覆核與抽樣

1. 先驗同意、UID、授權、影像品質及來源，保留拍攝時模型、原預測和觸發原因。把同一門／牌、連拍、影片、裁圖及增強分到同群組。獨立性不明時保守同組或只放 train。
2. 由人員逐圖補漏及修框，保留定義、來源群組、覆核者、時間及版本。私人 A10 核准需全圖十類 coverage 和另一位受權複核者。外部部分標註須有 coverage manifest 及已驗證的遮罩訓練／評估。未標註保留未知，確認目標不存在才可作負樣本。
3. 凍結資料 SHA、場景群組、映射及 train／val／test。validation 用於選擇參數，test 留作預先指定的最終判定。已反覆用於開發的 test 須另建保留集並留歷史。
4. 問題主張、觸發及人工真值分別記錄。認錯／漏認可用高分錯框或無框影像。距離另取指定表面量尺，文字另存人工確認的菜名—價格或設施—箭嘴關係。後兩種用途尚待契約及 App 接線。
5. 現有 `scene_sample` 是定時交替取樣。計劃的隨機層須另行同意，在合資格前景時間窗以固定 seed／機率抽樣，獨立於模型分數，仍受冷卻、配額及撤回限制。分手動、模型觸發及隨機層報抽中、擷取、淘汰、重複、配額與覆核分母。分母不足時分層報告。認錯／漏認接口與工作台的本機證據見 [Backend](BACKEND-DESIGN.zh-HK.md#data-contracts)。

<a id="quality-acceptance"></a>
<a id="3-訓練與改善判定"></a>
## 評估及發佈條件

先完成一個可重現的「問題→修正→重測」案例，再依對照結果決定是否擴展訓練。保留 issueId、reviewRevision、sourceGroup、snapshot／coverage SHA、候選與現用模型 SHA、profile、逐圖預測及配對、手機結果和發佈判定。回報原圖、相鄰幀與衍生圖留在開發群組。

**先凍結評估規格。** 按類別、材質、光線、尺度、獨立實體／場景／趟次定分母、最低覆蓋、不確定範圍及停止規則。用相同留集與預先指定的手機設定逐類報 TP／FP／FN、P／R、AP 和成組差異區間。50 張／三場景只作未來排隊候選起點。既有更新候選門檻為目標 P ≥ 80%、R ≥ 70%、R 增加 ≥ 5 個百分點，其他可評分類 P／R 下降 ≤ 2 個百分點。樣本、區間及任務驗收亦必須通過。

| 任務 | 獨立真值 | 結果與失敗處理 |
|---|---|---|
| 相機辨識與播報 | 人手記物件及有效應播事件，按事前規則去重 | 誤播、漏播、逾時、等待 p50／p95、重讀及自行恢復 |
| 站定測距 | 指定物件及相機到目標表面量尺，每次開始均入分母 | 類別、有效率／未知率、誤差、類別與距離同時正確、重試 |
| 閱讀文字／菜單／指示牌 | 標生活文字的原文、區域、讀序及可確認的部分。菜單標價格配對，指示牌方向任務另標設施與箭嘴關係 | 分報錯字、漏讀、讀序、錯配、不必要拒答、等待、重拍及停止。另驗部分結果的提示與逐區閱讀 |
| 場景描述與候選模型調度 | 另經同意的相同照片、人工意圖、可確認及不可推論內容 | 繁體廣東話、漏說、無據陳述、誤調度，以及取相、請求、模型、TTS 交接與實際起音分報 |
| 無障礙 | 分讀屏、語言、裝置、輸入方式，以固定任務配合實際操作 | 完成／需協助、焦點、操作次數、重複／過期播報及恢復。記實際 OS、語音、2×字體和裝置 |

普通相機基本版按物件名稱、畫面左／中／右及路標重認驗收。選填測距另外用同幀量尺評估。ARKit 相對追蹤獨立評估。導航偵測器及本機 VLM 的型號、runtime、量化、類別和門檻待選。5–10 Hz、p95 ≤ 500 ms 仍是工程候選；Android Redmi／Android 16 實測約 2.5–2.7 fps（推理 240–360 ms），iPhone 未有同口徑紀錄。先定義任務與人工真值，比較 OCR＋本機 VLM、B＋OCR、B＋OCR＋本機 VLM。B 未有合格產物的組合列待測。手機另記冷／熱啟動、記憶體、耗電、熱狀態及與導航／相機併用結果。

### 私人 A10 微調對照（未執行）

以同一權重起點、相容 taxonomy、前處理及手機 profile 比較 M0（現用）、Mshared（具共用授權資料＋舊類回放）、Mpersonal（UID 本人已核准開發資料＋獲授權基礎回放）。按不同實體及趟次留出個人驗收和舊類保留集，固定資料／計算量、seed、重複次數及可接受差異。Mpersonal 須有可重現的額外效益，且通過舊類退化、手機限制和維護成本檢查，才擴及私人自動訓練。在預算配置前保持付費 GPU 提交停用。

<a id="route-landmark-learning"></a>
### 已錄路標改善與跨樓層真值

首輪路線驗收範圍為彩明商場、調景嶺站出入口／非付費大堂、HKDI 及選定步行接駁，月台及乘車留待其他階段。普通重行與場景描述維持各自資料用途。雲端看圖、問題回報和訓練分開授權。CSDI 可作候選場地資料，當下位置及樓層須另行確認。[Frontend 導航與驗收](FRONTEND-DESIGN.zh-HK.md#route-memory-plan) · [已錄路標改善規格 #19](https://github.com/actiondarr/pathguide/issues/19)

- **工程證據。** P0 合成案例、P1 儲存、取幀及 L1 候選加密儲存各自有驗證。iPhone 開發分支已接候選收集、覆核 UI 及刪路線清理，裝置保護及實地覆核待驗。記憶補強及訓練未接通。P0 生成的答案只覆蓋工程狀態，另需人工真值及陪同實地試驗。[P0 證據](../verification/dsh-p0-cross-floor-20261104.json) · [P1 證據](../verification/dsh-p1-route-store-20261105.json) · [L1 工程證據](../verification/route-learning-integration-20261120.json)
- **整趟驗收。** 首次錄製可陪同，重行另趟沿錄製方向進行。以使用者原有定向方法作對照，分記完成、求助、錯認及中斷恢復。人工核實路段、方向、路標、樓層、出入口及轉層設備，並以關鍵轉角、轉層出口和終點作路線版本的驗收證據。按場地、裝置及獨立趟次報錯位置／樓層、拒答、錯過轉彎及等候。至少涵蓋一般 iPhone、升降機跳層、樓梯跨層、相似出口、反向視角、暫停及背景。錯層仍續行、過期指示復活或停不下來時，暫緩放行。物件、指示、幾何及真正起音各用相應真值。[重行驗收狀態](FRONTEND-DESIGN.zh-HK.md#route-replay-acceptance)
- **路標訓練對照。** 先選本人已錄常用路線的一個場地，由人事後核實。另取訓練同意後比較 M0（現版＋原記憶）、Mmemory（現版＋核實的新記憶）、Mtrained（同一增補記憶＋已訓練元件）。後兩組使用相同 gallery 及 query。允許同一已知 node 在不同趟次重現。同趟、相鄰幀、裁圖及增強保持同組。經不同光線／方向／相似樓層的另一趟比較錯認、漏認、拒答、p50／p95、恢復及手機資源。保存 base／output SHA、參數、工具與快照，Mtrained 須證實較 Mmemory 有額外效益，並通過舊路線及錯位置檢查。
- **用途與未知。** 觀察、手動標記、真正位置和人工核實各自記錄。特徵比對、補照片或改門檻只更新記憶或行為，權重訓練有獨立證據。陌生探索缺可靠線索時保留未知，重掃、暫停或求助。模型自評、CSDI、OCR 候選及畫面方位皆需獨立位置真值。

<a id="4-每版報告與還原"></a>
### 具備放行證據後的交付

模型與映射同版匯出，保留資料、工具、profile、權重與格式 SHA、逐類與任務結果、限制及回退資訊。TFLite 數值、自然圖、真機速度和讀屏逐項核對。共用版本先核 GitHub tag／Release 再交付。私人影像及權重留受權範圍。回退另記 from／to SHA、profile 及選填原因。[Backend 交付規則](BACKEND-DESIGN.zh-HK.md)

<a id="dataset-plan"></a>
## 開發階段與逐項計劃

| 階段 | 工作 | 有證據的現況 | 完成標準 | 下一步／依賴 |
|---|---|---|---|---|
| S0 工程基線與版本保存 | 來源、模型、資料相容與回退 | iPhone `1.12.1+31` 有原位裝機、獨立核對及啟動收據，內置模型及映射與收據相符。Android 移植線最新 tag 為 `v1.12.1+31-android-sync.9`（Redmi／Android 16 覆蓋安裝）；分支 `merge/upstream-1.12.1-31` 與九個 android-sync tag 已推送 fork 遠端並逐條核對 SHA | 來源、模型、相容資料及可回退版本均可追溯 | 回退前先核路線 schema 相容性。遠端保存已完成；下一步為真機重行驗收、候選整趟覆核及效能量度 |
| S1 App 核心功能 | 即時辨識、菜單、戶外步行、場景描述及讀屏 | 已有主要流程。截圖卡住未定位，場景與讀屏待複驗。Android 即時辨識、閱讀文字／菜單查價、系統返回鍵已在真機通過基本操作；Android 戶外導航代理及 TalkBack 未驗 | 逐任務驗可用內容、停止、取消及恢復 | 核對真機故障、語音起音及讀屏 |
| S2 照片收集與人工覆核 | 同意、私人相片、標註及清理 | 覆核 API 和工作台已有本機合成驗證，功能預設關閉 | 權限、撤回、全圖覆蓋、修訂及獨立覆核可追溯 | 確認角色、部署及真人案例 |
| S3 私人訓練與模型更新 | 快照、worker、比較、registry 及回退 | iPhone 開發分支已有本機候選收集及覆核，補記憶及訓練閉環待接 | 相較共用模型或記憶補強有額外效益，預算、更新及回退可驗 | 先有核准資料及評估。付費 GPU 須有預算 |
| S4 室內錄路與引導 | 普通相機、樓層、轉層、重認、障礙及語音 | 自動取樣、標記、加密路線及逐點重認已有。開發分支已接通方向提示、更多標記、失敗紀錄及文字／iPhone 錄音備註，行走感知待接。Android 錄製、加密保存及重開已在真機通過，重行比對及閾值未校準 | 錄製、保存重開及另趟重行，分報未知、錯層、漏報及恢復 | 真機核對收音、播放、VoiceOver／TalkBack 及同層／跨層 |
| S5 圖示與設施理解 | B11、牌面 OCR 與箭嘴配對 | B11 最後有證據到第 22 輪，存取待核，未入 App | 正式 run、獨立留集、匯出及手機任務均通過 | 先核原 run 與 checkpoint |
| S6 限定場地整合驗收 | 三地路線、讀屏與資源交接 | 整趟實地驗收待做 | 獨立趟次核對定位、提示、操作、時效及恢復 | 彩明商場、調景嶺非付費區、HKDI 與選定接駁分驗 |
| S7 場地與平台擴充 | 更多場地、複雜路網與平台 | 擴充能力待實作及驗證 | 各功能有資料、相容性及獨立任務證據 | S6 通過後逐項擴展 |

### 資料及模型功能計劃

| 功能／階段 | 方法與產物 | 依賴及完成條件 |
|---|---|---|
| D01 類別及映射／S0 | 依 manifest 固定 A／B 各自 namespace、名稱、索引、專案 ID、框法及正反例。OCR 獨立。 | F02／B08。訓練、匯出、手機核同一映射，變更保留原標註及版本。 |
| D02 回報、抽樣與覆核／S2 | 本機工具及 API 已有。按覆核流程保留觸發、預測、真值和抽樣分母。 | B02–B03。另驗真人全圖核准、撤回、權限及隨機取樣，分層報偏差。 |
| D03 去重與快照／S0–S3 | 用 SHA／pHash 與來源、影片、實體分組，保守處理近似，再凍結 split、coverage 及授權。 | B04。跨集合群組核對，test 留到最終判定。 |
| D04 A10 舊類及門／S0–S1 | 三個候選已拒用。先按材質、角度、尺度整理錯例。同 taxonomy 新快照以相容 A10 基礎權重、舊類回放及對照新 fine-tune。 | 先有人手覆核及門／圍欄獨立真值。逐類查退化。 |
| D05 B11 圖示／S5 | 正式 run 存取待核。確認 checkpoint／optimizer／names 後續原 run，再報逐類 AP 及 TP／FP／FN。 | F13／B08。區分 smoke 與正式結果，另驗 exit、複合牌、原圖 ROI 與未知圖示。 |
| D06 生活文字、菜單及牌面 OCR／S1–S5 | 以現有菜單 OCR 為基線。另收繁中／英文告示、標籤及指示牌測試樣例，保留原文及分段閱序。照舊分開標記菜單價錢配對及牌面箭嘴關係 | F07／F13。測細字、反光、多欄、讀屏及同圖切換。分報錯字、漏檢、讀序、錯配與拒答 |
| D07 私人微調／S3 | 未接通。固定同一架構與相容資料，先做人監督的 M0／Mshared／Mpersonal 對照。 | B04–B07。保留同人不同實體／趟次，效益、舊類、手機及成本同時過關。 |
| D08 模型包與手機／S0–S6 | A 自然圖 parity 與前處理已有證據。固定權重、執行 TFLite 格式與映射檢查、手機效能及播報。 | F02／F08／B08。品質門檻、真機任務及相容性都通過才交付，保留上版。 |
| D09 室內真值／S4–S7 | 先記原路、樓層、connector、方向、物件與量尺，再以獨立趟次驗定位及恢復。路標訓練另做對照。 | F14／F17、B14／B15。P2–P4 功能接線後執行實地。按裝置、位置、錯層與感知分報。 |
| D10 擴類及平台／S7 | 研究候選。先定新類定義及全圖 coverage，再版本化映射。Android 與無 LiDAR 各自建基準。 | F18／B14。相容遷移、未見場景及裝置能力有證據後才擴。 |
| D11 扶手電梯、推拉與近身障礙／S7 | 未開始。同設備採集動作、上下端、標示、持機移動及真方向。門推拉另取文字證據，近身／懸空物另外量測。 | F15–F16。按設備、場地、時段留集，報錯方向、拒答及過期撤回。 |
| D12 來源與保存／S0–S6 | 保留逐圖署名、SHA、來源分組及審核，引用同版快照。共用報告與私人副本各按授權保存。 | 所需模型、映射、前處理、報告及上一版均可追溯。 |
| D13 路口與電梯顯示／S5–S7 | 未建立。分標行人燈／車燈、方向、斑馬線、時序。電梯區分文字和亮燈。 | F20／F21。不同路口／設備另留集，覆蓋閃爍、反光、遮擋及未知。 |
| D14 聲音、手勢及背景／S4–S7 | 未執行。已知方向／距離下測方向辨別、讀屏、誤手勢、耳機斷線、鎖屏及恢復。 | F19／F22／F23。裝置、音訊、權限、耗電及完整任務分報。 |

<a id="6-下一輪資料工作依序交付"></a>
### 下一輪資料工作（暫停執行）

恢復範圍確認後，依序覆核 A10 錯例及類別定義 → 凍結足夠獨立資料及任務 profile → 針對一個可驗證假說提對照實驗 → 用固定設定作逐圖與真機重測 → 依品質結果決定是否匯出與更新。B11 依本文件交接獨立核對。前端與路線另見 [導航開發次序](FRONTEND-DESIGN.zh-HK.md#delivery-plan)。

既有 Section B 以 FYP 為基礎，可共用已獲授權的 Python 實驗。分開報告既有成果、小組新增工作、桌面及手機結果，私人資料留在原有授權範圍。

## 維護與證據追溯

2026 年 11 月 20 日更新 L1 收集及覆核狀態。原比對與人工覆核分開保存，仍須以獨立趟次評估任何後續改善。[工程證據](../verification/route-learning-integration-20261120.json)

2026 年 11 月 20 日開發分支加入整頁通用 OCR 回傳及多欄提示。合成介面案例已核對按區域閱讀和同圖切換。繁中／英文生活照片的辨識率、閱序及實機讀屏仍待驗。[工程證據](../verification/general-text-reading-20261120.json)

2026 年 11 月 20 日增列通用「閱讀文字」的測試樣例、部分結果提示及閱讀順序驗收，保留菜單查價與指示牌方向的獨立真值。

2026 年 11 月 20 日補記以使用者原有定向方法作對照，以及按獨立趟次記錄路線重行證據。

2026-11-20 以工作區、裝機收據、舊版資料覆核及 B11 本機交接重整閱讀順序，核對內置模型與映射，保留類別字典、留集、來源署名、證據及評估規格。本次範圍為文件核對。過往實驗及整理索引見 [verification](../verification/) 與 Git 歷史。

## 本倉庫 Android 維護紀錄（非上游內容）

2026-11-23 Android 檢測前處理對齊：Android 版改用 `CameraPreprocess.kt`，與本文件「離線設定」（640 RGB、半像素雙線性 letterbox、填色 114）一致；JVM 對照測試平均差 1.7e-8，真機 Y 範圍 [0,255] 證實相機為全範圍 YUV。此前 Android 手機上的誤認觀察不能直接與本文件逐類基準比較（前處理不同）；之後應以同一嚴格留集經 Android 管線重報 TP／FP／FN。另新增 Android 路標特徵模型：MediaPipe MobileNetV3-small 圖像嵌入（Apache-2.0，來源與雜湊見 `app/assets/models/route_landmark_embedder.json`），只作已錄路標比對，與十類檢測模型無關；距離閾值為暫定值，須以實拍路線照片校準。

2026-11-23 Android 管線誤認量化（`dataset_pipeline/android_pipeline_eval.py`，證據 `verification/android-pipeline-eval-20261123.json`）：以 App 實際 `detector.tflite`，在本機 `dataset_hk_stage2` 驗證集 105 張（行人 242、垃圾桶 19、單車 2 框；門／扶梯／圍欄無真值）先模擬相機全範圍 YUV420，再比較舊 Android 管線、現行管線與離線參照。現行管線與離線參照幾乎相同（TP 相同、FP 差 ≤1），前處理對齊在真實照片上成立。舊管線在此資料集召回較高（0.5 時行人 TP 108 對 88），但此結果未能在獨立的 Open Images test 評估重現（見下一條），應以下一條為準。門檻 0.5 → 0.7 精確率未升（0.900 → 0.885）、召回由 0.376 降至 0.205。最頑固的誤認是類別混淆而非低分：香港三色回收桶同時出「門」框（0.67–0.86，與正確「垃圾桶」框 IoU 0.95–1.00），有扶手的樓梯出「扶梯」（0.68–0.76）；不分類 NMS 不能修正（有一張錯誤「門」分數高於正確「垃圾桶」）。此資料集可能與 A10 訓練來源重疊，且以行人為主，未據此改門檻或 NMS；須以凍結嚴格留集重跑，並補香港回收桶／樓梯的困難負樣本。

2026-11-23 獨立評估（Open Images V7 test，`dataset_pipeline/build_oid_bundle.py` 固定種子 20261123 抽 978 張，人工核實圖像級標籤定逐圖覆蓋，排除群組框；證據及逐圖清單 `verification/android-oid-test-eval-20261123.json`，影像只留本機）：以 App 實際 `detector.tflite` 經相機 YUV 模擬，現行 Android 管線＝離線參照，舊管線並無優勢（0.7 時 P 0.827／0.826、R 0.210／0.220）。逐類（現行管線，0.7，95% Wilson 區間）：垃圾桶 P 1.00（0.93–1.00）R 0.47、單車 P 0.92（0.86–0.96）R 0.37、行人 P 0.77（0.72–0.82）R 0.21（0.8 時 P 0.87）、門 P 0.69（0.52–0.81）R 0.09（任何門檻 P 不足 0.70）、樓梯 R 0.04（模型幾乎測不到，門檻無法補救，屬安全相關缺口）。跨類重疊框（IoU>0.7）0.5 時 105 對，以單車／圍欄、門／圍欄、垃圾桶／門為主；模擬「兩者皆不報」或「保留高分」均令正確單車／垃圾桶框減少而誤認幾乎不變，不採用。按類門檻模擬：行人 0.8 令誤認 82 → 39（R 0.220 → 0.177），再暫停門播報 → 28（R 0.164）。使用者決定採用行人 0.80（本倉庫 sync.7 已實作於日常模式）；門未暫停。OID 無 bollard／traffic_cone／caution_slippery／escalator／fence 框，這五類未評；A10 自身的 Open Images 抽樣清單不在此機器，重疊無法核實。
