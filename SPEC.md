# 小狼毫雙語候選翻譯

## 1. 專案定位

替 **Windows 小狼毫（Weasel / Rime）拼音輸入法**增加「中文候選 + 英文翻譯」功能。

核心原則：

- 平常仍然正常使用拼音輸入中文。
- 不改變原本 Rime 的選字習慣。
- 每個中文候選旁邊／下方同步顯示英文意思。
- 英文屬於輔助資訊，不影響中文輸入。
- 後續可加入快捷鍵，直接把英文候選輸入到目前程式。

---

## 2. 目標使用方式

### 豎向候選

```text
1. 我        I
2. 你        You
3. 他        He
4. 今天      Today
5. 學校      School
```

### 橫向候選

```text
我       你       他       今天
I        You      He       Today
```

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

翻譯模組取得目前候選：

```text
今天
今天的
今天是
```

產生：

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

不應每個候選都獨立呼叫 API。

### 優先順序

```text
本機詞典
   ↓ 沒找到
本機 Cache
   ↓ 沒找到
Google Translate
   ↓ 可選
AI 自然化
```

### 本機詞典

高頻詞直接存在本機：

```text
我 = I
你 = You
他 = He
今天 = Today
明天 = Tomorrow
學校 = School
老師 = Teacher
```

優點：

- 幾乎零延遲
- 不需要網路
- 不消耗 API
- 翻譯結果固定

---

## 5. Google Translate

主要負責普通候選翻譯。

例如：

```text
不知道
→ Don't know

有可能
→ Possibly

沒關係
→ It's okay
```

Google Translate 適合：

- 常規單詞
- 詞組
- 短句
- 快速翻譯

不需要 AI 處理所有候選。

---

## 6. AI / OpenRouter

AI 為第二層功能，而不是主要翻譯引擎。

適合：

```text
一言難盡
說來話長
有點那個
怎麼說呢
```

AI 可以提供比較自然的語境翻譯。

例如：

```text
一言難盡
Google:
Hard to explain

AI:
It's a long story.
```

初期可使用 OpenRouter 免費模型。

---

## 7. API 最佳化

一次取得一頁候選，例如：

```text
我
你
他
今天
我們
```

不要：

```text
我 → request
你 → request
他 → request
今天 → request
我們 → request
```

而是盡量：

```text
[
  "我",
  "你",
  "他",
  "今天",
  "我們"
]
```

一次處理。

同時建立 Cache：

```text
"今天" → "Today"
"我們" → "We"
```

之後再出現就不需要重新查詢。

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
翻譯模組
```

### Lua Filter

主要負責：

- 讀取候選文字
- 找英文翻譯
- 把英文附加到 candidate comment
- 保留原本候選內容

概念：

```text
candidate.text
→ 今天

candidate.comment
→ Today
```

---

## 9. 第一版 UI 實作

優先利用 Rime 本身的 `comment` / annotation。

這樣第一版不需要直接改小狼毫 C++ UI。

目標：

```text
今天    Today
明天    Tomorrow
學校    School
```

如果原版 Weasel 無法漂亮做到：

```text
今天
Today
```

這種上下排列，再考慮第二階段修改 Weasel UI。

---

## 10. Weasel UI 第二階段

如果要做到真正的雙層候選：

### 橫向

```text
┌───────────────────────────────────┐
│ 我      你      他      今天       │
│ I       You     He      Today      │
└───────────────────────────────────┘
```

### 豎向

```text
┌────────────────────┐
│ 我       I          │
│ 你       You        │
│ 他       He         │
│ 今天     Today      │
└────────────────────┘
```

那時才 Fork Weasel。

可能需要修改：

- Candidate window layout
- Candidate text rendering
- Comment rendering
- Horizontal / vertical layout
- secondary text font / spacing
- candidate width calculation

---

## 11. 快捷鍵功能

第一版可先不做。

後續預計加入：

```text
正常選字
→ 中文上屏
```

例如：

```text
Space
→ 今天
```

增加快捷鍵：

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

---

## 12. 英文直接輸入模式

未來可以做到：

```text
jintian
```

候選：

```text
今天        Today
今天的      Today's
今天是      Today is
```

游標停在：

```text
今天
```

按：

```text
Ctrl + Enter
```

直接 commit：

```text
Today
```

不需要：

```text
選中文字
→ 複製
→ Google Translate
→ 複製英文
→ 貼回去
```

這是整個專案最實用的核心之一。

---

## 13. Cache

本機需要建立翻譯 Cache，例如：

```text
translations.db
```

內容：

```text
中文        英文          來源
今天        Today         local
不知道      Don't know    google
一言難盡    It's a long story.  ai
```

可考慮 SQLite。

### Cache Key

至少包含：

```text
source_text
source_language
target_language
```

未來如果加入翻譯模式：

```text
literal
natural
formal
```

也要包含在 key 裡。

---

## 14. 非同步問題

這是目前最大的技術重點之一。

輸入法不能因為 API 請求而卡住。

不能：

```text
Rime Filter
↓
HTTP API
↓
等待 500ms
↓
繼續顯示候選
```

否則每次按鍵都有可能卡頓。

預期架構：

```text
Rime
  │
  ├─ 立即顯示中文候選
  │
  └─ 查 Cache
         │
         ├─ 有 → 立即顯示英文
         │
         └─ 無
              ↓
        Translation Helper
              ↓
         Google / AI
              ↓
           Cache
```

下一次候選刷新時即可取得翻譯。

---

## 15. Translation Helper

可能做一個獨立背景程式：

```text
RimeTranslateHelper.exe
```

負責：

- API 請求
- Google Translate
- OpenRouter
- Cache
- Rate limit
- timeout
- retry
- batch translation

Rime 本身只需要：

```text
輸入文字
→ 查詢結果
```

這樣能避免網路工作直接塞進輸入法核心。

---

## 16. Helper 與 Rime 的通訊方式

初期可以考慮：

### 方法 A：Local HTTP

```text
http://127.0.0.1:xxxx/translate
```

優點：

- 最容易開發
- 最容易 Debug
- 語言不限

### 方法 B：Named Pipe

更像正式 Windows 應用。

優點：

- 延遲低
- 不需要 TCP port
- 本機 IPC 比較乾淨

但第一版沒必要先做。

### 建議

MVP：

```text
Local HTTP
```

成熟後：

```text
Named Pipe
```

---

## 17. 語境問題

單一候選翻譯可能有歧義。

例如：

```text
行
```

可能是：

```text
Okay
Go
Row
Profession
```

所以後續可以把：

```text
目前 composition
前後候選
前面已輸入文字
```

作為 context。

例如：

```text
銀行
```

就比單獨：

```text
行
```

容易翻。

這屬於 V2 功能。

---

## 18. 使用者資料與隱私

需要避免把所有輸入內容無條件傳到網路。

預計：

### 本機優先

```text
Local Dictionary
↓
Cache
↓
API
```

並提供：

```text
關閉網路翻譯
```

之後甚至可以加入：

```text
Private Mode
```

在：

- 密碼欄
- 無痕模式
- 指定 App

完全不呼叫任何外部 API。

---

## 19. MVP

第一個真正要完成的版本：

### V0.1

不用 Google、不用 AI。

只做：

```text
拼音輸入
↓
取得 Rime candidates
↓
本機假翻譯 Dictionary
↓
顯示在 comment
```

例如：

```text
我      I
你      You
今天    Today
```

確認：

- 拼音正常
- 選字正常
- 翻頁正常
- 橫向正常
- 豎向正常
- 不影響原本輸入速度

---

## 20. V0.2

加入本機翻譯資料庫：

```text
Dictionary
+
SQLite Cache
```

---

## 21. V0.3

加入 Google Translate：

```text
Rime
↓
Cache miss
↓
Helper
↓
Google Translate
↓
Cache
```

---

## 22. V0.4

增加：

```text
Ctrl + Enter
```

直接輸入英文。

---

## 23. V0.5

加入 OpenRouter：

```text
普通翻譯
→ Google

自然英文
→ OpenRouter
```

例如快捷鍵：

```text
Ctrl + Enter
→ Google 英文

Ctrl + Shift + Enter
→ AI 自然英文
```

---

## 24. V1.0

如果 comment UI 已經夠好：

直接發布。

如果不夠好：

Fork Weasel，做真正的：

```text
中文
英文
```

雙層候選 UI。

---

## 25. 第一階段暫時不做

為了避免專案一開始太大，先不做：

- 完整輸入法重寫
- 自己做拼音引擎
- 自己做詞頻排序
- 取代 Rime dictionary
- 語音輸入
- 整句 AI 改寫
- 多語言翻譯
- macOS / Linux
- 手機版
- 雲端同步
- 帳號系統

先把：

> **Rime 中文候選 → 英文候選註解**

做到穩定。

---

## 26. 專案最核心的一句話

> **不取代小狼毫，而是在小狼毫現有拼音候選上增加一層即時英文資訊，需要時可以直接把英文輸入。**

這是目前最適合保持不變的核心方向。