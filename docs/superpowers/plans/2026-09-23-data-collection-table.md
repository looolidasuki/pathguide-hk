# 數據採集表（按《labelObject_workload》50 項）

來源：`Accessible Visual Guidance Note/labelObject_workload 20260920.pdf`（5 頁，31 物件 + 19 設施）

---

## 〇、v3 已落地：類別表從 24 類擴到 48 類（2026-09-27）

本文件下面第二節的「當前類別表」列是**改表之前**的狀態（寫作時的快照）。
改表已按第三、四節的裁決執行，結果如下，`configs/classes.json` 是唯一事實源。

**動了兩個既有槽位（都經核查）：**

| 槽位 | v2 | v3 | 為什麼可以動 |
|---|---|---|---|
| id 13 | `cart_trolley` | **`push_cart`** | 只改名、**槽位不動**，既有 2 個標註仍然有效。語義收窄為「人手推的載貨小車」 |
| id 23 | `ambiguous_vertical`（佔位類） | **`fork_in_road`** | 該槽位**從未有過任何標註**，是全表唯一可安全複用的空位（生成器要求 id 連續）。複用前已確認它在本項目全部標籤文件中出現 0 次 |

**新增 25 類，佔 id 23–47**（id 23 = fork_in_road，24–47 按優先級排）：

| id | class | 中文 | P | id | class | 中文 | P |
|---|---|---|---|---|---|---|---|
| 23 | `fork_in_road` | 分岔路口 | P0 | 36 | `billboard` | 廣告看板 | P1 |
| 24 | `caution_slippery` | 小心地滑 | P0 | 37 | `traffic_cone_connector_rod` | 交通錐連接杆 | P2 |
| 25 | `crowds_of_people_queuing` | 排隊人潮 | P0 | 38 | `abrasion_resistant_steel_plates` | 鋪路鋼板 | P2 |
| 26 | `fence` | 圍欄 | P1 | 39 | `hand_truck` | 搬運手推車 | P2 |
| 27 | `barrier_fencing` | 工程圍網 | P1 | 40 | `pallet` | 唧車 | P2 |
| 28 | `scaffold` | 鷹架 | P1 | 41 | `pushchair` | 嬰兒車 | P2 |
| 29 | `road_excavation` | 掘路工程 | P1 | 42 | `broken_tree` | 樹木 | P2 |
| 30 | `power_distribution_box` | 配電箱 | P1 | 43 | `tree_root_on_the_road` | 地面樹根 | P2 |
| 31 | `goods` | 街邊貨物 | P1 | 44 | `cycle_path` | 單車徑 | P2 |
| 32 | `goods_rack` | 貨物架 | P1 | 45 | `streetlight` | 路燈 | P2 |
| 33 | `cardboard` | 紙皮 | P1 | 46 | `sign_post` | 標誌桿 | P2 |
| 34 | `table` | 桌椅 | P1 | 47 | `bucket` | 水桶 | P2 |
| 35 | `roll_up_banner_stand` | 易拉架 | P1 | | | | |

`streetlight`(45) 與 `sign_post`(46) 的 `announced=false`：兩者到處都有、
對用户**不可行動**，播報只會把真正該説的話擠掉。檢測保留，只是不説。

**移出檢測任務的兩批**（PDF 的兩條決策，是本表最大的減負）：

- `crop_classifier`（7 項）：`signage_lift` / `signage_escalator` /
  `signage_forward` / `signage_left` / `signage_right` / `signage_up` /
  `signage_down`。YOLO 只畫 `sign_pictogram(20)` 的外框，框內交給小分類模型。
- `ocr_only`（6 項）：店舖名稱、男士、女士、洗手間、地鐵站、巴士站牌。
  交本地 OCR（Android ML Kit / iOS Vision Framework）。

**新增類別的 `gdin_threshold` 尚無實測依據**，按同類近似值先填，
已在 `configs/class_aliases.json` 的 `unmeasured_thresholds` 裏逐個列明待重標。

---

## 一、任務類型先行分級（決定總工作量）

| 任務 | 項數 | 每項實例目標 | 説明 |
|---|---|---|---|
| detect | 37 | 250 | YOLO 檢測框 |
| crop+cls | 7 | 400 | 只需圈出指示牌外框 + 裁圖打小類標籤（通常一張圖能裁出多個） |
| ocr | 6 | — | 不採集檢測數據；由 ML Kit / Vision Framework 讀字 |

**檢測類實例總量：12,050**。按每圖平均 1.5 框估算，約需 **8,033 張圖**。

> PDF 的兩條決策把 12 項 `signage_*` + `shop` 從檢測任務裏拿掉了（共 13 項），
> 這是**最重要的減負**：它們原本會佔掉約 1/4 的檢測採集量。

## 二、逐項清單

| # | 分區 | class name | 中文 | 當前類別表 | 任務 | 優先級 | 採集難度 | 實例目標 | 備註 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 物件 | `rubbish_bin` | 垃圾桶 | bin (7) | detect | P0 | 易 | 250 | 已有 44 圖 / 88 框 |
| 2 | 物件 | `bicycle` | 單車 | bicycle (11) | detect | P0 | 易 | 250 |  |
| 3 | 物件 | `scooter` | 滑板車 | scooter (12) | detect | P1 | 中 | 250 |  |
| 4 | 物件 | `water_filled_barrier` | 水馬 | barrier_water (10) | detect | P1 | 易 | 250 |  |
| 5 | 物件 | `fence` | 圍欄 | **缺** | detect | P1 | 中 | 250 |  |
| 6 | 物件 | `barrier_fencing` | 工程圍網 | **缺** | detect | P1 | 易 | 250 |  |
| 7 | 物件 | `scaffold` | 鷹架 | **缺** | detect | P1 | 中 | 250 |  |
| 8 | 物件 | `road_excavation` | 掘路工程 | **缺** | detect | P1 | 難 | 250 | 文檔注：同時出現多種 label 應可辨識 |
| 9 | 物件 | `traffic_cone` | 交通錐 | traffic_cone (9) | detect | P0 | 易 | 250 |  |
| 10 | 物件 | `traffic_cone_connector_rod` | 交通錐連接杆 | **缺** | detect | P2 | 中 | 250 | 細長物，與錐體常同現 |
| 11 | 物件 | `abrasion-resistant-steel-plates` | 鋪路鋼板 | **缺** | detect | P2 | 中 | 250 |  |
| 12 | 物件 | `push_cart` | 手推車 | cart_trolley (13) | detect | P1 | 易 | 250 | 現表合併了 4 類，需拆分 |
| 13 | 物件 | `hand_truck` | 搬運重物手推車 | **缺** | detect | P2 | 中 | 250 |  |
| 14 | 物件 | `pallet` | 唧車 | **缺** | detect | P2 | 中 | 250 |  |
| 15 | 物件 | `pushchair` | 嬰兒車 | **缺** | detect | P2 | 中 | 250 |  |
| 16 | 物件 | `broken_tree` | 樹木 | **缺** | detect | P2 | 中 | 250 |  |
| 17 | 物件 | `tree_root_on_the_road` | 地面樹根 | **缺** | detect | P2 | 難 | 250 | 貼地，視角依賴 |
| 18 | 物件 | `cycle_path` | 單車徑 | **缺** | detect | P2 | 難 | 250 | 地面標線 |
| 19 | 物件 | `step` | 梯級 | step (14) | detect | P0 | 中 | 250 |  |
| 20 | 物件 | `power_distribution_box` | 配電箱 | **缺** | detect | P1 | 易 | 250 |  |
| 21 | 物件 | `streetlight` | 路燈 | **缺** | detect | P2 | 中 | 250 |  |
| 22 | 物件 | `sign_post` | 標誌桿 | **缺** | detect | P2 | 中 | 250 | 細長 |
| 23 | 物件 | `goods` | 商家放置的貨物 | **缺** | detect | P1 | 難 | 250 | 形態無定 |
| 24 | 物件 | `goods_rack` | 貨物架 | **缺** | detect | P1 | 中 | 250 |  |
| 25 | 物件 | `cardboard` | 紙皮 | **缺** | detect | P1 | 中 | 250 |  |
| 26 | 物件 | `table` | 桌椅 | **缺** | detect | P1 | 中 | 250 |  |
| 27 | 物件 | `roll_up_banner_stand` | 易拉架 | **缺** | detect | P1 | 易 | 250 |  |
| 28 | 物件 | `billboard` | 廣告看板 | **缺** | detect | P1 | 中 | 250 | 座地燈箱 |
| 29 | 物件 | `crowds_of_people_queuing` | 排隊人潮 | **缺** | detect | P0 | 難 | 250 | 文檔注：隊頭/隊尾/橫跨 3 種人潮 |
| 30 | 物件 | `bucket` | 水桶 | **缺** | detect | P2 | 易 | 250 | 文檔注：冷氣機滴水時可能出現在路中心 |
| 31 | 物件 | `caution_slippery` | 警示牌(小心地滑) | **缺** | detect | P0 | 易 | 250 |  |
| 32 | 設施 | `escalator` | 扶手電梯 | escalator_outdoor/indoor (2/19) | detect | P0 | 中 | 250 | 現表按室內外拆兩類 |
| 33 | 設施 | `stair` | 樓梯 | stairs (1) | detect | P0 | 中 | 250 |  |
| 34 | 設施 | `lift` | 升降機 | elevator (3) | detect | P0 | 易 | 250 |  |
| 35 | 設施 | `door` | 門 | door (18) | detect | P1 | 易 | 250 | 文檔注：推/拉/雙向 → action tag |
| 36 | 設施 | `fork_in_road` | 分岔路口 | **缺** | detect | P0 | 難 | 250 | 文檔標註 (??)，定義未定 |
| 37 | 設施 | `signage` | 指示牌(圖示標誌) | sign_pictogram (20) | detect | P1 | 易 | 250 | 只圈框，內部交給下級 |
| 38 | 設施 | `signage_lift` | 升降機指示 | **缺** | crop+cls | P2 | 易 | 400 | PDF 決策：crop + 小分類模型 |
| 39 | 設施 | `signage_escalator` | 扶手電梯指示 | **缺** | crop+cls | P2 | 易 | 400 | 同上 |
| 40 | 設施 | `signage_metro_station` | 地鐵站指示 | **缺** | ocr | — | — | — | PDF 決策：交本地 OCR |
| 41 | 設施 | `signage_washroom` | 洗手間指示 | **缺** | ocr | — | — | — | 同上 |
| 42 | 設施 | `signage_male` | 男士指示 | **缺** | ocr | — | — | — | 同上 |
| 43 | 設施 | `signage_lady` | 女士指示 | **缺** | ocr | — | — | — | 同上 |
| 44 | 設施 | `signage_forward` | 方向前行 | **缺** | crop+cls | P1 | 易 | 400 | 方向箭頭 |
| 45 | 設施 | `signage_left` | 方向左行 | **缺** | crop+cls | P1 | 易 | 400 |  |
| 46 | 設施 | `signage_right` | 方向右行 | **缺** | crop+cls | P1 | 易 | 400 |  |
| 47 | 設施 | `signage_up` | 方向向上 | **缺** | crop+cls | P1 | 易 | 400 |  |
| 48 | 設施 | `signage_down` | 方向向下 | **缺** | crop+cls | P1 | 易 | 400 |  |
| 49 | 設施 | `signage_bus_station` | 巴士站牌 | **缺** | ocr | — | — | — | PDF 決策：字交 OCR |
| 50 | 設施 | `shop` | 店舖類型及名稱 | shop_front (22) | ocr | — | — | — | PDF 決策：移出 YOLO |

## 三、三處衝突的裁決結果（2026-09-27 已定）

### 1. 現表有 10 類、文檔裏沒有 → **保留 9 類，刪 1 類**

| 現表 | id | 裁決 |
|---|---|---|
| `footbridge_entrance` | 0 | **保留**。天橋專項第 1 類，畢設主線入口，文檔遺漏 |
| `ramp` | 4 | 保留 |
| `footbridge_railing` | 5 | 保留 |
| `pedestrian` | 6 | **保留**，與 `crowds_of_people_queuing`(25) 並存。理由：單個行人是避讓對象，人潮是**不可穿越的塊**，處理方式不同（一個繞、一個改道） |
| `bollard` | 8 | 保留 |
| `tactile_paving` | 15 | **保留**。視障引導的核心設施，文檔遺漏 |
| `zebra_crossing` | 16 | 保留 |
| `glass_door` | 17 | 保留 |
| `glass_door_indoor` | 21 | 保留 |
| `ambiguous_vertical` | 23 | **刪除**。分類任務裏保留一個語義為「不知道」的類，會持續吸收本該丟棄的模糊框——那些框對訓練是噪聲、對用户毫無信息量。真遇到分不清的垂直設施，正確做法是**不產生框** |

### 2. 4 類合併成 1 類 → **拆開，且不動 id**

`cart_trolley(13)` 拆為 `push_cart(13)` / `hand_truck(39)` / `pallet(40)` /
`pushchair(41)`。**id 13 留給 push_cart**，所以既有的 2 個標註仍然有效。

拆類的真正風險不是 id，而是**別名互相串門**：`stroller` / `pram` / `hand truck`
原本全掛在 id 13 上，不搬走就會同一個詞命中兩類。已在
`tests/test_label_taxonomy.py::test_split_wheeled_objects_do_not_collide` 裏逐個釘住。

### 3. 兩處定義未定稿 → **都已定**

- `fork_in_road`：定義為「地面標線或路緣分叉成兩條可通行方向的點」，
  框住分叉處的地面區域（不含建築）；採集時只收「站在岔口前看得見分叉」的視角。
- `door` 的推/拉/雙向：用 **tag** 表達（`action:pull` / `action:push` /
  `action:both`），**不拆類別**——拆開會讓同一扇門在不同幀被標成不同類，
  而且推拉方向經常被遮擋。

---

## 四、採集優先級建議

**P0（先做，約決定 Demo 可行性）** — 10 項：rubbish_bin、bicycle、traffic_cone、step、crowds_of_people_queuing、caution_slippery、escalator、stair、lift、fork_in_road

**P1** — 21 項：scooter、water_filled_barrier、fence、barrier_fencing、scaffold、road_excavation、push_cart、power_distribution_box、goods、goods_rack、cardboard、table、roll_up_banner_stand、billboard、door、signage、signage_forward、signage_left、signage_right、signage_up、signage_down

**P2** — 13 項：traffic_cone_connector_rod、abrasion-resistant-steel-plates、hand_truck、pallet、pushchair、broken_tree、tree_root_on_the_road、cycle_path、streetlight、sign_post、bucket、signage_lift、signage_escalator

