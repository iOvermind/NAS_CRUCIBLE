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

**目標**：插 USB 開機即進入 NAS_CRUCIBLE，與主系統完全隔離，可對 SATA / SAS / NVMe
的 HDD 與 SSD 做燒機，BIOS 與 UEFI 皆可開機。操作體驗類似 memtest86。

### 架構決定
走極簡 Linux live image，不走裸機 EFI application。memtest86 是不含作業系統的 EFI
應用程式；照抄該架構等同要用 C 重寫 NVMe/AHCI 驅動與 SMART 命令，並且會失去
`lsblk` / `findmnt` 這些 admission 賴以判斷「此碟能否抹除」的檢查 —— 與 Fail-Closed
核心直接抵觸。

已定案的技術選擇記錄於 ADR：
- [0001](docs/adr/0001-signature-as-primary-admission-defence.md) 以碟上靜態 Signature 作為 admission 主防線
- [0002](docs/adr/0002-debian-stable-signed-boot-chain.md) Debian stable + 官方簽章開機鏈
- [0003](docs/adr/0003-first-boot-auto-partition-and-no-persistence-fallback.md) 首次開機自動建 Evidence Store 與 No-Persistence 降級

其餘定案：Live 內 tty1 自登入 → fbterm (中文字型) → tmux → TUI，tty2-6 保留 shell；
v1 完全無網路；只支援直通裝置，RAID 卡後面的實體碟明確不支援；ISO 內程式碼一律
取自 `git archive HEAD` 並寫入 `build_info.json`。

### M1: 安全底座 (已完成)
Live 開機會讓「已掛載 / ZFS pool / LVM holders」三道既有防線同時歸零，必須先補上
不依賴執行時狀態的防線，再談開機映像。
- [x] `dev_has_signature`：以 FSTYPE / PTTYPE 判定碟上是否曾被寫入資料
- [x] `detect_boot_medium` / `dev_is_removable` / `is_live_environment`：開機媒體自我排除，
      反查失敗時退化為「排除全部 removable」
- [x] admission 改為部分放行：問題碟標 `decision=BLOCK` 並記錄 `block_reason`，
      其餘照跑，不再整批 `exit 2`
- [x] Override：逐碟輸入序號才能解除 Signature 造成的封鎖，非互動情境一律維持封鎖
- [x] 序號重複改為兩顆都擋 (證據歸屬無法分辨)，而非整批中止
- [x] `tests/test_admission.sh` 鎖住上述全部行為

### M2: 可開機映像
- [ ] `build/` 目錄：Dockerfile + build_iso.sh，宿主只需 docker
- [ ] Debian stable live-build，含 smartmontools / nvme-cli / jq / whiptail / util-linux
- [ ] BIOS (isolinux) + UEFI (grub-efi) 雙開機，`shim-signed` 支援 Secure Boot
- [ ] fbterm + fonts-wqy-zenhei，tty1 自登入後進 tmux 跑 TUI
- [ ] 首次開機自動在開機碟尾端建立 ext4 Evidence Store 與小容量 FAT32 摘要分區
- [ ] 建不出來時降級 No-Persistence Mode，於 TUI 首頁、確認頁、進行中狀態列全程警告
- [ ] Summary Report 渲染器：每顆碟判定完就從 logs/ 重新產生一次 (中途斷電也有部分摘要)
- [ ] `build_info.json` 與 Evidence 帶上 commit hash (會動到五支 adapter 的 evidence 契約)
- [ ] `tests/test_build_contract.sh`：不建置的靜態檢查 (套件清單、grub 兩條開機路徑)

### M3: QEMU 測試層
- [ ] `tests/run_iso.sh`：UEFI (OVMF) / Secure Boot / Legacy BIOS 三條開機路徑都要進得到 TUI
- [ ] 驗自動建分區並在重開機後仍掛得到
- [ ] 驗開機碟不出現在可測清單
- [ ] 驗預先寫入 ext4 / zfs_member 簽章的虛擬碟被標 HAS DATA 並 BLOCK
- [ ] 以 AHCI (兩種 rotation rate) / megasas / nvme 驗 5 類 Device Class 分類與 policy 匹配
- [ ] 宿主需額外安裝 qemu-system-x86 與 OVMF

### 待實機驗證
- [ ] fbterm 在伺服器 BMC 顯示卡 (ASPEED 等) 上的 KMS framebuffer 相容性；
      起不來時需 fallback 回純 tty
- [ ] `✅❌⚠️` 這些 emoji 的 glyph 覆蓋：fonts-wqy-zenhei 不含，需另加單色 emoji
      字型，仍缺則改用 ASCII 標記
