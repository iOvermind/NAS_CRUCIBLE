---
status: accepted
---

# Live Image 採 Debian stable 與 Debian 官方簽章開機鏈

Live Image 以 Debian stable (13.x) 為基底，於 Docker 容器內建置，並使用 Debian
官方的 `shim-signed` + `grub-efi-amd64-signed` + `linux-image-amd64`，讓開啟
Secure Boot 的機器不必進 BIOS 改設定就能開機。選 Debian 而非 Alpine 的理由是
現有腳本依賴完整版 `lsblk` / `findmnt` / `whiptail`，且 Debian 官方 kernel
已內含 `mpt3sas` / `megaraid_sas` 等 SAS HBA 驅動——工具鏈與開發環境一致，
`precheck_adapter` 一行都不用改。

## Consequences

- **不能再換成自訂 kernel**。一旦自編 kernel 就失去微軟簽章，Secure Boot 機器
  即無法開機。任何「加個 patch 進 kernel」的需求都會撞上這個決定。
- ISO 體積約 400-600MB（Alpine 路線約 100-200MB）。對隨身碟而言不構成問題。
- 宿主機只需要 `docker`，不需安裝 `debootstrap` / `xorriso` / `live-build`。
