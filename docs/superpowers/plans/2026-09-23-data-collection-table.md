# 数据采集表（按《labelObject_workload》50 项）

来源：`Accessible Visual Guidance Note/labelObject_workload 20260920.pdf`（5 页，31 物件 + 19 設施）

---

## 〇、v3 已落地：类别表从 24 类扩到 48 类（2026-09-27）

本文件下面第二节的「当前类别表」列是**改表之前**的状态（写作时的快照）。
改表已按第三、四节的裁决执行，结果如下，`configs/classes.json` 是唯一事实源。

**动了两个既有槽位（都经核查）：**

| 槽位 | v2 | v3 | 为什么可以动 |
|---|---|---|---|
| id 13 | `cart_trolley` | **`push_cart`** | 只改名、**槽位不动**，既有 2 个标注仍然有效。语义收窄为「人手推的载货小车」 |
| id 23 | `ambiguous_vertical`（占位类） | **`fork_in_road`** | 该槽位**从未有过任何标注**，是全表唯一可安全复用的空位（生成器要求 id 连续）。复用前已确认它在本项目全部标签文件中出现 0 次 |

**新增 25 类，占 id 23–47**（id 23 = fork_in_road，24–47 按优先级排）：

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

`streetlight`(45) 与 `sign_post`(46) 的 `announced=false`：两者到处都有、
对用户**不可行动**，播报只会把真正该说的话挤掉。检测保留，只是不说。

**移出检测任务的两批**（PDF 的两条决策，是本表最大的减负）：

- `crop_classifier`（7 项）：`signage_lift` / `signage_escalator` /
  `signage_forward` / `signage_left` / `signage_right` / `signage_up` /
  `signage_down`。YOLO 只画 `sign_pictogram(20)` 的外框，框内交给小分类模型。
- `ocr_only`（6 项）：店舖名稱、男士、女士、洗手間、地鐵站、巴士站牌。
  交本地 OCR（Android ML Kit / iOS Vision Framework）。

**新增类别的 `gdin_threshold` 尚无实测依据**，按同类近似值先填，
已在 `configs/class_aliases.json` 的 `unmeasured_thresholds` 里逐个列明待重标。

---

## 一、任务类型先行分级（决定总工作量）

| 任务 | 项数 | 每项实例目标 | 说明 |
|---|---|---|---|
| detect | 37 | 250 | YOLO 检测框 |
| crop+cls | 7 | 400 | 只需圈出指示牌外框 + 裁图打小类标签（通常一张图能裁出多个） |
| ocr | 6 | — | 不采集检测数据；由 ML Kit / Vision Framework 读字 |

**检测类实例总量：12,050**。按每图平均 1.5 框估算，约需 **8,033 张图**。

> PDF 的两条决策把 12 项 `signage_*` + `shop` 从检测任务里拿掉了（共 13 项），
> 这是**最重要的减负**：它们原本会占掉约 1/4 的检测采集量。

## 二、逐项清单

| # | 分区 | class name | 中文 | 当前类别表 | 任务 | 优先级 | 采集难度 | 实例目标 | 备注 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 物件 | `rubbish_bin` | 垃圾桶 | bin (7) | detect | P0 | 易 | 250 | 已有 44 图 / 88 框 |
| 2 | 物件 | `bicycle` | 單車 | bicycle (11) | detect | P0 | 易 | 250 |  |
| 3 | 物件 | `scooter` | 滑板車 | scooter (12) | detect | P1 | 中 | 250 |  |
| 4 | 物件 | `water_filled_barrier` | 水馬 | barrier_water (10) | detect | P1 | 易 | 250 |  |
| 5 | 物件 | `fence` | 圍欄 | **缺** | detect | P1 | 中 | 250 |  |
| 6 | 物件 | `barrier_fencing` | 工程圍網 | **缺** | detect | P1 | 易 | 250 |  |
| 7 | 物件 | `scaffold` | 鷹架 | **缺** | detect | P1 | 中 | 250 |  |
| 8 | 物件 | `road_excavation` | 掘路工程 | **缺** | detect | P1 | 难 | 250 | 文档注：同時出現多種 label 應可辨識 |
| 9 | 物件 | `traffic_cone` | 交通錐 | traffic_cone (9) | detect | P0 | 易 | 250 |  |
| 10 | 物件 | `traffic_cone_connector_rod` | 交通錐連接杆 | **缺** | detect | P2 | 中 | 250 | 細長物，與锥體常同現 |
| 11 | 物件 | `abrasion-resistant-steel-plates` | 鋪路鋼板 | **缺** | detect | P2 | 中 | 250 |  |
| 12 | 物件 | `push_cart` | 手推車 | cart_trolley (13) | detect | P1 | 易 | 250 | 现表合并了 4 类，需拆分 |
| 13 | 物件 | `hand_truck` | 搬運重物手推車 | **缺** | detect | P2 | 中 | 250 |  |
| 14 | 物件 | `pallet` | 唧車 | **缺** | detect | P2 | 中 | 250 |  |
| 15 | 物件 | `pushchair` | 嬰兒車 | **缺** | detect | P2 | 中 | 250 |  |
| 16 | 物件 | `broken_tree` | 樹木 | **缺** | detect | P2 | 中 | 250 |  |
| 17 | 物件 | `tree_root_on_the_road` | 地面樹根 | **缺** | detect | P2 | 难 | 250 | 贴地，视角依赖 |
| 18 | 物件 | `cycle_path` | 單車徑 | **缺** | detect | P2 | 难 | 250 | 地面标线 |
| 19 | 物件 | `step` | 梯級 | step (14) | detect | P0 | 中 | 250 |  |
| 20 | 物件 | `power_distribution_box` | 配電箱 | **缺** | detect | P1 | 易 | 250 |  |
| 21 | 物件 | `streetlight` | 路燈 | **缺** | detect | P2 | 中 | 250 |  |
| 22 | 物件 | `sign_post` | 標誌桿 | **缺** | detect | P2 | 中 | 250 | 細長 |
| 23 | 物件 | `goods` | 商家放置的貨物 | **缺** | detect | P1 | 难 | 250 | 形态无定 |
| 24 | 物件 | `goods_rack` | 貨物架 | **缺** | detect | P1 | 中 | 250 |  |
| 25 | 物件 | `cardboard` | 紙皮 | **缺** | detect | P1 | 中 | 250 |  |
| 26 | 物件 | `table` | 桌椅 | **缺** | detect | P1 | 中 | 250 |  |
| 27 | 物件 | `roll_up_banner_stand` | 易拉架 | **缺** | detect | P1 | 易 | 250 |  |
| 28 | 物件 | `billboard` | 廣告看板 | **缺** | detect | P1 | 中 | 250 | 座地燈箱 |
| 29 | 物件 | `crowds_of_people_queuing` | 排隊人潮 | **缺** | detect | P0 | 难 | 250 | 文档注：隊頭/隊尾/橫跨 3 種人潮 |
| 30 | 物件 | `bucket` | 水桶 | **缺** | detect | P2 | 易 | 250 | 文档注：冷氣機滴水時可能出現在路中心 |
| 31 | 物件 | `caution_slippery` | 警示牌(小心地滑) | **缺** | detect | P0 | 易 | 250 |  |
| 32 | 設施 | `escalator` | 扶手電梯 | escalator_outdoor/indoor (2/19) | detect | P0 | 中 | 250 | 现表按室内外拆两类 |
| 33 | 設施 | `stair` | 樓梯 | stairs (1) | detect | P0 | 中 | 250 |  |
| 34 | 設施 | `lift` | 升降機 | elevator (3) | detect | P0 | 易 | 250 |  |
| 35 | 設施 | `door` | 門 | door (18) | detect | P1 | 易 | 250 | 文档注：推/拉/雙向 → action tag |
| 36 | 設施 | `fork_in_road` | 分岔路口 | **缺** | detect | P0 | 难 | 250 | 文档标注 (??)，定义未定 |
| 37 | 設施 | `signage` | 指示牌(圖示標誌) | sign_pictogram (20) | detect | P1 | 易 | 250 | 只圈框，內部交給下級 |
| 38 | 設施 | `signage_lift` | 升降機指示 | **缺** | crop+cls | P2 | 易 | 400 | PDF 决策：crop + 小分类模型 |
| 39 | 設施 | `signage_escalator` | 扶手電梯指示 | **缺** | crop+cls | P2 | 易 | 400 | 同上 |
| 40 | 設施 | `signage_metro_station` | 地鐵站指示 | **缺** | ocr | — | — | — | PDF 决策：交本地 OCR |
| 41 | 設施 | `signage_washroom` | 洗手間指示 | **缺** | ocr | — | — | — | 同上 |
| 42 | 設施 | `signage_male` | 男士指示 | **缺** | ocr | — | — | — | 同上 |
| 43 | 設施 | `signage_lady` | 女士指示 | **缺** | ocr | — | — | — | 同上 |
| 44 | 設施 | `signage_forward` | 方向前行 | **缺** | crop+cls | P1 | 易 | 400 | 方向箭頭 |
| 45 | 設施 | `signage_left` | 方向左行 | **缺** | crop+cls | P1 | 易 | 400 |  |
| 46 | 設施 | `signage_right` | 方向右行 | **缺** | crop+cls | P1 | 易 | 400 |  |
| 47 | 設施 | `signage_up` | 方向向上 | **缺** | crop+cls | P1 | 易 | 400 |  |
| 48 | 設施 | `signage_down` | 方向向下 | **缺** | crop+cls | P1 | 易 | 400 |  |
| 49 | 設施 | `signage_bus_station` | 巴士站牌 | **缺** | ocr | — | — | — | PDF 决策：字交 OCR |
| 50 | 設施 | `shop` | 店舖類型及名稱 | shop_front (22) | ocr | — | — | — | PDF 决策：移出 YOLO |

## 三、三处冲突的裁决结果（2026-09-27 已定）

### 1. 现表有 10 类、文档里没有 → **保留 9 类，删 1 类**

| 现表 | id | 裁决 |
|---|---|---|
| `footbridge_entrance` | 0 | **保留**。天桥专项第 1 类，毕设主线入口，文档遗漏 |
| `ramp` | 4 | 保留 |
| `footbridge_railing` | 5 | 保留 |
| `pedestrian` | 6 | **保留**，与 `crowds_of_people_queuing`(25) 并存。理由：单个行人是避让对象，人潮是**不可穿越的块**，处理方式不同（一个绕、一个改道） |
| `bollard` | 8 | 保留 |
| `tactile_paving` | 15 | **保留**。视障引导的核心设施，文档遗漏 |
| `zebra_crossing` | 16 | 保留 |
| `glass_door` | 17 | 保留 |
| `glass_door_indoor` | 21 | 保留 |
| `ambiguous_vertical` | 23 | **删除**。分类任务里保留一个语义为「不知道」的类，会持续吸收本该丢弃的模糊框——那些框对训练是噪声、对用户毫无信息量。真遇到分不清的垂直设施，正确做法是**不产生框** |

### 2. 4 类合并成 1 类 → **拆开，且不动 id**

`cart_trolley(13)` 拆为 `push_cart(13)` / `hand_truck(39)` / `pallet(40)` /
`pushchair(41)`。**id 13 留给 push_cart**，所以既有的 2 个标注仍然有效。

拆类的真正风险不是 id，而是**别名互相串门**：`stroller` / `pram` / `hand truck`
原本全挂在 id 13 上，不搬走就会同一个词命中两类。已在
`tests/test_label_taxonomy.py::test_split_wheeled_objects_do_not_collide` 里逐个钉住。

### 3. 两处定义未定稿 → **都已定**

- `fork_in_road`：定义为「地面标线或路缘分叉成两条可通行方向的点」，
  框住分叉处的地面区域（不含建筑）；采集时只收「站在岔口前看得见分叉」的视角。
- `door` 的推/拉/双向：用 **tag** 表达（`action:pull` / `action:push` /
  `action:both`），**不拆类别**——拆开会让同一扇门在不同帧被标成不同类，
  而且推拉方向经常被遮挡。

---

## 四、采集优先级建议

**P0（先做，约决定 Demo 可行性）** — 10 项：rubbish_bin、bicycle、traffic_cone、step、crowds_of_people_queuing、caution_slippery、escalator、stair、lift、fork_in_road

**P1** — 21 项：scooter、water_filled_barrier、fence、barrier_fencing、scaffold、road_excavation、push_cart、power_distribution_box、goods、goods_rack、cardboard、table、roll_up_banner_stand、billboard、door、signage、signage_forward、signage_left、signage_right、signage_up、signage_down

**P2** — 13 项：traffic_cone_connector_rod、abrasion-resistant-steel-plates、hand_truck、pallet、pushchair、broken_tree、tree_root_on_the_road、cycle_path、streetlight、sign_post、bucket、signage_lift、signage_escalator

