# 类别发现报告

- 图像：30 张（`data\frames\person_poc`）
- 模型：`IDEA-Research/grounding-dino-tiny`（**每次单 prompt**）
- 类别表：48 类；表内待查词 48 个；表外候选词 10 个
- 耗时：5.7 分钟（11.32 s/图）

## 表内检出（candidates.csv）

| id | 类别 | 框数 | 出现图 | 出图率 |
|---|---|---|---|---|
| 25 | crowds_of_people_queuing | 243 | 30 | 100% |
| 6 | pedestrian | 180 | 30 | 100% |
| 36 | billboard | 131 | 30 | 100% |
| 20 | sign_pictogram | 124 | 30 | 100% |
| 42 | broken_tree | 103 | 26 | 87% |
| 46 | sign_post | 83 | 30 | 100% |
| 0 | footbridge_entrance | 81 | 30 | 100% |
| 45 | streetlight | 67 | 25 | 83% |
| 4 | ramp | 65 | 30 | 100% |
| 38 | abrasion_resistant_steel_plates | 65 | 30 | 100% |
| 10 | barrier_water | 61 | 29 | 97% |
| 18 | door | 61 | 29 | 97% |
| 7 | bin | 56 | 28 | 93% |
| 44 | cycle_path | 55 | 30 | 100% |
| 41 | pushchair | 54 | 29 | 97% |
| 23 | fork_in_road | 52 | 30 | 100% |
| 43 | tree_root_on_the_road | 52 | 30 | 100% |
| 35 | roll_up_banner_stand | 50 | 29 | 97% |
| 39 | hand_truck | 48 | 27 | 90% |
| 13 | push_cart | 46 | 27 | 90% |
| 24 | caution_slippery | 45 | 26 | 87% |
| 40 | pallet | 43 | 26 | 87% |
| 22 | shop_front | 41 | 28 | 93% |
| 3 | elevator | 38 | 22 | 73% |
| 29 | road_excavation | 36 | 30 | 100% |
| 37 | traffic_cone_connector_rod | 36 | 20 | 67% |
| 21 | glass_door_indoor | 35 | 22 | 73% |
| 27 | barrier_fencing | 35 | 25 | 83% |
| 33 | cardboard | 32 | 21 | 70% |
| 30 | power_distribution_box | 32 | 19 | 63% |
| 11 | bicycle | 28 | 15 | 50% |
| 31 | goods | 28 | 24 | 80% |
| 17 | glass_door | 25 | 18 | 60% |
| 14 | step | 24 | 18 | 60% |
| 26 | fence | 24 | 20 | 67% |
| 1 | stairs | 23 | 18 | 60% |
| 8 | bollard | 23 | 19 | 63% |
| 32 | goods_rack | 21 | 14 | 47% |
| 19 | escalator_indoor | 16 | 15 | 50% |
| 16 | zebra_crossing | 14 | 13 | 43% |
| 2 | escalator_outdoor | 12 | 11 | 37% |
| 15 | tactile_paving | 9 | 9 | 30% |
| 28 | scaffold | 9 | 7 | 23% |
| 5 | footbridge_railing | 6 | 6 | 20% |
| 47 | bucket | 5 | 4 | 13% |
| 34 | table | 4 | 4 | 13% |
| 9 | traffic_cone | 3 | 3 | 10% |

表内零检出（1）：scooter


## ★ 表外候选（out_of_taxonomy.csv）

**这些不在类别表内，但确实被检出**。它们当前会被静默漏掉——
这份清单就是把「静默漏掉」变成「显式报告」。

| 标签 | 框数 | 出现图 | 出图率 |
|---|---|---|---|
| shopping bag | 88 | 30 | 100% |
| rubbish bag | 73 | 29 | 97% |
| bus stop | 23 | 15 | 50% |
| planter | 15 | 14 | 47% |
| post box | 10 | 7 | 23% |
| wheelchair | 5 | 4 | 13% |
| bench | 4 | 4 | 13% |
| suitcase | 4 | 4 | 13% |
| fire hydrant | 2 | 2 | 7% |

## 标签异常（返回标签 != 所问 query）

通常由 tokenizer 破损造成。异常标签会落入「表外」，不会被错误映射，
但仍需关注：

- `a queue people` × 218
- `water - filled barrier` × 60
- `banner` × 50
- `pavement` × 27
- `people` × 25
- `tree roots` × 18
- `street` × 18
- `bar` × 11
- `zebra` × 10
- `traffic bar` × 8
- `the pavement` × 7
- `the street` × 6
- `goods` × 4
- `traffic cone` × 3
- `sign` × 2