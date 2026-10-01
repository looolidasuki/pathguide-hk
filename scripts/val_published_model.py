"""对**已发布的那一份权重**重跑 val，把逐类指标落盘。

为什么单独写：之前逐类指标只打在控制台上，没存文件，于是文档里只能凭记忆写，
而记忆里的数字无法追溯。这份 JSON 就是文档与清单里数字的唯一来源。
"""
import json
import pathlib
import sys

from ultralytics import YOLO

WEIGHTS = pathlib.Path("runs/pg_poc3/weights/best.pt")
DATA = pathlib.Path("data/dataset_poc3/dataset.yaml")
OUT = pathlib.Path("artifacts/metrics/pg_poc3_val.json")

m = YOLO(str(WEIGHTS))
r = m.val(data=str(DATA), imgsz=416, split="val", workers=0, plots=False, verbose=False)

names = r.names
# nt_per_class：验证集里每类的实例数。**这个数必须一起记**——
# 没有它，「bicycle mAP50=0.496」和「bicycle 只有 2 个实例」是同一件事，
# 但只有后者才说明这个指标不该被引用。
nt = getattr(r, "nt_per_class", None)
classes = []
for i, name in names.items():
    p, rec, ap50, ap = r.box.p[i], r.box.r[i], r.box.ap50[i], r.box.ap[i]
    classes.append({
        "local_index": int(i),
        "name": name,
        "instances": int(nt[i]) if nt is not None else None,
        "precision": round(float(p), 4),
        "recall": round(float(rec), 4),
        "mAP50": round(float(ap50), 4),
        "mAP50_95": round(float(ap), 4),
    })

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
