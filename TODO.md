# NAS_CRUCIBLE 待辦事項 (TODO)

## UI / UX 改善
- [x] **互動式硬碟選擇介面 (TUI)**
  - 取代手動輸入參數 (`./crucible.sh sdb sdc`)。
  - 當不帶參數執行主程式時，自動掃描系統硬碟。
  - 提供類似 `whiptail`、`dialog` 或 `fzf` 的終端機互動介面。
  - 支援使用**方向鍵**上下移動、**空白鍵**勾選/取消勾選要測試的硬碟、**Enter鍵**確認送出。
  - 介面上應過濾或標示出已掛載 (Mounted) 或在 ZFS Pool 內的危險硬碟，避免誤選。

## 架構與功能擴展
- [x] **實作 NVMe SSD 的測試策略與 Adapter (`nvme-cli`)**
  - `policies/nvme_ssd.json`：critical_warning / available_spare / media_errors /
    percentage_used / num_err_log_entries 的裁決規則。
  - `adapters/nvme_smart_long_adapter.sh`：以 `nvme device-self-test` 啟動與中止，
    以 `smartctl -j -l selftest` 輪詢。
  - 尚待真機驗證：目前僅以 stub 測試覆蓋，需在有 NVMe 的機器上跑一次完整流程。
- [ ] **NVMe self-test「完成但有錯誤」目前只記錄在 observation，未直接判 FAIL**
  - 與 `smartctl_long_adapter` 行為一致（交由 verdict_engine 從 SMART 快照裁決）。
  - 若要更嚴格，應同時修改兩個 adapter，避免協議間標準不一致。

## 測試模式擴展
- [ ] **支援非破壞性檢測模式 (Read-Only / Live Check)**
  - 目前系統為嚴格的 Fail-Closed 破壞性測試，硬碟若已掛載會被阻擋。
  - 新增針對「已掛載 (Mounted) 且正在使用中」硬碟的非破壞性 Policy (例如僅擷取快照或執行背景 SMART Long Test，不跑 badblocks)。
  - 需小心設計，避免非破壞性檢測影響線上服務的 I/O 效能。

## Roadmap: 可開機映像 (Bootable Burn-in Media)

**目標**：插 USB 開機即進入 NAS_CRUCIBLE，與主系統完全隔離，操作體驗類似 memtest86。

### 架構決定：走 minimal Linux live image，不走裸機 EFI application
memtest86 是不含作業系統的 EFI 應用程式，自行驅動硬體。若照抄該架構，等同要用 C
重寫 NVMe/AHCI 驅動、SMART 命令與 badblocks，並且會失去 `lsblk` / `findmnt` /
`zpool` 這些 admission 階段賴以判斷「此碟能否抹除」的安全檢查——與本專案的
Fail-Closed 核心直接抵觸。因此採用極簡 Linux live image (GParted Live / Clonezilla 路線)，
使用者體驗相同，但整套 Bash + smartmontools 工具鏈可原封不動沿用。

註：「打包成單一二進位」對 Bash 專案沒有意義，最終產物是 `.img` / `.iso`。

### 候選建置方式
- **Alpine + `mkimage.sh`**：約 80-150MB，開機快；apk 有 smartmontools / nvme-cli / jq /
  e2fsprogs。風險：busybox 的 `lsblk` / `findmnt` 功能較弱，`precheck_adapter` 可能需調整。
- **Debian + `mkosi` 或 `debootstrap` + `systemd-boot`**：約 300-500MB；工具鏈與現行開發
  環境完全一致，`precheck_adapter` 無須修改，ZFS 支援較完整。

### 開工前必須先解決的設計問題
- [ ] **Evidence 持久化**：live rootfs 在 RAM，重開機證據全失。3-5 天的測試不可接受。
      需在 USB 上規劃持久分區掛載至 `logs/`，並處理掛載失敗時的 Fail-Closed 行為。
- [x] **live 環境下的 ZFS admission 衝突**：已由 `lib/device_probe.sh` 的
      `dev_in_zpool` 解決。判斷依據改為「`zpool` 指令是否存在」：指令不存在
      代表系統上不可能有已匯入的 pool，回傳「確定不屬於」而非查詢失敗；
      只有在 `zpool` 可用但查詢失敗時才回傳「無法判定」並維持 rc=2。
      對線上碟的保護沒有鬆脫 —— 有 ZFS 的環境行為完全不變。
- [ ] **live image 是否安裝 zfsutils**：承上，若 live image 內裝了 `zpool`
      但沒有匯入任何 pool，`zpool status` 的回傳碼需要實機確認 (無 pool 時
      是否為 0)。若非 0 則會退回「無法判定」而擋下所有碟。尚未實機驗證。
- [ ] **`tmux` / `screen` 強制檢查**：console 上無 SSH 斷線風險，此防呆失去意義，
      但仍應保留多 TTY 以便觀察。啟動流程需改寫。
- [ ] **Secure Boot**：自建 kernel 無簽章，開啟 SB 的機器無法開機。
      需決定走 shim + 自簽金鑰，或於文件中要求使用者關閉 SB。

