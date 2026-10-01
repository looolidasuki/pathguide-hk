# 领路通 PathGuide HK

为视障人士做的**手机端离线视觉导航助手**：用摄像头识别香港街头的设施与障碍物，
用**粤语语音**播报。演示路线：**调景岭站 → 彩明苑天桥 → 彩明商场**。

> **先读这份：** [`docs/PROJECT-STATUS.md`](docs/PROJECT-STATUS.md)
> —— 项目框架、各部分功能、进度、预期产出、难点排序、下一步，都在那里，且每个数字都注明实测来源。

---

## 现在能跑什么

Android 真机（Xiaomi 2609FRA74T / Snapdragon 685）实测：

| 指标 | 值 |
|---|---|
| 模型 | YOLO11n，**3 类**（行人 / 单车 / 垃圾桶），TFLite int8，416×416，2.87 MB |
| 映射 | `modelClassIds = [6, 11, 7]`（本地索引 → 48 类表真实 id） |
| 推理 | **268 ms/帧**，**3.7 FPS**（纯 CPU；本机无 NNAPI/GPU delegate 可用） |
| 逐类指标 | 垃圾桶 mAP50 **0.948**（召回 1.000）· 行人 0.790（标签来自 COCO，非人工） |
| 功能 | 实时画框 + 中文标签 + HUD 诊断 + 阈值滑条 + 粤语播报（分数门槛 0.70 才开口） |

---

## 快速开始

```powershell
# 1) 环境（仓库内自带 Flutter/JDK/SDK 路径，不污染系统）
. .\.env.flutter.ps1

# 2) Dart 测试 + 静态检查（不需要手机）
cd app; flutter analyze; flutter test; cd ..

# 3) 真机运行：手机用 USB 连上、打开「USB 调试」（小米还需「USB 安装」）
.\scripts\verify_on_device.ps1        # 自动装包→唤醒→启动→截图→抓 HUD 日志
# 或手动：cd app; flutter run -d <device-id>
```

## 标注与训练流水线

```powershell
# 视频 → 按类别定额选候选帧（只留有目标的帧）
python scripts\scan_video_frames.py --videos data\raw\myVideo --per-class 20

# 老师模型自动出框（COCO 的 person/bicycle → 本项目类别）
python scripts\coco_to_our_labels.py --images <帧目录> --coco-class person --our-class pedestrian --out data\dataset_person_poc

# 多来源合并（按帧合并标签 + 按类分组切分）
python scripts\build_multiclass_dataset.py --out data\dataset_poc3 `
    --add data\dataset_person_poc:pedestrian --add data\dataset_bicycle_poc:bicycle --add data\dataset_single_bin:bin

# 训练（默认参数都带上踩过的坑：workers=0、seed 固定、imgsz 416）
python scripts\train_yolo.py --data data\dataset_poc3\dataset.yaml --name pg_poc3 --epochs 60

# 导出 TFLite（会交叉校验模型类别数与 App 的 modelClassIds 是否一致）
.\.venv-export\Scripts\python.exe scripts\export_tflite.py --weights runs\pg_poc3\weights\best.pt --imgsz 416

# 标注（双击也行）
label.cmd
```

## 门禁（改代码后跑这些）

```powershell
python -m pytest                          # 248 个测试
cd app; flutter analyze; flutter test     # 64 个测试
python scripts\check_kotlin_compiles.py   # Kotlin 编译检查（不需要 Gradle）
python scripts\check_tflite_decode.py     # 模型 ↔ 原生解码假设的一致性
python scripts\gen_dart_labels.py --check # 类别表是否与唯一的源同步
```

---

## 目录结构

```
app/                    Flutter App（Android 原生实现已完整；iOS 待补）
  lib/vision/           抽象层：VisionSource / 几何 / 类别映射 / 平台通道契约
  lib/overlay/          检测框叠加层
  lib/tts/              播报决策（两级冷却 + 分数门槛）与粤语 TTS
  android/.../VisionPlugin.kt   CameraX + LiteRT，零拷贝取帧与推理
configs/                类别表唯一事实源（48 类）与别名表
scripts/                数据采集、扫描选帧、老师预标、训练、导出、门禁、真机验证
docs/PROJECT-STATUS.md  ★ 项目总览
docs/superpowers/plans/ 逐日过程记录（含六处静默缺陷的复盘）
data/                   数据集与素材（体积大，不入库）
```

## 这个项目里最值得读的三份记录

1. [`docs/superpowers/plans/2026-09-23-decode-silent-failures.md`](docs/superpowers/plans/2026-09-23-decode-silent-failures.md)
   —— **六处静默缺陷**：布局读反、坐标当像素、漏减 pad、逆旋转公式错、色度下标错、Dart 重复旋转。
   全部不崩溃、不报错，只是结果全错。
2. [`docs/superpowers/plans/2026-09-28-video-frame-scan.md`](docs/superpowers/plans/2026-09-28-video-frame-scan.md)
   —— 「只留有检测的帧」这个**听起来合理的筛选条件实测等于没筛**（任何门槛下保留率都是 100%）。
3. [`docs/superpowers/plans/2026-09-30-coco-person-distill-poc.md`](docs/superpowers/plans/2026-09-30-coco-person-distill-poc.md)
   —— 用 COCO 当老师零人工拿到行人标签（老师框回收 94%），以及蒸馏的评测口径陷阱。
