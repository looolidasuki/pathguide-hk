# 日常物件零样本可辨识性探测报告

> **这是可行性探测（spike）的产出，不是正式数据集评测。** 未标注真值框，
> 因此给不出 mAP，也不含误报率。它回答的是：*这些物件能不能被零样本认出来。*

- 权重：`yolov8s-world.pt`（YOLO-World-S）
- 图像：Wikimedia Commons **香港**分类，共 363 张（仅用于评测，不用于训练）
- 方法：**每个物件测多组 prompt 说法**，取最佳。这是必要的——
  CLIP 对生僻词敏感，单组 prompt 失败可能是「没问对」而非「认不出」。
- 判定门槛：置信度 >= 0.25
- 耗时：0.4 分钟

## 结论表（按最佳 prompt）

| 物件                     | 图片数 | 最佳检出率    | 平均置信度 | 最佳 prompt                      | 判定                    |
| ---------------------- | --- | -------- | ----- | ------------------------------ | --------------------- |
| 红绿灯 (traffic_light)    | 32  | **0.94** | 0.686 | `a traffic signal`             | ✅ 零样本可用               |
| 长椅 (bench)             | 40  | **0.88** | 0.681 | `a bench`                      | ✅ 零样本可用               |
| 邮筒 (post_box)          | 40  | **0.82** | 0.594 | `a post box`                   | ✅ 零样本可用               |
| 消防栓 (fire_hydrant)     | 7   | **0.71** | 0.639 | `a red fire hydrant`           | ✅ 零样本可用               |
| 花槽 (planter)           | 40  | **0.70** | 0.457 | `a potted plant`               | ✅ 零样本可用               |
| 垃圾桶 (trash_bin)        | 23  | **0.61** | 0.454 | `a rubbish bin`                | ✅ 零样本可用               |
| 店铺招牌 (shop_sign)       | 40  | **0.55** | 0.315 | `a shop signboard`             | ⚠️ 需微调                |
| 电话亭 (phone_booth)      | 39  | **0.21** | 0.140 | `a telephone booth`            | ❌ 弱（需大量实拍）            |
| 自动扶梯 (escalator)       | 27  | **0.15** | 0.069 | `an escalator entrance`        | ❌ 弱（需大量实拍）            |
| 触觉引路带 (tactile_paving) | 35  | **0.03** | 0.036 | `tactile paving on a sidewalk` | ❌ **零样本完全失效**（置信度≈噪声） |
| 行人天桥 (footbridge)      | 40  | **0.03** | 0.032 | `footbridge entrance`          | ❌ **零样本完全失效**（置信度≈噪声） |

## 各 prompt 变体明细

### 红绿灯 (traffic_light) — 32 张，4 组说法

| prompt | 检出率 | 平均置信度 |
|---|---|---|
| `a traffic signal` ⭐ | 0.94 | 0.686 |
| `a traffic light` | 0.88 | 0.586 |
| `traffic lights` | 0.84 | 0.540 |
| `a pedestrian crossing light` | 0.38 | 0.199 |

### 长椅 (bench) — 40 张，3 组说法

| prompt | 检出率 | 平均置信度 |
|---|---|---|
| `a bench` ⭐ | 0.88 | 0.681 |
| `a public bench` | 0.85 | 0.689 |
| `a park bench` | 0.72 | 0.432 |

### 邮筒 (post_box) — 40 张，3 组说法

| prompt | 检出率 | 平均置信度 |
|---|---|---|
| `a post box` ⭐ | 0.82 | 0.594 |
| `a mailbox` | 0.70 | 0.362 |
| `a red pillar box` | 0.03 | 0.017 |

### 消防栓 (fire_hydrant) — 7 张，3 组说法

| prompt | 检出率 | 平均置信度 |
|---|---|---|
| `a fire hydrant` | 0.71 | 0.562 |
| `a red fire hydrant` ⭐ | 0.71 | 0.639 |
| `a street hydrant` | 0.71 | 0.431 |

### 花槽 (planter) — 40 张，6 组说法

| prompt | 检出率 | 平均置信度 |
|---|---|---|
| `a potted plant` ⭐ | 0.70 | 0.457 |
| `a roadside planter` | 0.45 | 0.239 |
| `a plant container` | 0.38 | 0.221 |
| `a flower pot` | 0.30 | 0.182 |
| `a planter` | 0.00 | 0.021 |
| `a tree pit` | 0.00 | 0.001 |

### 垃圾桶 (trash_bin) — 23 张，5 组说法

| prompt | 检出率 | 平均置信度 |
|---|---|---|
| `a rubbish bin` ⭐ | 0.61 | 0.454 |
| `a garbage can` | 0.57 | 0.338 |
| `a trash bin` | 0.52 | 0.344 |
| `a waste basket` | 0.48 | 0.327 |
| `a litter bin` | 0.35 | 0.163 |

### 店铺招牌 (shop_sign) — 40 张，4 组说法

| prompt | 检出率 | 平均置信度 |
|---|---|---|
| `a shop signboard` ⭐ | 0.55 | 0.315 |
| `a shop sign` | 0.35 | 0.229 |
| `a store sign` | 0.35 | 0.243 |
| `a shop front` | 0.00 | 0.017 |

### 电话亭 (phone_booth) — 39 张，3 组说法

| prompt | 检出率 | 平均置信度 |
|---|---|---|
| `a telephone booth` ⭐ | 0.21 | 0.140 |
| `a phone booth` | 0.13 | 0.070 |
| `a public telephone` | 0.00 | 0.004 |

### 自动扶梯 (escalator) — 27 张，4 组说法

| prompt | 检出率 | 平均置信度 |
|---|---|---|
| `an escalator entrance` ⭐ | 0.15 | 0.069 |
| `an escalator` | 0.04 | 0.037 |
| `escalators` | 0.00 | 0.011 |
| `a moving staircase` | 0.00 | 0.000 |

### 触觉引路带 (tactile_paving) — 35 张，6 组说法

| prompt | 检出率 | 平均置信度 |
|---|---|---|
| `tactile paving on a sidewalk` ⭐ | 0.03 | 0.036 |
| `yellow tactile paving` | 0.03 | 0.013 |
| `tactile paving` | 0.00 | 0.009 |
| `a blind guide path` | 0.00 | 0.000 |
| `truncated domes on the ground` | 0.00 | 0.000 |
| `a guide path for the blind` | 0.00 | 0.000 |

### 行人天桥 (footbridge) — 40 张，10 组说法

| prompt | 检出率 | 平均置信度 |
|---|---|---|
| `a pedestrian bridge` | 0.03 | 0.012 |
| `footbridge entrance` ⭐ | 0.03 | 0.032 |
| `a footbridge` | 0.00 | 0.002 |
| `an overpass` | 0.00 | 0.034 |
| `a walkway bridge` | 0.00 | 0.016 |
| `a covered walkway` | 0.00 | 0.001 |
| `an elevated walkway` | 0.00 | 0.006 |
| `a pedestrian overpass` | 0.00 | 0.012 |
| `a bridge staircase` | 0.00 | 0.004 |
| `a skybridge` | 0.00 | 0.007 |


## 重要说明

1. **本表衡量的是『可检出性』，不是精度。** 未标注真值框，因此无法给出 mAP。
   未统计误报率——零样本模型可能在无关图像上乱出框。
2. 图像全部来自 Commons 的香港分类，是**真实香港街景**，因此该表可直接反映
   『零样本方案在香港能不能用』。
3. 图片量普遍偏小，检出率的分母很小，数字波动大。
   **这本身就是结论的一部分**：网上几乎没有香港日常物件的图。
4. 图片许可多为 CC BY / CC BY-SA，署名信息见 `attribution.jsonl`；
   若写入论文须列出作者与许可证。
