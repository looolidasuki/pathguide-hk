# Domain Docs

## 文件結構

採用 single-context，沿用以下文件作為產品及技術依據：

- docs/APP-FEATURES.zh-HK.md：完整產品願景，不代表已實作狀態。
- docs/FRONTEND-DESIGN.zh-HK.md：App 行為、裝置端、導航及驗收。
- docs/BACKEND-DESIGN.zh-HK.md：服務契約、雲端、交付及回退。
- docs/DATASET-REVIEW.zh-HK.md：類別字典、資料、模型品質及訓練。

## 閱讀及維護規則

- 探索程式前，先讀 AGENTS.md 及工作範圍相關的既有文件。
- 跨元件工作須讀取並維護所有受影響文件。
- 使用既有文件定義的術語；區分產品願景、計劃、本機測試及真機驗收。
- 若根目錄已有 GLOSSARY.md，讀取相關術語；若已有 ADR，讀取相關決策。
- GLOSSARY 或 ADR 不存在時直接繼續，不主動要求或建立。
- 遵守現有文件數量限制，將新術語及決策更新至相關既有文件。
- 與既有決策矛盾時，明確指出衝突及變更理由。
- docs/agents/ 僅保存技能設定，不保存重複的產品、進度或技術文件。
