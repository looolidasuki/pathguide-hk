"""下载 Roboflow 的直链数据集导出包。

用 Python 而不是 curl：本环境下 curl 走 Windows schannel，
在受限沙箱里 `AcquireCredentialsHandle` 会失败（`SEC_E_NO_CREDENTIALS`），
TLS 握手根本起不来。Python 的 ssl 用自带 CA 包，不受这个限制。

URL 形如 https://app.roboflow.com/ds/<id>?key=<key> —— 这是 Roboflow 的
「数据集导出直链」，key 是链接自带的下载令牌，不是 API key。

用法：
    python scripts/fetch_roboflow_link.py --url "https://app.roboflow.com/ds/xxx?key=yyy" \
        --out data/raw/roboflow2/roboflow.zip
"""
from __future__ import annotations

import argparse
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    out = Path(args.out)
    if not out.is_absolute():
        out = REPO_ROOT / out
    out.parent.mkdir(parents=True, exist_ok=True)

    req = urllib.request.Request(args.url, headers={
        "User-Agent": UA,
        "Accept": "*/*",
    })
    print(f"请求：{args.url.split('?')[0]}（key 已隐去）", flush=True)
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            ctype = r.headers.get("Content-Type", "?")
            clen = r.headers.get("Content-Length")
            total = int(clen) if clen else None
            print(f"HTTP {r.status}  Content-Type={ctype}  "
                  f"Content-Length={f'{total:,}' if total else '未声明'}", flush=True)

            # ★ 流式写盘，不读进内存。
            # 早先的写法是 `data = r.read()` 再 write_bytes ——
            # 对 31 MiB 的包没问题，但这份数据涨到 5060 张后可能是几个 GB，
            # 读进内存会直接把进程拖垮（而且中途失败就什么都不剩）。
            # 先写 .part 再改名，这样「文件存在」就等于「下载完整」。
            tmp = out.with_suffix(out.suffix + ".part")
            got = 0
            last_pct = -5
            with tmp.open("wb") as f:
                while True:
                    chunk = r.read(1 << 20)      # 1 MiB
                    if not chunk:
                        break
                    f.write(chunk)
                    got += len(chunk)
                    if total:
                        pct = int(got * 100 / total)
                        if pct >= last_pct + 5:
                            last_pct = pct
                            print(f"  {pct:3d}%  {got/1024/1024:8.1f} / "
                                  f"{total/1024/1024:.1f} MiB", flush=True)
                    elif got % (64 << 20) < (1 << 20):
                        print(f"  {got/1024/1024:8.1f} MiB", flush=True)
            if total and got != total:
                print(f"\n**下载不完整**：应 {total:,} 字节，实得 {got:,} 字节")
                return 1
            tmp.replace(out)
    except urllib.error.HTTPError as e:
        body = e.read()[:400].decode("utf-8", errors="replace")
        print(f"HTTP {e.code} {e.reason}")
        print("  " + body)
        return 1
    except Exception as e:
        print(f"请求失败：{type(e).__name__}: {e}")
        return 1

    # 校验 zip 完整性（比只看文件头更强：能发现截断）
    import zipfile
    print(f"\n已写 {out.relative_to(REPO_ROOT)}  {out.stat().st_size:,} 字节 "
          f"({out.stat().st_size/1024/1024:.2f} MiB)")
    try:
        with zipfile.ZipFile(out) as zf:
            bad = zf.testzip()
        if bad:
            print(f"**zip 内文件损坏**：{bad}")
            return 1
        print("zip 完整性检查通过")
    except zipfile.BadZipFile as e:
        print(f"**不是有效 zip**：{e}")
        print("  前 300 字节：" + out.read_bytes()[:300].decode("utf-8", errors="replace"))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
