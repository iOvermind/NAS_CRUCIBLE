# NAS_CRUCIBLE 待辦事項 (TODO)

## UI / UX 改善
- [ ] **互動式硬碟選擇介面 (TUI)**
  - 取代手動輸入參數 (`./crucible.sh sdb sdc`)。
  - 當不帶參數執行主程式時，自動掃描系統硬碟。
  - 提供類似 `whiptail`、`dialog` 或 `fzf` 的終端機互動介面。
  - 支援使用**方向鍵**上下移動、**空白鍵**勾選/取消勾選要測試的硬碟、**Enter鍵**確認送出。
  - 介面上應過濾或標示出已掛載 (Mounted) 或在 ZFS Pool 內的危險硬碟，避免誤選。

## 架構與功能擴展
- [ ] 實作 NVMe SSD 的測試策略與 Adapter (`nvme-cli`)。

## 測試模式擴展
- [ ] **支援非破壞性檢測模式 (Read-Only / Live Check)**
  - 目前系統為嚴格的 Fail-Closed 破壞性測試，硬碟若已掛載會被阻擋。
  - 新增針對「已掛載 (Mounted) 且正在使用中」硬碟的非破壞性 Policy (例如僅擷取快照或執行背景 SMART Long Test，不跑 badblocks)。
  - 需小心設計，避免非破壞性檢測影響線上服務的 I/O 效能。
