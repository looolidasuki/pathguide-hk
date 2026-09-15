# 日常物件零样本探测 · 结论与建议

**日期：** 2026-09-15
**性质：** 可行性探测（spike）· throwaway · **不是**正式数据集评测
**原始数据：** `data/probe/report.md`（自动生成）、`data/probe/report.json`、`data/probe/hk/attribution.jsonl`

---

## 1. 探测问题与结论

**问题：** 能否靠网上数据识别香港的日常物件（垃圾桶等）？

**结论：**
- **通用物件可以**，零样本即可用：红绿灯 0.94、长椅 0.88、邮筒 0.82、花槽 0.70、垃圾桶 0.61。
- **香港基础设施不行**，且失败原因**各不相同**：天桥 0.03、触觉引路带 0.03、扶梯 0.15。
- **网上数据只能冷启动通用物件，无法替代实地采集**——而且失败的三类恰好是毕设的核心类别。

---

## 2. 关键方法：为什么必须测多组 prompt

CLIP 对生僻词敏感。**单组 prompt 失败可能是「没问对」，而不是「认不出」**——两者结论完全相反。因此每个物件测 3–10 组说法，取最佳。

这个设计直接改变了三个结论：

| 物件 | 单 prompt | 多 prompt 最佳 | 变化 |
|---|---|---|---|
| 花槽 | 0.00（`a planter`） | **0.70**（`a potted plant`） | 从"完全失效"变为"可用" |
| 垃圾桶 | 0.52（`a trash bin`） | **0.61**（`a rubbish bin`） | 显著提升 |
| 店铺招牌 | 0.35（`a shop sign`） | **0.55**（`a shop signboard`） | 从"弱"变为"需微调" |
| 红绿灯 | 0.88（`a traffic light`） | **0.94**（`a traffic signal`） | 提升 |

**教训：** 用零样本方案时，**prompt 措辞是一等超参数**。`a planter` → 0.00 与 `a potted plant` → 0.70 的差距说明，若不测变体就会得出"花槽无法识别"的错误结论。

---

## 3. 失败原因诊断（本探测最有价值的部分）

三类的失败**原因不同**，处理方式也完全不同。**这一点无法从检出率数字看出，必须核对图像内容。**

### 3.1 天桥（0.03）—— **数据问题，不是模型问题**

Commons 的 `Category:Footbridges in Hong Kong` 全是**远景桥身**：

```
Aberdeen Tunnel Bus-Bus Interchange footbridge 28-07-2026(1).jpg
MTR Lai King Station to Kwai Tsing Container Terminals footbridge 28-04-2026.jpg
Connaught Road Central Bridge 201705.jpg
HK SKD TKO 將軍澳南 Tseung Kwan O South Promenade 海濱 bay footbridge June 2022 Px3 01.jpg
```

而项目目标是 **`footbridge_entrance`（入口近景）**——通道开口、楼梯、坡道、升降机。

**远景桥身与入口近景在视觉上几乎无共同点**（一个是横跨马路的完整结构，一个是地面高度的一个开口）。

> **因此 0.03 不能证明模型认不出天桥入口，只能证明它认不出桥身远景。**
> 这是一个**未决问题**，不是失败结论。

### 3.2 触觉引路带（0.03）—— **数据质量差**

样本里大量是"碰巧带盲道"的照片，分类标签本身就弱：

```
HK TST Star Ferry Piers interior night D0416-2 (10).JPG      ← 星光码头室内夜景
HK Central 中環中心 The Center mall shop interior Blindness care line.jpg  ← 室内店铺
HK Park 香港茶具文物館 Museum of Tea ware ... staircase ... fence n flooring  ← 楼梯与地板
```

这些图的主体**不是**盲道。分母不可信，因此 0.03 也不构成模型失败的证据。

### 3.3 扶梯（0.15）—— **真正的模型失败** ⚠️

样本是**货真价实的扶梯**：

```
HK MTR station long escalators metal stairs April 2026 N13P.jpg
HK Shatin Yu Chui Shopping Centre interior escalators Sept-2012.JPG
Hong Kong Mid-Level Escalators.jpg
```

模型仍然认不出（平均置信度仅 0.069）。**这是本探测中唯一一类"数据没问题、模型就是不行"的类别。**

扶梯在视觉上确实难：长条状、强透视、纹理重复，且与楼梯高度相似——这与设计文档中 `ambiguous_vertical` 类别的判断一致。

---

## 4. 数据可得性观察

| 观察 | 数据 |
|---|---|
| Commons 香港分类文件数 | 邮筒 47+ / 电话亭 78 / 长椅 98+ / 花槽 50 / 红绿灯 32 / 天桥 60+ / 扶梯 27 / 触觉引路带 35 / 店铺招牌 120+ |
| 垃圾桶 | `Rubbish bins in Hong Kong` **存在但 0 文件**；实际来自 `Waste containers in Hong Kong`，共 23 张 |
| 护柱 | `Bollards in Hong Kong` **分类不存在** |
| 全文搜索落差 | "trash bin" 全球 313,575 命中，加 "Hong Kong" 仅 **18** |

**这组数字说明：即使是香港这样影像资料极丰富的城市，Commons 上的日常物件图也只有几十张量级，而训练需要数百张。** 网上数据在数量上就不足以支撑训练。

---

## 5. 工具与环境适配（踩坑记录）

本次探测为跑通 YOLO-World 解决了 4 个真实障碍，均已写入 `scripts/env_setup.py`：

| 障碍 | 现象 | 处理 |
|---|---|---|
| CLIP 包缺失 | Ultralytics 要 `git+https://github.com/ultralytics/CLIP.git`，自动安装失败 | 下载源码 zip 从本地路径安装（`git clone` 在受限环境因 `sh.exe` 无法建信号管道而失败） |
| CLIP 权重写不进去 | `PermissionError: ~/.cache/clip` | 猴补 `clip.load` 注入 `download_root`。**设 `CLIP_DOWNLOAD_ROOT` 环境变量无效**——CLIP 根本没读它 |
| CLIP token device 不匹配 | `RuntimeError: Expected all tensors to be on the same device ... cpu ... cuda:0` | 猴补 `CLIP.tokenize` 把 token 移到内部模块参数的真实设备 |
| `self.device` 不可靠 | 用它反而制造 device 不匹配 | **必须从 `self.model.parameters()` 推导真实设备**——实测 `self.device` 可能记为 `cpu` 而参数在 `cuda:0` |

**另注：** `--per-cat` 递归统计 Commons 分类文件数时，因其限流，10 分钟未完成，已放弃——不值得为一个估计值耗这个时间。

---

## 6. 建议

### 6.1 立即可用（无需训练）

红绿灯、长椅、邮筒、花槽、垃圾桶、消防栓这 6 类**零样本即可用**。它们可作为**障碍物与地标**直接纳入 Demo，省掉训练成本。注意零样本的误报率未测——上线前必须补测。

### 6.2 必须实地采集（核心类别）

| 类别 | 原因 | 采集量 |
|---|---|---|
| `footbridge_entrance` | 网上无对应视角的图像 | ≥250 张（与 `collect_plan.md` 一致） |
| `escalator_*` | 零样本确实失败（平均置信度 0.069） | ≥120 张 |
| `tactile_paving` | 网上样本主体不对 | ≥200 张 |

### 6.3 下一步：30 张实地样本，排除"问法/数据"解释

这是本次探测**尚未回答**的唯一问题。用手机在调景岭站→彩明商场一线拍：

| 内容 | 张数 | 要求 |
|---|---|---|
| 天桥入口近景 | 10 | 通道开口、上行楼梯、坡道、升降机，**正面近景** |
| 扶梯 | 10 | **横视与正对两种姿态各 5 张** |
| 触觉引路带 | 10 | 俯视近景，盲道为画面主体 |

然后用同一组 prompt 重跑 `scripts/probe/probe_zeroshot.py`。判定：

- 天桥入口检出率 **≥0.6** → 零样本可用，网上数据的问题只是视角
- 仍 **<0.2** → 零样本确实不行，必须走"实地采集 + 微调"主线（即现有的 M0–M2 计划）

**这 30 张照片的成本是半小时，但它能把一个悬而未决的问题彻底关闭。**

---

## 7. 复现方式

```powershell
. .\.env.ps1
python scripts\probe\fetch_commons.py --out data/probe/hk --per-cat 40
python scripts\probe\probe_zeroshot.py --images data/probe/hk --out data/probe
```

**图像许可：** 全部来自 Wikimedia Commons，多为 CC BY / CC BY-SA。作者、许可证、描述页 URL 逐张记录在 `data/probe/hk/attribution.jsonl`。**若写入论文须列出署名。**
