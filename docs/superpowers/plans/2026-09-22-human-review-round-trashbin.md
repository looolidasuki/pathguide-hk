# 人工复核一轮 · 数据生产记录（trashbin 试点）

**日期：** 2026-09-22
**范围：** `data/raw/tiu_keng_leng/trashbin/` 实拍 44 张（单类 `bin` 试点）
**目的：** 跑通「AI 预标 → 人工复核 → 回写数据集 → 重训」这条闭环，验证它值不值得，
并为计划 Task 10 的 300 张种子集提供可复用的操作规程。

---

## 1. 这一轮暴露的真实缺陷：复核结果根本没进数据集

**现象：** 人工在 X-AnyLabeling 里改完框，`data/dataset/labels/` 里仍是三阶段
预标注的产物。

**根因：** GUI 保存只写回**同名 `.json`**。X-AnyLabeling 0.4.43 的 PyPI 版能导出
YOLO、不能导入 YOLO，它的原生标签格式就是同名 JSON。于是人工的修改停留在
`data/xtest/` 里，训练完全看不到。

**为什么危险：** 和已经踩过的「标签未镜像目录结构」是同一类错误——**不报错**。
训练照跑，指标照出，只是人工复核的收益为零。若不做这次核对，会直接得出
「人工复核没用」的错误结论。

**修复：** 新增 `scripts/xlabel_io.py`，把「JSON → 数据集」变成**显式的一步**，
并在转写前做质检。

---

## 2. 效果实测

| 指标 | 复核前（三阶段预标） | 复核后 | 变化 |
|---|---|---|---|
| 标注框总数 | 86 | **122** | +36（+42%） |
| `bin`(id=7) | 51 | **88** | +37 |
| `pedestrian`(id=6) | 30 | 30 | 0 |
| `cart_trolley`(id=13) | 3 | 2 | −1 |
| `sign_pictogram`(id=20) | 1 | 1 | 0 |
| `shop_front`(id=22) | 1 | 1 | 0 |
| 每图平均框数 | 1.95 | **2.77** | +0.82 |

**人工动作拆解**（把复核前的预标标签与复核后的标签按 IoU 配对，判定每个框的去留）：

| 人工动作 | 数量 | 涉及图像 | 判定依据 |
|---|---|---|---|
| 保留预标框、未动 | 81 | — | IoU ≥ 0.95 |
| **删除预标框**（误检） | **5** | 5 张 | 无配对 |
| **新画框**（漏检） | **41** | 22 张 | 无配对 |
| 微调预标框 | **0** | 0 张 | 0.5 ≤ IoU < 0.95 |
| 合计 | 86 → 122 | | |

**这个分布本身是最有价值的发现：人工既没有微调任何预标框，也没有把预标框
挪一下位置。** 41 个新框是纯新增区域，5 个删除是纯移除——人工复核的收益
**完全集中在「召回」**：

- **召回**：预标漏掉的对象被补上 41 个（`bin` 框数 +72%）。
  **复核前有 9 张图预标给出 0 个框**（`bin (4)/(5)/(6)/(7)/(8)/(20)/(32)/(34)/(35)`），
  复核后**零框图像降为 0 张**。这正是零样本模型的典型失败模式，与前期实测一致
  （`footbridge_entrance` 0.03、`tactile_paving` 0.03 等类零样本置信度极低）。
- **精度**：仅剔除 5 个误检，涉及 5 张图。

**结论：** 对零样本预标来说，人工复核的主要价值是**补召回**，不是纠偏差。
这直接影响标注规范的设计——复核界面与操作说明应当**引导标注员逐图扫视
「还有没有漏掉的目标」**，而不是只盯着已有的框去调整边界。

---

## 3. 质检结果（`scripts/xlabel_io.py check`）

| 检查项 | 结果 |
|---|---|
| 文件 | 44 |
| 文件内 shape 总数 | 122 |
| 可读矩形 | 122（被跳过的非矩形/坏点集：**0**） |
| 可写入数据集 | **122** |
| 致命问题框（退化/越界/极小/近重复/未知类） | **0** |
| 近似重复（同标签 IoU ≥ 0.8） | 0 |

122 个人工框全部通过，**没有一个是退化框、越界框或极小框**。这也间接说明
X-AnyLabeling 的交互是可靠的：之前怀疑的 `shape.py:161` `AssertionError`
没有在保存的数据里留下任何残留。

`ambiguous_vertical`（id=23，训练期占位类）**一次都没被用到**，无需分拣。

---

## 4. 尚未复核的部分（诚实记录）

**`bin (24).json` 与 `bin (33).json` 仍各自保留 1 个未复核的自动框**
（小数坐标，`bin (24)` 的框横跨 146–479 px，明显过大）。这两张图人工没有增画
框，因此无法判断是漏看还是认可。**下一轮开始时先看这两张。**

---

## 5. 无法回避的方法论限制：划分是同源的

44 张照片来自**同一次实地拍摄，只有一个 `source_folder`**。
分组防泄漏划分（`assign_folds`）对单来源无从下手——它会把 44 张全部丢进 train，
val/test 为空，训练直接跑不起来。

**处理（`scripts/single_source.py`）：** 退到**等间隔取样**划分
（train 36 / val 4 / test 4），并在 `split.json` 里写入机器可读的标记：

```json
"single_source": true,
"single_source_note": "单来源等间隔取样：同源划分无法防泄漏，指标偏乐观，仅用于跑通链路"
```

**这不是防泄漏方案，是诚实的退路。** 同一地点连拍的相邻帧几乎相同，
无论怎么切都有泄漏，因此：

- 本轮产出的指标**只能用来确认链路连通和相对变化**，
  **不能作为论文里的最终性能证据**；
- 论文中的性能数字必须来自多来源划分（≥ 3 个独立采集点位）；
- 单来源下讨论「人工复核带来多少 mAP 提升」也会被高估，
  因为 train 与 val 高度相似，模型容易记住具体场景。

**下一步的真实数据采集必须按「一个采集点位 = 一个文件夹」组织，且每类 ≥ 3 个点位。**

---

## 6. 可复用的操作规程（→ Task 10 的 300 张种子集）

```powershell
# 1. 预标（三阶段）后转成 X-AnyLabeling JSON，人工在 GUI 里复核
python scripts\to_xanylabeling.py --images data/dataset/images/<src> `
    --labels data/dataset/labels/<src> --out data/xtest/<src>

# 2. 复核完先质检，看有没有坏框/未知类，再决定是否回写
python scripts/xlabel_io.py check --json-dir data/xtest/<src> `
    --report data/xtest/check_report.md --csv data/xtest/boxes.csv

# 3. 质检通过后回写数据集（会覆盖预标结果；必要时先备份）
python scripts/xlabel_io.py emit --json-dir data/xtest/<src> `
    --labels-out data/dataset/labels/<src>

# 4. manifest → 划分 → 门禁 → 训练
python scripts/make_manifest.py
python scripts/split_dataset.py --seed 42
python scripts/check_labels.py
python scripts/run_pipeline.py --skip-generate --epochs 100
```

**回写前务必备份**：本次已把复核前的 44 个预标标签存到
`data/auto/trashbin_pre_review_labels_20260922/`，用于对比与回滚。

---

## 7. 新增交付物

| 文件 | 说明 |
|---|---|
| `scripts/xlabel_io.py` | X-AnyLabeling JSON 质检 + 回写 YOLO；`check` / `emit` 两个子命令 |
| `scripts/single_source.py` | 单来源数据集等间隔取样划分（显式声明限制） |
| `tests/test_xlabel_io.py` | 36 个用例：读 JSON 容错、类别解析、五类坏框、近重复、回写 |
| `tests/test_split_single_source.py` | 6 个用例：单来源端到端划分（本次故障的回归测试） |
| `data/xtest/check_report.md` | 本轮质检报告 |
| `data/xtest/boxes.csv` | 逐框明细（文件、类别、坐标、保留/剔除、原因） |

**测试总数：167 passed**（本轮新增 51 个）。
