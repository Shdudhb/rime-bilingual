# V0.2 架構

## 範圍與不變條件

V0.2 在 V0.1 的內建 Lua 詞典後加入 SQLite 本機 cache。它仍只使用 Rime Lua 與 Weasel 原生 comment UI，不包含外部翻譯 API、背景 Helper、英文上屏快捷鍵，也不修改 Weasel 原始碼。

設計維持以下不變條件：

- 候選文字、順序、分頁與選取身份由原 schema 決定。
- Space、數字鍵、方向鍵及 PageUp/PageDown 行為不變。
- 打字熱路徑不開 SQLite、不做檔案 I/O、不啟動程序，也不連網。
- cache 缺失、停用或無效時，內建詞典與原候選仍可正常工作。
- V0.2 不會把 composition、候選或密碼欄內容送出本機。

## 讀寫分離架構

```text
管理端（不在打字熱路徑）
scripts/cache.ps1
  -> init / put / import
  -> SQLite translations.db（可寫入的持久資料）
  -> publish
  -> canonical cache_snapshot.lua（原子發布、唯讀執行投影）

Rime schema 初始化
  -> 載入內建 Lua 詞典
  -> 驗證並載入 cache_snapshot.lua 一次
  -> 建立兩個記憶體 table

每個候選
  -> dictionary[candidate.text]
  -> 僅在 miss 時查 snapshot_cache[candidate.text]
  -> 命中時只改 genuine candidate.comment
  -> yield 原 candidate
```

SQLite 是 cache 的持久、可編輯資料來源；canonical snapshot 是固定格式、確定性排序的 Rime 執行期投影。Rime 刻意不直接連 SQLite，避免資料庫鎖、原生呼叫或磁碟延遲進入輸入法程序。

snapshot 只在 filter `init` 時讀取。`put`、`import` 或 `publish` 不會改變已建立的 filter 環境；發布後必須重新部署，新的 schema 環境才會載入新版 snapshot。

## 元件

| 檔案 | 責任 |
| --- | --- |
| `lua/rime_bilingual.lua` | filter 初始化與候選處理；實作 dictionary-first、cache-second 查詢。 |
| `lua/rime_bilingual_dictionary.lua` | V0.1 延續的內建唯讀高頻詞典。 |
| `lua/rime_bilingual_cache.lua` | 以受限環境載入並驗證 snapshot；失敗時回傳空 cache。 |
| `rime_ice.custom.yaml` | 在最後一個 `uniquifier` 前插入 filter，並提供 V0.2 設定。 |
| `data/cache_schema.sql` | SQLite schema 的可讀參考定義。 |
| `scripts/cache.ps1` | cache CLI：`init`、`put`、`import`、`publish`、`validate`。 |
| `scripts/lib/rime_bilingual_sqlite.psm1` | Windows SQLite ABI、schema、transaction、匯入與原子 snapshot 發布。 |
| `scripts/install.ps1` | 全新安裝或從受管理 V0.1 原地升級；初始化 DB 並發布 snapshot。 |
| `scripts/uninstall.ps1` | 還原受管理檔案；預設保留 cache，選用 `-PurgeCache` 刪除。 |

預設資料位置：

```text
%APPDATA%\Rime\rime-bilingual\translations.db
%APPDATA%\Rime\rime-bilingual\cache_snapshot.lua
```

## SQLite 資料契約

資料庫以 application id `RBIL`、`PRAGMA user_version = 1` 識別。`translations` 的主鍵為：

```text
(source_text, source_language, target_language, translation_mode)
```

紀錄同時保存 `translated_text`、來源標記 `source` 與 `updated_at_utc`。`cache_meta` 保存單一非負 `revision`；每次成功的 `put` 或整批 `import` transaction 增加一次 revision。V0.2 CLI 與 Rime runtime 固定使用：

```text
source_language = zh
target_language = en
translation_mode = literal
```

寫入採參數化 SQL 與 transaction。遇到 application id、schema version 或資料表契約不相容的既有檔案時，工具拒絕修改，而不是猜測或自動遷移。

## Canonical snapshot 契約

`publish` 在一致的 SQLite transaction 視圖中取得 revision 與 `zh/en/literal` entries，按 `source_text COLLATE BINARY` 排序，產生 UTF-8（無 BOM）的確定性 Lua table：

```lua
return {
  format_version = 1,
  db_schema_version = 1,
  revision = 3,
  source_language = 'zh',
  target_language = 'en',
  translation_mode = 'literal',
  entries = {
    ['一言難盡'] = 'It\'s hard to explain.',
  },
}
```

相同 DB revision 與內容會產生位元一致的 snapshot。字串經 Lua escaping，資料中看似 Lua 程式的內容仍只是字串。發布前會套用與 runtime 相同的 10,000 筆、每個 key/value 4,096 UTF-8 bytes、snapshot 16 MiB 上限；之後才完整寫入同目錄暫存檔並以同磁碟區原子替換。若驗證或替換失敗，上一份 snapshot 保持不變。

Lua loader 不執行 snapshot chunk，而是以 bounded canonical parser 讀取固定欄位順序與字串 escaping。它拒絕額外 token、函式或迴圈、重複／未排序 key、無效 UTF-8、錯誤版本與 tuple，以及超過上述容量上限的資料。任何讀取或解析失敗都會記錄一次 warning 並丟棄整份 snapshot，以空 cache 繼續。

`validate` 會驗證 SQLite schema；snapshot 存在或明確指定時，也會確認 snapshot revision 與 DB 一致。

## 候選資料契約與優先順序

filter 對 `candidate.text` 做精確比對：

```text
translation = dictionary[candidate.text]
if translation == nil:
    translation = cache[candidate.text]
```

因此內建詞典永遠優先，cache 無法覆寫同 key 的內建翻譯。命中時只設定 `candidate:get_genuine().comment`，並 yield 原 candidate；`type`、`text`、quality、起訖範圍、身份及串流順序不變。未命中時完全不改候選。

V0.2 採精確字串 key，不做繁簡轉換、詞形變化、語境消歧或大小寫推斷。

## Schema 整合與設定

`rime_ice.custom.yaml` 是使用者 patch，不是上游 schema 副本。filter 以 `engine/filters/@before last` 插在最後一個 `uniquifier` 前：此前的翻譯器、排序器與簡繁轉換已完成，comment 又能在候選被去重包裝前寫入。

設定介面：

| 鍵 | 預設值 | 用途 |
| --- | --- | --- |
| `enabled` | `true` | 啟用所有雙語註解。 |
| `cache_enabled` | `true` | schema 初始化時載入 snapshot；停用後仍查內建詞典。 |
| `comment_prefix` | `""` | 英文翻譯前綴。 |
| `comment_separator` | `" · "` | 既有 comment 與英文之間的分隔字串。 |
| `preserve_existing_comment` | `true` | 保留並接續既有 comment。 |

所有設定都在 schema 初始化時讀取，修改後必須重新部署。

## 安裝、升級與資料生命週期

全新安裝會部署三個 Lua 檔案及 schema patch，初始化 SQLite，發布空或既有 DB 的 snapshot，最後寫入 V0.2 manifest。若目的地已有不受管理的同名檔案，安裝程式會先備份，卸載時還原。

受管理的 V0.1 安裝可用相同 `install.ps1` 原地升級。升級前會驗證 V0.1 manifest、三個既有 payload hash 及備份；升級成功後才以 V0.2 manifest 取代舊 manifest。安裝中途失敗會回復 payload、snapshot 及新建 DB；若 rollback 不完整則保留復原資料並明確報錯。

卸載依 manifest hash 保護受管理檔案，拒絕無提示刪除使用者修改。預設只移除 payload、manifest 與專案備份，保留 `%RimeUserDir%\rime-bilingual` 中的 DB 和 snapshot；使用者明確指定 `-PurgeCache` 時才遞迴刪除該資料目錄。

安裝、升級、發布、設定修改及卸載都不會讓現有 Rime schema 熱更新；必須重新部署才會生效。

## Cache CLI 邊界

| 命令 | 行為 |
| --- | --- |
| `init` | 建立相容 SQLite schema，或驗證既有 schema。 |
| `put` | 對固定 runtime tuple upsert 單筆資料，revision 加一。 |
| `import` | 從 CSV、TSV 或 JSON 驗證並以單一 transaction upsert 整批資料，revision 加一。 |
| `publish` | 由 DB 建立 canonical snapshot 並原子發布。 |
| `validate` | 驗證 DB，並在 snapshot 存在時驗證 snapshot/revision。 |

`put` 與 `import` 不會隱式 publish；`publish` 也不會觸發 Weasel 重新部署。這個分離使資料編輯、snapshot 發布與輸入法重載都是明確、可驗證的步驟。

## 效能、故障與隱私

filter 初始化最多做一次 snapshot 檔案載入與驗證；每個候選的熱路徑最多做兩次 O(1) Lua table lookup 及一次 comment 寫入。沒有 SQLite、HTTP、API key、背景程序或 retry。

snapshot 缺失、不可讀、格式錯誤或過大時，loader 回退至空 cache；內建詞典仍可用。SQLite 或 publish 錯誤發生在獨立 CLI，不會阻塞候選 UI。外部翻譯與密碼欄資料保護屬後續版本，但 V0.2 完全沒有網路傳輸能力。

## V0.2 驗收界線

自動化測試必須涵蓋：

- SQLite schema、固定 runtime tuple、parameterized upsert/import 與 revision。
- canonical escaping、確定性排序、原子發布、失敗時保留舊 snapshot。
- snapshot 安全載入、格式與容量限制、錯誤時空 cache fallback。
- dictionary 命中優先於 cache、cache-only 命中、miss 不變。
- 候選身份、欄位、順序、既有 comment 與停用設定。
- 全新安裝、V0.1 原地升級、rollback、預設保留 cache、`-PurgeCache`。

Windows 上仍必須人工確認正常拼音、Space／數字鍵／方向鍵選字、PageUp/PageDown 翻頁、橫向與豎向版面，以及快速連續輸入時無可感知停頓。這些真正的 Weasel／librime-lua 驗證不能由靜態模型測試取代。

## 後續演進

V0.3 才由獨立 Helper 非同步取得外部翻譯並寫入 SQLite。即使後續加入 Google 或 AI，Rime 的同步 filter 仍只讀已發布的本機 snapshot；網路請求不得進入候選熱路徑。
