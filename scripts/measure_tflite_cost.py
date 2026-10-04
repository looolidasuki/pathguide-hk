"""量化「类别数从 3 增到 18」在推理上的代价。

## 为什么这个测量是干净的

`pg_poc3`（3 类，输出通道 7）与 `pg_stage2`（18 类，输出通道 22）是
**同一个骨干、同一输入尺寸（416）、同一量化方式（int8）**，
唯一的差别就是输出通道 4+nc。所以两者的推理耗时差**直接就是**
「多识别 15 个类」的代价，不掺杂其它变量。

## 局限（必须写清楚）

宿主是 i7-14700KF，部署端是 Snapdragon 685 —— **绝对耗时不可外推**。
但输出通道带来的**相对代价**主要取决于解码/写出的数据量，
量级上可以参照。**真实数字仍必须在真机上测。**

用法：
    .\.venv-export\Scripts\python.exe scripts/measure_tflite_cost.py
"""
from __future__ import annotations

import statistics
import time
from pathlib import Path

import numpy as np

MODELS = {
    "poc3（3 类, 通道 7）": Path("app/assets/models/detector.tflite"),
    "stage2（18 类, 通道 22）": Path(
        "runs/pg_stage2/weights/best_saved_model/best_int8.tflite"),
}
WARMUP = 20
RUNS = 100


def main() -> int:
    import tensorflow as tf

    results = {}
    for label, path in MODELS.items():
        if not path.exists():
            print(f"跳过（不存在）：{path}")
            continue
        size = path.stat().st_size
        interp = tf.lite.Interpreter(model_path=str(path), num_threads=1)
        interp.allocate_tensors()
        inp = interp.get_input_details()[0]
        out = interp.get_output_details()[0]
        shape = inp["shape"]  # (1,416,416,3)
        x = np.zeros(shape, dtype=inp["dtype"]) if inp["dtype"] != np.float32 \
            else np.random.rand(*shape).astype(np.float32)

        for _ in range(WARMUP):
            interp.set_tensor(inp["index"], x)
            interp.invoke()
        ts = []
        for _ in range(RUNS):
            t0 = time.perf_counter()
            interp.set_tensor(inp["index"], x)
            interp.invoke()
            ts.append((time.perf_counter() - t0) * 1000)
        med = statistics.median(ts)
        results[label] = (size, out["shape"], med)
        print(f"\n{label}")
        print(f"  文件       {size:,} 字节（{size/1e6:.2f} MB）")
        print(f"  输入       {inp['shape']} {inp['dtype'].__name__}")
        print(f"  输出       {out['shape']} {out['dtype'].__name__}")
        print(f"  推理中位   {med:.2f} ms  （{RUNS} 次，单线程）")

    if len(results) == 2:
        a, b = list(results.values())
        print("\n=== 差异 ===")
        print(f"  文件大小：{a[0]:,} → {b[0]:,}   "
              f"（{(b[0]-a[0])/a[0]*100:+.1f}%）")
        print(f"  输出通道：{a[1][1]} → {b[1][1]}   "
              f"（{(b[1][1]-a[1][1])/a[1][1]*100:+.1f}%）")
        print(f"  推理耗时：{a[2]:.2f} → {b[2]:.2f} ms   "
              f"（{(b[2]-a[2])/a[2]*100:+.1f}%）")
        print("\n  参考：真机 3 类 int8 实测 268 ms（Snapdragon 685，纯 CPU）。")
        print("  宿主与真机不同，绝对耗时不可外推，但相对代价可作量级参照。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
