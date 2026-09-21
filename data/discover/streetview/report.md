# 类别发现报告

- 图像：36 张（`data\probe\streetview`）
- 模型：`IDEA-Research/grounding-dino-tiny`（**每次单 prompt**）
- 类别表：24 类；表内待查词 23 个；表外候选词 17 个
- 耗时：5.4 分钟（8.94 s/图）

## 表内检出（candidates.csv）

| id | 类别 | 框数 | 出现图 | 出图率 |
|---|---|---|---|---|
| 6 | pedestrian | 266 | 36 | 100% |
| 20 | sign_pictogram | 214 | 36 | 100% |
| 7 | bin | 112 | 36 | 100% |
| 18 | door | 112 | 36 | 100% |
| 4 | ramp | 97 | 36 | 100% |
| 0 | footbridge_entrance | 81 | 36 | 100% |
| 10 | barrier_water | 69 | 36 | 100% |
| 13 | cart_trolley | 63 | 26 | 72% |
| 17 | glass_door | 61 | 34 | 94% |
| 21 | glass_door_indoor | 59 | 35 | 97% |
| 22 | shop_front | 39 | 36 | 100% |
| 3 | elevator | 36 | 26 | 72% |
| 15 | tactile_paving | 36 | 36 | 100% |
| 14 | step | 35 | 25 | 69% |
| 2 | escalator_outdoor | 28 | 26 | 72% |
| 16 | zebra_crossing | 28 | 23 | 64% |
| 8 | bollard | 21 | 21 | 58% |
| 1 | stairs | 21 | 18 | 50% |
| 19 | escalator_indoor | 17 | 16 | 44% |
| 5 | footbridge_railing | 11 | 10 | 28% |
| 11 | bicycle | 1 | 1 | 3% |

表内零检出（2）：traffic_cone, scooter


## ★ 表外候选（out_of_taxonomy.csv）

**这些不在类别表内，但确实被检出**。它们当前会被静默漏掉——
这份清单就是把「静默漏掉」变成「显式报告」。

| 标签 | 框数 | 出现图 | 出图率 |
|---|---|---|---|
| banner | 217 | 36 | 100% |
| shopping bag | 163 | 36 | 100% |
| lamp post | 129 | 36 | 100% |
| rubbish bag | 127 | 36 | 100% |
| tree | 51 | 36 | 100% |
| cardboard | 28 | 21 | 58% |
| utility box | 25 | 22 | 61% |
| suitcase | 23 | 18 | 50% |
| bench | 21 | 19 | 53% |
| chair | 17 | 17 | 47% |
| planter | 16 | 16 | 44% |
| post box | 13 | 11 | 31% |
| table | 11 | 11 | 31% |
| bus stop | 3 | 3 | 8% |
| wheelchair | 1 | 1 | 3% |

## 标签异常（返回标签 != 所问 query）

通常由 tokenizer 破损造成。异常标签会落入「表外」，不会被错误映射，
但仍需关注：

- `water - filled barrier` × 69