# V0.3 疑難排解

## `Built Helper is missing`

先在專案根目錄建置 release binary，再重新安裝：

```powershell
cargo build --release --locked --manifest-path .\helper\Cargo.toml
powershell -ExecutionPolicy Bypass -File .\scripts\build-bridge.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

## `Built native bridge is missing`／bridge export 或 x64 驗證失敗

從 x64 PowerShell 執行 `scripts\build-bridge.ps1`。安裝程式只接受 x64 PE，且 DLL 必須只 export `luaopen_rime_bilingual_bridge`。不要改名使用其他架構的 DLL，也不要另外放一份 `lua54.dll`；bridge 會從已載入的 `rime.dll` 動態解析 Lua 5.4 ABI。

## `Unsupported rime.dll build`／重新部署後 async disabled

V0.3 固定支援 Weasel 0.17.4／librime 1.13.1 x64 與安裝程式記載的 `rime.dll` SHA-256。安裝或 bridge configure 遇到不同 ABI 時會 fail closed，以免在輸入法程序內載入不相容原生碼。確認小狼毫安裝在預期位置且版本完全相同；不要跳過 hash 檢查。

## Gemma 下載出現 401／403

Gemma 需要先在官方 Hugging Face 頁面登入並接受授權。手動下載 `gemma-3-1b-it-q4_0.gguf` 後，使用 `model.ps1 import -Profile gemma -SourcePath <檔案>`；不要重新命名成其他 profile 的檔名。

## `Source model failed size or SHA-256 verification`

檔案必須同時符合 README 記載的精確大小與 SHA-256。刪除不完整下載並從固定 repository／revision 重下；不要用同名但不同量化或不同 revision 的 GGUF。

## llama-server 啟動後立即退出

先查看：

```powershell
Get-Content "$env:LOCALAPPDATA\RimeBilingual\logs\llama-server.stderr.log" -Tail 100
```

常見原因是 18080 已被占用、Vulkan driver 不可用，或模型／runtime 不完整。可在重新 `import` 時用 `-GpuLayers 0` 建立 CPU 設定；換 port 時 Helper 的 `--llama-endpoint` 也必須使用同一 port。

## `health` 顯示 `running: true`、`healthy: false`

模型可能仍在載入；稍後重試 `model.ps1 health`。若持續失敗，檢查 stderr log 與 18080 是否被其他程序占用。`status` 本身只回報狀態；`health` 未就緒時會以 exit code 1 結束。

## Helper health 的 `llama_ready` 是 `False`

確認 `model.ps1 health` 成功，並確認 Helper 使用：

```text
http://127.0.0.1:18080/v1/chat/completions
```

若自訂 llama port，重啟 Helper 並同步修改 `--llama-endpoint`。Helper port 預設是 18081，不要與 llama-server 的 18080 混用。

## `MODEL_TIMEOUT` 或翻譯很慢

Helper 預設 upstream timeout 是 30 秒，但 Rime bridge 的 request timeout 預設是 3 秒。CPU 推理或冷載入可能超時；可調整 Helper 的 `--timeout-ms` 與 `rime_ice.custom.yaml` 的 `rime_bilingual/request_timeout_ms`，然後重新部署。兩者都是 worker-side 上限，Rime callback 不會同步等待；timeout 只讓該次英文缺席。

## `MODEL_OUTPUT_INVALID`

模型輸出不是嚴格、等長的 JSON string array，Helper 因此 fail closed。先確認使用預設 Gemma profile 與固定模型檔；不要把錯誤結果手動發布到 Rime cache。

## Rime 完全沒有打字時 AI 翻譯

依序確認：

1. 已用 V0.3 installer 部署 bridge 與 Lua，並重新部署小狼毫。
2. `model.ps1 health` 成功。
3. Helper 正在前景執行，`http://127.0.0.1:18081/health` 可回應。
4. Helper 使用 `%APPDATA%\Rime\rime-bilingual\translations.db`；自訂 Rime 目錄時要同步傳 `--cache-path`。
5. schema 的 `rime_bilingual/async_enabled` 是 `true`，endpoint 是 `http://127.0.0.1:18081`。

V0.3 不會自動啟動 llama-server 或 Helper。兩個程序都停止時，dictionary／snapshot 註解和中文候選仍應正常。

## Helper 已完成，但英文沒有立刻出現

這是 V0.3 的既定更新語義。worker 不接觸 Rime Context、不送 synthetic key，也不呼叫 `refresh_non_confirmed_composition`；結果只會在下一次真實按鍵、PageUp／PageDown 或 Rime 自然重算時被 poll。若期間 composition、候選頁或 candidate identity 已改變，generation/fingerprint 不符的 stale result 會被丟棄。

## 密碼欄或某些程式永遠沒有 AI 翻譯

這通常是安全機制，而不是模型故障。只有 UI Automation 明確回報 `IsPassword == false`、查詢全部成功，且檢查前後 foreground HWND/PID 相同，bridge 才建立 loopback HTTP request。密碼欄、UIA unsupported/unknown/error 或 focus 改變都會 fail closed。不要為了讓該程式出現翻譯而關閉這項防線；本機 dictionary/snapshot 仍可正常顯示。

## 快速輸入／翻頁時英文偶爾缺席

這是預期的 stale 與 backpressure 行為。pending queue 最多 8 批，滿時 `try_submit` 立即回 `queue_full`；rapid input 產生新 generation 後，舊 completion 不會套到新頁。兩者都只造成英文暫時缺席，不應卡住中文、改變候選順序或讓高亮跳動。

## `CACHE_UNAVAILABLE`

Helper 在任何推理前先驗證並查詢 SQLite。資料庫 busy、損壞或 schema/application id 不相容時會回 `CACHE_UNAVAILABLE`，不會繞過 cache-first 直接呼叫模型。停止其他長時間寫入者，再執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\cache.ps1 validate
```

不要刪除資料庫來「修好」問題；若要重建或 purge，先備份並明確決定是否保留使用者翻譯。

## 如何暫時停用打字時 request

把 schema patch 的 `rime_bilingual/async_enabled` 設為 `false` 並重新部署。內建 dictionary 與 snapshot lookup 仍可使用；不必刪除模型、Helper 或 cache。

## 想要上下文消歧、自動啟動或 idle unload

V0.3 固定送出空 `context`，也不管理 Helper／llama-server lifecycle。最近輸入上下文屬 V0.4；自動 lifecycle 與 600 秒 idle unload 屬 V0.6，目前不是故障排解選項。

## 卸載因檔案已修改而停止

卸載器會拒絕覆寫或刪除已被修改的受管理檔案。先備份自己的變更，再還原 manifest 所記錄的安裝內容後重試。`-PurgeCache` 與 `-PurgeAIAssets` 都是永久刪除選項，只有確定不要保留資料時才使用。
