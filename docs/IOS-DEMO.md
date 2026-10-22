# iPhone 相機辨識版：安裝與驗收

> **來源：** 移植自上游 `actiondarr/pathguide` 的 `docs/IOS-DEMO.md`（2026-10-20），
> 並**按本倉庫的實際 App 改寫**。上游原文描述的是它的「三 tab 導航殼 +
> 香港九類模型 + 門檻滑桿」版本，那些本倉庫**沒有採用**
> （理由見 `docs/UPSTREAM-MERGE-ASSESSMENT.md` §3、§5、§6）。
> 上游原文的「驗證紀錄」是他自己機器上的結果，**不能當成本倉庫的驗收證據**，
> 所以那張表已重寫（見 §6）。

App 啟動後直接是**首頁的兩個模式**：**引導**（相機即時辨識 + 粵語播報）
與**讀字**（辨識招牌文字）。

- **引導**：Android 與 iOS 都用原生相機 + 同一個裝置端 TFLite 模型（18 類）。
- **讀字**：**只有 Android 有實作**（ML Kit）。iOS 進入讀字頁會明確說
  「此平台或此來源不支援讀字」，不會靜默什麼都不做。
- 沒有門檻滑桿、沒有 FPS／推理耗時面板、沒有採集按鈕——那些是開發者要的，
  不是使用者要的；診斷資訊改寫進狀態檔與 logcat。
- 所有影像只在裝置上即時處理，**不錄影、不儲存照片、不上傳**。

---

## 1. 把程式交到 Mac

把專案的 `app/` 資料夾和本文件複製到 Mac，例如放在
`~/Developer/pathguide-iphone/`。保留 `app/assets/models/`（含
`detector.tflite` 與 `detector.json`）、`app/pubspec.yaml`、`app/pubspec.lock`。

**不要**複製：`app/build/`、`app/.dart_tool/`、`app/ios/Flutter/ephemeral/`、
`app/ios/Flutter/Generated.xcconfig`、`.tools/`（1.9 GB 的 Flutter SDK 與各種
快取）。這些會在 Mac 上重新生成。

> Windows 上能做的靜態檢查與自動測試見 §3；iOS 建置**必須**在 Mac 上跑。

---

## 2. Mac 準備

1. 安裝並啟動 **Xcode**，完成首次設定與 iOS 元件安裝。
2. 安裝 **Flutter 3.47.5 stable**（Dart 3.13.4，與本專案的
   `environment: sdk: ^3.13.4` 一致），或符合該約束的相容版本。
3. `flutter doctor -v`，完成 iOS toolchain 項目；依提示安裝 CocoaPods
   （`Podfile` 需要它拉 `TensorFlowLiteSwift`）。
4. 連上 iPhone，解鎖並「信任此電腦」，並在 iPhone 的
   「設定 → 私隱與保安 → **開發者模式**」打開開發者模式。

官方步驟：<https://docs.flutter.dev/platform-integration/ios/setup>

---

## 3. 先測試再建置

在 Mac 的 `app/` 資料夾：

```sh
flutter pub get
flutter analyze          # 必須 0 問題
flutter test             # 必須全綠
flutter build ios --debug --no-codesign
open ios/Runner.xcworkspace
```

`--no-codesign` 只驗證工程能否編譯，不能直接裝到 iPhone。

**Windows 上可以跑的部分**（本倉庫實測，見 §6）：

```powershell
. .\.env.flutter.ps1
cd app
flutter analyze
flutter test
```

---

## 4. 簽署並安裝

1. Xcode → Settings → Accounts 加入你的 Apple 帳戶。
2. Runner → Signing & Capabilities 勾「Automatically manage signing」，
   Team 選你的帳戶／Personal Team。
3. 保留 bundle ID `hk.pathguide.pathguide`；若該帳戶不能用，才在本機改成
   唯一的 ID，並同步改 RunnerTests 的 ID。
4. 選已連接的 iPhone 作為執行裝置，按 Run。
5. iPhone 若提示不信任開發者：設定 → 一般 → VPN 與裝置管理 → 信任。

免費 Personal Team 可做真機測試；本交付**不含** App Store／TestFlight 發佈。
最低 iOS 版本見 `app/ios/Podfile` 的 `platform :ios`（本倉庫為 15.0）。

請記錄實際的 iPhone 型號、iOS 版本、Xcode 版本與 Flutter 版本。

---

## 5. 驗收清單

> 每一條都對應**本倉庫真實存在**的介面。上游原文裡的
> 「首次啟動顯示導航首頁，三張未來功能卡均標示為開發中」
> 「技術資料展開後看 FPS」屬於上游的三 tab 版本，本倉庫沒有那些東西，
> 因此那幾條已刪除，不是漏寫。

**首頁**

- [ ] 啟動後直接停在首頁，只有 **2** 個可操作項：**引導**、**讀字**。
- [ ] 標題（App 名）不會讓 TalkBack／VoiceOver 多停一站。
- [ ] 每個按鈕都同時唸出「標籤 + 一句說明」，不必再滑一次去讀說明。

**引導模式**

- [ ] 進入後**立刻有一次語音回饋**（不是安靜兩秒才動）。
- [ ] 首次進入才要求相機權限；拒絕時給出**可操作的中文原因**並出聲。
- [ ] 允許後出現後置相機即時畫面；對準行人／單車／垃圾桶時顯示相符的
      繁體中文標籤，框與物件位置一致。
- [ ] 引導畫面只有 **3** 個控件：**開始引導 / 關閉語音 / 結束引導**。
      **沒有**採集按鈕、**沒有**門檻滑桿、**沒有** FPS 與推理耗時。
- [ ] 「關閉語音」會**立刻**停掉正在唸的那一句（不是等它唸完）。
- [ ] 按下「結束引導」後回到未啟動狀態，相機停止但**不重建**整個畫面。

**讀字模式（Android 才有）**

- [ ] 對準招牌／菜單／指示牌會逐句唸出（句與句之間有停頓）。
- [ ] 讀不到字時會**出聲說明**（「沒有看到文字」），而不是靜默。
- [ ] 畫面下方有「再讀一次」與「返回」兩顆按鈕。
- [ ] **iOS 上**進入讀字頁會看到「此平台或此來源不支援讀字」——
      這是預期行為（ML Kit 只在 Android 側接入），不是故障。

**語言與語音**

- [ ] 語音語言**跟隨手機系統語言**：zh-HK／yue-HK 系統說粵語，
      zh-CN 系統說普通話，英文系統說英語。
- [ ] 系統是 zh-HK 時，實際語音是 `zh-HK`（或 `yue-HK`），要**親耳**確認。
- [ ] 系統語言與實際語音不一致時，會先播一句「語音回退」提示
      （`ttsFallbackWarning`）。
- [ ] 若系統完全沒有中文語音，會退回英文**並照樣發聲**——本專案刻意選擇
      「用錯語言唸」而不是「不唸」，因為靜默無法與故障區分。

**生命週期與離線**

- [ ] 切到其他 App／鎖屏後停止辨識與播報；回到前景**自動恢復**。
- [ ] 使用者自己按「結束引導」後，回到前景**不會**被擅自重啟。
- [ ] 飛航模式下仍可完整演示（模型隨 App 打包，不解譯任何網絡請求）。
- [ ] 在最大字體（iOS 輔助使用 → 更大字體）與直向下，按鈕與提示不被截斷。

---

## 6. 驗證紀錄（本倉庫）

**2026-10-23，Windows／Flutter 3.47.5／Dart 3.13.4（本機實測）：**

| 項目 | 結果 |
|---|---|
| `flutter analyze` | **No issues found**（0 問題） |
| `flutter test` | **235** 條全部通過 |
| `pytest` | **436** 條全部通過（Python 側流水線與類別表契約） |
| 類別表 | **52 類**（v6）；`gen_dart_labels.py` 生成物與 `classes.json` 同步 |
| Android release APK | ✅ 構建成功，`versionName=2.0.0`（`versionCode=2`），含 18 類模型（2,873,120 B，與清單 `bytes` 一致） |
| Android 真機（相機 + 推理 + 粵語播報） | ⏳ **待驗收**：本次無可用 Android 裝置連上（`adb devices` 為空） |
| Mac iOS `--no-codesign` 建置 | ⏳ **待驗收**：本機為 Windows，無法執行 |
| iPhone 真機安裝與粵語播報 | ⏳ **待驗收** |

> 在上述兩項「待驗收」完成前，只能說
> **「iOS 側的 Swift 通道與 Dart 契約已對齊、Windows 靜態檢查與自動測試通過」**，
> 不能說「已在 iPhone 上驗證」。

---

## 7. Android 回歸驗收

自動測試能證明 Dart 契約與通道鍵名沒有漂移（`platform_mapping_test.dart`
驗證「模型與清單不符就拒絕啟動」），但**不能代替 CameraX 真機測試**。

在可用的 Android 手機上：

```powershell
. .\.env.flutter.ps1
flutter run -d <serial>            # 或裝已構建好的 APK
```

確認：相機權限、即時預覽、真實辨識框、粵語播報、兩模式切換、
切到背景再回前景後相機可重新開啟。

需要「裝包 → 授權 → 啟動 → 截圖 → 抓日誌」一條命令時：

```powershell
.\scripts\verify_on_device.ps1 -ApkPath <你的 apk 路徑>
```

---

## 8. 已知限制（寫在前面，避免當成故障）

| 限制 | 說明 |
|---|---|
| iOS **沒有讀字** | `readText` 只在 `VisionPlugin.kt` 實作；Dart 側 `supportsTextReading` 預設 `Platform.isAndroid` |
| 18 類中的多數類 | 只有 pedestrian／bicycle／bin 等少數類有足夠數據；`bicycle` 在播報門檻 0.70 處仍可能不出框（見 `docs/PROJECT-STATUS.md` §3） |
| 樓梯方向類（50/51） | 類別表 v5 已納入 `downstairs`/`upstairs`，但**當前端上模型沒有這兩類**，要等換模型才會出框 |
| 上游九類模型 | **未採用**。理由與前置條件見 `docs/UPSTREAM-MERGE-ASSESSMENT.md` §4 |
| 語速 | 固定 0.45，不可在 App 內調整（沒有設定頁）；請用系統的語速設定 |
