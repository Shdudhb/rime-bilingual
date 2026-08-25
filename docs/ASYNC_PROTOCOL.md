# V0.3 Async Bridge 與 Helper v2 協定

本文件是 V0.3 的實作契約。數值皆為非負整數；文字皆為 UTF-8；所有 candidate slot 與 index 均為零起始。

## 1. 固定 limits

| 項目 | 上限/規則 |
| --- | --- |
| page candidates | 1～20 |
| AI misses | 1～20，且每個 slot 在頁內唯一 |
| candidate / translation | 1～256 UTF-8 bytes；不得含 control character |
| request id | 1～128 ASCII bytes，`[A-Za-z0-9._-]` |
| fingerprint | 64 個小寫 hex 字元（SHA-256） |
| native pending ring | 8 batches；滿時立即 `queue_full` |
| native completion ring | 32 batches；最舊 terminal entry 可被丟棄，不得阻塞 producer |
| completion retention | 30 秒或 32 entries，以先到者為準 |
| Helper request body | 32 KiB |
| Helper response body | 32 KiB；llama upstream 仍為 64 KiB |
| HTTP redirects/proxy | 禁止 |
| V0.3 context | 必須是空字串 |

limits 是 ABI/protocol 行為；若 schema 設定超界，bridge disabled，而不是放寬上限。

## 2. generation 與 candidate fingerprint

每個 Rime engine/schema lifecycle 只有一份由 processor 與 filter 共用的 Lua page state，並維護單調遞增 `generation`（uint64；溢位時清空 native queues 後從 1 重啟）。不得讓兩個 component 各自產生 generation。filter 以 `page_start = floor(selected_index / page_size) * page_size` 鎖定目前可視頁，再依 upstream `input:iter()` 的 lazy contract 逐 candidate consume/yield；只累積 absolute index 落在該頁範圍內的 bounded identity（最多 20 個）。完整頁在最後一個 candidate yield 前 submit，不足一頁只在 iterator exhausted 後 submit；同一 callback 最多 submit 一頁。Rime 為 uniquifier/後續頁預取的其他候選只能照常 yield，不得覆蓋目前可視頁 state。不得為湊頁而連續 consume 不 yield，也不得從 filter 反向呼叫 `segment.menu:prepare()`。PageUp/PageDown 完成後，`Context.update_notifier` 會觀察新的 `selected_index`；若 input 沒變而 page_start 改變，只能讀取 librime 已 materialize 的目的頁 (`candidate_count` / `get_candidate_at`) 並建立該頁 batch，仍不得呼叫 `prepare()`；同頁 highlight 只可 poll/apply 現有 pair。下列任一可觀察值改變即遞增：composition input、composition 是否存在、`page_start`、頁面 candidate 數量，或任一 candidate identity。純 comment 改變不遞增。共享 state 另保存目前頁最多 20 個 `{slot, genuine_ref, immutable_identity, local_hit}`；它只對應一個 generation/fingerprint pair。

完整頁 fingerprint 不含 translation/comment，也不含 generation；它是以下 bytes 的 SHA-256 小寫 hex：

```text
ASCII "RBIL-PAGE-V1\0"
LE32 page_start
LE32 candidate_count
for each candidate in display order:
  LE32 absolute_index
  LE32 byte_len(text)  + UTF-8 text
  LE32 byte_len(type)  + UTF-8 type
  LE32 start
  LE32 end
```

`absolute_index = page_start + slot`。所有 length/index 先驗證再 hash；不得用 delimiter 拼字串。candidate identity 只用上述欄位，避免既有/英文 comment 造成 self-invalidating fingerprint。結果身份是 `(generation, fingerprint)`；兩者都相同才可顯示。

## 3. Lua native module API

module entrypoint 固定為 `luaopen_rime_bilingual_bridge`。以下函式不得對一般 runtime failure `error()`；一律回傳狀態 table。Lua wrapper 仍必須用 `pcall` 隔離 ABI fault。

### `configure(options)`

只在 component init 呼叫一次：

```lua
bridge.configure({
  protocol_version = 2,
  helper_endpoint = "http://127.0.0.1:18081",
  request_timeout_ms = 3000,
  queue_capacity = 8,
  completion_capacity = 32,
  expected_rime_sha256 = "<64 uppercase/lowercase hex>"
})
```

主執行緒只驗證 bounded options、建立預先配置 rings/thread 並返回；不得連線、UIA 或讀設定檔。成功回 `{status="ready", protocol_version=2}`；可重複且相同設定回 `ready`；不同設定回 `{status="disabled", error="already_configured"}`。其他 error 值限 `invalid_config`、`abi_mismatch`、`worker_start_failed`。disabled 永久維持到下一次 Rime process/schema lifecycle。

### page table

`try_submit`/`try_poll` 共用：

```lua
{
  generation = 42,
  page_start = 0,
  candidates = {
    {absolute_index=0, text="今天", type="phrase", start=0, ["end"]=7},
    {absolute_index=1, text="今天的", type="phrase", start=0, ["end"]=7}
  }
}
```

bridge 按第 2 節自行計算 fingerprint，Lua 不提供/信任 digest。

### `try_submit(request)`

```lua
bridge.try_submit({
  generation = 42,
  page_start = 0,
  candidates = { ...full page identity... },
  misses = {
    {slot=0, text="今天"},
    {slot=1, text="今天的"}
  }
})
```

miss `text` 必須 byte-for-byte 等於同 slot page candidate text。回傳固定欄位：

```lua
{status="accepted", request_id="...", generation=42, fingerprint="..."}
```

status 可為 `accepted`、`duplicate`（相同 pair 已 pending/ready）、`queue_full`、`disabled`、`invalid`。只有 `accepted` 建立工作；其他狀態立即返回。安全性尚未由 worker 判定，故主執行緒不會收到/使用 `safe=true` 之類推測值。

### `try_poll(page)`

每次呼叫先原子發布此 page 為 caller 的最新 `(generation,fingerprint)`，再做 bounded completion lookup：

```lua
bridge.try_poll(page)
```

回傳之一：

```lua
{status="pending", generation=42, fingerprint="..."}
{status="not_found", generation=42, fingerprint="..."}
{
  status="ready", request_id="...", generation=42, fingerprint="...",
  translations={{slot=0,text="Today"},{slot=1,text="Today's"}},
  source="cache" -- cache | mixed | model
}
{status="failed", generation=42, fingerprint="...", error="timeout"}
```

terminal error 限 `unsafe`、`focus_changed`、`helper_unavailable`、`timeout`、`invalid_response`、`stale`、`worker_error`。任何 completion 在入 ring 前以及 poll 時都要和最新 pair 比較；不符即丟棄/回 `stale`，translations 不得暴露給 Lua。`ready` translations 的 slot 必須與原 misses 完全相同、唯一、遞增且等長。

poll 是非破壞 lookup，讓 processor 與 filter 可讀同一 result；entry 到 retention limit 才清除。`ready` 本身不授權修改 candidate：caller 還必須依第 6 節核對保存 refs。

### `status()`

只讀 atomic counters/snapshots：

```lua
{
  status="ready", protocol_version=2,
  pending=1, completed=2, dropped=0,
  last_error="timeout" -- 或 nil
}
```

不得包含 candidate、translation、prompt、foreground window title/PID 或本機路徑；不得藉此 health-check Helper/model。

## 4. Worker safety 與 HTTP

worker dequeue 後才執行 UIA。只有 `IsPassword` 明確為 false、UIA call 全部成功，且 UIA 前後 foreground HWND/PID 完全一致時可建立 HTTP body。每個失敗皆 terminal fail closed，無 retry；候選 bytes 不得先寫 log/file/SQLite。worker 使用固定 loopback IP endpoint、no proxy、no redirect、bounded connect/overall timeout。

在送出前 worker 再比較 request pair 與最新 pair；HTTP 回來後、寫 completion 前再次比較。任何不符為 stale，且 stale response 不可顯示。

## 5. Helper protocol v2

`POST /translate` 依 `protocol_version` 分派。既有 v1 request/response/error shape 與驗證繼續支援；v1 的 `context` 仍必須空字串。v2 request：

```json
{
  "protocol_version": 2,
  "request_id": "rime-42-a1b2",
  "generation": 42,
  "candidate_fingerprint": "<64 lowercase hex>",
  "page_start": 0,
  "context": "",
  "candidates": ["今天", "今天的"]
}
```

成功 response：

```json
{
  "protocol_version": 2,
  "request_id": "rime-42-a1b2",
  "generation": 42,
  "candidate_fingerprint": "<same>",
  "translations": ["Today", "Today's"],
  "model": "gemma-3-1b-it-qat-q4_0",
  "source": "cache",
  "elapsed_ms": 3
}
```

`source` 是 `cache|mixed|model`。response 的 version/id/generation/fingerprint 必須 exact echo；native 對任何 mismatch fail closed。v2 error envelope 保留 v1 的 `error:{code,message,retryable}`，並額外 exact echo generation/fingerprint（malformed request 無法安全解析時可用 `0`/空字串）。既有 `INVALID_REQUEST`、`MODEL_UNAVAILABLE`、`MODEL_TIMEOUT`、`MODEL_OUTPUT_INVALID` 保留，新增 `CACHE_UNAVAILABLE`；不得回 partial success。

Helper 先以 `source_text, zh, en, literal` 逐項查現有 SQLite schema。全 hit 不呼叫 llama；partial miss 先保留唯一 miss texts 的首次出現順序，然後對每個 unique miss 各做一次 **singleton inference**。每個 model request 的 `CANDIDATES` 區只有 `0: <candidate>`，grammar 也固定要求恰好一個 translation。所有 singleton 都成功且通過英文/格式驗證後，才在一個 transaction upsert，再依原 candidates（包含重複文字）重組等長 response。這可避免小模型把同頁近義／近形／同尾字候選彼此串義。DB busy/corrupt/migration mismatch 立即 `CACHE_UNAVAILABLE`，不得繞過「cache first」直接 inference。

in-flight dedup key 仍是 `model identity + translation_mode + ordered unique miss texts` 的 collision-safe framed hash；同 key caller await 同一 Helper task，但各自 response envelope 使用各自 id/generation/fingerprint。dedup 不跨不同 model/mode。singleton model calls 在該 shared task 內依 miss order 執行；整個 shared task 仍受一個總 timeout 約束。任一 singleton timeout/failure/invalid output 都使整個 page request fail closed，且在全部成功前不得寫入部分 cache。

Helper logs 僅允許 timestamp、sanitized request id、batch/miss/cache-hit count、model identity、source、latency、error code。禁止 candidate、translation、context、prompt、fingerprint、window/UIA metadata。SQLite 只保存翻譯 cache，不能保存 request envelope 或 UI 狀態。

### V0.4 Helper protocol v3：bounded context

Helper 已額外支援 `protocol_version: 3`，供 V0.4 context-aware translation backend 使用。既有 v1/v2 行為不變，尤其 v2 的 `context` 仍必須是**精確空字串**；因此目前 V0.3 native bridge 不會因 Helper 升級而改變行為。

v3 request 沿用 v2 的 generation/fingerprint/page 欄位，但允許 bounded `context`：

```json
{
  "protocol_version": 3,
  "request_id": "quality-42",
  "generation": 42,
  "candidate_fingerprint": "<64 lowercase hex>",
  "page_start": 0,
  "context": "老師說明天要交",
  "candidates": ["作業", "報告", "考卷"]
}
```

Helper 對 v3 context 做以下處理：

- trim 前後 whitespace，並把連續 whitespace 正規化成單一 ASCII space；
- 最多 120 個 Unicode scalar values；
- UTF-8 最多 512 bytes；
- newline/tab 等 whitespace 只可經正規化使用；其他 control character 直接 `INVALID_REQUEST`；
- context 不寫 log、不寫 SQLite，也不出現在 error body。

contextual cache 不改 SQLite schema。Helper 將 `model identity + prompt + normalized context` 以 collision-safe framing 做 SHA-256，並把結果放進既有 `translation_mode` 欄位：

```text
context-v5:<64 lowercase hex>
```

因此同一 candidate 在不同 context 不會共用翻譯；相同 normalized context 則可以 cache hit。DB 只保存 hash，不保存原始 context。空 context 仍沿用既有 `literal` cache namespace，以維持 v1/v2 相容性。

送給 llama-server 的候選使用明確編號，要求輸出第 N 項嚴格對應第 N 個 candidate。GBNF 將 translation string 限制為可顯示的 ASCII 英文字符集合，Helper 解析後還會再次要求至少包含一個 ASCII alphabetic character；中文回音、空值或非英文輸出一律 `MODEL_OUTPUT_INVALID` 且不得寫 cache。

**目前 v3 只完成 Helper/backend。** V0.3 bridge 仍送 v2 + `context: ""`。在 Rime 端啟用 recent committed context 前，必須先解決 context provenance：不能只在 Lua 保存最近 commit 文字後，於下一個安全欄位直接送出，否則密碼欄或其他敏感欄位先前 commit 的文字可能被帶入後續 request。V0.4 Rime bridge 必須讓「context 來源欄位安全性」也能 fail closed，才可正式切到 protocol v3。

## 6. 顯示與失敗語義

filter 建立目前頁時，最多保存 20 個 genuine candidate reference、對應 immutable identity（absolute index/text/type/start/end）與 `local_hit`。每個真實鍵事件的 processor 仍可 bounded poll 保存 pair，但 UI 自動更新**不依賴下一個鍵事件**。bridge worker 將 terminal `ready` completion 成功放入 completion ring 後，以 non-blocking `PostMessageW` 對 exact Weasel 0.17.4 IPC window 發送 private `WM_APP` message；worker 不得直接呼叫 Rime API。patched Weasel 在主 message thread 重新確認 active session 仍 `is_composing` 後 toggle schema-local `_rime_bilingual_refresh` option；librime 的 option update 因而安全重建未確認 composition。filter 重跑後 `prepare_filter()` 先 poll matching ready result，讓英文 comment 在新 candidate yield 前寫入。pending/failed/stale/expired completion 不得發 completion wakeup。

generation、composition、page_start、candidate count/identity 任一改變時，先清除全部舊 refs，再建立新頁集合；`M.fini` 直接清除 refs 與共享 state。V0.3 不宣稱有 commit/cancel notifier：commit/cancel 後，下一個真實鍵事件的 processor 必須在 poll 前檢查 composition；若為空，先清除 refs/state 並跳過舊 pair poll。Lua 不得跨 pair 使用 ref。原 dictionary/snapshot translation 優先，AI 不覆寫 local hit。任何 invalid/stale/failed/expired result 當作無英文。

本協定沒有 timer-driven polling：Lua 不 timer polling，也不送 synthetic key；bridge worker 也不呼叫 Rime API。唯一的主動喚醒是 terminal `ready` publication 後的 private Windows message。Weasel main thread 透過公開 `set_option` 路徑觸發 librime composition refresh；此 refresh 不執行 HTTP/SQLite/inference，只重建未確認 composition，filter 重跑後隨正常 UI render 顯示英文。若當下已失焦、session 不存在或不再 composing，Weasel 必須忽略 wakeup。
