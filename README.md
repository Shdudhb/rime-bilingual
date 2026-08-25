# 小狼毫雙語候選翻譯

這個專案為 Windows 小狼毫／Rime 拼音候選加入英文註解，不取代輸入法，也不改變候選順序或選字方式。

目前版本是 **V0.3**。它把本機批次翻譯接到 Rime 的打字事件，但以原生 bridge 建立非同步邊界：

```text
一頁中文候選
  -> x64 native bridge（bounded queue，不等待）
  -> RimeTranslateHelper（127.0.0.1:18081，cache first）
  -> llama-server（127.0.0.1:18080）
  -> Gemma 3 1B IT QAT Q4_0 GGUF
  -> 下一次自然的按鍵／候選更新顯示英文註解
```

Lua 主執行緒只做記憶體 lookup 與 `try_submit`／`try_poll`；HTTP、UI Automation、SQLite 與模型等待都在程序外或背景 worker。中文候選永遠先顯示，queue full、Helper 未啟動、模型超時或結果已過期時只是不加英文，不影響原本候選順序、高亮與選字。bridge 不會主動刷新候選；請求完成後若沒有其他事件，英文要到下一次真實按鍵、翻頁或 Rime 自然重算時才會出現。

V0.3 的 `context` 仍固定為空字串，不做上下文消歧；也不包含英文上屏快捷鍵、自動啟動 Helper／llama-server，或 600 秒 idle unload。這些分別屬 V0.4、V0.5 與 V0.6。

## 需求

- Windows 10／11 與已可正常使用的小狼毫（Weasel）
- 已安裝並啟用 `rime_ice` schema，以及可用的 Rime Lua
- Windows PowerShell 5.1 或 PowerShell 7
- **x64** Windows、Weasel 0.17.4／librime 1.13.1，以及符合安裝程式固定 SHA-256 的 `rime.dll`
- Rust 1.85 或更新版本與 Cargo（用來編譯 Rust 2024 edition Helper 與 x64 native bridge）
- 約 1.1 GB 模型空間，另加 llama.cpp runtime 與編譯空間
- Vulkan 可用的顯示卡驅動；也可用 `-GpuLayers 0` 改為 CPU 推理

預設 patch 只針對 `rime_ice`。使用其他 schema 時，不要直接套用 `rime_ice.custom.yaml`。

## 建置 Helper 與 native bridge

在專案根目錄執行：

```powershell
cargo build --release --locked --manifest-path .\helper\Cargo.toml
powershell -ExecutionPolicy Bypass -File .\scripts\build-bridge.ps1
```

成功後應產生：

```text
helper\target\release\RimeTranslateHelper.exe
bridge\target\release\rime_bilingual_bridge.dll
```

## 安裝或從舊 V0.2 升級

先完成兩個 release binary 的建置，再執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

安裝程式會：

- 將 Lua 模組與 `rime_ice` patch 部署到 `%APPDATA%\Rime`。
- 將 bridge 部署到 `%APPDATA%\Rime\rime-bilingual\native\rime_bilingual_bridge.dll`。
- 初始化並保留 `%APPDATA%\Rime\rime-bilingual\translations.db` 與 `cache_snapshot.lua`。
- 將 Helper 安裝到 `%LOCALAPPDATA%\RimeBilingual\bin\RimeTranslateHelper.exe`。
- 將既有 V0.2／V0.2-ai 原地升級成 manifest schema 4／V0.3，沿用原始備份與 cache。

若舊版受管理檔案已被修改、缺失或 manifest 不符合預期，升級會停止，不會覆寫使用者變更。安裝程式會驗證 x64 bridge export 與固定的 Rime ABI；不相容的 Weasel build 會 fail closed。安裝程式不會安裝模型、不會啟動 Helper 或 llama-server，也不會代替使用者執行小狼毫重新部署。

自訂資料位置時，後續命令必須持續使用相同路徑：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1 `
  -RimeUserDir "D:\Rime" `
  -LocalDataRoot "D:\RimeBilingualAI"
```

安裝完成後，從小狼毫功能表選擇「重新部署」。

## 安裝 llama.cpp runtime

模型管理腳本會下載並校驗已固定版本的官方 llama.cpp Vulkan x64 runtime：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\model.ps1 install -Component runtime
```

目前固定資產為 `llama.cpp b10516`、`llama-b10516-bin-win-vulkan-x64.zip`，下載後會檢查大小 `34,861,181` bytes 與 SHA-256：

```text
530f57d2a874ce017827c1e5a926812b9d5de4667248575d1372b1c0acf94d83
```

runtime 會安裝到 `%LOCALAPPDATA%\RimeBilingual\runtime\llama.cpp\b10516`。腳本只接受驗證成功的檔案，並使用暫存路徑完成替換。

## 手動下載並匯入 Gemma

預設模型來自 Google 官方 Hugging Face repository：

```text
Repository: google/gemma-3-1b-it-qat-q4_0-gguf
Revision:   d1be121d36172a4b0b964657e2ee859d61138593
File:       gemma-3-1b-it-q4_0.gguf
Size:       1,003,541,152 bytes
SHA-256:    95e5b8d891cd6a794f66c2a6fb59a41e9562b4660560b854274eceffb628b22a
```

1. 登入 [固定 revision 的 gemma-3-1b-it-q4_0.gguf](https://huggingface.co/google/gemma-3-1b-it-qat-q4_0-gguf/blob/d1be121d36172a4b0b964657e2ee859d61138593/gemma-3-1b-it-q4_0.gguf)，閱讀並接受 Google 的模型授權條款。
2. 從該頁下載精確檔名 `gemma-3-1b-it-q4_0.gguf`。
3. 可先自行查看檔案雜湊：

```powershell
Get-Item -LiteralPath "$env:USERPROFILE\Downloads\gemma-3-1b-it-q4_0.gguf" |
  Select-Object FullName, Length
Get-FileHash -Algorithm SHA256 -LiteralPath "$env:USERPROFILE\Downloads\gemma-3-1b-it-q4_0.gguf"
```

4. 交給管理腳本再次核對大小與 SHA-256，驗證成功才匯入並建立 `config.json`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\model.ps1 import `
  -Profile gemma `
  -SourcePath "$env:USERPROFILE\Downloads\gemma-3-1b-it-q4_0.gguf"
```

模型會放在 `%LOCALAPPDATA%\RimeBilingual\models\gemma-3-1b-it-qat-q4_0`。若原始檔案的大小或 SHA-256 不符，`import` 會拒絕安裝。

`model.ps1 install -Component model -Profile gemma -Token <HF_TOKEN>` 也支援直接下載，但 token 只應在當次命令中提供；手動下載與 `import` 不需要把 token 交給腳本。

## 管理 llama-server

`model.ps1` 使用設定檔啟動並辨識自己管理的 llama-server，只綁定 `127.0.0.1:18080`。

```powershell
# 啟動
powershell -ExecutionPolicy Bypass -File .\scripts\model.ps1 start

# 查看 configured / running / healthy、PID、endpoint 與 model identity
powershell -ExecutionPolicy Bypass -File .\scripts\model.ps1 status

# 健康時 exit code 為 0；未就緒時為 1
powershell -ExecutionPolicy Bypass -File .\scripts\model.ps1 health

# 只停止 PID、執行檔路徑、model path 與 loopback 參數均吻合的受管理程序
powershell -ExecutionPolicy Bypass -File .\scripts\model.ps1 stop
```

預設 context size 是 512、GPU layers 是 999。需要 CPU 推理或不同 port 時，必須在 `import`（或模型 `install`）建立設定時指定，例如：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\model.ps1 import `
  -Profile gemma `
  -SourcePath "$env:USERPROFILE\Downloads\gemma-3-1b-it-q4_0.gguf" `
  -Port 18080 `
  -ContextSize 512 `
  -GpuLayers 0
```

## 啟動 Helper

V0.3 尚未管理程序 lifecycle；每次使用打字時 AI 翻譯前，請先手動啟動 llama-server，再在另一個 PowerShell 視窗以前景方式啟動 Helper：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\model.ps1 start
powershell -ExecutionPolicy Bypass -File .\scripts\model.ps1 health

& "$env:LOCALAPPDATA\RimeBilingual\bin\RimeTranslateHelper.exe" `
  --bind 127.0.0.1:18081 `
  --llama-endpoint http://127.0.0.1:18080/v1/chat/completions `
  --model gemma-3-1b-it-qat-q4_0 `
  --timeout-ms 30000 `
  --cache-path "$env:APPDATA\Rime\rime-bilingual\translations.db" `
  --max-concurrency 2
```

這個視窗保持開啟；按 `Ctrl+C` 停止 Helper。從另一個視窗檢查：

```powershell
Invoke-RestMethod -Uri http://127.0.0.1:18081/health
```

`status` 應為 `ok`，且 `llama_ready` 應為 `True`。此 health request 不執行翻譯。Helper 視窗關閉或電腦重新啟動後都要重新手動啟動；V0.3 不會從 Rime callback 啟動程序。

## 打字時非同步翻譯

安裝、重新部署並啟動兩個本機程序後，照常用拼音輸入。當目前頁候選未命中內建詞典與已載入 snapshot 時，Rime 會將整頁 miss 一次送入 bounded native queue；不會逐字呼叫模型，也不會等待結果。

顯示時序如下：

1. 中文候選立即出現，Space、數字鍵、方向鍵與 PageUp／PageDown 維持原行為。
2. bridge 背景 worker 確認目前 focus 明確不是密碼欄，才向 loopback Helper 送出 protocol v2 request。
3. Helper 先查 SQLite；全數命中時不呼叫模型。部分未命中仍是一個 page request，但每個 unique miss 會各自做一次 singleton model inference，避免小模型讓相近候選互相串義；全部成功後才一次寫回 cache。
4. 翻譯完成後不送 synthetic key。下一次真實按鍵或同頁自然更新若 poll 到完全相同 generation/fingerprint 的 ready result，Lua 對該 pair 最多觸發一次 `refresh_non_confirmed_composition()`，讓 filter 在新 candidate yield 前寫入英文；舊 pair 一律丟棄。

因此停著不按鍵時看不到剛完成的英文是正常行為。快速繼續輸入或翻頁時，舊結果會被丟棄，絕不套到新候選。dictionary／snapshot 命中永遠優先，AI 不覆寫本地翻譯。

## 批次翻譯

在目前的 PowerShell session 直接呼叫腳本，送出一頁候選：

```powershell
& .\scripts\translate-batch.ps1 `
  -Candidates @("我", "你", "他", "今天") `
  -RequestId "readme-0001"
```

不要用 `powershell.exe -File ... -Candidates "我","你",...` 跨程序傳遞這個陣列；Windows PowerShell 的 `-File` 參數繫結只會讓腳本收到第一項。

成功輸出的形狀如下；翻譯文字由模型產生，實際措辭可能不同：

```json
{"protocol_version":1,"request_id":"readme-0001","translations":["I","You","He","Today"],"model":"gemma-3-1b-it-qat-q4_0","elapsed_ms":184}
```

需要從另一個程序啟動 `powershell.exe` 時，改用完整 protocol v1 JSON：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\translate-batch.ps1 `
  -InputJson '{"protocol_version":1,"request_id":"readme-0002","context":"","candidates":["學校","老師"]}'
```

V0.3 的 `context` 仍必須是空字串；候選必須有 1～20 個。CLI 保留 protocol v1 相容性；打字 bridge 使用 protocol v2，並攜帶 generation 與 SHA-256 candidate fingerprint。Helper 對 page request 中每個 unique cache miss 各做一次 singleton inference，再依原候選順序重組；任一 singleton 模型未就緒、timeout 或輸出無效時整個 request fail closed，不會補假翻譯或部分結果。

## Rime 本機詞典與 cache

Rime 的查詢順序是：

```text
內建詞典 -> 已載入的 cache snapshot -> matching async result -> 否則保留原候選
```

Helper 收到請求後另會直接查同一個 SQLite。全 cache hit 不呼叫 llama-server；partial hit 對 ordered unique misses 逐一做 singleton inference，再依原順序重組。並行的相同 ordered miss batch 仍共用同一個 in-flight Helper task。SQLite busy、損壞或 schema 不相容時，Helper 回 `CACHE_UNAVAILABLE`，不會繞過 cache-first 直接推理。

需要人工保存已核對的翻譯時，使用既有離線管理流程：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\cache.ps1 put `
  -SourceText "一言難盡" `
  -TranslatedText "It's hard to explain." `
  -Source "manual"
powershell -ExecutionPolicy Bypass -File .\scripts\cache.ps1 publish
powershell -ExecutionPolicy Bypass -File .\scripts\cache.ps1 validate
```

然後重新部署小狼毫，讓新的 snapshot 在 schema init 載入。打字 callback 本身仍只讀記憶體，不開 SQLite；Helper 在另一個程序讀寫 SQLite。

## 隱私與網路邊界

- Helper 固定只允許綁定 IPv4 loopback；llama endpoint 也必須是 `http://127.0.0.1:<port>/v1/chat/completions`。
- llama-server 由管理腳本以 `--host 127.0.0.1` 啟動，不預設暴露到 LAN。
- 模型與 runtime 安裝後，翻譯資料流不需要外部 API、帳號或 API key。
- Helper 日誌只包含經清理的 request id、batch/cache-hit/miss 數量、model identity、source、latency 與錯誤 code；不記錄候選、翻譯、prompt、fingerprint 或 UI metadata。
- native worker 在建立 HTTP body 前以 Windows UI Automation 檢查 focused element。只有 `IsPassword == false`、所有 UIA 呼叫成功，且檢查前後 foreground HWND/PID 完全一致才送出；密碼欄、unknown、錯誤或 focus 改變都 fail closed，零 HTTP request。
- bridge 與 Helper 只接受數字 IPv4 loopback endpoint，禁用 proxy 與 redirect；沒有雲端 fallback。
- V0.3 不傳送 recent context，protocol 欄位固定為空字串。

## 卸載與資料保留

若只是要釋放 VRAM，可以先停止 llama-server：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\model.ps1 stop
```

卸載本身不再要求手動 `Ctrl+C` Helper。腳本會先檢查 Rime managed payload 是否可安全替換；之後若發現**執行檔路徑精確等於受管理 `bin\RimeTranslateHelper.exe`** 的 Helper 程序，會在任何 Rime payload mutation 前停止它並再次確認已結束。同名但位於其他路徑的程序不會被停止。若 Helper 仍無法安全移除／還原，卸載會在 Rime payload 尚未變更前失敗。

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1
```

預設卸載會還原安裝前的 Rime 檔案、移除受管理 Helper 與 native bridge，但保留兩類使用者資料：

- `%APPDATA%\Rime\rime-bilingual` 的 SQLite 與 snapshot。
- `%LOCALAPPDATA%\RimeBilingual` 的模型、runtime、設定與 logs。

永久刪除 cache：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -PurgeCache
```

永久刪除 Helper、模型、runtime、設定與 logs（若受管理 llama-server 正在執行，腳本會先嚴格核對程序身份再停止）：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -PurgeAIAssets
```

全部永久刪除：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -PurgeCache -PurgeAIAssets
```

自訂資料位置時，卸載要傳入安裝時相同的 `-RimeUserDir` 與 `-LocalDataRoot`。卸載後重新部署小狼毫。

## 驗證

執行完整自動化測試（真實 Gemma E2E 需要已啟動的 llama-server）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\test_cache.ps1
powershell -ExecutionPolicy Bypass -File .\tests\test_filter.ps1
powershell -ExecutionPolicy Bypass -File .\tests\test_install.ps1
powershell -ExecutionPolicy Bypass -File .\tests\test_model.ps1
powershell -ExecutionPolicy Bypass -File .\tests\test_helper_integration.ps1
powershell -ExecutionPolicy Bypass -File .\tests\test_async_contract.ps1
```

只跑不需要真實模型或 Weasel UI 的非同步／Helper 測試：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\test_helper_integration.ps1 -SkipE2E
powershell -ExecutionPolicy Bypass -File .\tests\test_async_contract.ps1
```

`test_async_contract.ps1` 會核對 Lua／bridge／Helper／installer 的共同合約，並執行兩個 Rust crate 的測試；只做快速 static check 時可加 `-SkipCargo`。

實際 Weasel／librime-lua 仍須人工驗證正常拼音、Space／數字鍵／方向鍵選字、PageUp／PageDown，以及直列候選版面。雙語翻譯 UI 僅支援直列；初始化會檢查編譯後的 `build/weasel.yaml`，橫列或無法確認布局時會直接停用 dictionary/cache/AI 註解與 async tracking。再分別測試 Helper/model 正常、啟動很慢、停止與逾時；所有情況中文候選與選字都必須正常，AI 結果只能在下一次自然更新出現且不得改變高亮。

常見問題請見 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)，詳細邊界與介面請見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，V0.3 wire/ABI 合約請見 [docs/ASYNC_PROTOCOL.md](docs/ASYNC_PROTOCOL.md)，產品路線以 [SPEC.md](SPEC.md) 為準。
