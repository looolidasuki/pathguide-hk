import torch
import requests

print(f"你目前的 PyTorch 版本: {torch.__version__}")

# 使用國內清華大學的 PyPI 鏡像源 API 來查詢，避免網絡超時
url = "https://tsinghua.edu.cn"

try:
    response = requests.get(url, timeout=5)
    latest_version = response.json()["info"]["version"]
    print(f"最新穩定版本: {latest_version}")

    if torch.__version__ == latest_version:
        print("🎉 你的 PyTorch 已經是最新版本！")
    else:
        print("💡 官方已有更新版本，如有需要可以進行升級。")
except Exception as e:
    print("❌ 鏡像源連接依然超時，請檢查電腦的網絡聯網狀態。")
