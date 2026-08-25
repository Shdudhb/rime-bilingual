# 小狼毫雙語候選翻譯

## 1. 專案定位

替 **Windows 小狼毫（Weasel / Rime）拼音輸入法**增加「中文候選 + 英文翻譯」功能。

核心原則：

- 平常仍然正常使用拼音輸入中文。
- 不改變原本 Rime 的選字習慣。
- 每個中文候選旁邊／下方同步顯示英文意思。
- 英文屬於輔助資訊，不影響中文輸入。
- 英文翻譯可以根據最近輸入上下文做詞義消歧。
- 後續加入快捷鍵，可直接把目前候選的英文翻譯輸入到目前程式。
- **任何翻譯工作都不得阻塞中文候選顯示與正常輸入。**

---

## 2. 目標使用方式

### 直列候選（唯一支援的翻譯 UI）

```text
1. 我        I
2. 你        You
3. 他        He
4. 今天      Today
5. 學校      School
```

翻譯功能只在直列候選模式啟用與驗收。橫列候選不屬於雙語翻譯 UI；若使用者要改回橫列，應先停用 bilingual 翻譯。

英文需要與對應中文候選保持清楚的視覺關係。

---

## 3. 使用流程

使用者輸入拼音：

```text
jintian
```

Rime 正常產生候選：

```text
今天
今天的
今天是
```

翻譯模組取得目前候選與可用上下文：

```text
Context:
我覺得

Candidates:
今天
今天的
今天是
```

翻譯結果：

```text
今天        Today
今天的      Today's
今天是      Today is
```

使用者仍然使用原本：

```text
Space
1 2 3...
↑ ↓
PageUp / PageDown
```

進行選字。

---

## 4. 翻譯策略

### 4.1 AI-first

第一版不要求本地中英字典。

主要翻譯路徑：

```text
Rime candidates + context
        ↓
Translation Cache
        ↓ miss
Local AI
        ↓
English translations
        ↓
Cache result
```

AI 直接處理一頁候選，並根據最近輸入上下文選擇最自然、最常用的英文意思。

例如：

```text
Context: 這次考試考得
Candidate: 還好
→ Not bad
```

```text
Context: 還好我昨天有先準備
Candidate: 還好
→ Luckily
```

### 4.2 本地字典為可選最佳化

未來可選擇加入：

- User Dictionary
- CC-CEDICT
- 高頻詞表

用途是降低 AI 推理次數，而不是核心依賴。

即使完全沒有本地字典，專案也必須可以正常工作。

---

## 5. 本地 AI 模型

預設模型：

```text
Gemma 3 1B IT
Q4 quantization
GGUF
```

建議優先測試：

```text
Gemma 3 1B IT QAT Q4_0
```

替代模型可包括：

```text
Qwen3 0.6B Q4
其他支援 GGUF 的小型 multilingual instruct model
```

模型不是寫死在 Rime 端；應由 Translation Helper / llama.cpp 設定決定。

### 模型任務

模型只負責：

- 中 → 英短翻譯
- 根據最近上下文做詞義消歧
- 一次處理多個候選
- 回傳簡短英文

模型不負責：

- 長篇生成
- 聊天
- 複雜推理
- 改寫整篇文章
- 解答問題

---

## 6. llama.cpp

本地模型使用 **llama.cpp / llama-server** 執行。

預期架構：

```text
Rime
  ↓
Translation Helper
  ↓ localhost HTTP
llama-server
  ↓
Gemma 3 1B IT Q4 GGUF
```

Helper 不應依賴特定模型實作，只需要呼叫本地模型 API。

### 建議初始設定

```text
Context size: 256～512 tokens
Temperature: 0～0.2
Output: 只允許很短的翻譯結果
GPU offload: 優先
```

實際數值以 benchmark 為準。

### 結構化輸出

模型應盡量回傳固定格式，例如 JSON array：

```json
["I", "You", "He", "Today"]
```

輸出數量必須與輸入候選數量一致。

若解析失敗，Helper 不得阻塞 Rime；應忽略該次結果或重新請求。

---

## 7. 批次翻譯

不應每個候選都做一次模型請求。

一次取得一頁候選，例如：

```text
我
你
他
今天
我們
```

禁止：

```text
我 → inference
你 → inference
他 → inference
今天 → inference
我們 → inference
```

應一次送出：

```json
{
  "context": "最近輸入的文字",
  "candidates": ["我", "你", "他", "今天", "我們"]
}
```

一次取得：

```json
["I", "You", "He", "Today", "We"]
```

---

## 8. Rime 端架構

第一階段盡量不 Fork 小狼毫。

```text
Weasel
  │
Rime Engine
  │
拼音 Schema
  │
Lua Filter / Processor
  │
Bilingual Layer
```

### Lua Filter

主要負責：

- 讀取候選文字
- 查詢已存在的翻譯結果
- 把英文附加到 candidate comment
- 保留原本候選內容與排序

概念：

```text
candidate.text
→ 今天

candidate.comment
→ Today
```

### Lua Processor

後續負責：

- 攔截英文上屏快捷鍵
- 取得目前高亮候選
- 取得對應英文結果
- 使用 `commit_text` 類機制輸入英文

---

## 9. 第一版 UI 實作

優先利用 Rime 本身的 `comment` / annotation。

第一版不直接修改小狼毫 C++ UI。

目標：

```text
今天    Today
明天    Tomorrow
學校    School
```

如果原版 Weasel 無法漂亮做到上下排列，再進入第二階段 UI 修改。

### UI 硬性要求

- 中文候選必須立即顯示。
- 英文可以稍後補上。
- 英文更新不得改變 candidate ordering。
- 英文更新不得讓目前高亮候選跳動。
- 英文更新不得造成輸入卡頓。

---

## 10. Weasel UI 第二階段

如果要做到真正的雙層候選：

### 直列

```text
┌────────────────────┐
│ 我       I          │
│ 你       You        │
│ 他       He         │
│ 今天     Today      │
└────────────────────┘
```

只有當 Rime comment 無法達到可接受 UX 時才 Fork Weasel。

可能需要修改：

- Candidate window layout
- Candidate text rendering
- Comment rendering
- Vertical candidate layout only
- Secondary text font / spacing
- Candidate width calculation

---

## 11. 快捷鍵功能

正常選字：

```text
Space
→ 今天
```

預計增加：

```text
Ctrl + Enter
→ Today
```

也就是：

```text
目前候選：
今天    Today
```

正常選：

```text
今天
```

按英文快捷鍵：

```text
Today
```

快捷鍵必須可以設定，不應硬編碼為唯一選項。

---

## 12. 英文直接輸入模式

例如輸入：

```text
jintian
```

候選：

```text
今天        Today
今天的      Today's
今天是      Today is
```

目前高亮：

```text
今天
```

按英文快捷鍵後直接 commit：

```text
Today
```

不需要：

```text
選中文字
→ 複製
→ 開翻譯工具
→ 複製英文
→ 貼回去
```

---

## 13. Translation Cache

本機建立翻譯 Cache，例如：

```text
translations.db
```

建議使用 SQLite。

Cache 不是字典，而是保存模型已經算過的結果。

### 13.1 無上下文候選

例如：

```text
今天 → Today
```

可長期快取。

### 13.2 上下文相關候選

例如：

```text
還好
```

不能只用 `source_text` 當 key，因為：

```text
這次考得還好
→ Not bad
```

```text
還好我帶了雨傘
→ Luckily
```

因此上下文翻譯的 Cache Key 應至少考慮：

```text
candidate text
normalized recent context
model / translation mode
```

可以對 context 做 hash，避免直接使用長文字作為 DB key。

### 13.3 Cache 原則

- Cache hit 時不得呼叫模型。
- 模型版本變更後，可選擇 invalidate 舊 cache。
- Cache 失效不能影響中文輸入。
- Cache 可以設定最大容量與清理策略。

---

## 14. 非同步與延遲

這是專案最重要的技術要求。

禁止：

```text
Rime Filter
↓
等待 AI inference
↓
取得英文
↓
才顯示中文候選
```

正確方式：

```text
Rime
  │
  ├─ 立即顯示中文候選
  │
  └─ 非同步查翻譯
          │
          ├─ Cache hit
          │     ↓
          │   顯示英文
          │
          └─ Cache miss
                ↓
         Translation Helper
                ↓
          llama-server
                ↓
             Gemma
                ↓
             Cache
                ↓
          非同步補上英文
```

### 硬性驗收條件

無論模型處於：

- 未載入
- 冷啟動
- 推理中
- 出錯
- 已卸載

都不得阻塞：

- 拼音輸入
- 中文候選顯示
- 選字
- 翻頁
- 中文上屏

---

## 15. Translation Helper

建立獨立背景程式：

```text
RimeTranslateHelper.exe
```

主要負責：

- 接收 Rime 翻譯請求
- 整理最近上下文
- 候選 batch
- Translation Cache
- 呼叫 llama-server
- 驗證模型輸出
- request 去重
- stale request 丟棄
- timeout
- retry（有限次數）
- 模型狀態偵測

Rime 不直接負責模型推理。

---

## 16. Helper 與 Rime 的通訊方式

MVP 優先使用 Local HTTP：

```text
http://127.0.0.1:PORT
```

可能 API：

```text
POST /translate
GET  /result/{request_id}
GET  /health
```

成熟後可以評估 Named Pipe。

### Local HTTP 優點

- 容易開發
- 容易 Debug
- Lua / C++ / Rust / Python 都容易接
- 可以獨立測試 Helper

### 安全要求

- 只監聽 `127.0.0.1`
- 不應預設暴露到 LAN
- 不需要外部帳號或 API key

---

## 17. 上下文感知翻譯

上下文翻譯是第一版 AI 路線的重要能力，不再列為遙遠的 V2 功能。

可能提供給模型：

```text
最近已 commit 的文字
目前 composition
目前候選列表
目前高亮候選
```

### Context 範圍

不需要把整個輸入歷史交給模型。

初始建議：

```text
最近約 30～100 個中文字
或限制在 256～512 model tokens 內
```

實際數值需 benchmark。

### Context 範例

```text
Context:
你這樣做也

Candidate:
行

Expected:
Fine / Works
```

另一個語境：

```text
Context:
銀行

Candidate:
行
```

模型應能避免機械式固定翻譯。

### 隱私

上下文只傳給本機 llama-server。

預設不得傳到外部網路服務。

---

## 18. 模型生命週期與 VRAM

本專案設計為模型按需載入，而不是永久占用 VRAM。

目前目標硬體假設：

```text
GPU VRAM: 8 GB
系統已有其他 AI / 語音輸入模型常駐
```

因此翻譯模型採 idle unload。

### 18.1 載入

第一次需要 AI 翻譯時：

```text
Translation request
↓
llama-server 喚醒 / 載入模型
↓
推理
```

模型冷啟動期間中文輸入仍正常。

### 18.2 Keep Alive

每次真正執行 AI inference 後重新計時。

```text
Idle timeout = 600 seconds
```

也就是 10 分鐘。

### 18.3 卸載

連續 10 分鐘沒有 AI inference：

```text
Gemma unload
↓
釋放模型與 KV cache VRAM
```

可優先使用 llama.cpp 提供的 idle sleep / unload 能力。

### 18.4 什麼不算 AI activity

以下行為不應延長模型 keep-alive：

- Rime 一般輸入
- Candidate refresh
- Cache hit
- User Dictionary hit（若未來加入）

只有實際模型 inference 才重置 idle timer。

---

## 19. 與其他本地 AI 共存

系統可能同時執行另一個本地 AI，例如語音輸入模型。

因此：

- 翻譯模型不得假設自己獨占 GPU。
- 可設定 GPU / CPU offload。
- 應記錄 AI inference latency。
- 若其他 AI 正在高負載推理，英文翻譯允許稍晚出現。
- 不得為了等英文結果阻塞中文輸入。

未來可加入優先級策略：

```text
語音模型 active
→ 中文輸入照常
→ Cache 結果照常
→ AI 翻譯低優先級 / 延後
```

這不是 MVP 的必要條件，但架構不得阻止未來加入此能力。

---

## 20. Prompt / Model Contract

模型 prompt 應盡可能固定且短。

概念：

```text
You translate Chinese IME candidates into concise natural English.
Use the recent context to disambiguate meaning.
Return one short English translation per candidate.
Preserve order.
Return only a JSON array.
```

輸入：

```json
{
  "context": "這次考試考得",
  "candidates": ["還好", "不錯", "很差"]
}
```

期望輸出：

```json
["Not bad", "Good", "Very bad"]
```

### 模型輸出驗證

Helper 必須驗證：

- JSON 可以解析
- array 長度正確
- 每一項是 string
- 不含明顯多餘說明
- 字串長度合理

不符合規格時不得把垃圾結果顯示到 Rime。

---

## 21. Stale Request 處理

輸入法候選變化非常快。

例如：

```text
wo
↓
wojin
↓
wojintian
```

前一個 AI request 完成時，候選可能早已改變。

因此每次 request 需要：

```text
request_id
composition revision / candidate fingerprint
```

結果回來後：

```text
如果 candidate fingerprint 已過期
→ 丟棄結果
```

不得把舊英文翻譯套到新的候選列表。

---

## 22. MVP

### V0.1 — Rime UI Proof of Concept

不接 AI。

使用固定假翻譯：

```text
我      I
你      You
今天    Today
```

確認：

- 拼音正常
- 選字正常
- 翻頁正常
- 直列候選正常
- 橫列不作為 bilingual 翻譯 UI 驗收模式
- comment 可以顯示英文
- 不影響原本輸入速度

---

## 23. V0.2 — Local AI Translation

加入：

```text
Rime
↓
Translation Helper
↓
llama-server
↓
Gemma 3 1B IT Q4
```

一次 batch 翻譯目前候選。

先不要求漂亮的即時更新，重點是完整資料流可運作。

---

## 24. V0.3 — Cache + Async

加入：

- SQLite Translation Cache
- 非同步 request
- stale request 丟棄
- timeout
- 中文候選零阻塞

這一版開始要求日常可用的輸入流暢度。

---

## 25. V0.4 — Context-aware Translation

加入最近輸入上下文。

測試：

```text
還好 → Luckily / Not bad
行   → Fine / Works / Row ...
算了 → Never mind / I'll pass ...
```

需要根據 context 選義。

---

## 26. V0.5 — English Commit Shortcut

加入可配置快捷鍵，例如：

```text
Ctrl + Enter
```

把目前候選的英文翻譯直接上屏。

---

## 27. V0.6 — Model Lifecycle

加入／確認：

```text
Idle 600 seconds
↓
模型自動卸載
```

確認：

- 冷啟動不阻塞 Rime
- 卸載後 VRAM 正常釋放
- 下一次請求可以自動恢復
- Cache hit 不會無意義地喚醒模型

---

## 28. V1.0

如果 Rime comment UI 已經夠好：

直接使用 comment 方案發布第一個穩定版本。

如果 UX 不夠好：

Fork Weasel，做真正的雙層候選 UI：

```text
中文
英文
```

或：

```text
中文    English
```

---

## 29. Benchmark

至少比較：

```text
Gemma 3 1B IT Q4
Qwen3 0.6B Q4
```

可選測試 Q8 作為品質基準。

Benchmark 內容應貼近日常輸入，而不是一般聊天 benchmark。

### 指標

- 首次模型載入時間
- warm inference latency
- 一頁 candidates 翻譯 latency
- VRAM 使用量
- 與其他本地 AI 同時使用時的延遲
- 中文 → 英文基本翻譯正確率
- 上下文選義正確率
- JSON format failure rate

### 測試案例

```text
Context: 這次考試考得
Candidate: 還好
Expected: Not bad
```

```text
Context: 還好我昨天有先準備
Candidate: 還好
Expected: Luckily
```

```text
Context: 你這樣做也
Candidate: 行
Expected: Fine / Works
```

```text
Context: 他說太貴了，所以我就
Candidate: 算了
Expected: Never mind / I'll pass / decided against it
```

最終模型選擇以實際延遲與翻譯品質為準，不以參數量單獨決定。

---

## 30. 第一階段暫時不做

為避免專案一開始過大，先不做：

- 完整輸入法重寫
- 自己做拼音引擎
- 自己做詞頻排序
- 取代 Rime dictionary
- 雲端翻譯 API 作為必要依賴
- Google Translate 作為必要依賴
- OpenRouter 作為必要依賴
- 大型 LLM
- 整句 AI 改寫
- 多語言翻譯
- macOS / Linux
- 手機版
- 雲端同步
- 帳號系統

可選的本地字典也不屬於 MVP 必要條件。

先把：

> **Rime 中文候選 → 本地 AI 上下文英文候選註解**

做到穩定。

---

## 31. 專案核心原則

> **不取代小狼毫，而是在小狼毫現有拼音候選上增加一層由本地 AI 產生的即時英文資訊；中文輸入永遠優先，AI 可以慢，但不能讓輸入法慢。**
