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

