# 阶段 13：自动学词 v2（完整采集 + Enter 触发 + 可解释）

> 起因：阶段 12b 的真机验收失败。本文档是设计，不是实现记录。
> 依据：对本地 Typeless 2.7.0（Electron）的拆解，见「二、证据」。

---

## 一、目标

让「听写后改词 → 自动学进词典」在**真实场景**（Chrome/微信/原生输入框）稳定工作，并且
**每一步可解释**（为什么学了 / 为什么没学）。

1. **采集可靠**：浏览器/Electron 的 contenteditable 也能读到文本。
2. **发送信号可靠**：以 Enter 为主信号，不再依赖「字段清空/失焦」。
3. **可解释**：每次学词尝试都落本地记录，能看到 pasted/final/LLM 原始返回/失败原因。
4. **判定不变**：仍然「只在发送后学、只听错、LLM + 本地回退」。

## 二、背景与证据（为什么 12b 失败）

阶段 12b 真机日志：

- Chrome：`AXFocusedUIElement` 返回 **`-25212 (kAXErrorNoValue)`**，80+ 次全失败 → 读不到框。
- Chrome：两次 watch 直接 45s `timeout`（既不清空也不失焦）→ 没结算。
- 微信：AX 读到（53/60 readable），LLM 也调通（deepseek 200），但返回「no mishearing」→ 不学，
  且**无从知道模型看到了什么**。

拆解 `/Applications/Typeless.app`（Electron + 原生 Swift helper）得到：

- `libContextHelper.dylib` 符号：`setFocusedWindowEnhancedUserInterfaces`（设
  `AXEnhancedUserInterface`）、`isBrowserApp`、`findWebArea`、`collectVisibleTexts`、
  `collectContentBefore/After`、`smartJoinTexts`、`CaptureTimeout`、`getFocusedElementInfoAsync`、
  `getFocusedAppInfoAsync`；字符串含 `AXWebArea`、`AXDOMClassList`、`AXURL`、`com.google.Chrome`。
- 主进程字符串：`track-edit-text:start-track/stop-track`、`track_timeout`、
  `lastPressEnterTime`、`[User Edit] 🔵 Enter key pressed`、
  `[User Edit] 🟢 Content edited (small-scale), triggering report`、`auto_add_dictionary`、
  `isTextCaptureBlockedByBlacklist`。
- DB（drizzle）：`history.ax_text`、`ax_html`、`edited_text`、
  `edited_text_status`(默认 `NOT_EXTRACTED`)、`edited_text_attempts`、`hasRevertedAI`。

结论：Typeless 是「原生采集（AX 增强 + 可见文本）→ 键盘 Enter 触发 → edited_text 落库带重试 →
学词」；我们缺的正是采集与触发，以及可解释性。

## 三、范围

- 采集层重做：`core/core/src/learning/ax/*`（AX 增强 + web area + 可见文本）。
- 触发层重做：`core/core/src/learning/watcher.rs` + 复用 `handy-keys` 键盘监听。
- 判定层增强：记录 LLM 原始返回与原因（`core/core/src/learning/llm.rs`）。
- 可解释性：`dictionary.db` 新表 + FFI + 设置页调试区。
- 不改本地 ASR；不新增重型依赖；无自建云/账号/遥测。

## 四、非目标

- 不抄 Typeless 的云同步/账号/订阅；不抄其代码，只借鉴技术路线。
- 不做 Windows/Linux。
- 不做「app-aware 润色」（阶段 4 已否决）。

---

## 五、设计

### 5.1 分层

```
capture(采集)  →  trigger(触发)  →  judge(判定)  →  learn(落库 + 事件)
```

- `capture`：给定「粘贴时刻的聚焦字段」，读其文本与身份。
- `trigger`：观察期间判定「用户已发送」。
- `judge`：从 `(pasted, final)` 得出要学的词对（只听错）。
- `learn`：写词典、写 `learning_attempts`、发事件（弹窗/撤销）。

### 5.2 采集层（`learning/ax`）

新增/改造：

1. **AX 增强**：读之前，对聚焦元素所在的窗口（`AXFocusedWindow`，否则 `AXFocusedApplication`）
   `AXUIElementSetAttributeValue("AXEnhancedUserInterface", true)`。这是 Chrome/Electron 暴露
   AX 树的前提（`libContextHelper` 的 `setFocusedWindowEnhancedUserInterfaces` 同款）。
2. **三级读取**（按成本递增）：
   - `AXValue`（原生控件快路径，现有）。
   - 文本标记 `AXTextMarkerRangeForUIElement` / `AXStringForTextMarkerRange`（现有 web 路径）。
   - **可见文本收集**：找可编辑元素或其祖先 `AXWebArea`，递归收集 `AXStaticText` /
     `AXTextArea` / `AXTextField` 等可见文本，按位置顺序拼接（`smartJoinTexts` 风格）。
     带 `CaptureTimeout`（默认 300ms）与总字符上限（默认 4000）。
3. **字段身份** `FieldIdentity`：优先 `pid + AXIdentifier`，其次 `AXDOMIdentifier` / `AXURL`，
   再退化到 `pid + role + frame`。用于「还是同一个框」判断。
4. 读不到时返回 `None`（沿用「静默、不报错」）；密码框/被禁 app 仍跳过。

接口：
```rust
pub struct FocusedField {
    pub text: String,
    pub identity: FieldIdentity,
    pub strategy: &'static str, // 诊断用
}
pub fn read_focused_field(timeout_ms: u32) -> Option<FocusedField>;
```

### 5.3 触发层（`learning/watcher`）

- **Enter 为主**：观察期间监听 `Key::Return` 的 keyDown（复用 `handy-keys::KeyboardListener`，
  它有 `recv_timeout` 与 `Key`；若与 `HotkeyManager` 的 tap 冲突，则在 `hotkeys.rs` 的监听线程里
  把未匹配的 Return 事件转发给 learning）。命中 Enter → 立刻读字段 → 结算。
- **兜底**（沿用并简化）：字段清空 / 焦点丢失（连续 2s 不可读）/ 前台变化 → 结算；
  45s 超时 → 不学。
- **字段身份变化**：观察到 `identity` 与起始不同 → 立即停止（避免读到别的框），不学。
- 结算条件与原因进入 `WatchMachine`（阶段 12b 已有），新增 `Enter` 与 `IdentityChanged` 两种输入。

### 5.4 判定层（`learning/llm` + `learning/diff`）

- 保留：LLM 只听错（BYOK，复用 active polish provider + key）；失败/不可用 → 本地
  `diff::detect_edits` + `diff::is_likely_mishearing`。
- 新增记录：LLM 原始返回字符串、来源（`llm` / `local` / `none`）、原因（如
  `llm_empty` / `not_related` / `gate_rejected` / `not_mishearing`）。

### 5.5 可解释性（本地表 + 调试页）

`dictionary.db` 新表：

```sql
CREATE TABLE learning_attempts (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at    TEXT NOT NULL,
  bundle_id     TEXT,
  field_id      TEXT,
  pasted        TEXT,
  final_text    TEXT,
  source        TEXT,          -- llm | local | none
  llm_raw       TEXT,
  outcome       TEXT,          -- learned | skipped
  reason        TEXT,          -- 人类可读原因
  learned_json  TEXT           -- 学到的词对 [{pattern,replacement}]
);
```

- 只保留最近 200 条（写入时裁剪）；可清空。
- FFI：`list_learning_attempts(limit)`、`clear_learning_attempts`。
- 设置页调试区新增「学词记录」：列出最近 N 条，显示 pasted→final、来源、原因、学到的词。
- 本地存储、不联网。

### 5.6 隐私

- 仅当用户配置了 provider + key 时才把 `pasted`/`final` 发给该 provider；否则纯本地。
- `learning_attempts` 只存本地；密码框/被禁 app 永不读取。

---

## 六、数据流

```
Enter / 清空 / 失焦 / 前台变化
  ↓ capture: read_focused_field()（AX 增强 + 三级读取）
final == pasted ? 不学
  ↓ judge: llm 只听错 → 失败回退本地门槛
  ↓ learn: 写词典 + 写 learning_attempts + learned-correction/learned-overlay
  ↓ 弹窗（与录音悬浮窗同位）+ 撤销
```

## 七、错误处理

- AX 读不到 / 超时 / 安全输入 / 被禁 app：静默不学，写 attempts（reason=unreadable 等）。
- LLM 任何失败：回退本地；本地无候选则写 attempts（reason 对应）。
- 字段身份变化：停止观察，不学。
- 写词典失败：跳过该条。

## 八、测试与验收

**单元测试**
- `capture` 的可见文本拼接与顺序（用固定的 AX 文本片段序列模拟）。
- `trigger` 的 `WatchMachine`：新增 Enter、IdentityChanged 分支；原有清空/失焦/超时/取代保持。
- `judge`：llm_raw 记录、原因分类；本地门槛不变。
- `learning_attempts`：写入、裁剪到 200、清空、序列化。

**真机验收**
1. Chrome（contenteditable，如 Gmail/Google Docs 输入框）：听写 → 改词 → Enter → 学到 + 弹窗。
2. 微信输入框：同上。
3. TextEdit / 原生输入框：同上。
4. 改意思（早→晚）不学。
5. 调试页能看到每次尝试的 pasted/final/来源/原因。
6. 撤销可用；未配 key 时走本地。

**命令**
```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml
cargo fmt --manifest-path core/core/Cargo.toml --check
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
python3 scripts/check_translations.py
```

## 九、任务拆分

1. `learning/ax`：AXEnhancedUserInterface + `read_focused_field` + 可见文本收集 + `FieldIdentity` + 单测。
2. `learning/watcher`：Enter 监听（handy-keys）+ `WatchMachine` 扩展（Enter / IdentityChanged）+ 单测。
3. `learning/llm`：记录 llm_raw / 原因；判定结果结构化。
4. `learning_attempts` 表 + FFI + 设置页调试区（含新 i18n key，26 语言同步）。
5. 真机验收（Chrome / 微信 / TextEdit）+ 全量测试构建。

## 十、风险与取舍

- **AXEnhancedUserInterface 副作用**：它改变目标 app 的 AX 行为。策略：观察开始时对聚焦窗口设置，
  观察结束（结算/超时/身份变化）时**恢复为原值**（读原值再写回）。真机验证 Chrome 是否被唤醒。
- **可见文本收集的性能/隐私**：遍历 web area 可能慢或读到整页；用 `CaptureTimeout` + 字符上限
  + 只取可编辑区附近。仍只在用户配置了 provider 时才外发。
- **Enter 与输入法**：组字期间 Enter 可能被输入法消费；轮询兜底仍在，真机验证中文输入法。
- **两个键盘监听冲突**：`handy-keys` 的 `HotkeyManager` 与新增 `KeyboardListener` 是否能共存需
  验证；不行则在现有监听线程转发 Return。
- **Typeless 借鉴边界**：只借鉴技术路线（AX 增强、可见文本、Enter 触发、落库），不抄代码、
  不引入其云/账号。

## 十一、与 12b 的关系

- 保留：`WatchMachine` 结算状态机、`diff::is_likely_mishearing`、LLM 只听错 + 本地回退、
  弹窗同位、阈值滑块。
- 替换：AX 读取（新增增强与可见文本）、发送触发（Enter 为主）、新增可解释记录。
- 12b 分支上未提交的诊断性改动（日志增强）在实现 5.2 时一并整理。
