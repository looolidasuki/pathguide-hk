"""核实 CUDA 到底能不能用。

项目多处文档写着「本机无 GPU、CUDA 不可用」，并据此做了决策
（见 docs/superpowers/plans/2026-09-28-decision-no-ssl-pretraining.md）。
但 ultralytics 的启动横幅显示 `torch-2.11.0+cu128 CUDA:0 (RTX 5070)`。

这两者不可能同时为真，所以必须实测一次：
- torch 版本与是否带 CUDA 支持
- torch.cuda.is_available()
- 实际分配一个张量并做一次矩阵乘，确认不是「报告可用但一跑就崩」
"""
import time

import torch

print(f"torch           {torch.__version__}")
print(f"torch.version.cuda {torch.version.cuda}")
print(f"cuda.is_available  {torch.cuda.is_available()}")
print(f"device_count       {torch.cuda.device_count()}")

if torch.cuda.is_available():
    print(f"设备名          {torch.cuda.get_device_name(0)}")
    props = torch.cuda.get_device_properties(0)
    print(f"显存            {props.total_memory/1024**3:.1f} GiB")
    print(f"算力            sm_{props.major}{props.minor}")
    # 真跑一次，确认不是「报告可用但一用就崩」
    try:
        a = torch.randn(2000, 2000, device="cuda")
        b = torch.randn(2000, 2000, device="cuda")
        torch.cuda.synchronize()
        t0 = time.time()
        for _ in range(20):
            c = a @ b
        torch.cuda.synchronize()
        dt = (time.time() - t0) / 20
        print(f"实测 2000x2000 矩阵乘 {dt*1000:.2f} ms/次  -> {2*2000**3/dt/1e12:.2f} TFLOP/s")
        # 与 CPU 比一比
        ac = a.cpu(); bc = b.cpu()
        t0 = time.time()
        for _ in range(3):
            _ = ac @ bc
        print(f"CPU 同规模 {(time.time()-t0)/3*1000:.1f} ms/次")
        print("结论：GPU **确实可用**（不只是报告可用）")
    except Exception as e:
        print(f"分配/计算失败：{type(e).__name__}: {e}")
        print("结论：报告可用但实际不可用")
else:
    print("结论：CUDA 不可用")
    print(f"  torch 是否为 CPU 版：{'cpu' in torch.__version__}")
