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
- [x] `build/` 目錄：Dockerfile + build_iso.sh，宿主只需 docker
- [x] Debian stable debootstrap，含 smartmontools / nvme-cli / jq / whiptail / util-linux
- [x] BIOS (isolinux) + UEFI (grub-efi) 雙開機，`shim-signed` 支援 Secure Boot
- [x] fbterm + fonts-wqy-zenhei，tty1 自登入後進 tmux 跑 TUI
- [x] 首次開機自動在開機碟尾端建立 ext4 Evidence Store 與小容量 FAT32 摘要分區
- [x] 建不出來時降級 No-Persistence Mode，於 TUI 首頁、確認頁、進行中狀態列全程警告
- [x] Summary Report 渲染器：每顆碟判定完就從 logs/ 重新產生一次 (中途斷電也有部分摘要)
- [x] `build_info.json` 與 Evidence 帶上 commit hash (改為寫進 exec_record 與 log dir，
      不動五支 adapter 的版本化契約)
- [x] `tests/test_build_contract.sh`：不建置的靜態檢查 (套件清單、grub 兩條開機路徑)

### M3: QEMU 測試層
- [x] `tests/run_iso.sh`：UEFI (OVMF) / Secure Boot / Legacy BIOS 三條開機路徑都要進得到 TUI
- [x] 驗自動建分區並在重開機後仍掛得到
- [x] 驗開機碟不出現在可測清單
- [x] 驗預先寫入 ext4 簽章的虛擬碟被標 HAS_DATA 並 BLOCK
- [x] 以 AHCI (兩種 rotation rate) / megasas / nvme 驗 5 類 Device Class 分類與 policy 匹配
- [ ] **尚未實跑**：宿主需先 `sudo apt install qemu-system-x86 ovmf`

## 現況 (2026-09-02)

M1 / M2 / M3 的程式碼與測試都已完成並提交。`./tests/run_all.sh` 全綠
(9 支測試、約 180 個斷言，不需要任何硬體)。

### 已在 QEMU 實機模擬中驗證通過
以 commit `928455e` 建出的 ISO 實際開機驗證，下列全部通過：

- **Legacy BIOS (SeaBIOS)** 開機 → 進到 userspace → 序列埠取得 root shell
- **UEFI (OVMF)** 開機 → 同上
- **UEFI + Secure Boot** (OVMF.secboot + 微軟金鑰)：shim → 簽章 grub →
  Debian 官方 kernel 整條鏈通過
- **Evidence Store**：首次開機在隨身碟尾端建立分區成功
  (`/dev/sde4 -> /var/lib/crucible/logs`)，未進入 No-Persistence Mode
- **持久化**：重新開機後掛回同一個 Evidence Store，未重建
- **Admission (VM 內實際執行 crucible.sh 的輸出)**：
  - 開機媒體 `/dev/sde` → `BLOCKED: BOOT_MEDIUM`
  - 寫入 ext4 簽章的碟 → `BLOCKED: HAS_DATA`
  - 非互動情境不提供 Override
  - `SN-SASHDD` → `SAS_HDD` (megasas 直通)
  - `SN-SATASSD` → `SATA_SSD` (rotation_rate=1)
  - `SN-SATAHDD` → `SATA_HDD`
  - `SN-NVME` → `NVME_SSD`
  - 四顆合格碟正確匹配到 `HDD_FULL_BURNIN` / `SSD_WEAR_BURNIN` profile

### 唯一尚未實跑驗證的一項
- [ ] **tty1 自動進入選碟畫面** —— 修正已提交 (`1a6b943`)，但**尚未用新 ISO 實跑**。

  問題是 live-config 會在開機時於 `/run/systemd/generator/` 產生
  `live-config_autologin.conf` (`--autologin user`)，systemd 依檔名排序套用
  drop-in，我們原本的 `autologin.conf` 排在它前面而被整個蓋掉 —— ISO 開得起來、
  Evidence Store 也建得好，就是主程式不會啟動，開機後停在 live-config 的 user
  帳號 shell。已改名為 `zz-crucible-autologin.conf` 並加上排序斷言，
  但驗證用的第四次建置被中斷，`build/out/` 目前是空的。

  **接續步驟**：
  ```bash
  ./build/build_iso.sh          # 約 19 分鐘，需要 docker (--privileged)
  ./tests/run_iso.sh            # 約 7 分鐘，需要 qemu-system-x86 + ovmf
  ```
  預期 11 條斷言全過。失敗時序列埠 log 會保留在 `build/out/iso-test-logs/`。

  註：本機的 `docker run --privileged` 在 Claude Code 的沙箱下會卡住，
  需要在一般終端機執行，或以 `!` 前綴在對話中執行。

### 實機 (非 QEMU) 仍待驗證
- [ ] fbterm 在伺服器 BMC 顯示卡 (ASPEED 等) 上的 KMS framebuffer 相容性；
      起不來時需 fallback 回純 tty (程式已有此分支，未在真硬體上驗過)
- [ ] `✅❌⚠️` 這些 emoji 的 glyph 覆蓋：fonts-wqy-zenhei 不含，需另加單色
      emoji 字型，仍缺則改用 ASCII 標記
- [ ] 真實 SAS HBA (mpt3sas / megaraid_sas IT mode) 上的完整燒機流程
- [ ] NVMe `device-self-test` 的完整流程 (QEMU 模擬碟的 SMART 支援太薄，測不到)

