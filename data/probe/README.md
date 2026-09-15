# 日常物件零样本可辨识性探测（spike）

**定位：可行性探测，throwaway。** 不是正式数据采集流水线，产物不进入训练。

正式数据采集见 `docs/superpowers/plans/2026-09-15-pathguide-m0-m2-training-pipeline.md`。

## 它回答什么问题

**能否靠网上数据识别香港的日常物件（垃圾桶、天桥入口、扶梯、触觉引路带……）？**

## 结论

看 [`FINDINGS.md`](FINDINGS.md)。一句话版本：

- **通用物件可以**零样本识别：红绿灯 0.94、长椅 0.88、邮筒 0.82、花槽 0.70、垃圾桶 0.61。
- **香港基础设施不行**，且三类失败原因**各不相同**：天桥 0.03（网上没有入口视角的图）、
  触觉引路带 0.03（分类里没有以盲道为主体的图）、扶梯 0.15（**真正的模型失败**）。

## 跑法

```powershell
. .\.env.ps1
# 1. 拉香港实景小集（含 CC 署名信息）
python scripts\probe\fetch_commons.py --out data/probe/hk --per-cat 40
# 2. 零样本探测（每个物件测多组 prompt 说法）
python scripts\probe\probe_zeroshot.py --images data/probe/hk --out data/probe
```

产出 `report.md`（结论表 + 全部 prompt 变体明细）与 `report.json`。

## 待你补的一步：实地近景样本

网上数据**没有**天桥入口的近景视角，因此上表中天桥 0.03 这个数字**证明不了模型认不出入口**——
它只证明模型认不出远景桥身。这个悬而未决的问题需要在实地闭环：

| 内容 | 张数 | 放置位置 |
|---|---|---|
| 天桥入口近景（开口、上行楼梯、坡道、升降机） | 10 | `data/probe/hk_onsite/footbridge/` |
| 扶梯（横视 5 + 正对 5） | 10 | `data/probe/hk_onsite/escalator/` |
| 触觉引路带（俯视，盲道为主体） | 10 | `data/probe/hk_onsite/tactile_paving/` |

然后：

```powershell
python scripts\probe\probe_zeroshot.py --images data/probe/hk_onsite --out data/probe_onsite
```

**判定：** 天桥入口检出率 ≥0.6 → 零样本可用（之前只是视角问题）；仍 <0.2 → 零样本确实不行，
走 M0–M2 的「实地采集 + 微调」主线。

## 依赖

需要 YOLO-World + CLIP 文本编码器。首次运行会自动下载：

| 文件 | 体积 | 位置 |
|---|---|---|
| `yolov8s-world.pt` | 27 MB | 仓库根（`*.pt` 已被 gitignore） |
| CLIP `ViT-B-32.pt` | 354 MB | `.cache/clip/`（由 `scripts/env_setup.py` 重定向） |

受限环境下还需 `ultralytics/CLIP` 源码包，安装方式见 `scripts/env_setup.py` 的注释——
`git clone` 在受限环境会因无法创建命名管道而失败，需下载源码 zip 从本地路径安装。

## 许可

图像来自 Wikimedia Commons，多为 CC BY / CC BY-SA。作者、许可证与描述页 URL
逐张记录在 `data/probe/hk/attribution.jsonl`（该文件与图像均不入库，可重新拉取）。
**若写入论文须列出署名。**
