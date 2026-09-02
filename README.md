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
5. 危險或不可測的硬碟會標示原因：`[BOOT]` 開機媒體本身、`[MOUNTED]` 已掛載、`[ZFS]` 在 ZFS Pool 內、`[LVM/RAID]` 被上層儲存堆疊佔用、`[DATA]` 碟上有既有資料。

### 方式二：直接指定硬碟 (CLI)

1. 傳入硬碟代號 (不含 `/dev/`)：
   ```bash
   sudo ./crucible.sh sdb sdc sdd
   ```
2. 腳本會自動檢驗硬碟身分、匹配對應的測試策略，並要求你輸入 `YES` 確認。
3. 測試啟動後，可以放著讓它跑 (通常需數天)。你可以隨時 detach (`Ctrl+b`, `d`)。
4. 測試完成後會印出最終表格，所有測試紀錄與 JSON 證據皆會保存在 `logs/<timestamp>/` 目錄中。

## 硬碟為什麼被擋下

工具只會對「確定可以抹除」的硬碟動手。任一顆碟不合格時，**只有那一顆會被擋，
其餘照常受測**，最終表格會列出每顆碟被擋的原因：

| 標示 | 意思 | 怎麼處理 |
| :--- | :--- | :--- |
| `BOOT_MEDIUM` | 這就是你正在用來開機的那顆碟 | 換一顆碟測 |
| `MOUNTED` | 已掛載，正在使用中 | 先卸載 |
| `ZFS_POOL_MEMBER` | 屬於已匯入的 ZFS pool | 先匯出 pool |
| `STORAGE_HOLDERS` | 被 LVM / mdraid / LUKS 佔用 | 先停用上層裝置 |
| `NO_POLICY` | 認不出這是哪一類硬碟 | 確認 `smartctl -i` 讀得到轉速與協議 |
| `DUPLICATE_SERIAL` | 兩顆碟回報同一個序號，證據會互相覆寫 | 一次只測其中一顆 |
| `HAS_DATA` | 碟上有既有的檔案系統或 RAID/ZFS/LVM 殘留 | 見下方 |

### `HAS_DATA`：二手碟、退役碟要怎麼測

這是唯一可以解除的一條。工具會逐碟詢問，**輸入該碟的序號**才會解除封鎖：

```
⚠️  下列硬碟偵測到既有資料簽章 (檔案系統 / ZFS / LVM / mdraid 成員)。
    確定要抹除的話，請逐碟輸入該碟序號解除封鎖；直接 Enter 維持封鎖。
    /dev/sdb (SN: WD-ABC123456) 輸入序號以解除:
```

沒有「一次全開」的旗標，這是刻意的設計。非互動執行 (例如從腳本呼叫) 一律維持封鎖。
被解除的硬碟在最終報表上會帶 `(OVERRIDE)` 標記，事後看得出來這顆碟是被強制放行的。

## 開發與維護
如需了解系統架構或進行擴充，請參閱 [DEVELOPER.md](DEVELOPER.md)。
