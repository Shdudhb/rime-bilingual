# V0.3 打字時非阻塞請求架構契約

## V0.3 交付邊界

V0.3 在既有 V0.2-ai Helper 與模型資料流前加入一個 x64 原生 Lua bridge，讓候選頁在打字時自動送出翻譯請求。完整資料流是：

```text
Rime Lua filter / processor
  -> dictionary + canonical snapshot（只讀記憶體，永遠優先）
  -> miss page -> native bridge 的 bounded try_submit
  -> native worker thread -> UIA password check -> loopback HTTP
  -> Helper v2 -> SQLite cache -> miss 才呼叫 llama-server
  -> native completion ring
  -> DLL runtime mount -> bounded Weasel FOCUS_IN wake
  -> Rime refresh -> try_poll -> 核對保存的 genuine refs -> comment
```

V0.3 不傳送 recent context（固定 `context: ""`），不實作英文上屏快捷鍵，也不管理 V0.6 的模型載入／600 秒 idle unload。SQLite cache、非同步 request、timeout、dedup、generation + SHA-256 fingerprint stale rejection 和打字熱路徑零等待屬本版。

## 不可妥協的執行緒邊界

- Rime/Lua 主執行緒只可執行既有 dictionary/snapshot 記憶體查詢，以及 bridge 的 bounded `try_submit`、`try_poll`、`status`。不得在 callback 中開檔、開 SQLite、DNS、HTTP、UI Automation、啟動程序或等待 mutex/event/thread。
- bridge 呼叫只可複製有上限的資料並操作 lock-free ring 或 non-waiting try-lock；ring 忙碌或已滿時立即回傳狀態並略過英文，中文候選照常 yield。
- 原生 worker 是唯一可執行 UIA、loopback HTTP、timeout 與 response parsing 的執行緒。Helper 是唯一可讀寫 SQLite 或等待 llama-server 的程序。
- filter 保存目前頁最多 20 個 `candidate:get_genuine()` reference 與其 immutable identity/local-hit flag；filter 與 processor 都只能修改這些 genuine candidate 的 `comment`，不得改 text、type、quality、range、順序、分頁或選取身份。processor 對每個按鍵（包含 PageUp/PageDown）做 bounded poll，ready 時再次核對 pair 與 reference identity、套用 comment，最後一律回傳 `kNoop`，不攔截原有按鍵。

## 元件與載入

bridge 安裝到 `%APPDATA%\Rime\rime-bilingual\native\rime_bilingual_bridge.dll`。Lua 以 `rime_api:get_user_data_dir()` 組出此**絕對路徑**，並且只用：

```lua
package.loadlib(absolute_path, "luaopen_rime_bilingual_bridge")
```

不得把 native 目錄加入全域 `package.cpath`，也不得從目前工作目錄或 PATH 搜尋 DLL。DLL 與 Weasel/Rime 必須同為 x64；安裝 manifest 必須 pin 已驗證的 `rime.dll` SHA-256 與 bridge SHA-256。安裝/升級時 architecture 或 hash 不符就不得發布 payload；runtime `configure` 再核對目前已載入的 `rime.dll` identity，失配就將 AI bridge 設為 disabled，記錄不含候選內容的單一診斷，繼續純中文/dictionary/snapshot 路徑。這是明確 ABI pin；不宣稱跨任意 librime/Lua build 相容。

bridge 的逐函式契約、fingerprint framing、limits 與 Helper v2 wire format 以 [ASYNC_PROTOCOL.md](ASYNC_PROTOCOL.md) 為準。

## Rime callback 流程

0. `rime_bilingual.init` 只在初始化時讀取 `build/weasel.yaml`。只有編譯後的 Weasel candidate layout 明確為 `style/layout/type: vertical`，或舊式 `style/horizontal: false` 時才啟用 bilingual；橫列、未知或讀取失敗都 fail closed，dictionary/cache/AI 註解與 async page tracking 一併停用。typing callback 不讀 Weasel config。
1. filter 逐候選先查 dictionary，再查 schema init 時載入的 canonical snapshot。命中立即使用並標記 `local_hit=true`；只有兩者皆 miss 的 slot 可進 AI batch。
2. filter 先從 composition 的 `selected_index` 與 schema `page_size` 算出目前可視頁的 `page_start`，再依 upstream `input:iter()` 的 lazy contract 逐候選處理並 yield。只有 absolute index 落在該可視頁範圍內的候選會被保存，最多 `page_size`（上限 20）個 refs/identity；Rime 為 uniquifier 或後續頁面預取的候選不得建立新的 AI batch。取得該可視頁最後一個 candidate 時，先對完整頁 misses 呼叫一次 `try_submit`，再 yield 該最後一個 candidate；最後不足一頁時只在 iterator 已確認 exhausted 後 submit。保存 `{slot, genuine_ref, immutable_identity, local_hit}` 的集合只代表一個確切 `(generation, fingerprint)`；不得逐候選 inference、不得為了湊頁而連續 consume upstream 卻不 yield，也不得從 filter 反向呼叫 `segment.menu:prepare()`。
3. bridge DLL 由 Rime Lua 正常 `package.loadlib()` 載入官方 `WeaselServer.exe` process；**磁碟上的官方 EXE 不修改、不替換**。runtime mount 只在 exact Weasel 0.17.4 `WeaselServer.exe` SHA-256 與 pinned `rime.dll` SHA-256 都匹配時安裝。它在 process 記憶體內以 IAT hook 觀察官方 `KERNEL32!ReadFile` 收到的 Weasel named-pipe `PipeMessage`，只接受 12-byte、pipe handle、已知 `WM_APP+1..15` command；由真實 `PROCESS_KEY_EVENT` / `FOCUS_IN` / `FOCUS_OUT` 等 request 被動追蹤 active IPC session。filter 在 `PROCESS_KEY_EVENT` 內 submit 時保存該 request 的 IPC session 與 foreground HWND，worker 本身**不得**呼叫任何 Rime API。
4. bridge worker 將 terminal `ready` completion 成功放入 bounded completion ring 後，只有保存的 IPC session 仍為 active、foreground HWND 仍相同時，才以最多 50 ms timeout 的 `CallNamedPipeW` 對官方 `\\.\pipe\<user>\WeaselNamedPipe` 送出一個既有 `WEASEL_IPC_FOCUS_IN` request，並在 `wParam` 帶 private `RBIL` marker。若 focus/session 在 preflight 後又競態改變，ReadFile hook 會在 upstream dispatch 前把該 wake 改寫成無副作用 `ECHO`，不得讓舊 session 被重新標成 active。官方 `FocusIn()` 本身先執行 `_UpdateUI(ipc_id)` 再維持同一 active session，因此不需要新增 Weasel IPC command、synthetic key、timer 或 patched server binary。
5. runtime mount 同時只包裝 pinned librime 1.13.1 `RimeApi.get_status` function-table entry。只有帶 `RBIL` marker、仍對應 active IPC session 的官方 `_UpdateUI()` 進入 `get_status(session_id)` 時才消耗 wake；wrapper 先用原始 `get_status` 確認 `is_composing`，再透過原始 `get_option` / `set_option` toggle schema-local `_rime_bilingual_refresh`。此時正在 Weasel 自己的 serialized API handler 內，librime option update 會呼叫 `RefreshNonConfirmedComposition()`；接著 upstream `_UpdateUI()` 繼續讀取新 status/context。任何 hash、PE import、Rime API table、focus/session 或 composing 條件不符都 fail closed，只缺英文。
6. native wakeup 造成 filter 重新執行；`prepare_filter()` 在該輪 page materialization 時先 `try_poll`，只有 generation/fingerprint 完全匹配的 ready result 才可在 candidate `yield` **之前**寫入 comment。PageUp/PageDown 或頁內 highlight 完成後，`Context.update_notifier` 仍只觀察已更新的 `selected_index`；若 input 未改變而 page_start 改變，callback 只以 `candidate_count()` / `get_candidate_at()` 讀取 librime 已 materialize 的目的頁，建立新 generation 並 submit，**不得**呼叫 `menu:prepare()`。input 編輯仍由正常 filter path 處理，不由 notifier 重複 batching。generation、composition、page 或 identity 一改變，必須在建立新集合前清除舊 refs。component fini 斷開 notifier 並清除 state；本版沒有 commit/cancel notifier，因此 commit/cancel 後由下一個真實鍵事件的 processor 在 poll **之前**偵測 composition 為空並清除，不得先 poll 舊 pair。不得在不同頁或不同 generation 保留/使用 ref。
7. 舊 generation、不同頁、不同順序、不同 candidate identity、local hit 或數量不符一律丟棄；AI 永遠不得覆寫 dictionary/snapshot comment。
8. 不得送 synthetic key、不得用 timer polling/刷新、不得讓 bridge worker 直接呼叫 Rime API。只有 terminal `ready` completion publication 且保存的 wake target 仍有效時才可發 bounded named-pipe wake；pending/failed/stale/expired completion 不得觸發 UI refresh。runtime hook 只存在於目前 Weasel process 記憶體，重啟 Weasel 即完全恢復官方 executable 行為。

因此 AI 完成後即使使用者完全停住不按鍵，也會由 native completion message 喚醒 Weasel/Rime，filter 自動重跑並補上英文；**不需要 timer、synthetic key 或下一個真實鍵盤事件。** Helper/bridge/Weasel 任一環節失敗時只缺英文，中文候選與選字不得受影響。

頁面計算使用 Rime 的零起始 `selected_index` 與 schema `page_size`：`page_start = floor(selected_index / page_size) * page_size`。初次/輸入變更時，filter 的 `absolute_index` 只用來辨識 upstream iterator 中哪些候選屬於這個可視頁；超出範圍的預取候選照常 yield，但不 submit。每個 filter callback 最多建立一個 batch，最後不足一頁時使用實際數量。filter 始終保持「consume 一個 candidate 後正常 yield」的 librime-lua lazy 模型，只在可視頁尾 candidate yield 前完成 submit。換頁則由 `update_notifier` 在 librime 已完成 destination page preparation 與 highlight 後讀取已存在的 Menu 候選；此路徑也不呼叫 `prepare()`。兩條路徑共同避免 Menu 重入、無 yield 預讀，以及後續預取頁覆蓋目前可視頁 state。

## 密碼欄與 loopback fail closed

Lua 不傳 composition 或 context；V0.3 request 只含需要翻譯的候選文字。即使如此，worker 在任何 HTTP body 離開 Weasel process 前仍必須：

1. 取得非零 foreground HWND/PID；
2. 在 worker COM apartment 用 UI Automation 取得當前 focused element；
3. 成功讀到 `IsPassword == false`（未知、錯誤、timeout、unsupported 均不算 safe）；
4. 緊接送出前再次取得 foreground HWND/PID，且必須與步驟 1 完全一致；
5. 確認 Helper endpoint 是 `http://127.0.0.1:<port>`，不接受 hostname、IPv6、redirect 或 proxy。

只有全部明確 safe 才送出；否則 terminal status 為 `unsafe`/`focus_changed` 並靜默省略英文。安全檢查不得退回「假設不是密碼欄」。Helper/模型也不得提供外網 fallback。

## Cache、dedup 與故障

- Lua dictionary/snapshot hit 不得提交 Helper。
- Helper v2 對每個 miss 先查 SQLite `zh/en/literal`；全 hit 時不呼叫模型。partial miss 仍由 Rime/bridge 以一個 page request 傳入，但 Helper 會將 ordered unique misses 逐一做 singleton model inference，再按原 slot 合成完整結果。這是刻意的品質隔離：小模型不得讓同頁相近候選彼此串義。
- 同 model identity、translation mode 與相同 ordered miss batch 的並行 request 共用一個 in-flight inference；各 caller 仍取得自己的 request id/generation/fingerprint envelope。
- 經嚴格驗證的模型結果才可 transactionally upsert SQLite。失敗、timeout、stale 或不安全結果不可寫成翻譯。
- AI cache 是可丟棄的最佳化資料；`scripts/cache.ps1 purge-model` 只刪除 provenance 為 `model:*` 的項目並保留 manual/import rows，之後必須重新 `publish` snapshot。這用於模型/prompt/mapping bug 曾污染 cache 時的安全復原。
- queue full、bridge disabled、Helper/model 不可用、timeout、invalid output、cache 損壞與 native panic/exception 都只造成英文缺席。所有跨 Lua/C boundary 的例外必須轉成狀態；filter/processor 以 `pcall` 做最後隔離。

## V0.3 驗收

- 證明 callback 路徑沒有檔案/SQLite/HTTP/UIA/process launch，也沒有 blocking lock wait；queue full 立即 fail open。
- dictionary/snapshot hit 零 Helper call；相同 ordered miss batch 仍共用同一個 in-flight Helper task；partial cache miss 的每個 unique miss 各做一次 singleton model inference，全部成功後才一次 transaction 寫 cache 並依原順序重組 response。
- 模擬快速連續輸入、選取移動和 PageUp/PageDown，舊 generation/fingerprint 結果不顯示，順序與選取不變。
- UIA unknown/error/`IsPassword=true`、foreground PID 改變、非 loopback endpoint 均為零 HTTP request。
- Helper v1 測試仍通過；v2 success/error/limits/cache/dedup/timeout 測試通過。
- 驗證 cache miss 頁在 AI 完成後**完全不按鍵**也會自動重跑 filter 並補上英文；快速切換輸入框或 FocusOut 時，晚到 completion 不得重新喚醒舊 session。若 runtime mount hash/ABI 檢查失敗，則 fail closed 為純中文/local annotation，不能修改或替換官方 `WeaselServer.exe`。
- 實機驗證正常拼音、Space/數字/方向鍵選字、PageUp/PageDown、直列候選，以及 Helper/model unavailable 時無可感知卡頓。雙語翻譯 UI 僅支援直列；橫列不是本功能的驗收模式。

---

## V0.2-ai 基線（保留供相容性參考）

## 交付邊界

V0.2-ai 在既有 V0.2 的 Rime 註解與本機 cache 基礎上，加入可獨立部署、測試的本機 AI 翻譯資料流：

```text
一頁中文候選（batch）
  -> Translation Helper
  -> http://127.0.0.1:<llama-port>
  -> llama-server
  -> Gemma 3 1B IT QAT Q4_0 GGUF
  -> 經驗證、順序不變的英文字串陣列
```

這一版的完成條件是：安裝本機推理 runtime 與模型後，可從 Helper 的批次介面送入一頁候選，經由 llama-server 取得並驗證等長的翻譯結果。模型名稱、GGUF 路徑與 llama-server 參數由 Helper／部署設定決定，不寫死在 Rime Lua。

V0.2-ai **不把 Helper 呼叫接進 Rime 打字事件**。Rime 打字時自動送出 request、非同步輪詢、candidate fingerprint、stale result 丟棄與稍後刷新 comment 屬 V0.3。V0.2-ai 的批次 E2E 測試從 Helper API／CLI 邊界開始，使用與 Rime 當頁候選相同形狀的資料；它不是日常打字時的同步呼叫。

因此，V0.2-ai 不宣稱已提供下列能力：

- 打字時自動觸發 AI 翻譯或即時補上英文。
- 上下文選義；`context` 欄位在本版保持空字串，V0.4 才啟用其語意。
- 英文上屏快捷鍵、模型 idle unload 或 Weasel C++ 雙層 UI。
- 把模型輸出自動寫入 SQLite 或發布成 Rime snapshot。

這個邊界刻意確保「模型可部署、Helper batch 可端到端運作」不會把網路或推理延遲帶進輸入法程序。

## 不變條件

- 候選文字、順序、分頁、quality 與選取身份完全由原 schema 決定。
- Space、數字鍵、方向鍵及 PageUp/PageDown 行為不變。
- Rime 打字熱路徑不開 SQLite、不做檔案 I/O、不啟動程序、不送 HTTP，也不等待 Helper 或模型。
- dictionary、cache、Helper 或模型任一項缺失或失敗時，中文候選與選字都必須正常。
- 本機 dictionary／cache 必須先於任何未來的 AI request；cache hit 不得呼叫模型。
- V0.2-ai 不蒐集密碼欄內容。未來加入 Rime IPC 時，無法確認欄位安全就不得送出 composition、上下文或候選。
- Weasel 只允許 exact 0.17.4 的最小可重現 patch：新增 private completion message 與 main-thread Rime refresh handler；不得改候選排序、commit、TSF key handling 或 renderer。英文仍透過原生 candidate comment 顯示。

## 元件與信任邊界

```text
Rime / Weasel process                         管理與測試程序
------------------------------------          --------------------------------
schema init                                   caller / E2E test
  -> load built-in dictionary                   -> POST /translate (batch)
  -> load canonical snapshot once               -> Translation Helper
candidate hot path                                    -> validate request
  -> dictionary lookup                                 -> fixed prompt
  -> snapshot lookup                                   -> loopback HTTP
  -> optional comment                            llama-server
  -> yield original candidate                          -> local GGUF
                                                    <- model text
                                                 <- strict validated JSON
```

Translation Helper 與 llama-server 是 Rime 程序外的本機程序。兩者之間只使用 loopback HTTP；Helper 不依賴 Gemma 專屬 API，而是依賴 llama-server 的 OpenAI-compatible chat completion 介面。部署時預設模型為 Gemma 3 1B IT QAT Q4_0 GGUF；更換其他 GGUF instruct model 只改部署設定與 model identity。

V0.2-ai 的 Helper 可以同步等待 llama-server，因為 caller 是獨立管理／測試程序，不是 Rime filter 或 processor。後續 Rime 整合必須在此介面前增加真正的非同步邊界，不能直接從同步 Lua filter 呼叫 `/translate`。

## Helper HTTP 契約

Helper 只監聽 `127.0.0.1`。V0.2-ai 提供下列版本化介面：

```text
POST /translate
GET  /health
```

### `POST /translate`

Request 使用 UTF-8 JSON：

```json
{
  "protocol_version": 1,
  "request_id": "e2e-0001",
  "context": "",
  "candidates": ["我", "你", "今天"]
}
```

欄位契約：

| 欄位 | 規則 |
| --- | --- |
| `protocol_version` | 必須為整數 `1`；未知版本拒絕處理。 |
| `request_id` | caller 產生的非空字串；只用於關聯 request／response，不作候選身份。 |
| `context` | V0.2-ai 必須是空字串；欄位保留供 V0.4 啟用。 |
| `candidates` | 1～20 個非空 UTF-8 字串，陣列順序就是輸出順序；禁止逐候選拆成多次 inference。 |

成功時回傳 HTTP 200：

```json
{
  "protocol_version": 1,
  "request_id": "e2e-0001",
  "translations": ["I", "You", "Today"],
  "model": "gemma-3-1b-it-qat-q4_0",
  "elapsed_ms": 184
}
```

`translations` 必須與 `candidates` 等長、逐項為非空短字串，且索引一一對應。Helper 必須先完成整份驗證才回傳成功；不得回傳部分結果、重排結果或拿上一個 request 的結果補洞。`model` 是實際部署 identity，供診斷與未來 cache invalidation；`elapsed_ms` 是 Helper 觀測到的本次處理時間，不包含任何 Rime UI 承諾。

失敗時使用非 2xx 狀態並回傳：

```json
{
  "protocol_version": 1,
  "request_id": "e2e-0001",
  "error": {
    "code": "MODEL_OUTPUT_INVALID",
    "message": "model output did not match the requested batch",
    "retryable": true
  }
}
```

錯誤 code 至少區分 `INVALID_REQUEST`、`MODEL_UNAVAILABLE`、`MODEL_TIMEOUT` 與 `MODEL_OUTPUT_INVALID`。對 malformed JSON、陣列長度不符、非字串項目、空翻譯、過長翻譯或模型多餘說明，Helper 一律視為失敗，不把垃圾內容交給 caller。有限 retry 可在 Helper 內進行，但必須受 timeout 約束；失敗不會影響 Rime。

### `GET /health`

`/health` 只報告 Helper 是否可回應以及設定的 llama endpoint／model identity 是否就緒，不載入模型、不執行 inference，也不延長未來的模型 keep-alive。健康檢查不得回傳 prompt、候選、翻譯內容或本機敏感路徑。

## Helper 到 llama-server 的模型契約

Helper 呼叫設定的 loopback llama-server chat completion endpoint，固定使用短 system prompt：將一批中文輸入法候選翻成自然、精簡的英文；保留順序；只輸出 JSON string array。V0.2-ai 的 prompt 不提供最近輸入上下文。

初始推理設定以部署 benchmark 調整，預設範圍為：

```text
context size: 256～512 tokens
temperature: 0～0.2
output budget: 足以容納一頁短翻譯，但限制長篇生成
GPU offload: 可設定，優先使用可用 GPU
```

Helper 不信任模型文字。即使 llama-server 回傳 HTTP 200，仍必須抽取 assistant content、解析 JSON、驗證數量／型別／長度，最後才建立 Helper response。Markdown code fence、解釋文字或其他非 JSON array 輸出都不能直接顯示。

## Loopback 與隱私

- Helper server 與 llama-server 都明確 bind `127.0.0.1`，不可使用 `0.0.0.0`、`::` 或 LAN 位址作為預設值。
- Helper 只接受設定為 `http://127.0.0.1:<port>` 的模型 endpoint；V0.2-ai 不提供雲端 fallback、外部帳號或 API key。
- 模型與 runtime 安裝完成後，翻譯資料流不需要對外網路。下載工具必須與執行時翻譯程序分離。
- 日誌預設只記錄時間、request id、batch size、model identity、latency 與錯誤 code；不記錄 context、candidate、prompt 或 translation 內容。
- `/translate` 不提供 CORS 公開存取能力，也不因模型失敗轉送至其他服務。
- 未來 Rime caller 必須在 password／sensitive input 狀態停用請求；安全狀態未知時採 fail closed。

## 資料與安裝目錄

Rime 可攜設定與既有 cache 維持原位置：

```text
%APPDATA%\Rime\rime-bilingual\translations.db
%APPDATA%\Rime\rime-bilingual\cache_snapshot.lua
```

大型、機器相依且不可提交 Git 的本機 AI 資產放在：

```text
%LOCALAPPDATA%\RimeBilingual\config.json
%LOCALAPPDATA%\RimeBilingual\runtime\llama.cpp\<version>\
%LOCALAPPDATA%\RimeBilingual\models\gemma-3-1b-it-qat-q4_0\<model>.gguf
%LOCALAPPDATA%\RimeBilingual\logs\
```

`config.json` 只保存 loopback ports、model identity、GGUF 路徑、context size、temperature、timeout 與 offload 設定，不保存候選或上下文。下載中的檔案先放同一資產目錄的暫存名稱；下載、大小／hash 驗證與原子改名成功後才能被設定引用。GGUF、llama.cpp binary、暫存下載與 runtime log 不屬於 repository payload。

## 既有 Rime dictionary／cache 熱路徑

V0.2-ai 保留 V0.2 的讀寫分離設計，不把 AI call 塞進現有 filter：

```text
管理端（不在打字熱路徑）
scripts/cache.ps1
  -> init / put / import
  -> SQLite translations.db
  -> publish
  -> canonical cache_snapshot.lua

Rime schema 初始化
  -> 載入內建 Lua 詞典
  -> 驗證並載入 snapshot 一次
  -> 建立記憶體 table

每個候選
  -> dictionary[candidate.text]
  -> miss 時查 snapshot_cache[candidate.text]
  -> 命中時只改 genuine candidate.comment
  -> yield 原 candidate
```

目前優先順序維持 `dictionary` first、`snapshot cache` second；二者都 miss 時，候選保持不變。V0.2-ai Helper 的結果不會自動穿越這個邊界。若管理者要讓既有 Rime 顯示某批已核對的結果，仍使用既有 `cache.ps1 put/import`、`publish` 與重新部署流程；這是離線管理動作，不是即時 AI 更新。

SQLite 仍是可寫持久資料，canonical snapshot 仍是 Rime 唯一讀取的執行期投影。既有 application id `RBIL`、`user_version = 1`、固定 `zh/en/literal` tuple、revision、canonical parser、容量限制與原子發布契約都不變。

## V0.2 → V0.2-ai 升級策略

升級採 additive、可回退策略：

1. 先驗證現有受管理 V0.2 manifest 與 payload；不覆寫使用者修改的 Rime 檔案。
2. 保留 `%APPDATA%\Rime\rime-bilingual` 的 SQLite、snapshot、revision 與既有備份。
3. 將 Helper、llama.cpp runtime、model 與本機設定安裝至 `%LOCALAPPDATA%\RimeBilingual`；Rime Lua 與 schema patch 不需要為批次 E2E 改動。
4. 驗證 binary／GGUF 後，先啟動只綁 loopback 的 llama-server，再啟動 Helper，依序檢查 `/health` 與一個 batch translation smoke test。
5. 任一步驟失敗都停止新增的本機 AI 程序並回復本次新增／替換的 AI 資產；不得刪除或重建既有 Rime cache。

移除 V0.2-ai 時，AI runtime、model、Helper 設定與 logs 必須與 Rime payload 分開處理。預設保留使用者的 `translations.db`／snapshot；刪除模型或 cache 都需要明確的 purge 選項。回退到 V0.2 只停用／移除 AI 元件，原本的 dictionary／snapshot 註解繼續工作。

## 故障行為

| 故障 | V0.2-ai 行為 |
| --- | --- |
| Helper 未啟動 | batch caller 收到連線失敗；Rime 不受影響。 |
| llama-server 未啟動／模型未載入 | Helper 回 `MODEL_UNAVAILABLE`；不回傳假翻譯。 |
| 模型 timeout | Helper 終止該次等待並回 `MODEL_TIMEOUT`；不產生部分結果。 |
| 模型輸出格式錯誤 | Helper 回 `MODEL_OUTPUT_INVALID`；不發布、不顯示。 |
| AI 資產缺失或設定無效 | 部署／health check 失敗；既有 V0.2 繼續工作。 |
| SQLite／snapshot 缺失或無效 | Lua loader 使用空 cache；dictionary 與中文候選繼續工作。 |
| dictionary 與 cache 都 miss | 原候選不加英文、順序與選取身份不變。 |

所有 AI 故障都發生在 Rime 程序外。V0.3 即使加入自動 request，也必須維持相同行為：中文先顯示，英文允許缺席，任何模型狀態都不能阻塞輸入、選字或翻頁。

## V0.2-ai 驗收

自動化／命令列驗證至少涵蓋：

- Helper 拒絕錯誤 protocol、空／過大 batch 與非空 context。
- 一個 batch 只觸發一次 inference，輸出順序及數量與輸入一致。
- llama-server 使用指定 Gemma GGUF 在 loopback 提供服務，Helper 可完成真實 batch smoke test。
- 模型回傳 malformed JSON、錯誤數量、非字串、空字串或冗長內容時，Helper fail closed。
- Helper／llama-server 僅綁 `127.0.0.1`，設定拒絕非 loopback endpoint。
- 模型未載入、server 中斷與 timeout 時回傳明確錯誤，且既有 Rime 測試仍通過。
- 從 V0.2 升級及回退不變更既有 DB、snapshot、Rime payload 或候選熱路徑。
- 日誌不含候選、context、prompt 或翻譯文字。

既有 Rime 自動化與 Windows 人工驗收仍不可省略：正常拼音、Space／數字鍵／方向鍵選字、PageUp/PageDown、橫向與豎向候選版面，以及快速連續輸入時無可感知停頓。V0.2-ai 的模型 smoke test 與這些 Rime 回歸測試是兩組獨立驗收，前者不得以同步方式嵌入後者。

## 後續演進

- V0.3（本文件頂部定義）：在 Rime 與 Helper 之間加入非同步 request／result 通道、timeout、去重、candidate fingerprint 與 stale result 丟棄；cache hit 仍先行，AI miss 才送出。
- V0.4：Helper/backend 已加入 protocol v3 bounded context、contextual cache namespace 與 English-only model output validation；Rime/native bridge 暫時維持 v2 空 context，直到 recent committed context 能附帶可驗證的安全來源，避免把先前敏感欄位文字帶到後續 request。contextual cache 以 model identity、prompt 與 normalized context 的 SHA-256 放入既有 `translation_mode`，不把 raw context 存入 SQLite。
- V0.5：加入可配置英文 commit shortcut。
- V0.6：加入／確認 idle 600 秒 unload、冷啟動恢復與 VRAM 釋放；只有真正 inference 重置 timer。

若原生 comment UI 最終不足以提供可接受的橫／豎向雙語關係，才另案評估 Weasel UI 修改；不在 V0.2-ai 範圍內。
