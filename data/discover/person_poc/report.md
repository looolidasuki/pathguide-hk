# 类别发现报告

- 图像：2 张（`data\frames\person_poc`）
- 模型：`IDEA-Research/grounding-dino-tiny`（**每次单 prompt**）
- 类别表：48 类；表内待查词 48 个；表外候选词 10 个
- 耗时：0.4 分钟（10.88 s/图）

## 表内检出（candidates.csv）

| id | 类别 | 框数 | 出现图 | 出图率 |
|---|---|---|---|---|
| 36 | billboard | 17 | 2 | 100% |
| 25 | crowds_of_people_queuing | 16 | 2 | 100% |
| 6 | pedestrian | 11 | 2 | 100% |
| 45 | streetlight | 11 | 2 | 100% |
| 0 | footbridge_entrance | 7 | 2 | 100% |
| 20 | sign_pictogram | 7 | 2 | 100% |
| 39 | hand_truck | 6 | 2 | 100% |
| 38 | abrasion_resistant_steel_plates | 5 | 2 | 100% |
| 46 | sign_post | 5 | 2 | 100% |
| 18 | door | 4 | 2 | 100% |
| 23 | fork_in_road | 4 | 2 | 100% |
| 33 | cardboard | 4 | 2 | 100% |
| 43 | tree_root_on_the_road | 4 | 2 | 100% |
| 4 | ramp | 3 | 2 | 100% |
| 7 | bin | 3 | 2 | 100% |
| 11 | bicycle | 3 | 2 | 100% |
| 21 | glass_door_indoor | 3 | 2 | 100% |
| 22 | shop_front | 3 | 2 | 100% |
| 41 | pushchair | 3 | 2 | 100% |
| 44 | cycle_path | 3 | 2 | 100% |
| 1 | stairs | 2 | 2 | 100% |
| 8 | bollard | 2 | 2 | 100% |
| 10 | barrier_water | 2 | 2 | 100% |
| 13 | push_cart | 2 | 2 | 100% |
| 14 | step | 2 | 2 | 100% |
| 19 | escalator_indoor | 2 | 2 | 100% |
| 24 | caution_slippery | 2 | 2 | 100% |
| 29 | road_excavation | 2 | 2 | 100% |
| 31 | goods | 2 | 2 | 100% |
| 35 | roll_up_banner_stand | 2 | 2 | 100% |
| 37 | traffic_cone_connector_rod | 2 | 1 | 50% |
| 3 | elevator | 1 | 1 | 50% |
| 40 | pallet | 1 | 1 | 50% |
| 2 | escalator_outdoor | 1 | 1 | 50% |
| 15 | tactile_paving | 1 | 1 | 50% |
| 16 | zebra_crossing | 1 | 1 | 50% |
| 42 | broken_tree | 1 | 1 | 50% |
| 47 | bucket | 1 | 1 | 50% |

表内零检出（10）：footbridge_railing, traffic_cone, scooter, glass_door, fence, barrier_fencing, scaffold, power_distribution_box, goods_rack, table


## ★ 表外候选（out_of_taxonomy.csv）

**这些不在类别表内，但确实被检出**。它们当前会被静默漏掉——
这份清单就是把「静默漏掉」变成「显式报告」。

| 标签 | 框数 | 出现图 | 出图率 |
|---|---|---|---|
| planter | 3 | 2 | 100% |
| shopping bag | 2 | 2 | 100% |
| post box | 1 | 1 | 50% |
| rubbish bag | 1 | 1 | 50% |

## 标签异常（返回标签 != 所问 query）

通常由 tokenizer 破损造成。异常标签会落入「表外」，不会被错误映射，
但仍需关注：

- `a queue people` × 16
- `water - filled barrier` × 2
- `the street` × 2
- `banner` × 2
- `bar` × 2
- `the pavement` × 2
- `tree roots` × 2