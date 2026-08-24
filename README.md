# 小狼毫雙語候選翻譯

這個專案為 Windows 小狼毫／Rime 拼音候選加入英文註解，不取代輸入法，也不改變候選順序或選字方式。

V0.2 先查內建本機詞典，再查使用者的 SQLite 本機 cache。Rime 實際載入的是由 SQLite 發布的唯讀 Lua snapshot；打字期間只有記憶體查詢，不開啟資料庫、不連網，也不會把輸入內容送出電腦。

## 需求

- Windows 與已可正常使用的小狼毫（Weasel）
- 已安裝並啟用 `rime_ice` schema
- PowerShell 5.1 或更新版本
- Rime Lua 支援（目前小狼毫發行版通常已包含）

預設 patch 只針對 `rime_ice`。使用其他 schema 時，不要直接套用 `rime_ice.custom.yaml`。

## 安裝或從 V0.1 升級

在專案根目錄執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

安裝程式會將 Lua 模組及 schema patch 部署至 `%APPDATA%\Rime`，建立：

```text
%APPDATA%\Rime\rime-bilingual\translations.db
%APPDATA%\Rime\rime-bilingual\cache_snapshot.lua
```

若該目錄已有由本專案 V0.1 安裝程式建立的 manifest，同一命令會原地升級至 V0.2；不必先卸載 V0.1。安裝程式會驗證既有受管理檔案並沿用原備份，遇到曾被修改或不完整的 V0.1 安裝時會停止，避免覆寫使用者資料。

Rime 使用者資料位於其他位置時，安裝與後續 cache 命令必須指定相同根目錄：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1 -RimeUserDir "D:\Rime"
```

安裝完成後，從小狼毫功能表選擇「重新部署」。安裝程式不會代替使用者執行部署；在重新部署前，新 filter 或 snapshot 不會生效。

## 管理本機 cache

`scripts/cache.ps1` 提供 `init`、`put`、`import`、`publish`、`validate` 五個命令。預設資料根目錄是 `%APPDATA%\Rime`；自訂安裝位置時，為每個命令加上 `-RimeRoot "D:\Rime"`。

### 建立或檢查資料庫

安裝時會自動執行初始化，也可以手動執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\cache.ps1 init
powershell -ExecutionPolicy Bypass -File .\scripts\cache.ps1 validate
```

`validate` 會檢查 SQLite application id、schema version、資料表及 revision；snapshot 已存在時也會檢查其格式與資料庫 revision 是否一致。

### 新增或更新單筆翻譯

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\cache.ps1 put `
  -SourceText "一言難盡" `
  -TranslatedText "It's hard to explain." `
  -Source "manual"
```

相同的中文 key 會更新既有 `zh -> en / literal` 紀錄。`-Source` 是來源標記，預設為 `manual`。

### 批次匯入

`import` 支援 `.csv`、`.tsv` 及 `.json`；JSON 以 UTF-8 讀取。CSV／TSV 請使用目前 PowerShell 可正確讀取的文字編碼。最小 CSV 格式如下：

```csv
source_text,translated_text,source
一言難盡,It's hard to explain.,manual
說來話長,It's a long story.,manual
```

匯入命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\cache.ps1 import `
  -InputPath .\translations.csv `
  -DefaultSource "import"
```

欄位亦可包含 `source_language`、`target_language`、`translation_mode` 及 `updated_at_utc`；V0.2 僅接受 `zh`、`en`、`literal` 這組固定值。

### 發布 snapshot 並套用

`put` 與 `import` 只更新 SQLite，Rime 不會直接讀取資料庫。完成變更後依序執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\cache.ps1 publish
powershell -ExecutionPolicy Bypass -File .\scripts\cache.ps1 validate
```

接著從小狼毫功能表選擇「重新部署」。filter 在 schema 初始化時載入一次 snapshot，所以即使 `publish` 已成功，現有輸入法程序也不會熱更新；必須重新部署才會看見新翻譯。

`publish` 會依固定順序產生 canonical snapshot，並以同磁碟區原子替換發布檔。發布失敗時會保留上一份可用 snapshot。

如需獨立測試路徑，可使用 `-DatabasePath` 與 `-SnapshotPath`；一般安裝建議使用 `-RimeRoot`，避免兩個路徑指向不同資料集。

## 查詢優先順序

候選文字採精確比對：

```text
內建詞典
  -> 未命中才查已載入的 cache snapshot
  -> 仍未命中則保留原候選，不加英文
```

若內建詞典與 cache 含有相同 key，內建詞典優先。修改 cache 無法覆蓋例如「今天」等內建詞典條目。V0.2 不做繁簡轉換、詞形變化或語境消歧。

## 顯示與開關設定

`rime_ice.custom.yaml` 的設定如下：

```yaml
rime_bilingual:
  enabled: true
  cache_enabled: true
  preserve_existing_comment: true
  comment_prefix: ""
  comment_separator: " · "
```

- `enabled: false` 停用所有雙語註解。
- `cache_enabled: false` 只停用 snapshot，內建詞典仍生效。
- `preserve_existing_comment: true` 保留其他 filter 的 comment，再以 `comment_separator` 接上英文。

任何設定變更後都必須重新部署。

## 卸載

預設卸載會移除受管理的 Lua／patch 檔案並還原安裝前備份，但保留 `rime-bilingual` 資料目錄中的 SQLite 與 snapshot，方便日後重裝：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1
```

若確定要永久刪除本機翻譯資料，明確加上 `-PurgeCache`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -PurgeCache
```

自訂資料目錄時，卸載也要傳入相同的 `-RimeUserDir`。卸載後請重新部署小狼毫，讓還原後的 schema 生效。

## 驗證

先執行自動化測試：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\test_cache.ps1
powershell -ExecutionPolicy Bypass -File .\tests\test_filter.ps1
powershell -ExecutionPolicy Bypass -File .\tests\test_install.ps1
```

這些測試涵蓋 SQLite schema、upsert/import、canonical snapshot、dictionary 優先、cache fallback、候選欄位保留、V0.1 升級及安全卸載。實際 Weasel／librime-lua 行為仍須人工驗證：

1. 輸入 `wo`、`ni`、`jintian`，確認內建詞典註解正常。
2. 用 `put` 新增一個詞典未收錄的詞，執行 `publish`、`validate` 及重新部署，確認 cache 註解出現。
3. 對內建詞典 key 寫入不同 cache 翻譯，確認仍顯示內建詞典結果。
4. 對未知詞輸入拼音，確認候選與原 comment 保持不變。
5. 分別用 Space、數字鍵、方向鍵及 PageUp/PageDown 選字與翻頁，確認上屏文字、候選順序及分頁不變。
6. 分別測試小狼毫橫向與豎向候選版面，確認中英文對應清楚。
7. 快速連續輸入及退格，確認候選窗沒有可感知的卡頓。
8. 將 `cache_enabled` 設為 `false` 並重新部署，確認 cache-only 註解消失而內建註解保留。

不同小狼毫主題對 comment 的字型、顏色與間距處理不同。V0.2 驗收重點是操作不受影響及中英文關係清楚，不要求真正的上下雙層排版。

## V0.2 不包含

- Google Translate 或 AI 翻譯
- Translation Helper 背景程式
- Ctrl+Enter 英文直接上屏
- 對其他 schema 的自動設定
- 修改或 Fork Weasel UI

產品路線請見 `SPEC.md`，設計細節請見 `docs/ARCHITECTURE.md`。
