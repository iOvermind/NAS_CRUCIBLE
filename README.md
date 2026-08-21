# Crucible

> 針對 SATA 傳統硬碟設計的破壞性驗收腳本。透過自動化全盤抹寫與嚴格的 SMART 檢測，剔除帶有暗傷的硬碟，確保 Zpool 的資料安全。

## 這是什麼 / 能做什麼

Crucible 是一套硬碟上線前的嚴格測試流程（Burn-in）。它會對硬碟執行高強度的實體壓力測試，並在測試前後擷取狀態進行比對。

主要功能與驗收標準：
- **環境防呆**：自動阻擋已掛載或存在於活躍 ZFS Pool 中的硬碟，防止誤殺。
- **實體破壞性測試**：透過 `badblocks -wsv` 執行全盤四次覆寫與讀取測試。
- **嚴格驗收（Fail-Closed）**：只要出現以下任一情況即判定不合格（FAIL）：
  - SMART 總體健康狀態異常
  - 出現壞軌（Reallocated Sector 或 Pending Sector 大於 0）
  - 出現離線無法修復區塊（Offline Uncorrectable 大於 0）
  - 測試前後的 CRC 錯誤次數增加
  - 測試前後的 SMART Error Log 筆數增加
  - SMART Long Test 或 badblocks 執行過程異常或中斷

## 取得與安裝

本腳本為單一 Bash 檔案，無需編譯即可執行。不適用於 SAS 或 NVMe 磁碟。

**環境需求**：
- Linux 作業系統（如 TrueNAS SCALE 或 Debian/Ubuntu）
- 必須以 `root` 權限執行
- 必須安裝 `jq` 套件
- 必須在 `tmux` 或 `screen` 環境中執行，避免斷線導致測試中斷

**相容性對照**：

| 介面 / 類型 | 支援狀態 | 說明 |
| :--- | :--- | :--- |
| SATA HDD | 支援 | 本腳本專為 SATA 傳統硬碟設計 |
| SATA SSD | 不建議 | 破壞性覆寫會過度消耗 SSD 壽命 |
| SAS HDD / SSD | 不支援 | 底層通訊與錯誤紀錄判定邏輯不同 |
| NVMe SSD | 不支援 | 採用的 SMART 屬性定義完全不同 |

## 快速開始

確保你已經進入 tmux 或 screen 環境，並確認要測試的硬碟代號（如 `sdb`、`sdc`，不需要加上 `/dev/`）。

```bash
chmod +x nas_crucible.sh
./nas_crucible.sh sdb sdc
```

執行後，腳本會列出即將被**全盤抹除**的硬碟型號與序號，需手動輸入 `YES` 才會正式開始。整個流程依硬碟容量可能耗時數天。

## 常見問題 / 疑難排解

- **顯示「必須在 tmux 或 screen 環境下執行」被拒絕？**
  這項測試通常需要跑好幾天，為了防止 SSH 斷線導致進度消失，腳本強制要求使用終端機多工器。請輸入 `tmux` 啟動環境後再執行腳本。
- **顯示硬碟「目前被 OS 掛載」或「出現於活躍的 ZFS Pool」？**
  腳本內建安全機制。如果你確定要抹除該硬碟，請先從 TrueNAS 介面將該 Pool 匯出（Export/Disconnect），或手動卸載分割區。
- **最後判定 FAIL，顯示 `RC:64` 或其他數字是什麼意思？**
  這是 `smartctl` 的底層狀態碼，例如 `64` 代表 Error Log 有新增錯誤。詳細的錯誤原因，請至 `/root/burnin_logs_<時間戳>` 目錄下查看對應硬碟的 JSON 與 log 實體檔案。

## 授權

本專案採用 GNU 通用公眾授權條款第三版（GNU General Public License v3.0, GPL-3.0）。你可以自由使用、修改與散布本軟體，但修改後的衍生版本亦必須以相同授權開源。

請注意**本腳本具備資料破壞性**，本軟體依 GPLv3 條款「現狀（AS-IS）」提供，作者對任何資料遺失或硬體損壞不承擔任何法律與擔保責任。詳細條款請參閱 [LICENSE](LICENSE) 檔案。

## 開發者入口

想了解如何建置開發環境、修改程式碼、執行測試或了解架構決策，請參閱 [DEVELOPER.md](DEVELOPER.md)。
