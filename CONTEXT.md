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
