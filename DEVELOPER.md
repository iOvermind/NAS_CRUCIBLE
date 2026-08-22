# NAS_CRUCIBLE 開發者指南

## 1. 專案簡介
NAS_CRUCIBLE 是一個基於純 Bash 實作的儲存載體（SATA/SAS/NVMe）破壞性測試框架。設計核心遵循「Fail-Closed (寧可誤殺絕不放過)」，所有錯誤（硬體、傳輸或腳本本身）都會終止進程或標記為 FAIL。

## 2. 工具依賴
- `bash` (4.0+)
- `smartmontools` (提供 `smartctl`)
- `e2fsprogs` (提供 `badblocks`)
- `jq` (強型別 JSON 操作)
- 系統核心指令 (`lsblk`, `findmnt`, `kill`, `setsid`)

## 3. 日常開發與測試
執行測試：
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
│   ├── smartctl_long_adapter.sh
│   └── badblocks_adapter.sh
├── lib/                           # 共用模組
│   └── device_probe.sh
├── policies/                      # Policy JSON (Admission, Execution, Verdict 規則)
│   ├── sata_hdd.json
│   ├── sas_hdd.json
│   ├── sata_ssd.json
│   └── sas_ssd.json
├── legacy/                        # 歸檔舊程式碼 (包含 Gen 1 nas_crucible.sh)
├── tests/                         # 測試與 Mocks
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
- **新增裝置類型 (如 NVMe)**：
  在 `crucible.sh` 中新增分類邏輯，並建立 `policies/nvme_ssd.json` (設定 `jq_path` 與閾值)。
- **新增測試階段**：
  在 `adapters/` 中建立新的腳本，產出 standard JSON evidence，然後在 `device_runner.sh` 中註冊。
- **修改驗收標準**：
  只修改對應的 `policies/*.json` 內的 `verdict_rules` 即可。

## 7. 版本號同步
下列檔案/腳本必須保持一致的 `version`：
- `policies/*.json`
- 所有 `adapters/*.sh` (在 JSON evidence 的 `adapter.version` 欄位)
- `device_runner.sh`
- `crucible.sh` (如果印出版號)

