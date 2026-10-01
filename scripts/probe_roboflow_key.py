"""检查 .env.secret.ps1 里的 Roboflow key 是否已更新，并实测鉴权。

注意：只打印长度与前 4 位，不打印完整 key。
"""
import json
import pathlib
import urllib.error
import urllib.request

envf = pathlib.Path(".env.secret.ps1")
if not envf.exists():
    print(".env.secret.ps1 不存在")
    raise SystemExit(0)

lines = [l.strip() for l in envf.read_text(encoding="utf-8", errors="replace").splitlines()]
print(f".env.secret.ps1 有 {len(lines)} 行，含 ROBOFLOW 的行：")
key = None
for l in lines:
    if "ROBOFLOW" in l.upper():
        # 只显示变量名，不显示值
        left = l.split("=", 1)[0] if "=" in l else l
        val = l.split("=", 1)[1].strip().strip('"').strip("'") if "=" in l else ""
        print(f"  {left} = ({len(val)} 字符, 以 {val[:4]}… 开头)" if val else f"  {left} = (空)")
        if "API_KEY" in left.upper() and val:
            key = val

if not key:
    print("\n没有可用的 ROBOFLOW_API_KEY")
    raise SystemExit(0)

try:
    with urllib.request.urlopen(f"https://api.roboflow.com/?api_key={key}", timeout=30) as r:
        body = json.loads(r.read().decode("utf-8"))
    print(f"\n鉴权：可用  |  账号 {body.get('user')}  工作区 {body.get('workspace')}")
except urllib.error.HTTPError as e:
    print(f"\n鉴权：失败 HTTP {e.code}")
    print("  ", e.read().decode("utf-8", errors="replace")[:200])
except Exception as e:
    print(f"\n请求失败（可能网络问题）：{type(e).__name__}: {e}")
