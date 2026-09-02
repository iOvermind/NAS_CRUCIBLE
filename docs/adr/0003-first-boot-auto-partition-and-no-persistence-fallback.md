---
status: accepted
---

# 首次開機自動建立 Evidence Store，失敗時降級為 No-Persistence Mode

Live rootfs 在 RAM，而一輪燒機要跑 3-5 天，重開機或斷電會讓 Evidence 全滅。
因此 Live Image 在首次開機時偵測 Boot Medium 尾端的剩餘空間，自動建立兩個分區：
一個 ext4 的 Evidence Store（journaling 保護長時間連續寫入），與一個小容量 FAT32
分區存放 Summary Report（讓報告能插到任何電腦上直接讀）。當自動建立做不到時
（虛擬光碟開機、隨身碟已無剩餘空間、分區表寫入失敗），系統降級為
No-Persistence Mode 繼續執行，並在 TUI 首頁、確認頁與進行中狀態列全程醒目警告。

## Considered Options

- **要求操作員預先準備好持久分區，找不到就拒絕開跑**：對 Fail-Closed 而言最純粹，
  但 Fail-Closed 該管的是「要不要抹這顆碟」，不該在程式還沒開始前就把使用者擋在門外。
- **燒錄時就把分區建好（提供 write_usb.sh）**：Live 環境永遠不需要寫分區表，
  但使用者就不能單純把 ISO `dd` 進隨身碟了。

## Consequences

- Live 環境具備寫入分區表的能力，這是本專案唯一一個「非受測碟也會被寫入」的動作。
  因此 Boot Medium 的識別必須零誤判：由掛載中的映像來源反查 parent disk，
  整顆碟連同所有分區硬性 BLOCK；一旦反查失敗，則退化為「排除全部 removable
  裝置」的保守規則（內接 SATA / SAS / NVMe 不受影響）。
