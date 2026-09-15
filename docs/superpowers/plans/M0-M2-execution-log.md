# M0–M2 环境搭建与流水线跑通 · 执行记录

**日期：** 2026-09-15
**执行方式：** Inline Execution（当前会话，带检查点）
**结论：** 训练环境已就绪，数据→标注→训练→评测→报告全链路已端到端跑通，产出真实非零指标。

---

## 1. 实测环境

| 项 | 值 |
|---|---|
| 操作系统 | Windows |
| Python | **3.12.3**（`uv venv`；系统默认 3.14.4 过新，PyTorch 无对应 wheel） |
| 环境管理 | **uv 0.12.13 + venv**（本机未安装 conda，计划中的 conda 步骤已替换） |
| PyTorch | **2.11.0+cu128** |
| torchvision | 0.26.0+cu128 |
| CUDA runtime | 12.8 |
| GPU | **NVIDIA GeForce RTX 5070** / sm_120 (Blackwell) / 11.91 GB / 驱动 616.56 |
| ultralytics | 8.3.253 |
| opencv-python | 5.0.0.93 |
| 磁盘可用 | 1188 GB |
| 建议 batch | 12（冒烟实测；流水线使用 8 以留余量） |

**GPU 关键验证：** `sm_120` 必须搭配 CUDA 12.8+ 的 PyTorch 构建。已实测矩阵乘法通过，无 "no kernel image" 错误。

`runs/env_report.json` 为机读版本，7 项检查全部 OK。

---

## 2. 端到端跑通结果

命令：

```powershell
. .\.env.ps1
python scripts\gen_synthetic.py --per-class 24 --sources 8
python scripts\make_manifest.py
python scripts\split_dataset.py --seed 42
python scripts\check_labels.py
python scripts\run_pipeline.py --skip-generate --epochs 60 --imgsz 416 --batch 8 --workers 0
```

| 环节 | 结果 |
|---|---|
| 数据生成 | 30 张合成图（含 6 张负样本），91 个标注框，9 个来源文件夹 |
| manifest | 30 条，缺标签 0 |
| 分组分层划分 | train 12 / val 9 / test 9，**泄漏校验通过** |
| 标签门禁 | 致命错误 0 |
| 训练 | YOLOv8n，60 epochs，3,013,968 参数，8.2 GFLOPs，GPU 正常 |
| 评测（test 折） | mAP@0.5 = **0.1013**，macro Recall = **0.7257**，12 个类别有指标 |
| 报告 | `runs/pipeline_report.md` |

**这些指标本身没有意义**——30 张合成图、16 个类别，样本量远低于计划要求的 2,500–3,000 张。它们的作用是证明**链路连通**，而不是模型性能。

真实数据到位后，只需把第 1 步换成 `extract_frames.py` → `dedup.py`，其余步骤不变。

---

## 3. 排查过程中发现并修复的 4 个真实缺陷

这些都是**在真实采集数据上同样会犯**的错误，不是合成数据特有问题。

### 缺陷 1（最严重）：标签未镜像图像目录结构

**现象：** 训练与评测全部 `Instances = 0`，指标全为 0，**且不报任何错误**。

**根因：** Ultralytics 的 `img2label_paths()` 是把路径里的 `\images\` **替换**为 `\labels\` 并保留其余层级：

```
images/route_A_synthetic_src00/xxx.jpg
  -> labels/route_A_synthetic_src00/xxx.txt   # 期望
```

而我们把标签扁平写在 `labels/xxx.txt`，因此**每一个标签都找不到**。

**为什么危险：** 它不报错。指标全 0 看起来像"模型没学好"，会把排查方向引向超参、数据量、模型容量，而真实原因是路径契约。

**修复：** `gen_synthetic.py`、`make_manifest.py`、`check_labels.py` 三处统一改为镜像结构，并写入 spec §6.2 决定四。

### 缺陷 2：manifest 丢失子目录

**现象：** `train.txt` 写出的路径指向不存在的文件。

**根因：** manifest 只记录文件名（`xxx.jpg`），未记录相对 `images/` 的路径。

**附带风险：** 真实采集时不同来源文件夹可能存在同名帧（多机位 `IMG_0001.jpg`），只记文件名会让**标签互相覆盖**，且分组泄漏校验失效。

**修复：** manifest 列 `image_name` 改为 `image_rel`（相对 `images/` 的 posix 路径，含子目录）。

### 缺陷 3：划分清单使用相对正斜杠路径

**现象：** Ultralytics 报 `No such file or directory`。

**根因（两点叠加）：**
1. Ultralytics 从 **CWD** 解析相对路径，而非从 yaml 的 `path` 字段；
2. `img2label_paths()` 在 Windows 上用 `os.sep` 拼 `\images\`，正斜杠路径无法匹配。

**修复：** 划分清单写**绝对原生路径**（`Path` 拼接，非字符串拼接），并加单元测试断言路径为绝对且不含正斜杠。

### 缺陷 4：合成生成器的类别集合退化

**现象：** 最初 train 折只有 1 张正样本，test 折全是负样本。

**根因：** 生成器让每个来源都含**完全相同的 16 类**，于是划分脚本把它们全部归入同一个分层桶；桶内前两个来源被固定分给 val/test，train 几乎无正样本。

**说明：** 这是合成生成器的缺陷，真实数据下每个采集点位的类别集合天然不同，不会这样退化。但它验证了划分脚本的**分层优先级裁决**（无泄漏 > val 覆盖全类 > 比例）是有效的——脚本确实保证了各折都拿到来源。

**修复：** 生成器改为把每轮目标轮转切片给不同来源，使各来源类别集合不同。

---

## 4. 受限沙箱适配（重要）

当前执行环境禁止打开**命名管道**，因此：

| 影响 | 处理 | 是否影响你 |
|---|---|---|
| DataLoader 多进程失败 | `workers=0` | **是**——你在普通终端应设为 4–8 |
| Ultralytics `cache_labels` 用 ThreadPool | `scripts/env_setup.py` 探测后打顺序补丁 | **否**——普通终端会自动探测为可用，不打补丁 |
| TFLite 导出挂起 | 改在普通终端执行 `scripts/export_model.py` | **是**——需你手动执行一次 |

适配细节已写入 spec §14，包括 `cache_labels` 补丁的 4 条实现约束（补丁目标类、`verify_image_label` 签名、缓存字典必需键、`im_file` 必须为 str）。

---

## 5. 交付物

| 文件 | 说明 |
|---|---|
| `.env.ps1` | **环境激活脚本**：激活 venv + 重定向 `UV_CACHE_DIR` / `YOLO_CONFIG_DIR` / `MPLCONFIGDIR` |
| `requirements.txt` | 依赖清单（torch 需单独用 cu128 索引安装） |
| `configs/classes.json` | 16 类类别表（单一事实源） |
| `scripts/env_setup.py` | 沙箱适配：写路径重定向 + `cache_labels` 补丁 |
| `scripts/env_check.py` | 环境自检（7 项），产出 `runs/env_report.json` |
| `scripts/gen_synthetic.py` | 合成数据生成（**仅用于验证流水线**） |
| `scripts/extract_frames.py` | 视频抽帧 + 模糊过滤 |
| `scripts/dedup.py` | 感知哈希去重（评测域刻意保留冗余） |
| `scripts/make_manifest.py` | manifest 生成 |
| `scripts/split_dataset.py` | 分组分层划分 + 泄漏校验 |
| `scripts/check_labels.py` | 标签质量门禁 |
| `scripts/run_pipeline.py` | 端到端编排 |
| `scripts/run_all.py` | 完整复现脚本 |
| `scripts/export_model.py` | TFLite 导出（**须在普通终端运行**） |
| `scripts/smoke_test.py` | Windows+CUDA 冒烟测试 |
| `tests/` | 6 个测试文件，**47 个用例全部通过** |

---

## 6. 下一步

### 立即可做（普通终端）

```powershell
cd "C:\Users\user\PycharmProjects\Accessible Visual Guidance"
. .\.env.ps1
python scripts\env_check.py            # 确认 7 项全 OK
python -m pytest tests\ -v             # 确认 47 passed
python scripts\export_model.py --weights runs\pg_pipeline\weights\best.pt --int8
```

导出后还需**手动复测 INT8 量化精度**（Ultralytics 的 `val()` 不支持 TFLite 后端），损失 > 1.5% 则回退 FP16。

### 进入真实数据阶段

1. **实地核实**彩明商场与调景岭站的连通方式，以及商场内目标店/锚点店清单（阻塞节点图与 logo 数据采集）。
2. 按 `configs/collect_plan.md` 采集（**第 1 周内必须先拍满 `footbridge_entrance` ≥ 250 张**）。
3. 清空 `data/dataset/`，把第一步换成 `extract_frames.py` → `dedup.py`，其余流水线不变。
4. 人工精标 300 张种子集 + 200 张冻结基线（`data/golden/`）。

### 完成 M0–M2 后

进入 M3（Flutter Demo）。M2 出口验收模板见计划 Task 12；M3 的输入契约是 `app/assets/models/detector.tflite` + `configs/classes.json` + `configs/logos.json`。
