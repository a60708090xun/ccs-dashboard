# ccs-dashboard Session Review 功能提案 — 交接文件

> **日期：** 2026-03-31
> **來源：** claude.ai AI 趨勢觀察站 session
> **用途：** 帶入 Claude Code 設計與實作
> **前置文件：** ccs-session-lifecycle-handoff-2026-03-21.md（session lifecycle automation 概念）

---

## 一、概念來源

Facebook 上有人分享了一套「Claude Code 對話紀錄回顧系統」（codotx.com/memory/），核心做法：

1. 解析 Claude Code session 的原始對話紀錄
2. 生成可閱讀的 chat bubble UI（使用者右側黃色、AI 左側灰色）
3. 側邊統計面板：token 數、工時、回合數、tool use 分佈、使用模型
4. 頂部兩個 LLM 生成的摘要區塊：「初始需求精煉」（可當 prompt 複用）和「對話改善建議」
5. 長訊息自動折疊、分批載入（每次 20 則）

他們的使用場景：嵌入技術文章，讓讀者看到「這個功能背後的 AI 協作過程」。

**我們的使用場景不同：分享給主管當 AI 協作進度報告。**

---

## 二、核心設計：雙層產出

主管看的和工程師看的不是同一件事。需要兩層：

### 上層：主管報告（LLM 生成）

這是主管第一眼看到的內容，需要用「做了什麼 + 花了多少成本 + 下一步」的框架：

- **本次完成項目：** 從對話中提取實際產出（功能、修正、文件），不是 tool call 列表
- **耗時與效率指標：** 「50 分鐘完成電子書閱讀器」比「61 回合 278 次工具呼叫」有意義
- **遇到的問題與解決方式：** 從多次來回修正的 pattern 中萃取
- **下一步待做：** 從對話尾段和 TodoWrite 提取

### 下層：原始統計 + 對話紀錄（資料驅動）

作為佐證，主管想看細節時可展開：

- Token 消耗估算
- Session 時間跨度（first message → last message）
- 總回合數
- Tool use breakdown（Read / Edit / Write / Bash / Grep / Agent 各幾次）
- 使用的 AI 模型
- 完整對話紀錄（chat bubble UI，長訊息折疊）

---

## 三、ccs-dashboard 現有可複用的零件

| 零件 | 來源 | 複用方式 |
|------|------|---------|
| JSONL 解析 | `ccs-core.sh` | 直接用：session path 解析、project path 還原 |
| Prompt-Response 配對 | `_ccs_get_pair()` | 直接用：已含 tool_use 摘要提取 |
| Session 時間範圍 | `_ccs_last_active()` + JSONL first message | 直接用 |
| Tool use 統計 | `_ccs_get_pair()` 的 tool_use 解析 | 需擴充：目前只做摘要，需要做 count aggregation |
| Session 狀態判斷 | `_ccs_session_status()` | 可用於篩選（只 review 已完成的 session） |
| Handoff note | `ccs-handoff` | 參考：LLM 摘要的 prompt 設計可借用 |
| Resume prompt | `ccs-resume-prompt` | 參考：「初始需求精煉」跟 resume prompt 邏輯類似 |
| Recent files | `_ccs_recent_files_md()` | 可納入報告的「涉及檔案」區塊 |
| Todo items | `_ccs_todos_md()` | 可納入「下一步」區塊 |

### 需要新建的部分

1. **HTML 渲染引擎：** 把結構化資料轉成靜態 HTML 頁面
2. **LLM 摘要生成：** 呼叫 Claude API（或用 Claude Code subagent）生成上層報告
3. **Tool use aggregation：** 從 JSONL 統計各類工具呼叫次數
4. **Token 估算：** 根據對話文字量估算 token 消耗（中英文不同算法）
5. **CLI 入口：** `ccs-review <session_id>` 命令

---

## 四、實作方案

### Phase 1：`ccs-review` CLI 命令（Markdown 輸出）

不做 HTML，先驗證資料提取和 LLM 摘要的品質。

```bash
ccs-review <session_id>
# 輸出 markdown 到 stdout 或指定檔案
# 包含：統計摘要 + tool use breakdown + 對話摘要（非完整對話）
```

資料來源全部從 JSONL 提取，LLM 摘要用 Claude Code subagent 或直接 API call。

**驗收標準：** 拿 3 個不同長度的 session 跑一次，確認統計數字合理、LLM 摘要準確反映工作內容。

### Phase 2：HTML 渲染

把 Phase 1 的 markdown 結構轉成靜態 HTML 頁面。

**HTML 結構：**

```
┌─────────────────────────────────────────────┐
│  Session Review: [project] - [date]         │
├─────────────────────────────────────────────┤
│                                             │
│  ┌─ 完成項目摘要 ─────────────────────────┐ │
│  │ （LLM 生成，主管看這裡就夠）          │ │
│  └─────────────────────────────────────────┘ │
│                                             │
│  ┌─ 統計面板 ──────────────────────────────┐ │
│  │ 耗時 | 回合數 | Token | 模型           │ │
│  │ Tool Use: Read ×23  Edit ×15  Bash ×8  │ │
│  └─────────────────────────────────────────┘ │
│                                             │
│  ┌─ 改善建議 ──────────────────────────────┐ │
│  │ （LLM 分析對話模式產生）               │ │
│  └─────────────────────────────────────────┘ │
│                                             │
│  ▼ 完整對話紀錄（預設折疊）                 │
│  ┌─────────────────────────────────────────┐ │
│  │        [User]  需求描述...              │ │
│  │ [AI]  回覆...                           │ │
│  │        [User]  追加需求...              │ │
│  │ [AI]  回覆...（tool: Read, Edit）       │ │
│  └─────────────────────────────────────────┘ │
│                                             │
│  ▼ 涉及檔案清單（預設折疊）                 │
│                                             │
└─────────────────────────────────────────────┘
```

**技術選型：**
- 純靜態 HTML + CSS + vanilla JS（無框架依賴）
- 一個 HTML 檔案，CSS/JS 內嵌（方便單檔分享）
- Chat bubble UI 用 CSS flexbox
- 長訊息折疊用 JS toggle
- 統計面板用 CSS grid
- Responsive：手機上統計面板折疊成按鈕展開

**生成方式：**
- 方案 A：Bash template（heredoc + sed 替換），跟 ccs-dashboard 現有風格一致
- 方案 B：Python script（Jinja2 template），更好維護但增加依賴
- **建議選 B：** HTML 生成的複雜度超過 Bash heredoc 的舒適範圍，而且未來 Phase 3 做 PDF 匯出時 Python 生態更方便（weasyprint / reportlab）

### Phase 3（未來）：PDF 匯出

在 Phase 2 的 HTML 基礎上加 `--pdf` flag：

```bash
ccs-review <session_id> --html  # 預設
ccs-review <session_id> --pdf   # PDF 匯出
```

PDF 方案：weasyprint 從 HTML 轉 PDF（最小額外工作量），或 reportlab 做精細排版。

---

## 五、LLM 摘要的 Prompt 設計方向

### 完成項目摘要

```
你是一個開發進度報告生成器。以下是一段 Claude Code session 的對話紀錄。
請提取本次 session 的實際產出，用主管能理解的語言描述。

規則：
- 只列出具體完成的事項（功能、修正、文件產出）
- 不要列 tool call 或技術細節
- 每個項目一句話，動詞開頭
- 如果有半完成的項目，標註進度百分比

對話紀錄：
{conversation_pairs}
```

### 對話改善建議

```
分析以下 Claude Code 對話的溝通模式，找出可改善的地方。

關注：
1. 需求是否一次說清楚，還是多次追加
2. 截圖/錯誤回報是否附帶文字說明
3. 類似的調整是否合併在同一則訊息
4. 是否有不必要的確認問題（答案已在上文）
5. Tool use 是否有明顯浪費（重複讀取同一檔案）

給出 3 條具體建議，每條包含：問題描述 + 改善做法 + 對話中的具體例子。
```

---

## 六、與 ccs-dashboard repo 的整合方式

建議加在 ccs-dashboard 內，不獨立 repo：

- `ccs-review.sh`：CLI 入口 + markdown 輸出
- `ccs-review-html.py`：HTML 渲染（新增 Python 依賴）
- `templates/review.html`：HTML template
- `templates/review.css`：樣式（內嵌到 HTML 時 inline 化）

### 命令介面

```bash
# 基本用法：review 最近一個 session
ccs review

# 指定 session
ccs review <session_id>

# 指定輸出格式
ccs review <session_id> --format html    # 預設
ccs review <session_id> --format md
ccs review <session_id> --format pdf     # Phase 3

# 指定輸出路徑
ccs review <session_id> -o ./reports/

# 跳過 LLM 摘要（只輸出統計 + 對話）
ccs review <session_id> --no-summary

# Review 多個 session（週報模式）
ccs review --since "2026-03-24" --until "2026-03-31"
```

### 週報模式（延伸）

`--since/--until` 可以把一週的多個 session 合併成一份報告：

- 上層：本週完成項目總覽（跨 session 彙整）
- 下層：各 session 的個別統計（可折疊展開）

這對主管進度報告特別有用——不用一個一個 session 看，一份週報涵蓋所有工作。

---

## 七、不做的事

1. **不做即時對話串流。** 這是靜態回顧，不是 live dashboard。
2. **不做跨使用者分享平台。** 輸出的 HTML 是本地檔案，分享靠手動傳檔或放到靜態 hosting。
3. **不做對話編輯/匿名化 UI。** 敏感資訊過濾沿用 ccs-dashboard 現有的路徑縮短邏輯，不做互動式編輯。
4. **不做嵌入式卡片。** codotx 做了可嵌入文章的卡片元件，我們不需要，直接分享完整頁面。

---

## 八、開放問題

1. **LLM 摘要的觸發方式：** 用 Claude Code subagent 跑（需要有活著的 Claude Code session），還是直接打 Anthropic API（需要 API key 設定）？前者跟 ccs-dashboard 的 skill 層整合更自然，後者可以在 CLI 獨立使用。
2. **Token 估算精度：** codotx 說中英文分開算，有 10-20% 誤差。是否值得用 tiktoken / anthropic tokenizer 做精確計算，還是粗估夠用？
3. **敏感資訊過濾範圍：** 分享給主管的報告，除了檔案路徑還有什麼需要過濾？API key、環境變數、內部 IP？需要定義一個 filter rule set。
4. **HTML 的視覺風格：** 要走 codotx 的通訊軟體風格（chat bubble），還是更正式的報告風格（表格 + 段落）？給主管看的話，後者可能更合適。
5. **多 session 週報的 LLM 成本：** 一週如果有 20 個 session，每個都跑一次 LLM 摘要可能太貴。是否可以先合併對話，只跑一次彙整摘要？

---

## 九、建議實作順序

```
Step 1: ccs-review CLI + markdown 輸出（純統計，不含 LLM 摘要）
        → 驗證 JSONL 解析和 tool use aggregation 的正確性

Step 2: 加入 LLM 摘要生成
        → 用 3 個不同 session 測試摘要品質，調 prompt

Step 3: HTML 渲染（Python + template）
        → 單一 HTML 檔案，可在瀏覽器開啟

Step 4: 週報模式（--since/--until）
        → 合併多 session，測試彙整摘要品質

Step 5: PDF 匯出（weasyprint）
        → 從 HTML 轉 PDF
```

每個 Step 都是獨立可交付的，不需要全部完成才有用。Step 1 做完就可以開始用了。

---

## 十、參考資料

- codotx session review 實例：https://codotx.com/memory/ebook-reader/
- codotx 回顧功能開發紀錄：https://codotx.com/memory/session-review/
- 原始 Facebook 分享：https://www.facebook.com/share/1C9CBZkZut/
- ccs-dashboard repo：https://github.com/a60708090xun/ccs-dashboard
- ccs-session-lifecycle-handoff-2026-03-21.md（前一份交接文件，session lifecycle automation 概念）
