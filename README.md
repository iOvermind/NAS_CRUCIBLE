# NAS_CRUCIBLE (儲存裝置破壞性測試框架)

NAS_CRUCIBLE 是一個全自動、Fail-Closed 的儲存裝置破壞性燒機 (Burn-in) 測試框架。旨在為 NAS 或伺服器建置前，對全新的硬碟進行最嚴格的物理壓力測試，找出潛在的故障品 (Infant Mortality)。

## ⚠️ 警告：破壞性測試
本工具包含 `badblocks -wsv` 全盤寫入測試。**將會無條件抹除硬碟上的所有資料！** 絕對不可以在存有重要資料的硬碟上執行。

## 支援的硬體
- SATA HDD (完整支援)
- SAS HDD (完整支援)
- SATA SSD / SAS SSD (透過策略跳過抹除，僅測試)
- NVMe SSD (透過策略跳過抹除，執行 NVMe Device Self-test；需額外安裝 `nvme-cli`)

## 系統需求
- Linux (Debian/Ubuntu 推薦)
- 必須以 `root` 身分執行
- 必須在 `tmux` 或 `screen` 中執行 (測試需耗時 3-5 天)
- 依賴套件: `smartmontools`, `e2fsprogs`, `jq`, `whiptail`
- 測試 NVMe 裝置時另需 `nvme-cli`

```bash
apt install smartmontools e2fsprogs jq whiptail nvme-cli
```

## 使用方式

### 方式一：互動式選碟 (TUI)

1. 確保所有要測試的硬碟是**全新或已備份**的，且**尚未被掛載**。
2. 啟動 tmux：
   ```bash
   tmux new -s burnin
   ```
3. 不帶參數執行，自動進入互動式選碟介面：
   ```bash
   sudo -E ./crucible.sh
   ```
4. 使用**方向鍵**上下移動、**空白鍵**勾選/取消要測試的硬碟、**Enter** 確認送出。
5. 已掛載或在 ZFS Pool 內的硬碟會以 `[MOUNTED]`/`[ZFS]` 標示。

### 方式二：直接指定硬碟 (CLI)

1. 傳入硬碟代號 (不含 `/dev/`)：
   ```bash
   sudo ./crucible.sh sdb sdc sdd
   ```
2. 腳本會自動檢驗硬碟身分、匹配對應的測試策略，並要求你輸入 `YES` 確認。
3. 測試啟動後，可以放著讓它跑 (通常需數天)。你可以隨時 detach (`Ctrl+b`, `d`)。
4. 測試完成後會印出最終表格，所有測試紀錄與 JSON 證據皆會保存在 `logs/<timestamp>/` 目錄中。

## 開發與維護
如需了解系統架構或進行擴充，請參閱 [DEVELOPER.md](DEVELOPER.md)。
