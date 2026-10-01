"""从 Roboflow 下载数据集（YOLO 格式），落到 data/raw/roboflow/。

## 为什么单独一个脚本，而不是直接用 `from roboflow import Roboflow`

1. **key 只从一个地方读，且绝不打印。** key 存在 `.env.secret.ps1`（已 gitignore）
   或环境变量里。这个脚本只报长度与前 4 位，避免 key 进日志/进对话。
2. **先探测再下载。** `--list-only` 只查项目与版本信息，确认有权限、版本存在、
   类别是什么，再决定下不下。下载几百 MB 之后才发现 key 没权限是很浪费的一次尝试。
3. **下载完直接把类别列出来。** 类别名对不上是本项目的常客，
   而 `import_roboflow.py` 需要 `--class-override` 才能把
   Roboflow 的 `person` 映射到本项目的 `pedestrian`。
   所以这里把 Roboflow 的类别表与项目类别表并排列出来，给出建议的 override。

用法：
    python scripts/fetch_roboflow.py --list-only
    python scripts/fetch_roboflow.py
    python scripts/fetch_roboflow.py --workspace chris-law --project people-detection-o4rdr-nlryq --version 1
"""
from __future__ import annotations

import argparse
import io
import json
import re
import sys
from contextlib import redirect_stdout
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"
SECRET_PATH = REPO_ROOT / ".env.secret.ps1"


def read_key() -> str | None:
    """从 .env.secret.ps1 或环境变量读 key。只返回值，不打印。"""
    import os

    v = os.environ.get("ROBOFLOW_API_KEY")
    if v and v.strip():
        return v.strip()

    if not SECRET_PATH.exists():
        return None
    for raw in SECRET_PATH.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("#") or "=" not in line:
            continue
        left, right = line.split("=", 1)
        if "ROBOFLOW_API_KEY" in left.upper():
            val = right.strip().strip('"').strip("'")
            if val:
                return val
    return None


def load_target_classes() -> list[dict]:
    return sorted(json.loads(CLASSES_PATH.read_text(encoding="utf-8"))["classes"],
                  key=lambda c: c["id"])


def suggest_override(source_names: list[str], targets: list[dict]) -> dict[str, int]:
    """给出类别映射建议，并**标出哪些是猜的**。

    Roboflow 的类别名来自许多个上游数据集拼起来，同一样东西会有多种写法。
    实测 `chris-law/people-detection-o4rdr-nlryq` 声明了 **63 个**类别，
    其中「人」就有 8 种写法：person / persons / people / Pedestrian /
    Pedestrians / Pessoa（葡）/ Persona（西·意）/ player（?）。

    这里只映射**语义无歧义**的写法。「人」的各语言同义词是无歧义的；
    而下面这些**故意不映射**，因为它们与本项目的类不等价，
    而映射错会让每帧标签都错（不报错）：

    | 数据集里的类 | 为什么不映射 |
    |---|---|
    | `Cyclist` / `cyclist` | 是**骑车的人**（人+车），不是本项目的 `bicycle`（单車，一个障碍物）。映过去会让「骑车的人」被念成「單車」 |
    | `player` | 体育场景里的「人」，还是「球员」这一角色？歧义 |
    | `head` / `face` / `helmet` | 是身体部位/穿戴物，不是人 |
    | `Signboard` | 通常是店铺招牌，本项目的 `sign_pictogram` 是**指示牌**、`billboard` 是廣告看板，均不等价 |
    | `Stopper` | 语义不明（门挡？车位挡？） |
    | `diningtable` / `chair` | 本项目的 `table`(34) 是「桌椅」；COCO 的 dining table 与本项目 `table` 的**语义已知不等价**，不应再扩大这个偏差 |
    | `0`~`6` | **无名数字类**，语义未知，无法映射 |
    | `high` / `medium` / `low` | 疑似人潮密度或置信度分档，不是物件类 |
    | `dianzhuan` / `jatuh` / `berdiri` | 语义不明（`jatuh`/`berdiri` 是印尼语的跌到/站立，来自跌倒检测数据集） |
    | 车辆类（`car`/`car`/`auto`/`truck`/`bus`/`motorbike`/`train`…） | 本项目类别表**没有**车辆类 |

    这些类的框会被 `import_roboflow.py` 跳过，并且**会打印出来**——
    跳过是有意的，静默丢弃才是问题。
    """
    ALIASES = {
        # 「人」的各语言/各写法同义词——语义无歧义
        "person": "pedestrian",
        "persons": "pedestrian",
        "people": "pedestrian",
        "pedestrian": "pedestrian",
        "pedestrians": "pedestrian",
        "pessoa": "pedestrian",      # 葡萄牙语
        "persona": "pedestrian",     # 西班牙语 / 意大利语
        "human": "pedestrian",
        # 单車
        "bike": "bicycle",
        "bikes": "bicycle",
        "bicycle": "bicycle",
        "bicycles": "bicycle",
        # 垃圾桶
        "trash": "bin",
        "trash bin": "bin",
        "trashbin": "bin",
        "garbage bin": "bin",
        "litter bin": "bin",
        "bin": "bin",
        "rubbish bin": "bin",
        "waste bin": "bin",
    }
    by_en = {c["name_en"].lower(): c["id"] for c in targets}
    out: dict[str, int] = {}
    for nm in source_names:
        key = nm.strip().lower()
        tgt = ALIASES.get(key, key)
        if tgt in by_en:
            out[nm] = by_en[tgt]
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", default="chris-law")
    ap.add_argument("--project", default="people-detection-o4rdr-nlryq")
    ap.add_argument("--version", type=int, default=1)
    ap.add_argument("--format", default="yolov8",
                    help="下载格式（导出格式名，如 yolov8 / coco / voc）")
    ap.add_argument("--out", default="data/raw/roboflow",
                    help="下载到哪里（相对仓库根）")
    ap.add_argument("--list-only", action="store_true",
                    help="只探测项目/版本/类别，不下载")
    args = ap.parse_args()

    key = read_key()
    if not key:
        print("没找到 ROBOFLOW_API_KEY。")
        print(f"  写入 {SECRET_PATH.name}：$env:ROBOFLOW_API_KEY = \"<你的key>\"")
        return 1
    print(f"凭据：{len(key)} 字符，以 {key[:4]}… 开头（未打印完整 key）")

    try:
        from roboflow import Roboflow
    except ImportError:
        print("未安装 roboflow SDK：.venv\\Scripts\\pip install roboflow")
        return 1

    # SDK 会把「正在载入」之类的信息打到 stdout；这里把探测阶段的输出收起来，
    # 只保留我们自己要报的内容，避免把可能含 key 的调试行漏出来。
    buf = io.StringIO()
    try:
        # 注意：Roboflow(...) 的**构造函数自己就会鉴权**并抛 RuntimeError。
        # 所以构造函数也必须在 try 里面——否则 key 无效时用户看到的是一个 traceback，
        # 而不是「key 被吊销了」这句话。
        with redirect_stdout(buf):
            rf = Roboflow(api_key=key)
            ws = rf.workspace(args.workspace)
            proj = ws.project(args.project)
            ver = proj.version(args.version)
    except Exception as e:
        print(f"\n探测失败：{type(e).__name__}")
        msg = str(e)
        # 只保留错误体的关键部分，避免整段 SDK 输出里夹带 key
        msg = re.sub(r"api_key=[^&\s\"']+", "api_key=***", msg)
        print("  " + msg[:600])
        print("\n常见原因：key 无效/被吊销、无此工作区权限、项目或版本不存在。")
        return 1

    names: list[str] = []
    try:
        names = list(getattr(ver, "name_of_classes", None) or [])
    except Exception:
        pass
    if not names:
        try:
            names = list(proj.classes)
        except Exception:
            names = []

    print(f"\n项目：{args.workspace}/{args.project}  版本 {args.version}")
    print(f"Roboflow 声明类别 {len(names)} 个：{', '.join(names) if names else '(未知)'}")

    targets = load_target_classes()
    ov = suggest_override(names, targets)
    if ov:
        print("\n建议的类别映射（**请确认语义是否正确**，别直接照抄）：")
        for k, v in ov.items():
            tgt = next(c for c in targets if c["id"] == v)
            print(f"  {k:<24} -> {v:>3} {tgt['name_en']}")
        unmatched = [n for n in names if n not in ov]
        if unmatched:
            print(f"\n[警告] 这些类别未能映射：{unmatched}")
            print("  它们的框会被 import_roboflow.py 跳过——这是**有意**的，不静默丢弃。")
    elif names:
        print("\n[警告] 没有任何类别能映射到本项目类别表。")
        print("  本项目不需要的类别（如数据集里的其他物件）应当跳过，但要显式确认。")

    if args.list_only:
        print("\n--list-only：未下载。")
        return 0

    out_dir = REPO_ROOT / args.out
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"\n开始下载（格式 {args.format}）到 {out_dir.relative_to(REPO_ROOT)} ...")
    try:
        with redirect_stdout(buf):
            ds = ver.download(args.format, location=str(out_dir), overwrite=True)
    except Exception as e:
        print(f"下载失败：{type(e).__name__}: {str(e)[:500]}")
        return 1

    loc = Path(getattr(ds, "location", out_dir))
    print(f"下载完成：{loc}")

    n_img = sum(1 for p in loc.rglob("*") if p.suffix.lower() in
                (".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"))
    print(f"  图像 {n_img} 张")

    # 把建议的映射**写到数据集旁边**。
    #
    # 为什么写文件而不是只打印一条命令：忘了传 --class-override 时，
    # import_roboflow.py 只做精确名匹配，于是 person / Persona / Pessoa /
    # people / persons / bike 这些**数据大头**会被跳过。它会打印未映射警告，
    # 但如果人不看输出，就会以为导入成功了。
    # 写成文件以后，导入命令里只需给一个路径，既不会漏也不会打错
    # （Windows 上 PowerShell 还会吃掉命令行 JSON 里的双引号）。
    ov_path = loc / "_class_override.json"
    ov_path.write_text(json.dumps(ov, ensure_ascii=False, indent=2) + "\n",
                       encoding="utf-8")
    print(f"  类别映射建议已写入：{ov_path.relative_to(REPO_ROOT)}")
    if not ov:
        print("  [警告] 没有任何类别能映射到本项目类别表，导入会跳过全部框。")

    print("\n下一步（先 dry-run 看清映射与框数，再真正写入）：")
    print(f"  python scripts\\import_roboflow.py --dir \"{loc}\" --dry-run "
          f"--class-override-file \"{ov_path}\"")
    print()
    print(f"  python scripts\\import_roboflow.py --dir \"{loc}\" "
          f"--source-folder roboflow_{args.project} "
          f"--class-override-file \"{ov_path}\"")
    print("\n注意 1：**必须带 --class-override-file**。不带的话 import_roboflow.py 只做"
          "精确名匹配，")
    print("        person / Persona / Pessoa / people / persons / bike 等变体会被跳过——"
          "那正是数据的大头。")
    print("注意 2：--source-folder 填**实际采集点位**。这个数据集是多个上游数据集拼起来的，")
    print("        它自带的 train/valid/test 是**逐图随机**划分的，同一段视频的相邻帧")
    print("        很可能被分到两边。所以建议**整份当一个来源**（一个名字），")
    print("        让它整体进训练集，别让它污染本项目的验证集。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
