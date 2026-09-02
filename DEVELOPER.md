# NAS_CRUCIBLE 開發者指南

## 1. 專案簡介
NAS_CRUCIBLE 是一個基於純 Bash 實作的儲存載體（SATA/SAS/NVMe）破壞性測試框架。設計核心遵循「Fail-Closed (寧可誤殺絕不放過)」，所有錯誤（硬體、傳輸或腳本本身）都會終止進程或標記為 FAIL。

## 2. 工具依賴
- `bash` (4.0+)
- `smartmontools` (提供 `smartctl`)
- `e2fsprogs` (提供 `badblocks`)
- `jq` (強型別 JSON 操作)
- `whiptail` (TUI 互動式硬碟選擇介面，Debian 預裝)
- `nvme-cli` (提供 `nvme`，**僅測試 NVMe 裝置時必要**；缺少時 runner 會直接 Fail-Closed 退出)
- 系統核心指令 (`lsblk`, `findmnt`, `kill`, `setsid`)

## 3. 日常開發與測試
執行不需要硬體的迴歸測試（提交前必跑）：
```bash
./tests/run_all.sh
```
對真實硬碟執行 burn-in：
```bash
sudo ./crucible.sh sdb sdc
```

## 4. 目錄結構
```
NAS_CRUCIBLE/
├── crucible.sh                    # Layer 0: 唯一入口 (CLI UX, 設備探測與策略匹配)
├── crucible_controller.sh         # Layer 1: 並行協調 (PGID 隔離與 Global Abort)
├── device_runner.sh               # Layer 2: 單碟 Phase FSM 執行器
├── verdict_engine.sh              # Layer 2: Fail-Closed 嚴格裁決邏輯
├── report_renderer.sh             # Layer 2: Summary Report 渲染 (Evidence 的衍生物)
├── adapters/                      # Layer 3: 硬體接縫 (防腐層)
│   ├── precheck_adapter.sh
│   ├── snapshot_adapter.sh
│   ├── smartctl_long_adapter.sh   # ATA / SCSI 長程自我檢測
│   ├── nvme_smart_long_adapter.sh # NVMe Device Self-test
│   └── badblocks_adapter.sh
├── lib/                           # 共用模組
│   └── device_probe.sh
├── policies/                      # Policy JSON (Admission, Execution, Verdict 規則)
│   ├── sata_hdd.json
│   ├── sas_hdd.json
│   ├── sata_ssd.json
│   ├── sas_ssd.json
│   └── nvme_ssd.json
├── legacy/                        # 歸檔舊程式碼 (包含 Gen 1 nas_crucible.sh)
├── logs/                          # 測試產出 (Evidence JSONs, 不進版控)
├── tests/                         # 測試 (run_all.sh / fixtures / stubs / mocks)
├── README.md                      # 給一般使用者的說明文件
├── DEVELOPER.md                   # 給維護者的架構文件
└── docs/                          # 架構與規則文件
```

## 5. 架構與關鍵設計決策
系統架構分為 4 層，採用深度模組設計：
1. **Layer 0 (CLI / Admission):** `crucible.sh` 負責人類互動，防呆，並依據 `policies/` 將硬碟分類。
2. **Layer 1 (Orchestration):** `crucible_controller.sh` 啟動平行的 `device_runner.sh`，透過 `setsid` 隔離 PGID，在收到中斷時執行 Global Abort。
3. **Layer 2 (Execution / Verdict):** `device_runner.sh` 嚴格控制 precheck -> baseline -> smart1 -> bb -> smart2 -> final 的管線；`verdict_engine.sh` 在最後比對 JSON 快照與 policy 閾值。
4. **Layer 3 (Adapters):** 隔離真實 OS 指令 (`smartctl`, `badblocks`)，只回傳標準化的 Evidence JSON。不允許在 runner 內直接呼叫 OS 工具。

## 6. 添加新功能指南
- **新增裝置類型**：
  在 `crucible.sh` 的分類邏輯新增 Device Class，建立同名小寫的 `policies/<class>.json`
  (設定 `jq_path` 與閾值)，若協議需要不同的 OS 工具，再於 `device_runner.sh` 的
  協議准入清單與 `run_phase` 分派中加上分支。NVMe 即是此路徑的範例。
- **新增測試階段**：
  在 `adapters/` 中建立新的腳本，產出 standard JSON evidence，然後在 `device_runner.sh` 中註冊。
- **修改驗收標準**：
  只修改對應的 `policies/*.json` 內的 `verdict_rules` 即可。

## 7. Adapter 檔名契約 (務必遵守)
`device_runner.sh` 的 `validate_evidence` 只會去讀
`$LOG_DIR/${SERIAL}_${phase}_evidence.json`。
Adapter **必須**把 Evidence 寫到這個路徑，否則不論硬體結果如何，該 Phase 一律被判為
`ADAPTER_CONTRACT_VIOLATION` (rc=2)。因此長程檢測類 adapter 都以第 6 個參數接收 phase 名稱
(`smart_long_1` / `smart_long_2`)，這同時確保兩輪檢測的 Evidence 與 log 不會互相覆蓋。

## 8. 版本號同步
下列檔案/腳本必須保持一致的 `version`：
- `policies/*.json`
- 所有 `adapters/*.sh` (在 JSON evidence 的 `adapter.version` 欄位)
- `device_runner.sh`
- `crucible.sh` (如果印出版號)


## 9. Admission 防線與 Override
`crucible.sh` 的 admission 有五道，任何一道不過只會把該碟標成
`decision=BLOCK` 並記下 `block_reason`，其餘裝置照常受測 —— 不再整批 `exit 2`。
判定結果一律寫進 `device_manifest.json`，被擋本身就是需要留存的紀錄。

| 順序 | 檢查 | block_reason | 可 Override |
| :--- | :--- | :--- | :--- |
| 1 | 裝置節點存在 | `NOT_A_BLOCK_DEVICE` | 否 |
| 2 | 開機媒體自我排除 | `BOOT_MEDIUM` / `REMOVABLE_BOOT_UNKNOWN` | 否 |
| 3 | 掛載 / ZFS / holders | `MOUNTED` / `ZFS_POOL_MEMBER` / `ZFS_QUERY_FAILED` / `STORAGE_HOLDERS` | 否 |
| 4 | 身分與 Policy | `IDENTITY_UNREADABLE` / `NO_POLICY` / `DUPLICATE_SERIAL` | 否 |
| 5 | 碟上 Signature | `HAS_DATA` / `SIGNATURE_QUERY_FAILED` | **是** |

### 為什麼需要 Signature 這一道
前三道判斷的全是「執行時狀態」。Live Image 開機時主系統沒有啟動，沒有東西被掛載、
沒有 pool 被匯入、沒有 md/LVM 被組裝 —— 三道防線同時歸零，一顆服役中的資料碟會
看起來跟全新空碟一模一樣。`dev_has_signature` 讀的是碟上的靜態事實
(FSTYPE / PTTYPE)，不依賴任何執行時狀態，因此 Live 與已安裝環境行為一致。
見 [ADR-0001](docs/adr/0001-signature-as-primary-admission-defence.md)。

### Override 的形狀
`HAS_DATA` 是唯一可解除的一條，解除方式是**逐碟輸入該碟序號**。刻意不提供全域
`--force`：單一旗標關掉整條防線，正是本專案已經修過數次的 fail-open 形狀。
`stdin` 不是 tty 時一律維持封鎖，避免這條路徑被寫進排程腳本變成預設值。
解除後 manifest 記 `overridden=true`，最終報表帶 `(OVERRIDE)` 標記。

### precheck_adapter 為何不重複檢查 Signature
既有的深度防禦是為了 TOCTOU：admission 到破壞性階段之間硬碟可能被抽換。但那個
情境已由 `precheck_adapter` 的序號比對 (`IDENTITY_MISMATCH`) 攔下，而簽章不會憑空
出現。被 Override 的碟本來就帶著簽章，在 precheck 再驗一次只會把它們全部擋掉，
因此需要把 override 旗標一路傳進 runner —— 代價大於收益，故不做。

### 新增的探針 (`lib/device_probe.sh`)
| 函式 | 用途 | 測試接縫 |
| :--- | :--- | :--- |
| `dev_has_signature` | 碟上是否有檔案系統或成員標記。0=有 / 1=無 / 2=無法判定 | PATH 上的 `lsblk` |
| `dev_is_removable` | 是否為可移除或 USB 裝置 | `SYSFS_ROOT`、PATH 上的 `lsblk` |
| `is_live_environment` | 是否跑在 Live Image 中 | `CRUCIBLE_LIVE_DIR`、`CRUCIBLE_CMDLINE_FILE` |
| `detect_boot_medium` | 反查承載 Live Image 的整顆實體碟 | `SYSFS_ROOT`、PATH 上的 `findmnt` / `lsblk` |

`detect_boot_medium` 回傳 1 代表**反查失敗**，呼叫端必須退化為「排除全部 removable
裝置」，絕不可當成「沒有開機碟」。

## 10. 測試分層
| 層 | 檔案 | 需要什麼 | 何時跑 |
| :--- | :--- | :--- | :--- |
| 純軟體迴歸 | `tests/run_all.sh` | 無 (stub 攔截硬體) | **每次提交前必跑** |
| 建置靜態檢查 | `tests/test_build_contract.sh` | 無 (不實際建置) | 每次提交前 (已納入 run_all.sh) |
| 端到端開機驗證 | `tests/run_iso.sh` | qemu-system-x86 + ovmf + 一顆已建好的 ISO | 手動 / release 前 |

QEMU 層驗的是 stub 永遠測不到的東西：BIOS / UEFI / Secure Boot 三條開機路徑、
開機碟自我排除、自動建分區與重開機後重掛、以及用 AHCI / megasas / nvme 模擬出來的
5 類 Device Class 分類。注意 QEMU 模擬碟的 SMART 支援很薄，`smartctl -t long` 與
NVMe `device-self-test` 在 VM 內基本上跑不起來 —— 那部分的覆蓋留在 `run_all.sh`。

## 11. 建置可開機映像 (build/)
```bash
./build/build_iso.sh                 # 產物在 build/out/
./build/build_iso.sh --allow-dirty   # 開發驗證用，ISO 會標記 dirty
```
宿主唯一需要的依賴是 `docker` 與 `git`；`debootstrap` / `xorriso` / `mksquashfs`
全部只存在於容器內。程式碼一律取自 `git archive HEAD`，working tree 不乾淨時
預設拒絕建置 —— 交出去的 ISO 必須對應到一個 commit，否則三天後拿到異常
Evidence 時無從重現。

| 檔案 | 職責 |
| :--- | :--- |
| `build/build_iso.sh` | 宿主入口。dirty 檢查、`git archive`、`docker build` / `docker run --privileged` |
| `build/Dockerfile` | 建置環境 (debian:stable + debootstrap/xorriso/mksquashfs/mtools) |
| `build/in_container/build.sh` | debootstrap → 裝套件 → 植入程式碼 → squashfs → 組 BIOS/UEFI 開機路徑 → hybrid ISO |
| `build/in_container/packages.list` | 套件清單**單一來源**，`test_build_contract.sh` 逐項檢查 |
| `build/boot/` | `grub.cfg` (UEFI) 與 `isolinux.cfg` (BIOS)，兩者都必須帶 `boot=live` |
| `build/rootfs/` | 疊進 live rootfs 的檔案 (autologin、Evidence Store、autostart、fbterm 設定) |

### 開機鏈
BIOS 走 isolinux，UEFI 走 `shim-signed` → `grub-efi-amd64-signed` → Debian 官方
簽章 kernel，因此開著 Secure Boot 的機器不必進 BIOS 改設定。ISO 以
`-isohybrid-mbr` 與 `-isohybrid-gpt-basdat` 產生，`dd` 進隨身碟後兩種韌體都能開機，
且尾端仍留有可加分區的空間給 Evidence Store。**這條開機鏈不能換成自編 kernel**，
換了就失去簽章。見 [ADR-0002](docs/adr/0002-debian-stable-signed-boot-chain.md)。

### 開機後的流程
```
systemd
 ├─ crucible-evidence-store.service   建立/掛載 Evidence Store (Before=getty@tty1)
 └─ getty@tty1 (autologin root)
     └─ crucible-autostart            fbterm -> tmux -> crucible.sh
```
`crucible-autostart` 會把 `CRUCIBLE_LOG_DIR` 指到 Evidence Store 的掛載點。
**漏掉這一步的話 Evidence 會寫進 live rootfs (RAM)**，持久分區等於白建 ——
`test_build_contract.sh` 有一條專門盯這件事。

### No-Persistence Mode
Evidence Store 建不起來 (虛擬光碟開機、隨身碟無剩餘空間、分區表寫入失敗) 時，
`crucible-evidence-store` 會掛 tmpfs 並寫出 `/run/crucible/no-persistence`，
`crucible-autostart` 與 `crucible.sh` 都讀這個旗標並全程警告。三支腳本共用
`CRUCIBLE_NOPERSIST_FLAG` 這一個環境變數，測試會檢查它們沒有各自寫死不同路徑。

## 12. Summary Report 與可追溯性
`report_renderer.sh <log_dir> [out_dir]` 是純資料處理器：讀 `device_manifest.json`、
`exec_record_*.json` 與 `*_verdict_evidence.json`，產出 `summary.csv` 與
`summary.html`。CSV 與 HTML 從同一個中間 JSON 產生 —— 兩種格式各算一次的話，
遲早會出現「CSV 說 PASS、HTML 說 FAIL」。

呼叫時機有兩處：`device_runner.sh` 每顆碟跑完重繪一次 (3-5 天的測試中途斷電時，
摘要裡至少有已經跑完的那幾顆)，`crucible.sh` 在 controller 返回後再產一次最終版。
兩處都是 best-effort —— **摘要是 Evidence 的衍生物，渲染失敗絕不能影響測試結果**。

渲染器最關鍵的性質是「沒有 verdict evidence 的 ALLOW 裝置不得留白」：
執行中標 `RUNNING`，其餘一律 `FAIL` 並說明原因。留白會被讀成沒問題。

### 可追溯性
ISO 建置時在專案根目錄產生 `build_info.json` (commit / 建置時間 / Debian 版本)。
`crucible.sh` 啟動時把它複製進 log dir，並把 commit 寫進每顆碟的
`exec_record_<serial>.json` 的 `.build.commit`。因此三天後拿到一份 Evidence，
可以直接從 log 目錄回答「這是哪一版程式碼跑出來的」。

五支 adapter 的 evidence **沒有**加上這個欄位：adapter evidence 是有版本號的
契約 (見 §8)，為此同步改五支 adapter 加五份 policy 的版本，代價大於收益 ——
log dir 層級的自我描述已經足夠回答重現問題。
