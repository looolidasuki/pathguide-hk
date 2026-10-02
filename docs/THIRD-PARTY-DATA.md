# 第三方数据来源与署名 / Third-Party Data Attribution

> **这份文件必须在仓库里而不是在 `data/` 里**：`data/` 是 gitignore 的，
> 随数据集下载的 README 会丢，而 CC BY 系列许可**要求保留署名**。
> 丢了署名就等于违反许可。

最后更新：2026-10-02

---

## 1. 使用状态

| 数据集 | 用途 | 许可状态 | 引用位置 |
|---|---|---|---|
| Everyday Object Finder v3（Roboflow Universe，`chris-law/everyday-object-finder`） | `pedestrian`/`bicycle` 及 16 个类（含新增的 `obstacle`/`escalator`）的训练数据（**仅训练集**，不进验证集） | ✅ 声明 **CC BY 4.0**（但有来源疑点，见 §2） | 本文件 §2 |
| People Detection v1（Roboflow Universe，`chris-law/people-detection-o4rdr-nlryq`） | `pedestrian` / `bicycle` 训练数据（**仅训练集**） | ⚠️ **仅限研究用途**，见 §3 | 本文件 §3 |
| Wikimedia Commons 抓取（`data/raw/external/`） | 候选素材，**尚未使用** | CC BY / CC BY-SA / CC0，逐张记于 `data/raw/external/attribution.jsonl` | 本文件 §4 |

---

## 2. Everyday Object Finder v3（**主用**）

**URL：** https://universe.roboflow.com/chris-law/everyday-object-finder/dataset/3
**导出格式：** YOLOv8，**5060 张**（train 4282 / valid 654 / test 124）
**导出时间：** 2026-10-02
**声明的许可：** **CC BY 4.0**（见 `data.yaml` 与 `README.dataset.txt`）
**该项目自带 README 未列出任何上游项目**（与 §3 那份 14 项目拼盘不同）。

### 2.1 使用方式

- **只用于训练集，绝不进入验证集**（`build_multiclass_dataset.py --add-multi-train-only`）。
  已逐帧核对：`data/dataset_poc5` 的 103 张 val **全部**来自香港来源，
  且 15 个第三方独有的类在 val 里**全部零框**。
- 进入 `dataset_poc5` 的规模：**4812 张**（5060 减去 248 张真灰度图，见 §2.3）、
  **6746 个映射上的框**。

### 2.2 ⚠️ 来源疑点（必须写进论文）

该数据集**声明** CC BY 4.0，但其图像看起来**大量来自网络抓取**，而非拍摄者自摄：

- 文件名含素材站编号形态，例如 `1000_F_220334286_53z6aJnh72XgyxQjsDahg2IEoaItSiJO`
  （Shutterstock 式 ID）、`686311476354-Water-filled-Barrier.jpeg`（产品目录照）；
- `escalator` 类的文件名前缀含 **Singapore / Changi / Marina / China / Otis**
  —— 即**新加坡、樟宜机场、滨海湾**等地，不是香港；
- **CC BY 4.0 是上传者声明的**。对于抓取来的图片，上传者未必持有转授该许可的权利。

因此本项目的处理是：**照「声明为 CC BY 4.0」使用并署名，
同时在论文的数据来源一节如实写明上述疑点**，不声称已核实每一张图的原始权利。
这与 §3 那份「仅限研究用途」不同 —— 那份是**聚合导出自身声明 `Private`** 且含未声明许可的上游，
这一份至少有一个明确的 CC BY 4.0 声明。

### 2.3 已排除的内容

**248 张 `_grayscale` 真灰度图已排除**（抽查 62/62 确认三通道差 0.00）。
理由：本项目按颜色判类（交通錐橙、水馬红白、盲道黄），
灰度图进训练集是域污染。全库真灰度仅 3.8%，基本就集中在这批。

### 2.4 类别映射（18 个映上，4 个跳过）

| Roboflow 类 | 本项目 id | 框数 |
|---|---|---:|
| `bicycle` | 11 bicycle | 2272 |
| `barrier` | **48 obstacle（v4 新类）** | 2156 |
| `escalator` | **49 escalator（v4 新类）** | 1980 |
| `person` | 6 pedestrian | 172 |
| `water_filled_barrier` | 10 barrier_water | 44 |
| `door` + `fire_door` | 18 door | 39 |
| `rubbish_bin` | 7 bin | 25 |
| `fence` / `streetlight` / `scooter` / `sign_post` / `bucket` | 26 / 45 / 12 / 46 / 47 | 各 15 / 15 / 6 / 5 / 6 |
| `power_distribution_box` / `billboard` / `cycle_path` / `cardboard` / `goods` / `barrier_fencing` | 30 / 36 / 44 / 33 / 31 / 27 | 各 3 / 3 / 2 / 1 / 1 / 1 |

**跳过（理由记录在 `data/raw/roboflow_everyday_v3/_class_override.json`）：**

| 跳过 | 框数 | 理由 |
|---|---:|---|
| `tree` | 86 | 不等价：`tree` 是「树」，本项目 `broken_tree`(42) 是「樹木（倒/斷）」 |
| `signage` | 25 | 待定：可能是 `sign_pictogram`(20 指示牌) 也可能是 `billboard`(36 廣告看板) |
| `toilet` | 3 | 本项目类别表里没有这一类 |
| `brige` | 1 | 不等价 + 拼写错误：bridge ≠ `footbridge_entrance`(0 天橋入口) |

（合计 115 框，与导入 dry-run 的统计一致。）

### 2.5 域与预期（避免高估）

| 指标 | 本数据集 | People Detection（§3，实测零收益） |
|---|---:|---:|
| 框高占图比中位 | **0.501** | 0.183 |
| 框长宽比中位 | **0.913**（近正方形） | 0.281 |
| 正方形图占比 | **65%** | — |

即这是**近景实物照**为主，而部署场景是街景（目标小、杂乱）。

**但标注质量看起来是可信的** —— 这几个类的框几何完全贴合实物形状：
`person` 长宽比 0.315（竖长条）、`streetlight` 0.146（细长杆）、
`fence` 1.633（横向）、`signage` 高占图仅 0.042（薄片）。

**因此本项目不假定它有用**：与前一份第三方数据同样处理 ——
先在**同一份香港 val** 上实测，再用数字决定是否采用。

---

## 3. People Detection v1（Roboflow Universe）

**URL：** https://universe.roboflow.com/chris-law/people-detection-o4rdr-nlryq/dataset/1
**导出格式：** YOLOv8，7261 张（train 5070 / valid 1431 / test 760）
**导出时间：** 2026-10-01
**聚合导出自身声明的许可：** `Private`（见 `data.yaml`）

### 3.1 使用限制声明（重要）

**本项目将该数据集的使用限定为学术研究（FYP 毕设），不用于任何商业用途，
也不重新分发其图像。** 理由：

1. 聚合导出自身声明 `license: Private`；
2. 其中一个上游项目（`MOT17-03-DPM`）**未声明许可证**，
   而 MOT17 是行人跟踪基准，其条款通常为仅限研究、需注册同意；
3. Roboflow 导出会抹掉来源身份（文件名只保留 `原名_jpg.rf.<哈希>`），
   **因此无法从导出物重建「哪张图来自哪个上游」，也就无法精确排除那一个上游**。

上述第 3 点已实测确认（见 `docs/superpowers/plans/2026-10-02-roboflow-dataset-provenance.md`）：
曾试图按 6 位数字帧名排除 MOT17，但该子集里出现了 MOT17 官方标注中不会有的
`Stopper` / `Signboard` / `helmet` 类别，且分辨率混杂 —— 说明**数字命名并非单一来源**，
按文件名排除是**不可靠**的。

### 3.2 上游项目与许可（按数据集自带 README 转录）

本数据集由 Roboflow Universe 上以下项目"curated"而来：

| 上游项目 | 许可 |
|---|---|
| [First Pedestrian Test](https://universe.roboflow.com/safer-strides/first-pedestrian-test) | CC BY 4.0 |
| [person_camera_security1](https://universe.roboflow.com/chinh/person_camera_security1) | CC BY 4.0 |
| [Human Action Recognition 2000](https://universe.roboflow.com/skripsi-u18dy/human-action-recognition-2000) | CC BY 4.0 |
| [People Detection](https://universe.roboflow.com/chris-kydks/people-detection-2csbw) | CC BY 4.0 |
| [contador-de-gente teste 3](https://universe.roboflow.com/mackleaps/contador-de-gente-teste-3) | CC BY 4.0 |
| [OD3](https://universe.roboflow.com/object-detection-tuphv/od3-fq4yp) | CC BY 4.0 |
| [Person Detection](https://universe.roboflow.com/illimited/person-detection-gbuka) | CC BY 4.0 |
| [MOT17-03-DPM](https://universe.roboflow.com/bhu-ykklm/mot17-03-dpm-udorc) | ⚠️ **未声明** |
| [The Curve](https://universe.roboflow.com/people-8gcmt/the-curve-02) | CC BY 4.0 |
| [pedestrain safety](https://universe.roboflow.com/intel-9horw/pedestrian-safety-obyfo) | CC BY 4.0 |
| [People Detection](https://universe.roboflow.com/jmedel/people-detection-f0fgt) | CC BY 4.0 |
| [people、rabish](https://universe.roboflow.com/cpk-wow-k5nlf/people-rabish) | CC BY 4.0 |
| [Pascal VOC 2012](https://universe.roboflow.com/jacob-solawetz/pascal-voc-2012) | CC BY 4.0 |
| [Person Detection (General)](https://universe.roboflow.com/mohamed-traore-2ekkp/people-detection-general) | CC BY 4.0 |

（以上链接与许可是数据集自带 `README.dataset.txt` 的转录。`MOT17-03-DPM` 一项在该 README 中确实没有许可字段。）

### 3.3 类别使用情况

该数据集声明 53 个类别（`data.yaml` 的 `names`；Roboflow API 报 63 个，以导出物为准），
本项目只映射其中 2 个真实类：

| 本项目类 | id | 该数据集里的写法 |
|---|---:|---|
| pedestrian | 6 | `person` `persons` `people` `Pedestrian` `Pedestrians` `Persona` `Pessoa` |
| bicycle | 11 | `bicycle` `bicycle` `Bicycle` `bike` `Bike` |

其余 43 个类别的框**显式跳过并打印**（不是静默丢弃）。
其中 `Cyclist` **故意不映射**：那是「骑车的人」，不是本项目的 `bicycle`（单車，一个障碍物）。

### 3.4 对本项目方法论的影响（必须写进论文）

- 该数据**只用于训练集，绝不进入验证集**。它自带逐图随机划分，
  同一段视频的相邻帧会跨 train/val；混进 val 会让 val 既不代表性、又有泄漏，
  从而使所有验证指标失去意义。
- 因此本项目报告的验证指标**全部来自香港实拍数据**，不含该数据集。
- 该数据域为通用场景（实测：灰度图 1.7%、框长宽比中位 0.281 即全身标注、
  框中心纵向 0.453），与香港行人视角**不完全一致**，存在域偏移。

---

## 4. Wikimedia Commons（`data/raw/external/`）

901 张，16 个类别，逐张署名与许可记录在
`data/raw/external/attribution.jsonl`（字段：`title` `artist` `license` `license_url`
`class_or_target` `tier` `local_file`）。

许可分布：CC BY-SA 4.0（499）· CC BY-SA 3.0（132）· CC0（76）· CC BY 2.0（45）·
CC BY-SA 2.0（37）· Public domain（36）· CC BY 3.0（26）· CC BY 4.0（22）· 其它（8）。

**状态：尚未用于训练。** 它们是整图单物件照片、**没有框**，
需先走老师预标链出框。

**注意**：`attribution.jsonl` 被 .gitignore 显式放行（见 `.gitignore` 第 36 行），
因为它是 CC BY/SA 许可要求保留的署名，且体积小、不可再生。

---

## 5. 训练用模型的预训练权重

| 权重 | 来源 | 许可 |
|---|---|---|
| `yolo11n.pt` | Ultralytics YOLO11，COCO 预训练 | AGPL-3.0（Ultralytics） |
| `yolov8s-world.pt` | Ultralytics YOLO-World | AGPL-3.0 |
| `sam2.1_t.pt` | Meta SAM 2.1 | Apache-2.0 |
| `IDEA-Research/grounding-dino-tiny` | IDEA-Research Grounding DINO | Apache-2.0 |
| `nvidia/LocateAnything-3B` | NVIDIA | 见模型卡 |

> ⚠️ **Ultralytics 是 AGPL-3.0。** 毕设若以源码形式发布到此仓库，
> 需注意 AGPL 的传染性；若只发布论文与演示，通常不构成分发。
> 这一点建议在论文的"工具与许可"一节写明。
