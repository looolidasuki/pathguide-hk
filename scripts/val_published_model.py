"""对**已发布的那一份权重**重跑 val，把逐类指标落盘。

为什么单独写：之前逐类指标只打在控制台上，没存文件，于是文档里只能凭记忆写，
而记忆里的数字无法追溯。这份 JSON 就是文档与清单里数字的唯一来源。
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from yolo_metrics import ap_index_of, map_per_class_metrics  # noqa: E402

from ultralytics import YOLO

WEIGHTS = pathlib.Path("runs/pg_poc3/weights/best.pt")
DATA = pathlib.Path("data/dataset_poc3/dataset.yaml")
OUT = pathlib.Path("artifacts/metrics/pg_poc3_val.json")

m = YOLO(str(WEIGHTS))
r = m.val(data=str(DATA), imgsz=416, split="val", workers=0, plots=False, verbose=False)

# ★ 必须用 ap_class_index 映射，不能按 r.names 的下标取。
# r.names 是 **data.yaml 的类别数**（poc5 是 18），而 box.p 只覆盖
# **val 里真有实例的类**（通常更少）。直接 r.box.p[i] 会在类别数 > 有实例的类数时
# IndexError；更糟的是旧模型 3 类时两个长度恰好相等，它会**靠巧合工作**。
# 这段逻辑现在抽到 scripts/yolo_metrics.py 并有单测覆盖。
per_class = map_per_class_metrics(
    r.names, r.box.p, r.box.r, r.box.ap50, r.box.ap,
    ap_class_index=ap_index_of(r),
    # nt_per_class：验证集里每类的实例数。**这个数必须一起记**——
    # 没有它，「bicycle mAP50=0.496」和「bicycle 只有 2 个实例」是同一件事，
    # 但只有后者才说明这个指标不该被引用。
    instances=getattr(r, "nt_per_class", None),
)
classes = [
    {"local_index": v["class_index"], "name": k, "instances": v["instances"],
     "precision": v["precision"], "recall": v["recall"],
     "mAP50": v["mAP50"], "mAP50_95": v["mAP50_95"]}
    for k, v in per_class.items()
]

out = {
    "weights": str(WEIGHTS),
    "data": str(DATA),
    "split": "val",
    "imgsz": 416,
    "overall": {
        "precision": round(float(r.box.mp), 4),
        "recall": round(float(r.box.mr), 4),
        "mAP50": round(float(r.box.map50), 4),
        "mAP50_95": round(float(r.box.map), 4),
    },
    "per_class": classes,
}
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print(f"已写 {OUT}")
print(f"总体 P={out['overall']['precision']} R={out['overall']['recall']} "
      f"mAP50={out['overall']['mAP50']} mAP50-95={out['overall']['mAP50_95']}")
for c in classes:
    n = "" if c["instances"] is None else f" n={c['instances']}"
    print(f"  {c['name']:12} P={c['precision']:.3f} R={c['recall']:.3f} "
          f"mAP50={c['mAP50']:.3f}{n}")
