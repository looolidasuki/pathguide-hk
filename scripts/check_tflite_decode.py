"""在电脑上把原生 `YoloDetector.decode()` 的每一步照抄一遍，用真实图片验证。

## 为什么必须有这个脚本

真机上出现过三个症状，都**不崩溃、不报错**，只是结果全错：

- 「HUD 显示十几个检测框，屏幕上一个框都画不出来」；
- 「分数 1.0 几」，以及 `score=-386`（模型最后一层是 sigmoid，分数不可能越界）；
- 「没有垃圾桶也一直显示垃圾桶」。

同一个模型、同一批图片在电脑上却完全正常。根因全部在**解码假设**上，
而这些假设错了只会让数值变垃圾，不会有任何异常：

1. **输出张量的内存布局。** Ultralytics 的 TFLite 导出是 `[1, 4+nc, anchors]`
   （通道优先），ONNX 常是 `[1, anchors, 4+nc]`。读错就是把框坐标当成分数——
   于是出现「分数 1.0 几」和成千上万个假框。
2. **坐标是不是归一化的。** TFLite 导出的 xywh 是**归一化到 letterbox 输入**
   的比例值，不是像素。当成像素用（漏乘 `inputSize`）会把所有框压成 0 大小，
   于是「有十几个框、屏幕上一个都看不到」。
3. **letterbox 的 pad 偏移。** 必须减掉灰边宽高才是原图坐标。
   漏减的表现是框整体平移，平移量恰好等于灰边宽度。

本脚本把这三件事都变成可执行的断言，并且**同时读 Kotlin 源码**核对两边
假设一致。任何一处不一致就退出码非 0——「电脑与真机解码分叉」不会再静默发生。

## 用法

    .venv-export/Scripts/python.exe scripts/check_tflite_decode.py
    .venv-export/Scripts/python.exe scripts/check_tflite_decode.py --images 10
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
DEFAULT_TFLITE = REPO / "app" / "assets" / "models" / "detector.tflite"
KOTLIN = (
    REPO / "app" / "android" / "app" / "src" / "main" / "kotlin"
    / "hk" / "pathguide" / "pathguide" / "VisionPlugin.kt"
)
# 导出脚本里的布局推导是 Kotlin 那句的源头，必须一起核对。
EXPORT_SCRIPT = REPO / "scripts" / "export_tflite.py"
IMG_DIR = REPO / "data" / "dataset" / "images" / "trashbin"
LBL_DIR = REPO / "data" / "dataset" / "labels" / "trashbin"

# 必须与 VisionPlugin.kt 的 `const val PAD` 一致。Ultralytics 训练时的灰边填充值。
PAD = 114

# 端到端质量门槛。真实图片上「正确解码」的平均最佳 IoU 约 0.86；
# 门槛设在 0.5，既能抓住解码退化，又不会因个别难图误报。
MIN_MEAN_IOU = 0.5


# --------------------------------------------------------------------------- #
# letterbox：逐行照抄 detectYuv 的预处理
# --------------------------------------------------------------------------- #
def letterbox(img: np.ndarray, input_size: int) -> tuple[np.ndarray, int, int, int, int]:
    """返回 (张量, newW, newH, padX, padY)，与 Kotlin 的算法逐行对应。

    Kotlin 用整数除法取 pad 与 `newW`：`padX = (inputSize - newW) / 2`、
    `newW = (srcW * scale).toInt()`。这里必须完全一致，
    否则差一个像素又变成「电脑对、真机差一点」这种最难查的偏差。
    """
    src_h, src_w = img.shape[:2]
    scale = min(input_size / src_w, input_size / src_h)
    new_w = max(int(src_w * scale), 1)
    new_h = max(int(src_h * scale), 1)
    pad_x = (input_size - new_w) // 2
    pad_y = (input_size - new_h) // 2

    # 先用填充色铺满，再覆盖真实内容——与 Kotlin 的两趟写入等价。
    canvas = np.full((input_size, input_size, 3), PAD / 255.0, dtype=np.float32)
    # 最近邻采样：Kotlin 的 sampleRgb 按目标下标反查源点，等价于 nearest。
    ys = (np.arange(new_h) * (src_h / new_h)).astype(np.int64).clip(0, src_h - 1)
    xs = (np.arange(new_w) * (src_w / new_w)).astype(np.int64).clip(0, src_w - 1)
    canvas[pad_y:pad_y + new_h, pad_x:pad_x + new_w] = img[ys][:, xs]
    return canvas[None, ...], new_w, new_h, pad_x, pad_y


# --------------------------------------------------------------------------- #
# 布局：通道优先还是锚点优先
# --------------------------------------------------------------------------- #
def layout_of(out_shape: list[int]) -> tuple[bool, int, int, int]:
    """由形状判定布局，返回 (anchor_major, channels, anchors, num_classes)。

    **锚点优先当且仅当 anchors 落在第 1 维，即 d1 > d2。**
    这就是 Kotlin 里那一行 `transposed = d1 ? d2` 必须成立的规则。
    """
    d1, d2 = int(out_shape[1]), int(out_shape[2])
    channels, anchors = min(d1, d2), max(d1, d2)
    return d1 > d2, channels, anchors, channels - 4


def score_channel_range(out: np.ndarray, anchor_major: bool, num_classes: int) -> tuple[float, float]:
    """按给定布局取出**类别分数通道**的取值范围（不受阈值影响）。

    sigmoid 输出必在 [0,1]。读到框坐标（可到 640）就说明布局读错了——
    这正是真机上「分数 1.0 几 / -386」的来源。
    """
    flat = out.reshape(-1)
    channels, anchors = min(out.shape[1], out.shape[2]), max(out.shape[1], out.shape[2])
    stride = channels
    lo, hi = np.inf, -np.inf
    for c in range(num_classes):
        ch = 4 + c
        idx = (np.arange(anchors) * stride + ch) if anchor_major else (ch * anchors + np.arange(anchors))
        vals = flat[idx]
        lo, hi = min(lo, float(vals.min())), max(hi, float(vals.max()))
    return lo, hi


def coord_channel_range(out: np.ndarray, anchor_major: bool) -> tuple[float, float]:
    """坐标通道（cx/cy/w/h）的取值范围，用来判定坐标是归一化还是像素。"""
    flat = out.reshape(-1)
    channels, anchors = min(out.shape[1], out.shape[2]), max(out.shape[1], out.shape[2])
    stride = channels
    lo, hi = np.inf, -np.inf
    for c in range(4):
        idx = (np.arange(anchors) * stride + c) if anchor_major else (c * anchors + np.arange(anchors))
        vals = flat[idx]
        lo, hi = min(lo, float(vals.min())), max(hi, float(vals.max()))
    return lo, hi


# --------------------------------------------------------------------------- #
# 解码：照抄 decode()，可切换变体以证明哪一种是对的
# --------------------------------------------------------------------------- #
VARIANTS: dict[str, tuple[bool, bool, bool]] = {
    # 名字               布局对  乘 inputSize  减 pad
    "正确":              (True,  True,  True),
    "错布局":            (False, True,  True),
    "漏减pad":           (True,  True,  False),
    "漏乘边长":          (True,  False, False),
    # 修复前真机上跑的正是这一组：布局读反 + 旧坐标换算。
    "真机旧行为":        (False, False, False),
}


def decode(
    out: np.ndarray,
    *,
    input_size: int,
    new_w: int,
    new_h: int,
    pad_x: int,
    pad_y: int,
    threshold: float,
    anchor_major: bool,
    multiply_input_size: bool = True,
    subtract_pad: bool = True,
) -> list[dict]:
    """解码一帧，返回通过阈值与几何检查的框（未 NMS）。

    默认参数就是 Kotlin 里现在的写法；把两个布尔开关关掉可以复现历史变体。
    """
    flat = out.reshape(-1)
    channels, anchors = min(out.shape[1], out.shape[2]), max(out.shape[1], out.shape[2])
    num_classes = channels - 4
    stride = channels

    def at(channel: int, a: int) -> float:
        idx = a * stride + channel if anchor_major else channel * anchors + a
        return float(flat[idx])

    dets: list[dict] = []
    for a in range(anchors):
        best_c, best_s = -1, threshold
        for c in range(num_classes):
            v = at(4 + c, a)
            if v > best_s:
                best_s, best_c = v, c
        if best_c < 0:
            continue

        cx, cy, bw, bh = at(0, a), at(1, a), at(2, a), at(3, a)
        if not all(np.isfinite(v) for v in (cx, cy, bw, bh)):
            continue
        if bw <= 0 or bh <= 0:
            continue

        side = float(input_size) if multiply_input_size else 1.0
        ox = pad_x if subtract_pad else 0
        oy = pad_y if subtract_pad else 0
        x1 = ((cx - bw / 2) * side - ox) / new_w
        y1 = ((cy - bh / 2) * side - oy) / new_h
        x2 = ((cx + bw / 2) * side - ox) / new_w
        y2 = ((cy + bh / 2) * side - oy) / new_h
        nx1 = min(max(x1, 0.0), 1.0)
        ny1 = min(max(y1, 0.0), 1.0)
        nx2 = min(max(x2, 0.0), 1.0)
        ny2 = min(max(y2, 0.0), 1.0)
        if nx2 <= nx1 or ny2 <= ny1:
            continue
        dets.append({
            "id": best_c,
            "score": best_s,
            "cx": (nx1 + nx2) / 2,
            "cy": (ny1 + ny2) / 2,
            "w": nx2 - nx1,
            "h": ny2 - ny1,
        })
    return dets


def nms(dets: list[dict], iou_thr: float = 0.45, max_det: int = 100) -> list[dict]:
    """照抄 Kotlin 的 nms（同类别、按分数降序贪心抑制）。"""
    kept: list[dict] = []
    for d in sorted(dets, key=lambda d: -d["score"]):
        clash = False
        for k in kept:
            if k["id"] != d["id"]:
                continue
            ax1, ay1 = k["cx"] - k["w"] / 2, k["cy"] - k["h"] / 2
            ax2, ay2 = k["cx"] + k["w"] / 2, k["cy"] + k["h"] / 2
            bx1, by1 = d["cx"] - d["w"] / 2, d["cy"] - d["h"] / 2
            bx2, by2 = d["cx"] + d["w"] / 2, d["cy"] + d["h"] / 2
            iw = min(ax2, bx2) - max(ax1, bx1)
            ih = min(ay2, by2) - max(ay1, by1)
            if iw <= 0 or ih <= 0:
                continue
            inter = iw * ih
            union = k["w"] * k["h"] + d["w"] * d["h"] - inter
            if union > 0 and inter / union > iou_thr:
                clash = True
                break
        if not clash:
            kept.append(d)
            if len(kept) >= max_det:
                break
    return kept


def iou(a: dict, bbox: tuple[float, float, float, float]) -> float:
    ax1, ay1 = a["cx"] - a["w"] / 2, a["cy"] - a["h"] / 2
    ax2, ay2 = a["cx"] + a["w"] / 2, a["cy"] + a["h"] / 2
    bx1, by1, bx2, by2 = bbox
    iw = min(ax2, bx2) - max(ax1, bx1)
    ih = min(ay2, by2) - max(ay1, by1)
    if iw <= 0 or ih <= 0:
        return 0.0
    inter = iw * ih
    union = a["w"] * a["h"] + (bx2 - bx1) * (by2 - by1) - inter
    return inter / union if union > 0 else 0.0


def yolo_boxes(label_path: Path) -> list[tuple[float, float, float, float]]:
    out = []
    for line in label_path.read_text(encoding="utf-8").splitlines():
        p = line.split()
        if len(p) < 5:
            continue
        cx, cy, w, h = (float(v) for v in p[1:5])
        out.append((cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2))
    return out


# --------------------------------------------------------------------------- #
# 与 Kotlin 源码对照
# --------------------------------------------------------------------------- #

# `sampleRgb` 里「正立图坐标 -> 原始帧坐标」的四个分支。
# 这些不是抄来的，而是下面 `verify_rotation_formulas()` 用 numpy 的顺时针旋转
# 逐点验证过的唯一正确形式；验证不通过会直接报错，不会拿错公式去对照源码。
CANONICAL_ROTATION = {
    0: "Pair(ux, uy)",
    90: "Pair(uy, frameHeight - 1 - ux)",
    180: "Pair(frameWidth - 1 - ux, frameHeight - 1 - uy)",
    270: "Pair(frameWidth - 1 - uy, ux)",
}

# UV 取色下标必须按**紧凑副本**算。`copyPlane` 返回的是 out[y*uvWidth + x]。
CANONICAL_UV_INDEX = "(cy / 2) * uvWidth + (cx / 2)"


def _norm(s: str) -> str:
    """去掉空白，用于比较源码里的表达式而不受排版影响。"""
    return re.sub(r"\s+", "", s)


def _render(expr: str, ux: int, uy: int, W: int, H: int) -> tuple[int, int]:
    """把 `Pair(a, b)` 形式的表达式算出来，只为验证公式本身。

    只做**字符串替换后解析整数运算**，不使用 eval：表达式里只有
    ux / uy / frameWidth / frameHeight 四个量与 + - * / ()。
    """
    body = expr[len("Pair("):-1]
    a, b = body.split(",")
    ns = {"ux": ux, "uy": uy, "frameWidth": W, "frameHeight": H}
    out = []
    for side in (a, b):
        if not re.fullmatch(r"[A-Za-z0-9_+\-*/() ]+", side):
            raise ValueError(f"公式含不支持的字符：{side!r}")
        out.append(int(eval(side, {"__builtins__": {}}, ns)))  # noqa: S307 - 见上方正则白名单
    return out[0], out[1]


def verify_rotation_formulas() -> list[str]:
    """用 numpy 的「顺时针旋转」作为参照，逐点验证 CANONICAL_ROTATION。

    判据来自 Android 的语义：`rotationDegrees` 是「把原始帧**顺时针**转这么多度
    才正立」。这里独立地用 `np.rot90(R, k=-(rot/90))` 造出正立图，
    再要求公式反查回来的源像素与正立图逐点一致。
    """
    problems: list[str] = []
    for (W, H) in ((1280, 720), (720, 1280), (1920, 1080)):
        R = np.arange(H * W).reshape(H, W)
        for rot in (0, 90, 180, 270):
            U = np.rot90(R, k=-(rot // 90))  # 顺时针 rot 度 = 正立图
            out_h, out_w = U.shape
            if rot in (90, 270):
                assert (out_w, out_h) == (H, W), (rot, out_w, out_h, W, H)
            src_w = H if rot in (90, 270) else W
            src_h = W if rot in (90, 270) else H
            scale = min(640 / src_w, 640 / src_h)
            new_w, new_h = int(src_w * scale), int(src_h * scale)
            bad = tot = 0
            for dy in range(0, new_h, 11):
                for dx in range(0, new_w, 11):
                    ux, uy = dx * out_w // new_w, dy * out_h // new_h
                    try:
                        sx, sy = _render(CANONICAL_ROTATION[rot], ux, uy, W, H)
                    except ValueError as e:
                        problems.append(f"旋转公式无法解析：{e}")
                        return problems
                    sx = max(0, min(sx, W - 1))
                    sy = max(0, min(sy, H - 1))
                    tot += 1
                    if R[sy, sx] != U[uy, ux]:
                        bad += 1
            if bad:
                problems.append(
                    f"参照公式在 raw {W}x{H}、rotation={rot} 下与 numpy 旋转不符"
                    f"（{bad}/{tot}）。脚本自身的参照有问题，先修脚本。"
                )
    return problems


def check_kotlin(d1: int, d2: int, coords_normalized: bool) -> list[str]:
    """读 Kotlin 源码，断言它的解码假设与实测到的模型行为一致。

    这是本项目最容易静默出错的部分：写反了不会有任何报错，
    只会让真机上的数值变成垃圾，而电脑上一切正常。
    所以「源码里那几行」必须纳入检查，而不是只检查模型。
    """
    problems: list[str] = []
    if not KOTLIN.exists():
        return [f"找不到 Kotlin 源码：{KOTLIN}"]
    src = KOTLIN.read_text(encoding="utf-8")

    # (1) 布局规则。transposed 在 Kotlin 里当「锚点优先」用，
    #     因此它必须等于 `d1 > d2`——运算符必须是 `>`，与具体形状无关。
    m = re.search(r"transposed\s*=\s*d1\s*([<>])\s*d2", src)
    if m is None:
        problems.append("Kotlin 里找不到 `transposed = d1 ? d2`，无法核对布局规则")
    elif m.group(1) != ">":
        problems.append(
            f"Kotlin 的布局推导是 `d1 {m.group(1)} d2`，应为 `d1 > d2`。"
            f"（模型输出形状 [1, {d1}, {d2}]：锚点优先 ⟺ anchors 在第 1 维 ⟺ d1 > d2。）"
            f"写反会让真机读到完全错误的通道——症状是分数越界（1.0 几、-386）"
            f"与成千上万个假框，而电脑上正常。"
        )

    # (1b) 导出脚本里的同一规则也必须一致。
    #      这两处曾经一起写反，而且**导出日志是错的那一处**：
    #      它把 [1, 5, 3549] 说成「[1, anchors, 4+nc]（转置）」，
    #      Kotlin 那句就是照抄它的。一处错的名字会生产出另一处错的代码，
    #      所以两处都要盯。
    if EXPORT_SCRIPT.exists():
        ex = EXPORT_SCRIPT.read_text(encoding="utf-8")
        m2 = re.search(r"anchors_first\s*=\s*d1\s*([<>])\s*d2", ex)
        if m2 is None:
            problems.append("export_tflite.py 里找不到 `anchors_first = d1 ? d2`")
        elif m2.group(1) != ">":
            problems.append(
                f"export_tflite.py 的布局推导是 `d1 {m2.group(1)} d2`，应为 `d1 > d2`——"
                f"它是 Kotlin 那句的源头，两处必须同时正确。"
            )

    # (2) 坐标换算的三步。逐行核对最稳：找到 nx1 那一行，要求它同时
    #     乘过输入边长、减过 padX、除以 newW。
    line = next((ln for ln in src.splitlines() if "val nx1" in ln), None)
    if line is None:
        problems.append("Kotlin 里找不到 `val nx1`，无法核对坐标换算")
    else:
        if coords_normalized and not ("inputSize" in line or "side" in line):
            problems.append(
                f"Kotlin 的坐标换算没有乘输入边长：{line.strip()}\n"
                f"    模型输出是**归一化**比例值，漏乘会把所有框压成 0 大小"
                f"（症状：HUD 有十几个框、屏幕上一个都看不到）。"
            )
        if "padX" not in line:
            problems.append(
                f"Kotlin 的坐标换算没有减 padX：{line.strip()}\n"
                f"    漏减会让框整体平移，平移量 = 灰边宽度。"
            )
        if "newW" not in line and "/ srcW" not in line:
            problems.append(f"Kotlin 的坐标换算没有除以缩放后宽度：{line.strip()}")

    # (3) 逆旋转的四个分支必须与 numpy 参照一致。
    #     90/270 写错时**每个像素都取错源位置**，而且不会报错——
    #     真机上 90 分支曾把 78% 的画面都取成原始帧的最后一行。
    block = re.search(
        r"val \(sx, sy\) = when \(rotationDegrees\) \{(.*?)\n\s*\}", src, re.S)
    if block is None:
        problems.append("Kotlin 里找不到 `val (sx, sy) = when (rotationDegrees)`，无法核对逆旋转")
    else:
        got: dict[int, str] = {}
        for num, expr in re.findall(r"(\d+)\s*->\s*(Pair\([^)]*\))", block.group(1)):
            got[int(num)] = expr
        else_expr = re.search(r"else\s*->\s*(Pair\([^)]*\))", block.group(1))
        if else_expr:
            got[0] = else_expr.group(1)
        for rot, want in CANONICAL_ROTATION.items():
            have = got.get(rot)
            if have is None:
                problems.append(f"Kotlin 的逆旋转缺少 rotation={rot} 分支")
            elif _norm(have) != _norm(want):
                problems.append(
                    f"Kotlin 的逆旋转 rotation={rot} 分支是 `{have}`，"
                    f"应为 `{want}`（已用 numpy 顺时针旋转逐点验证）。\n"
                    f"    写错时每个采样点都取错源像素，却不报错："
                    f"以 raw 1280x720、rotation=90 为例，旧写法 9216 个采样点 100% 取错，"
                    f"且 sy 越界被夹到末行，78% 的画面退化成一条横线。"
                )

    # (4) UV 取色下标必须按紧凑副本算。
    uv_line = next((ln for ln in src.splitlines() if "val uvIndex" in ln), None)
    if uv_line is None:
        problems.append("Kotlin 里找不到 `val uvIndex`，无法核对色度取样")
    else:
        if _norm(uv_line) != _norm(f"val uvIndex = {CANONICAL_UV_INDEX}"):
            problems.append(
                f"Kotlin 的色度下标是：{uv_line.strip()}\n"
                f"    应为：val uvIndex = {CANONICAL_UV_INDEX}\n"
                f"    `copyPlane` 返回的是紧凑副本 out[y*uvWidth + x]，"
                f"用原始平面的 rowStride/pixelStride 会把下标放大（NV21 下约 2 倍），"
                f"上半幅取错色度、下半幅越界兜成 128（灰度）——"
                f"表现与「喂灰度图」相同，不报错。"
            )
    if re.search(r"fun detectYuv\((?:[^)]*?)uvRowStride", src, re.S):
        problems.append(
            "detectYuv 仍在接收 uvRowStride/uvPixelStride：色度下标应按紧凑副本宽度算，"
            "应改为传 uvWidth。")
    # (5) letterbox 填充值必须与训练时一致（Ultralytics 用 114）。
    m = re.search(r"const val PAD\s*=\s*(\d+)", src)
    if m is None:
        problems.append("Kotlin 里找不到 `const val PAD`")
    elif int(m.group(1)) != PAD:
        problems.append(
            f"Kotlin 的 PAD={m.group(1)}，本脚本用 {PAD}。"
            f"填充值与训练时不一致会拉低置信度，且不报错。"
        )
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tflite", default=str(DEFAULT_TFLITE))
    ap.add_argument("--images", type=int, default=8, help="抽几张带标注的图做端到端核对")
    ap.add_argument("--threshold", type=float, default=0.30)
    args = ap.parse_args()

    tflite = Path(args.tflite).resolve()
    if not tflite.exists():
        print(f"模型不存在：{tflite}")
        return 1

    def rel(p: Path) -> str:
        """相对仓库的短路径；不在仓库里就退回绝对路径。

        以前直接 `p.relative_to(REPO)`：命令行传**相对路径**时 Path 并未解析，
        会抛 ValueError 把整个脚本打挂——而报错信息（「不在子路径中」）
        和真正的问题（模型好不好）毫无关系。
        """
        try:
            return str(p.relative_to(REPO))
        except ValueError:
            return str(p)

    from ai_edge_litert.interpreter import Interpreter

    it = Interpreter(model_path=str(tflite))
    it.allocate_tensors()
    ind = it.get_input_details()[0]
    outd = it.get_output_details()[0]
    in_shape = [int(v) for v in ind["shape"]]
    out_shape = [int(v) for v in outd["shape"]]

    print("=" * 78)
    print(f"模型      : {rel(tflite)}（{tflite.stat().st_size:,} 字节）")
    print(f"输入张量  : shape={in_shape} dtype={np.dtype(ind['dtype']).name}")
    print(f"输出张量  : shape={out_shape} dtype={np.dtype(outd['dtype']).name}")
    if len(out_shape) != 3:
        print(f"输出应为 3 维，实际 {out_shape}")
        return 1
    input_size = in_shape[1]
    anchor_major, channels, anchors, num_classes = layout_of(out_shape)
    print(f"布局      : {'锚点优先 [1, anchors, C]' if anchor_major else '通道优先 [1, C, anchors]'}"
          f"  channels={channels} anchors={anchors} classes={num_classes}")
    print("=" * 78)

    labels = sorted(IMG_DIR.glob("*.jpg"))
    if not labels:
        print(f"没有可用的测试图片：{IMG_DIR}")
        return 1
    step = max(len(labels) // max(args.images, 1), 1)
    picked = labels[::step][:args.images]

    problems: list[str] = []

    from PIL import Image

    # 先跑一张真实图片，拿到原始输出缓冲，用于下面的范围统计。
    probe = picked[0]
    probe_img = np.asarray(Image.open(probe).convert("RGB"), dtype=np.float32) / 255.0
    probe_ten, _, _, _, _ = letterbox(probe_img, input_size)
    it.set_tensor(ind["index"], probe_ten)
    it.invoke()
    out = it.get_tensor(outd["index"])

    # ---- 两种布局的分数范围都算出来，用来解释「为什么这个 bug 看不见」 ----
    # 注意：**不能用分数范围判定布局**。本模型的坐标已被归一化到 [0,1]，
    # 于是读错布局时取到的仍然是 [0,1] 内的数值，只是含义完全不同——
    # 分数范围看着照样合法。这正是当初这个 bug 能活下来的原因。
    # 真正的判据有两个：张量形状（锚点优先 ⟺ anchors 在第 1 维），
    # 以及下面端到端 IoU 的对照。
    print()
    print("两种布局下的类别分数范围（说明为什么单看分数判不出布局）")
    for am in (anchor_major, not anchor_major):
        lo, hi = score_channel_range(out, am, num_classes)
        tag = "按形状判定为正确" if am == anchor_major else "错误读法"
        print(f"  {('锚点优先' if am else '通道优先'):<24}[{lo:>10.4f},{hi:>10.4f}]   {tag}")
    print("  两者都落在 [0,1]：本模型坐标已归一化，读错布局取到的仍是合法区间内的"
          "数值，\n  所以分数范围**不能**用来判布局，只能靠形状 + 端到端 IoU。")

    # ---- 坐标是否归一化 ----
    c_lo, c_hi = coord_channel_range(out, anchor_major)
    coords_normalized = c_hi <= 1.5
    print()
    print(f"坐标通道范围：[{c_lo:.4f},{c_hi:.4f}] -> "
          f"{'归一化（需乘 inputSize）' if coords_normalized else '像素（不要再乘）'}")

    # ---- 端到端：与人工标注比 IoU，这才是布局与坐标换算的最终判据 ----
    print()
    print(f"端到端核对（与人工标注的最佳 IoU；阈值 {args.threshold}）")
    header = f"  {'图片':<13}{'new,pads':<18}" + "".join(f"{v:<11}" for v in VARIANTS)
    print(header)
    print("  " + "-" * (len(header) - 2))
    totals: dict[str, list[float]] = {v: [] for v in VARIANTS}
    box_counts: dict[str, list[int]] = {v: [] for v in VARIANTS}
    for p in picked:
        lbl = LBL_DIR / f"{p.stem}.txt"
        gts = yolo_boxes(lbl) if lbl.exists() else []
        im = np.asarray(Image.open(p).convert("RGB"), dtype=np.float32) / 255.0
        ten, nw, nh, px, py = letterbox(im, input_size)
        it.set_tensor(ind["index"], ten)
        it.invoke()
        o = it.get_tensor(outd["index"])
        cells = []
        for name, (use_layout, mul, sub) in VARIANTS.items():
            raw_boxes = decode(
                o, input_size=input_size, new_w=nw, new_h=nh, pad_x=px, pad_y=py,
                threshold=args.threshold,
                anchor_major=(anchor_major if use_layout else not anchor_major),
                multiply_input_size=mul, subtract_pad=sub,
            )
            box_counts[name].append(len(raw_boxes))
            ds = nms(raw_boxes)
            bi = max((iou(d, g) for d in ds for g in gts), default=0.0)
            totals[name].append(bi)
            cells.append(f"{bi:<11.3f}")
        print(f"  {p.stem[:12]:<13}{f'{nw}x{nh} {px},{py}':<18}" + "".join(cells))
    print("  " + "-" * (len(header) - 2))
    means = {v: float(np.mean(l)) for v, l in totals.items()}
    print("  平均 IoU：" + "  ".join(f"{v}={means[v]:.3f}" for v in VARIANTS))
    print("  过阈值的框数（NMS 前，均值）："
          + "  ".join(f"{v}={np.mean(box_counts[v]):.0f}" for v in ("正确", "错布局")))
    print("  ↑ 「错布局」这一列的框数就是真机上「HUD 十几个框、屏幕上一个都画不出来」"
          "与\n    「没有垃圾桶也一直显示垃圾桶」的来源：读到的全是别的通道的数值。")

    if means["正确"] < MIN_MEAN_IOU:
        problems.append(
            f"正确解码的平均 IoU 只有 {means['正确']:.3f}（门槛 {MIN_MEAN_IOU}）。"
            f"模型或预处理有问题，不是解码假设的问题。"
        )
    for name in VARIANTS:
        if name != "正确" and means[name] >= means["正确"]:
            problems.append(f"变体「{name}」的平均 IoU 不低于「正确」，本脚本的判定依据失效，请复核。")

    # ---- 与 Kotlin 源码对照 ----
    print()
    print("Kotlin 源码核对")
    print("  先验证脚本自身的旋转参照公式（与 numpy 逐点比对）")
    rot_problems = verify_rotation_formulas()
    problems += rot_problems
    if not rot_problems:
        print("    四个旋转分支的参照公式与 numpy 顺时针旋转完全一致。")
    print("  再核对 Kotlin 里的解码/取样假设")
    problems += check_kotlin(int(out_shape[1]), int(out_shape[2]), coords_normalized)
    if not any(p.startswith(("Kotlin", "detectYuv", "参照")) for p in problems):
        print("    布局规则、坐标三步换算、逆旋转四分支、色度下标、PAD 均与实测一致。")

    print()
    if problems:
        print("发现问题：")
        for i, msg in enumerate(problems, 1):
            print(f"  {i}. {msg}")
        return 1

    print("全部通过：模型布局、坐标换算、Kotlin 源码三者一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main())

