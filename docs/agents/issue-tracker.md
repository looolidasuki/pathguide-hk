# Issue tracker: GitHub

本專案的工作項目及規格存放在 actiondarr/pathguide 的 GitHub Issues。
在專案根目錄使用 gh CLI，並明確指定 --repo actiondarr/pathguide。

## 操作規則

- 確認目標：gh repo view actiondarr/pathguide --json nameWithOwner,url
- 建立：gh issue create --repo actiondarr/pathguide --title "..." --body-file <file>
- 讀取：gh issue view <number> --repo actiondarr/pathguide --json number,title,body,labels,comments
- 列出：gh issue list --repo actiondarr/pathguide --state open --json number,title,labels
- 修改：gh issue edit <number> --repo actiondarr/pathguide
- 留言：gh issue comment <number> --repo actiondarr/pathguide --body-file <file>
- 關閉：先記錄結果及驗收證據，再使用 gh issue close。
- 2026-11-05已確認：每票檢查及覆核通過後，先commit／push相關程式、文件及證據並核對遠端，再更新完成狀態。原始碼保存不等於App裝機版；手機版依AGENTS.md另建不可變tag／prerelease。
- 多行內容寫入暫存檔，使用 --body-file 傳入。
- 子工作優先使用 GitHub 原生 sub-issues；不支援時以 Part of #<number> 關聯。
- 阻擋關係優先使用原生 issue dependencies；不支援時在內文記錄 Blocked by: #<number>。
- 發佈至 issue tracker 表示建立 GitHub Issue；讀取 ticket 表示讀取對應 Issue。
- Issue 用於追蹤工作；產品與技術現況仍維護在既有文件。
- 遵守 AGENTS.md 的資料保護規則，不得把私人照片、憑證或私人評估內容寫入公開 Issue。

## Pull requests as a triage surface

PRs as a request surface: no.
