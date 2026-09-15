import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = REPO_ROOT / "scripts"

# 让 tests 能直接 import scripts/ 下的独立 CLI 脚本
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

# 必须在任何 ultralytics / matplotlib 导入之前重定向写路径，
# 否则会因沙箱拒绝写入 %APPDATA% 而失败。
import env_setup  # noqa: E402

env_setup.apply()
