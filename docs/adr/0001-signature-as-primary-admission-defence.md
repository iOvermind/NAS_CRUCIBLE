---
status: accepted
---

# 以碟上靜態 Signature 作為 admission 的主防線

原本的 admission 三道防線（`MOUNTPOINT` 掛載狀態、`zpool status` 的 pool 歸屬、
`/sys/.../holders` 的 LVM/mdraid 佔用）判斷的全部是**執行時狀態**。把 NAS_CRUCIBLE
搬進 Live Image 之後，主系統不會啟動，於是沒有任何東西被掛載、沒有 pool 被匯入、
沒有 md/LVM 被組裝——三道防線同時歸零，一顆正在服役的 NAS 資料碟看起來會跟一顆
全新空碟完全一樣。因此新增 Signature 偵測（`blkid` 可見的檔案系統與
`zfs_member` / `LVM2_member` / `linux_raid_member` 成員標記）作為主防線：它讀的是
碟上的靜態事實，不依賴任何執行時狀態，在 Live 與已安裝環境下行為一致。

## Considered Options

- **在 Live Image 內安裝 zfsutils 並掃描可匯入的 pool**：只保護 ZFS，
  ext4 / XFS / NTFS / LVM 的資料碟依然裸奔；且 `zpool` 指令存在但 kernel module
  未載入時查詢會失敗，依現行 `dev_in_zpool` 契約會回傳「無法判定」而擋下所有裝置。
- **只在 Live 模式啟用這條規則**：會引入「執行模式」這個新概念，讓 admission
  分岔成兩套行為與兩套測試矩陣。既然對一顆有 ext4 簽章的碟跑 `badblocks -wsv`
  在任何環境下都同樣危險，規則一律生效。

## Consequences

- Signature 偵測一律生效，不分環境。在開發機上拿舊硬碟試跑會被擋下。
- 唯一解除路徑是 Override（逐碟輸入序號），且僅限互動情境；工具內不提供
  全域 `--force`。這是刻意的：本專案已多次修補 fail-open 缺陷，不再自行製造新的。
- admission 失敗的粒度同時改為「只擋該碟、其餘照跑」，沿用 `device_manifest.json`
  既有的 `decision` 欄位，不新增概念。
