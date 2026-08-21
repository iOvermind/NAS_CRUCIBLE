# DEVELOPER.md

> 本文件規範Crucible專案的開發與架構細節。

## 1. 技術棧與系統需求
- **Bash**:最低版本需求為bash4.0+(因使用關聯陣列`declare -A`)。
- **作業系統**:Linux(建議TrueNASSCALE或Debian/Ubuntu)。
- **必備工具**:
  - `smartmontools`:用於執行`smartctl`讀取硬碟數據。
  - `e2fsprogs`:用於執行`badblocks`進行破壞性抹寫。
  - `jq`:最低版本需求1.6+，用於解析JSON數據。
  - `tmux`或`screen`:確保長期執行不斷線。

## 2. 環境建置
1. 取得原始碼:將`nas_crucible.sh`下載至目標Linux機器。
2. 賦予執行權限:執行`chmod +x nas_crucible.sh`。
3. 安裝依賴套件:執行`apt-get update && apt-get install smartmontools e2fsprogs jq tmux`。
4. 驗證環境:執行`jq --version`與`smartctl -V`確認有正常輸出。

## 3. 日常開發
- **啟動指令**:必須先執行`tmux`，接著以root權限執行`sudo ./nas_crucible.sh <硬碟代號>`(例如`sudo ./nas_crucible.sh sdb sdc`)。
- **除錯模式**:若需追蹤腳本執行，可在腳本開頭加入`set -x`。
- **錯誤訊息**:所有測試過程的log與JSON狀態皆會自動輸出至`/root/burnin_logs_<時間戳>`目錄下。

## 4. 目錄結構

```text
.
├── nas_crucible.sh - 主程式邏輯，包含前置檢查、測試流程與結果判定。
├── README.md - 使用者導向的操作說明。
└── DEVELOPER.md - 開發者導向的開發規範與架構說明。
```

## 5. 架構與關鍵設計決策
- **純Bash無額外語言依賴**:為了在TrueNAS等Appliance系統上達到最低相依性，捨棄Python等進階語言，確保隨插即用。
- **使用jq解析取代grep**:SMART數據格式易變，使用`grep`極易出錯，故強制依賴`jq`解析`smartctl -j`輸出的結構化JSON，確保狀態判定準確。
- **Fail-Closed嚴格判定**:任何通訊中斷、無法獲取數據或未預期錯誤，皆直接判定為FAIL。寧可誤殺，不讓有潛在暗傷的硬碟進入ZFS池。
- **強制tmux防呆**:全盤覆寫與LongTest需耗時數天，若SSH斷線將導致測試中斷，故強制排查環境變數阻擋一般終端機執行。

## 6. 測試
- **測試指令**:目前無自動化單元測試。需備妥全新或二手SATA傳統硬碟進行End-to-End手動測試。
- **略過測試條件**:由於腳本針對SATAHDD設計，若輸入SAS、NVMe或USB隨身碟代號，SMART讀取與判定邏輯將自動失敗或略過，無法完成完整流程。

## 7. 建置與產物
- **建置指令**:本專案為直譯腳本，無需編譯。
- **產物**:執行過程會於`/root/burnin_logs_<時間戳>`產生以下檔案:
  - `<SN>_baseline.json`:初始SMART狀態。
  - `<SN>_p1_start.log`與`<SN>_p3_start.log`:測試啟動紀錄。
  - `<SN>_p1_selftest.txt`與`<SN>_p3_selftest.txt`:測試結果紀錄。
  - `<SN>_badblocks.log`:覆寫進度。
  - `<SN>_final.json`:最終SMART狀態。

### 版本號同步清單
單一來源:`nas_crucible.sh`內的輸出字串。

| 位置 | 欄位 | 方式 |
| :--- | :--- | :--- |
| `nas_crucible.sh` | `BURN-IN FINAL RESULT (V5)`字串 | 手動(單一來源) |

## 8. 分支、commit與PR慣例
- **分支策略**:主分支為`main`，新功能開發請從`main`開出`feature/<功能名稱>`。
- **Commit格式**:遵循ConventionalCommits(如`feat:`、`fix:`、`docs:`)。

### 舊實作的保留規則
目前專案僅有Bash實作。若未來以其他語言(如Python)重構，舊有Bash版本必須以分支保留，禁止直接刪除。分支名稱必須為`legacy/bash-version`，並停止接受新功能，僅於重大Bug時修正。主分支將全面轉向新實作。

## 9. 安全與敏感資料
1. **機密不進版控**:測試產生的log包含硬碟真實序號(SN)，預設存於`/root`下不進專案目錄。專案的`.gitignore`必須排除`*.log`與`*.json`避免誤傳。
2. **權限最小化**:本腳本需操作底層區塊裝置`/dev/sdX`，故絕對要求`root`權限。刻意不實作掛載或卸載檔案系統的功能，避免誤動系統碟。
3. **依賴來源與鎖檔**:依賴Linux系統內建與官方Repo，無套件鎖檔機制，使用`apt-get`直接安裝。
4. **破壞性操作的保護**:腳本內含`badblocks -wsv`全盤覆寫，資料將徹底銷毀且無法還原。防護機制包含:排查OS掛載、排查ZFS池佔用，並於起飛前強制要求使用者手動輸入`YES`確認。

## 10. 已知陷阱
#### 執行時提示缺少jq或SMART判定為ERROR
- **症狀**:出現`❌ 錯誤：未安裝 jq`，或是測試環節不斷回報`FAIL_COMM`。
- **原因**:基礎OS環境(如某些精簡版Debian)未內建`jq`，或硬碟採用USB轉接導致`smartctl`無法取得正確狀態。
- **處置**:以root身分執行`apt-get install jq`安裝依賴;並確保所有待測硬碟皆原生直連主機板SATA埠。

#### 執行腳本立刻跳出警告並結束
- **症狀**:出現`⚠️ 警告：必須在 tmux 或 screen 環境下執行，避免斷線導致進度全毀！`。
- **原因**:直接透過SSH連線執行，不符合腳本的防護要求。
- **處置**:先輸入`tmux`進入多工環境後，再執行腳本。
