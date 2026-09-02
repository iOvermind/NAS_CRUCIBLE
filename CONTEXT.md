# NAS_CRUCIBLE Context

這是一個用於儲存裝置破壞性測試的自動化框架。

## Language

**Policy**:
定義特定硬碟種類（如 SATA HDD）該如何進行測試的 JSON 檔案，包含准入、執行參數與驗收規則。
_Avoid_: Config, Ruleset

**Device Class**:
硬碟的分類（例如 `SATA_HDD`、`SAS_SSD`）。
_Avoid_: Drive type, Disk category

**Evidence**:
每個測試階段（Phase）完成後產出的 JSON 檔案，記錄硬體的原始輸出（如 SMART 數據）與該階段的成功/失敗狀態。
_Avoid_: Log, Result file

**Phase**:
測試流程中的單一階段（如 precheck, badblocks）。每個 Phase 都有自己的 Adapter 負責執行並產出 Evidence。
_Avoid_: Step, Task

**Verdict**:
最終的判定結果（PASS/FAIL），由 Verdict Engine 根據 Policy 中的規則，比對初始與最終的 Evidence 產生。
_Avoid_: Conclusion, Final Check

**Global Abort**:
當收到中斷訊號（如 Ctrl+C）時，Controller 透過 PGID 強制終止所有子進程與背景測試工具的行為。
_Avoid_: Force stop, Kill all

**TUI (Terminal User Interface)**:
終端機互動式介面。當 `crucible.sh` 不帶參數執行時，提供 checklist 形式的硬碟選擇器，自動掃描系統區塊裝置並顯示裝置資訊與安全標示。
_Avoid_: Interactive mode, Menu

### 可開機媒體 (Bootable Media)

**Live Image**:
把 NAS_CRUCIBLE 與其工具鏈完整封裝、可寫入隨身碟並以 BIOS 或 UEFI 開機的最小 Linux 映像。
_Avoid_: Live CD, Bootable USB, 開機碟

**Boot Medium**:
承載 Live Image、且系統當下正由它開機的那一顆實體裝置。它與其上所有分區永遠不得成為受測對象。
_Avoid_: USB, 開機隨身碟, 系統碟

**Evidence Store**:
Live 環境下用來保存 Evidence 的持久儲存區，以標籤辨識而非以裝置路徑辨識。
_Avoid_: Persistence partition, 資料碟, logs 分區

**Summary Report**:
給人閱讀的判定摘要。它是 Evidence 的衍生物，任何時候都能從 Evidence 重新產生，本身不是證據。
_Avoid_: Report file, 結果檔, 報表

**No-Persistence Mode**:
Evidence Store 無法建立或掛載時的降級狀態。此狀態下 Evidence 只存在於記憶體，斷電即失，必須全程對操作員明示。
_Avoid_: RAM mode, tmpfs mode, 暫存模式

**Signature**:
裝置上可被靜態讀出的檔案系統或儲存堆疊成員標記，代表這顆碟曾經被寫入資料。與「是否正在被使用」無關。
_Avoid_: Filesystem, Metadata, 殘留資料

**Override**:
操作員逐碟輸入該碟序號，明確解除由 Signature 造成的 BLOCK。這是系統中唯一一條解除防線的路徑。
_Avoid_: Force, Bypass, 略過, 強制模式
