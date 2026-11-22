# 場景模式交接：複雜廚廁場景拒絕（2026-11-09）

本文件由使用者明確要求，交畀下一個工作視窗／Windows 環境繼續處理。本輪只讀取安全狀態、核對程式及整理交接，沒有修補、部署、安裝、修改額度或付費模型請求。請先讀本檔及 AGENTS.md；現行規格仍以 docs/FRONTEND-DESIGN.zh-HK.md、docs/BACKEND-DESIGN.zh-HK.md 為準。

## 接手目標與最新真人結果

使用者最新回報：「現在在房間裏能夠順利播出讀音，但在更複雜的場景例如廁所或廚房會顯示回覆格式不符或內容含受限字句」。下一步應修復這兩種拒絕，維持完整輸出驗證及語音有效性保護；不是重做 UI，也不是先修 TTS 或加額。

- 房間場景已有真人語音成功；不代表複雜場景、內容準確率、走動延遲或 VoiceOver 已通過。
- IMG_2177.PNG：廚房／門口雜物場景；自動開關開啟，顯示「連續回覆未符合要求，暫停新分析」，後端拒絕 answer-format、未交予播音；畫面累計25／50，許可餘25。
- IMG_2178.PNG：廁所場景；自動開關開啟，顯示「回覆未符合要求；等候新環境，不重傳同一畫面」，後端拒絕 disallowed-content、未交予播音；畫面累計26／50，許可餘24。
- 兩圖沒有展開「場景測試資料」，看不到 rejectionDetail、requestId、原始模型輸出。不能從照片推定是哪個字或哪個 JSON 欄位失敗。
- 原圖僅在使用者私人 Mac：`/Users/darr/Downloads/IMG_2177.PNG`、`/Users/darr/Downloads/IMG_2178.PNG`。沒有複製／上傳到 Git；下一部機不會自動取得。需要照片時由使用者重新提供，不要把它們加入公開倉庫、訓練或付費重播。

## 最新只讀狀態（不是截圖當刻）

核對時間：2026-11-09 03:03:43 香港時間（2026-11-08T19:03:43.148Z）。機械證據：`verification/scene-complex-handoff-20261109.json`。

| 項目 | 值 |
|---|---|
| App | 已裝機 1.10.1+25；最新圖片沒有版本欄，尚未另作新版本核對 |
| 累計次數／上限 | 32／50，名義餘18；不是截圖中的25／26 |
| 已估算使用／總額 | 13331／500000 microUSD，即 US$0.013331／US$0.50 |
| 下一次保守預留 | 2458 microUSD，足夠 |
| 帳本 | fingerprint 相符、無 inFlight、lastStatus complete、window ready |
| 停止原因 | 只讀 inspect 為 null，窗口未到期，冷卻已過 |
| 許可到期 | 2026-11-09 12:06:25 香港時間；不要默認續期 |
| 最近三結果 | 均 complete：模型2268／2510／2403ms；不是全流程起音時間 |

`halted=true` 是保留舊停止歷史的設計，現有 ready window 可在限額內繼續，不能單憑 halted 判斷被封。最新三條成功已覆蓋較早25／26次失敗，不能用它們證明拒絕根因。

使用者已明確批准估算總預算 US$0.50（上一輪美元問題之後回覆「總預算$0.5」），累計上限仍50、原到期不變。原 count／花費／IDs／未知用量及 recovery 歷史均保留。費用為工程估算停止策略，不是供應商帳單硬上限；Firebase費用另計。不要清零、退回拒絕嘗試花費、擴大次數或自動解除未知用量停止。

## 版本與部署

- Repo：https://github.com/actiondarr/pathguide
- Branch：`feature/cross-platform-navigation`。
- 最新 App 原始碼：`7525a486d442d30673f15f50c591072fbf9d28d5`；不可變 tag `v1.10.1+25`。
- Release：https://github.com/actiondarr/pathguide/releases/tag/v1.10.1%2B25
- 裝機／額度證據提交：`c8765302fa2dd78e571c652dd63c9f5ec321c884`；本交接所在提交在其後。
- `verification/release-receipts/app-1.10.1+25.json`、`verification/scene-rejection-budget-20261109.json` 保存簽章、模型 SHA、來源核對及審計 CAS。
- Firebase `pathguide-dev`，function `describeScene`、asia-east2、Node22、timeout40s、maxInstances2；Qwen Singapore、固定 qwen3-vl-plus、Secret Manager v2；Auth／App Check／指定帳戶／active／刪除阻擋保持。
- 私人 Profile 工程包含已註冊 App Check debug 配置，不能當 GitHub 資產上傳。正式 DeviceCheck 尚未驗收。

## 程式位置與目前資料流

| 路徑 | 接手重點 |
|---|---|
| `backend/functions/scene_description.js` | `validateText`、`renderAnswer`、`validateObservations`、server-owned prompt、`safeResult`、`readStatus`、最近結果 transaction |
| `backend/functions/scene_trial.js` | configure／assess／allocate／inspect／settle，跨日限額、fingerprint、window、未知用量停止 |
| `backend/functions/scene_function.js` | callable，只有確認供應商前失敗才附 beforeProvider／stopReason／limits |
| `app/lib/scene/scene_backend.dart` | SceneReply、SceneObservation、語意 key、本機完整驗證、狀態／拒絕細項 allowlist、Firebase adapter |
| `app/lib/scene/live_scene_controller.dart` | `_rejectedReplies`、兩次拒絕後受限、首次／更新、作廢、去重、診斷及恢復 |
| `app/lib/ui/demo_page.dart` | 現有測試 UI、共用相機、讀取安全狀態、語音路由；暫不改正式單開關 |
| `app/lib/tts/speech_coordinator.dart` | 導航優先、只播最新仍有效內容 |

v2 一張當前 JPEG → overview兩至三句／update一句＋observations → 伺服器整段驗證 → 手機整段驗證／本機重點比較 → TTS。只傳當前照片，不把舊文字／照片交雲端。觀察／描述只在手機短期記憶；伺服器只保存三個數值／固定原因結果。進頁 `operation:status` 不取相、不讀 provider key、不呼叫模型、不預留試驗次數；仍有一般 Firebase 請求。

現有 prompt 要求最多三項觀察，驗證仍允許最多六項。category 僅 person／door／stairs／table／chair／passage／vehicle／sign／other；position 僅 left／centre／right。detail≤40字、無句號、同類同位置不可重複；句數、長度、繁體與禁止內容均驗證。廚廁有櫃、洗手盆、馬桶、洗衣機、爐具等，但 taxonomy 未單列它們：可用 other，不能因此宣稱它們本來不可描述。

## 已確認問題、待驗假設

1. **已確認：最新 raw lastResult 有舊拒絕欄位殘留。** 最新 requestId `505957433004eb4d5e0a24dd9150c746` 為 status complete，但 raw lastResult 同時含 rejectionReason disallowed-content／rejectionDetail text-content；recentResults 對應成功項沒有這些欄位。程式以 `tx.set(...,{merge:true})` 寫 lastResult，成功時省略拒絕鍵，Firestore 巢狀 map merge 可能保留舊鍵。此寫法與讀回不一致直接吻合，優先修補並加能模擬 Firestore 遞迴 merge 的測試。現有 fake DB 只做頂層 merge，未捕捉這個問題。不能把殘留 text-content 當最新成功或截圖25／26次的拒絕原因。`safeResult` 讀回時按 status 過濾，故不代表本機新成功回覆一定被拒。
2. **待驗：觀察格式。** 未支援 category／position、同類同位置重複、detail標點、缺／多欄位都可能使整段 answer-format；複雜物件較多只是線索，未確認是哪項。
3. **待驗：禁字誤擋。** `validateText`／手機 counterpart 用整段 regex；例如「米」會連正常「米缸」也擋，「層」可能擋「多層架」。這是程式可重現的假陽性候選，不是兩張截圖的已確認觸發詞。禁止推測距離／樓層／安全通行／避障指令仍要保留；不要全刪禁字。
4. **已確認行為：連續兩次 rejected 後 restricted。** 這能解釋第一圖的「暫停新分析」，不代表預算用盡。單次失敗等候新環境，不對同一畫面再付費；未知付費結果立即受限，不自動重傳。

## 建議接手次序

1. 同步分支、讀 AGENTS.md 及上述兩份現行文件，確認最新只讀狀態／到期；不要重設 ledger，也不要先發模型請求。
2. 先修 lastResult 的巢狀 merge 殘留，明確替換完整子 map 或刪除舊拒絕鍵；保持其他 counter／recentResults 欄位。用真實 merge 語意驗證 rejected→complete 沒有舊原因；同時檢查最近三次歷史與帳戶刪除防護。
3. 下次拒絕立即從「複製測試資料」取 `requestId`、`rejectionDetail`、模式／時序及最近結果。最新三條已覆蓋舊失敗，現時不能還原；不要為找舊錯誤亂查／保存原圖或原始回答。
4. 以合成非私人 fixture 離線重現正常廚廁名詞、category=other、合法位置、重複觀察及 detail 標點等；區分 JSON 結構問題與文字內容問題。只有有證據的格式偏差才做安全正規化／契約改動，後端與手機驗證同步。
5. 對禁詞改為能區分正常名詞與距離／導航／安全指令的限制；合法「米缸／多層架」與不合法米數、樓層推測、安全通行、方向指令一起回歸。不能只刪 guard，不能只改 prompt 便宣稱修好。
6. 保留 overview2–3句／update1句、完整驗證、不讀半段、一次在途、原花費／未知停止、正常走動／轉向撤舊、背景需重開、普通物件語音讓位／導航優先等既定行為。
7. scoped tests／analyze／文件／證據→來源提交／推送核對。任何新手機版須新版本、不可變 tag及Release先核遠端，然後在Mac簽署／安裝；不要移動1.10.1+25 tag。
8. 真人複測房間、廚房、廁所：記錄首次概述、更新句、拒絕細項、重複／漏講／過時、從變化到相關聲音起播；截圖或模型耗時不能代替內容與起音驗收。不要再把房間成功當全場景通過。

## 驗證與環境注意

上一輪正式檢查：Flutter591通過／7項flag-off略過；flag-on相關98；後端44；analyze、私人Profile／deep strict簽章及四模型SHA通過。Swift／模型未改，原生測試未重跑。本輪交接未重跑測試，也沒有宣稱新拒絕已修好。

```sh
# 在 app 目錄（Windows 可用 flutter/dart，shell語法自行對應）
flutter analyze --no-pub
flutter test --no-pub
flutter test --no-pub --dart-define=SCENE_DESCRIPTION_ENABLED=true test/scene_mode_test.dart test/live_scene_test.dart test/scene_description_test.dart test/speech_coordinator_test.dart test/ios_demo_test.dart
# 在 repo 根目錄；Node須能載入sharp
node --test backend/functions/test/scene_description.test.cjs backend/functions/test/scene_trial.test.cjs backend/functions/test/scene_mode.test.cjs backend/functions/test/scene_provider_probe.test.cjs
```

Mac路徑：`/Users/darr/Desktop/development/pathguide-iphone-demo-source`。該機 shell 沒有一般 node/firebase 命令，已用可載入 sharp 的 Node：`/Users/darr/Library/Application Support/dsh-desktop/harness/.desktop-bin/node`；這只是本機執行檔，不得向 DSH 模型派工。

Windows 若指真正作業系統：可做 Dart／Node 離線開發及相關測試，iOS簽署、devicectl、真機安裝仍需Mac。不要把 Mac 的私人 debug define、Firebase 登入 token、UID、Secret 值或 /tmp 操作檔搬入Git。現有私人 build define 在 Mac `/tmp/pathguide-scene-data-build-defines.json`；單用 app/config/firebase.local.json 會漏場景／debug旗標，不能直接當等效交付配置。

工作樹有大量不屬本任務的 dirty／untracked 工作：backend/functions/index.js、backend package/lockfiles、Firestore規則相關、photo_review/workbench、dataset_pipeline，以及四份 docs 的其他改動。不要 stash／reset／clean／整批 stage。文件需只 stage 自己的差異；必要時對 HEAD 套同一 transform 用 git update-index，保留工作樹其他修改。

不應做的事：把「暫未辨識到支援物件」當成場景拒絕根因（這是另一條本機 detector 提示）；把原始場景內容存日誌；上傳私人圖片；放寬Auth/App Check；清零試驗；自動重播付費請求；把上述假設寫成已證明結論。
