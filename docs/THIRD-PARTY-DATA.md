# 第三方数据来源与署名 / Third-Party Data Attribution

> **这份文件必须在仓库里而不是在 `data/` 里**：`data/` 是 gitignore 的，
> 随数据集下载的 README 会丢，而 CC BY 系列许可**要求保留署名**。
> 丢了署名就等于违反许可。

最后更新：2026-10-02

---

## 1. 使用状态

| 数据集 | 用途 | 许可状态 | 引用位置 |
|---|---|---|---|
| People Detection v1（Roboflow Universe，`chris-law/people-detection-o4rdr-nlryq`） | `pedestrian` / `bicycle` 训练数据（**仅训练集**，不进验证集） | ⚠️ **仅限研究用途**，见下 | 本文件 §2 |
| Wikimedia Commons 抓取（`data/raw/external/`） | 候选素材，**尚未使用** | CC BY / CC BY-SA / CC0，逐张记于 `data/raw/external/attribution.jsonl` | 本文件 §3 |

---

## 2. People Detection v1（Roboflow Universe）

**URL：** https://universe.roboflow.com/chris-law/people-detection-o4rdr-nlryq/dataset/1
**导出格式：** YOLOv8，7261 张（train 5070 / valid 1431 / test 760）
**导出时间：** 2026-10-01
**聚合导出自身声明的许可：** `Private`（见 `data.yaml`）

### 2.1 使用限制声明（重要）

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

### 2.2 上游项目与许可（按数据集自带 README 转录）

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

### 2.3 类别使用情况

该数据集声明 53 个类别（`data.yaml` 的 `names`；Roboflow API 报 63 个，以导出物为准），
本项目只映射其中 2 个真实类：

| 本项目类 | id | 该数据集里的写法 |
|---|---:|---|
| pedestrian | 6 | `person` `persons` `people` `Pedestrian` `Pedestrians` `Persona` `Pessoa` |
| bicycle | 11 | `bicycle` `bicycle` `Bicycle` `bike` `Bike` |

其余 43 个类别的框**显式跳过并打印**（不是静默丢弃）。
其中 `Cyclist` **故意不映射**：那是「骑车的人」，不是本项目的 `bicycle`（单車，一个障碍物）。

### 2.4 对本项目方法论的影响（必须写进论文）

- 该数据**只用于训练集，绝不进入验证集**。它自带逐图随机划分，
  同一段视频的相邻帧会跨 train/val；混进 val 会让 val 既不代表性、又有泄漏，
  从而使所有验证指标失去意义。
- 因此本项目报告的验证指标**全部来自香港实拍数据**，不含该数据集。
- 该数据域为通用场景（实测：灰度图 1.7%、框长宽比中位 0.281 即全身标注、
  框中心纵向 0.453），与香港行人视角**不完全一致**，存在域偏移。

---

## 3. Wikimedia Commons（`data/raw/external/`）

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

## 4. 训练用模型的预训练权重

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
