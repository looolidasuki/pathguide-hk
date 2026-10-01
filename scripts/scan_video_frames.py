"""扫长视频，**按类别挑出最值得标注的帧**，产出可人工复核的图像集与依据清单。

## 为什么不是「只留有检测的帧」

最初的设计是：高步长扫描 + 开放词表检测，凡有命中的帧就留。
**实测证明这个筛子等于没筛**（`scripts/probe_scan_selectivity.py`，12 张真实街景）：

| 门槛 | 保留帧占比 |
|---|---|
| 0.15 | 100% |
| 0.35 | 100% |
| 0.55 | 100% |

原因很直接：48 类 × 164 条 prompt 的开放词表在真实街景上**什么都能匹配**——
每帧命中 9~16 个类、90~150 个框（`hand_truck` 平均 18 框/帧）。
「有没有检测」在街景里恒为真，所以它不构成筛选条件。

更糟的是反向的：我们**唯一有真实模型的类 `bin`，在这 12 帧里最高只到 0.18**。
零样本既筛不掉，也认不准。

## 改成什么：按类别定额取前 K

数据集的真实需求不是「哪些帧有东西」，而是**「每一类各要 250 个实例」**。
所以选帧的正确形式是**按类别排序取前 K**：

- 对每一类，按该类在帧上的最高分排序，取前 `--per-class` 帧；
- 一帧可同时被多个类选中，只存一张图；
- 选完再按 phash 去重，避免同类前 K 全是同一堵墙；
- **某一类一帧都没选上，本身就是结论**：这个类在这段视频里找不到，
  报告里会明确列出来，而不是让人以为「扫过了就有」。

零样本分数**没有标定**，所以它只用来**排序**，不用来判定真伪；
真伪交给人工复核。`class_aliases.json` 里的 `gdin_threshold` 是
Grounding DINO 的阈值，**不能**拿来用在这里（两者分值分布不同）。

## 两遍扫描（不浪费磁盘）

第一遍解码 + 推理，**只在内存里记下每帧各类的分数**，不写图；
据此算出每类的前 K，选出帧号集合；
第二遍只解码并写出这些帧号。解码很便宜（推理才是瓶颈），
换来的是「绝不落地一张不会被选中的图」。

## 产出

    <out>/<source>/<source>_<video>_<帧号>.jpg   被选中的帧
    <out>/manifest.csv                            每帧的依据：为哪些类而留、分数
    <out>/report.md                               总账 + 逐类候选数与前 K 得分

## 用法

    # 扫 data/raw 下的全部视频，每类最多留 20 帧
    python scripts/scan_video_frames.py

    # 每类 50 帧、0.5 秒采一帧、先只统计不写图
    python scripts/scan_video_frames.py --per-class 50 --sample-fps 0.5 --dry-run

    # 指定素材
    python scripts/scan_video_frames.py --videos data/raw/route_A --per-class 10
"""
from __future__ import annotations

import argparse
import csv
import sys
import time
from collections import Counter
from pathlib import Path

import cv2

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))
sys.path.insert(0, str(REPO_ROOT / "scripts" / "pipeline"))

import env_setup  # noqa: E402,F401  导入即生效（模块底部调用 apply()）

from dedup import compute_hash, is_duplicate  # noqa: E402
from extract_frames import (  # noqa: E402
    VIDEO_EXTS,
    find_videos,
    frame_filename,
    is_sharp,
)
from label_taxonomy import LabelTaxonomy, normalize_text  # noqa: E402
from stage1_propose import yolo_to_xyxy  # noqa: E402

DEFAULT_OUT = REPO_ROOT / "data" / "frames" / "selected"
RAW_DIR = REPO_ROOT / "data" / "raw"


# --------------------------------------------------------------------------- #
# 纯逻辑（可单测，不需要模型/视频）
# --------------------------------------------------------------------------- #
def frame_class_scores(dets: list[dict], min_score: float) -> dict[int, float]:
    """把一帧的检出压成 `{类别 id: 该类最高分}`，低于 `min_score` 的丢掉。

    只留最高分而不留框：选帧只需要「这一帧对这类有多像」，
    留着框会让第一遍的内存随框数膨胀（实测每帧上百个框）。
    """
    out: dict[int, float] = {}
    for d in dets:
        if d["conf"] < min_score:
            continue
        cid = d["class_id"]
        if d["conf"] > out.get(cid, 0.0):
            out[cid] = d["conf"]
    return out


def select_by_class(
    frames: dict[tuple[str, int], dict[int, float]],
    per_class: int,
) -> dict[tuple[str, int], set[int]]:
    """按类别定额选帧。

    返回 `{(video_key, frame_index): {为哪些类别而留}}`。

    **排序键里带 video_key 与帧号**，是为了让同分时结果稳定：
    否则同一份输入可能选出不同的帧，复核时对不上号。
    某一类一帧都没选上就不出现在结果里——报告会把它列成「没找到」。
    """
    by_class: dict[int, list[tuple[float, str, int]]] = {}
    for (video_key, idx), scores in frames.items():
        for cid, conf in scores.items():
            by_class.setdefault(cid, []).append((conf, video_key, idx))

    selected: dict[tuple[str, int], set[int]] = {}
    for cid, items in by_class.items():
        items.sort(key=lambda t: (-t[0], t[1], t[2]))
        for conf, video_key, idx in items[:per_class]:
            selected.setdefault((video_key, idx), set()).add(cid)
    return selected


def class_score_text(scores: dict[int, float], names: dict[int, str],
                     max_classes: int = 4) -> tuple[str, str, float]:
    """返回 (摘要, 为哪些类而留, 最高分)。

    摘要形如 `bin:0.62;bicycle:0.31`，按分数降序 —— 复核时先看的就是「最像什么」。
    """
    ordered = sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))
    text = ";".join(f"{names.get(cid, str(cid))}:{c:.2f}"
                    for cid, c in ordered[:max_classes])
    top = ordered[0][1] if ordered else 0.0
    return text, top, len(ordered)


def resolve_videos(args) -> list[Path]:
    """把 --videos 的输入展开成视频文件列表（去重、排序）。"""
    out: list[Path] = []
    for v in args.videos:
        p = Path(v)
        if not p.is_absolute():
            p = REPO_ROOT / p
        if p.is_dir():
            out.extend(find_videos(p))
        elif p.is_file() and p.suffix in VIDEO_EXTS:
            out.append(p)
        else:
            print(f"[WARN] 跳过（不是视频也不是含视频的目录）：{v}")
    return sorted(dict.fromkeys(out))


# --------------------------------------------------------------------------- #
# 第一遍：解码 + 推理，只记分数
# --------------------------------------------------------------------------- #
def collect_scores(video: Path, video_key: str, args, model, idx_to_id: dict[int, int]
                   ) -> tuple[dict[tuple[str, int], dict[int, float]], dict]:
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        print(f"  [WARN] 无法打开视频：{video}")
        return {}, {"decoded": 0, "sampled": 0, "blur": 0}

    video_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    if video_fps <= 0:
        video_fps = 30.0
    step = max(1, int(round(video_fps / args.sample_fps)))

    frames: dict[tuple[str, int], dict[int, float]] = {}
    stats = {"decoded": 0, "sampled": 0, "blur": 0}
    read_idx = 0
    t0 = time.time()

    while True:
        # ★ 用 grab() 跳过不需要的帧，只在被采样的那一帧 retrieve() 解码成图像。
        #
        # 为什么这很重要：本项目素材是 59.94 fps（每 120 帧才取 1 帧），
        # read() 会对每一帧都做一次 BGR 解码，而 grab() 只推进解码器内部指针。
        # 两步式扫描要解码两遍，用 read() 的话光是白解码就要多花好几分钟。
        if not cap.grab():
            break
        stats["decoded"] += 1
        if read_idx % step == 0:
            stats["sampled"] += 1
            ok, frame = cap.retrieve()
            if not ok:
                read_idx += 1
                continue
            # 先判清晰度再推理：模糊帧注定没用，推理它纯属浪费
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            if not is_sharp(gray, args.blur_thresh):
                stats["blur"] += 1
            else:
                r = model.predict([frame], imgsz=args.imgsz,
                                  conf=args.scan_floor, verbose=False)[0]
                h, w = r.orig_shape[:2]
                dets: list[dict] = []
                if r.boxes is not None and len(r.boxes):
                    for c_i, cf, box in zip(r.boxes.cls.tolist(),
                                            r.boxes.conf.tolist(),
                                            r.boxes.xywh.tolist()):
                        cid = idx_to_id.get(int(c_i))
                        if cid is None:
                            continue
                        dets.append({"class_id": cid, "conf": float(cf),
                                     "bbox": yolo_to_xyxy(box, w, h)})
                scores = frame_class_scores(dets, args.min_score)
                if scores:
                    frames[(video_key, read_idx)] = scores
            if stats["sampled"] % 100 == 0:
                print(f"    采样 {stats['sampled']}，候选帧 {len(frames)}，"
                      f"用时 {time.time() - t0:.0f}s", flush=True)
            if args.max_sampled and stats["sampled"] >= args.max_sampled:
                break
        read_idx += 1

    cap.release()
    return frames, stats


# --------------------------------------------------------------------------- #
# 第二遍：只写被选中的帧
# --------------------------------------------------------------------------- #
def write_selected(video: Path, out_dir: Path, source: str, wanted: set[int],
                   args, tax: LabelTaxonomy, video_key: str,
                   scores_by_frame: dict[tuple[str, int], dict[int, float]],
                   ) -> list[dict]:
    if not wanted:
        return []
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        return []
    video_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    if video_fps <= 0:
        video_fps = 30.0

    names = {c["id"]: c["name_en"] for c in tax.classes}
    out_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict] = []
    read_idx = 0
    while True:
        if not cap.grab():
            break
        if read_idx in wanted:
            ok, frame = cap.retrieve()
            if ok:
                name = frame_filename(source, video.stem, read_idx)
                ok_write, buf = cv2.imencode(
                    ".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
                if ok_write:
                    buf.tofile(str(out_dir / name))
                    scores = scores_by_frame.get((video_key, read_idx), {})
                    text, top, n = class_score_text(scores, names)
                    rows.append({
                        "image": name,
                        "source_video": video.name,
                        "frame_index": read_idx,
                        "time_sec": f"{read_idx / video_fps:.2f}",
                        "n_classes": n,
                        "top_conf": f"{top:.3f}",
                        "classes": text,
                        "dedup": "",
                    })
        read_idx += 1
    cap.release()
    return rows


# --------------------------------------------------------------------------- #
# 去重与产物
# --------------------------------------------------------------------------- #
def dedup_rows(rows: list[dict], out_dir: Path, threshold: int) -> int:
    """按 phash 去重。返回被丢弃的条数。

    只标记 + 删文件，不删 manifest 行——「因为重复而没留」本身也是信息，
    否则下次会疑惑「这段明明选了 30 帧，怎么只剩 3 张」。
    """
    if threshold <= 0:
        return 0
    seen: list[int] = []
    dropped = 0
    for row in rows:
        path = out_dir / row["image"]
        if not path.exists():
            continue
        h = compute_hash(path, "phash")
        if is_duplicate(h, seen, threshold):
            row["dedup"] = "dropped"
            path.unlink(missing_ok=True)
            dropped += 1
        else:
            seen.append(h)
            row["dedup"] = "kept"
    return dropped


def write_manifest(rows: list[dict], path: Path) -> None:
    cols = ["image", "source_video", "frame_index", "time_sec",
            "n_classes", "top_conf", "classes", "dedup"]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow(r)


def write_report(rows: list[dict], class_stats: dict[int, list[float]],
                 stats: dict, args, path: Path, tax: LabelTaxonomy) -> None:
    kept = [r for r in rows if r["dedup"] != "dropped"]
    names = {c["id"]: c["name_en"] for c in tax.classes}
    lines = [
        "# 视频扫描报告（按类别定额选帧）",
        "",
        f"- 采样频率：{args.sample_fps} fps    清晰度门槛：{args.blur_thresh}",
        f"- 每类最多留：**{args.per_class}** 帧    候选下限分：{args.min_score}"
        f"（推理下限 {args.scan_floor}）",
        f"- 去重：phash 汉明距离 <= {args.dedup_threshold}"
        + ("（已关闭）" if args.dedup_threshold <= 0 else ""),
        "",
        "| 阶段 | 帧数 |",
        "|---|---|",
        f"| 解码总帧 | {stats['decoded']} |",
        f"| 采样 | {stats['sampled']} |",
        f"| 模糊被丢 | {stats['blur']} |",
        f"| 有候选的帧 | {stats['candidates']} |",
        f"| 按定额选中 | {stats['selected']} |",
        f"| 去重后又丢 | {stats['dedup_dropped']} |",
        f"| 最终可用 | **{len(kept)}** |",
        "",
        "## 逐类候选情况",
        "",
        "| 类别 | 候选帧 | 选中 | 最高分 |",
        "|---|---|---|---|",
    ]
    for cid in sorted(class_stats, key=lambda c: -len(class_stats[c])):
        confs = class_stats[cid]
        n_sel = min(len(confs), args.per_class)
        lines.append(f"| {names.get(cid, cid)} | {len(confs)} | {n_sel} | "
                     f"{max(confs):.3f} |")
    # 「一帧都没选上」是结论，必须显式写出来
    missing = [c["name_en"] for c in tax.classes if c["id"] not in class_stats]
    lines += [
        "",
        "**没有任何候选的类别（{n} 个）**：".format(n=len(missing))
        + ("、".join(missing) if missing else "无"),
        "",
        "> 这几类在这段素材里**一帧都没扫到**。但**光看本报告分不清两种原因**：",
        "> ① 零样本对这些类没有召回；② 只是分数低于 `--min-score`。",
        "> 跑 `scripts/probe_missing_classes.py --video <视频>` 用很低的推理下限重扫一遍，",
        "> 它会给出每个类的**最高分**，据此就能区分——两者的处理方式完全相反：",
        "> 无召回只能靠实拍补数据；低于门槛则可以考虑降门槛（但要接受噪声）。",
        "",
        "## 必须知道的局限",
        "",
        "- 零样本分数**没有标定**，只用于**排序**取前 K，不用于判定真伪。",
        "- `class_aliases.json` 的 `gdin_threshold` 是 Grounding DINO 的阈值，"
        "**不能**用在这里。",
        "- 实测开放词表在街景上噪声很大（每帧命中 9~16 类），"
        "所以清单里的类名要当**线索**看，不是结论。",
        "- **这是候选帧，不是标注。** 每帧依据见同目录 `manifest.csv`。",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--videos", nargs="*", default=[str(RAW_DIR)],
                    help=f"视频文件或目录（默认扫 {RAW_DIR}）")
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--sample-fps", type=float, default=0.5)
    ap.add_argument("--blur-thresh", type=float, default=100.0)
    ap.add_argument("--per-class", type=int, default=20,
                    help="★ 每类最多保留多少帧（这就是筛选的真正手段）")
    ap.add_argument("--min-score", type=float, default=0.25,
                    help="低于这个分数的检出不算候选（零样本噪声很大，需要一个下限）")
    ap.add_argument("--scan-floor", type=float, default=0.05,
                    help="送进统计前的推理下限；比 --min-score 低，"
                         "让阈值判断集中在一处（便于单测）")
    ap.add_argument("--weights", default="yolov8s-world.pt")
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--dedup-threshold", type=int, default=6)
    ap.add_argument("--max-sampled", type=int, default=None)
    ap.add_argument("--limit-videos", type=int, default=None)
    ap.add_argument("--dry-run", action="store_true",
                    help="只统计不写图，用来预估这次扫描会选出多少张")
    args = ap.parse_args()

    videos = resolve_videos(args)
    if args.limit_videos:
        videos = videos[: args.limit_videos]
    if not videos:
        print(f"没有找到视频。把素材放到 {RAW_DIR} 下，或用 --videos 指定路径。")
        return 1

    out_root = Path(args.out)
    if not out_root.is_absolute():
        out_root = REPO_ROOT / out_root

    tax = LabelTaxonomy()
    prompts = tax.yolo_world_prompts()
    prompt_to_id = tax.prompt_to_id()
    from ultralytics import YOLO

    model = YOLO(args.weights)
    model.set_classes(prompts)
    idx_to_id = {i: prompt_to_id[normalize_text(p)]
                 for i, p in enumerate(prompts)
                 if normalize_text(p) in prompt_to_id}

    print(f"视频 {len(videos)} 个；类别 {len(tax.classes)}，prompt 说法 {len(prompts)}")
    print(f"采样 {args.sample_fps} fps；每类最多留 {args.per_class} 帧；"
          f"候选下限 {args.min_score}"
          + ("（dry-run，不写图）" if args.dry_run else ""))

    t0 = time.time()
    total = {"decoded": 0, "sampled": 0, "blur": 0, "candidates": 0,
             "selected": 0, "dedup_dropped": 0}
    all_rows: list[dict] = []
    class_conf: dict[int, list[float]] = {}

    # 按「来源目录」分组：同一段路线的多个视频共用一个配额，
    # 避免某个视频把配额吃光、另一个视频一帧都选不上。
    groups: dict[str, list[Path]] = {}
    for v in videos:
        groups.setdefault(v.parent.name, []).append(v)

    for source, group in sorted(groups.items()):
        print(f"\n[{source}] {len(group)} 个视频")
        frames: dict[tuple[str, int], dict[int, float]] = {}
        for video in group:
            video_key = f"{source}/{video.name}"
            got, st = collect_scores(video, video_key, args, model, idx_to_id)
            frames.update(got)
            for k in ("decoded", "sampled", "blur"):
                total[k] += st[k]
            print(f"  {video.name}: 采样 {st['sampled']}，候选 {len(got)}")

        total["candidates"] += len(frames)
        for scores in frames.values():
            for cid, conf in scores.items():
                class_conf.setdefault(cid, []).append(conf)

        selected = select_by_class(frames, args.per_class)
        total["selected"] += len(selected)
        print(f"  按定额选中 {len(selected)} 帧"
              + ("（dry-run 不写盘）" if args.dry_run else "，开始写盘…"))

        if args.dry_run:
            continue
        out_dir = out_root / source
        for video in group:
            video_key = f"{source}/{video.name}"
            wanted = {idx for (vk, idx), _ in selected.items() if vk == video_key}
            rows = write_selected(video, out_dir, source, wanted, args, tax,
                                  video_key, frames)
            dropped = dedup_rows(rows, out_dir, args.dedup_threshold)
            total["dedup_dropped"] += dropped
            all_rows.extend(rows)

    if not args.dry_run:
        write_manifest(all_rows, out_root / "manifest.csv")
        write_report(all_rows, class_conf, total, args,
                     out_root / "report.md", tax)

    print(f"\n解码 {total['decoded']}，采样 {total['sampled']}，模糊 {total['blur']}，"
          f"有候选 {total['candidates']}，选中 {total['selected']}，"
          f"去重再丢 {total['dedup_dropped']}，"
          f"最终 {total['selected'] - total['dedup_dropped']} 张")
    print(f"用时 {(time.time() - t0) / 60:.1f} 分钟")
    if not args.dry_run:
        print(f"输出：{out_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
