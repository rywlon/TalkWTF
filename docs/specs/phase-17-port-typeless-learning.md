# 阶段 17：移植 Typeless 的采集/触发机制（去云）

> 起因：阶段 16 的学词在真机上时灵时不灵。对 `/Applications/Typeless.app` 做了逆向
> （`libContextHelper.dylib` 符号表 + 反汇编 + Electron 主进程行为串 + `typeless.db` schema），
> 本文档把其中**可移植、无云**的部分落成设计。本文档是设计，不是实现记录。

---

## 一、目标

把 Typeless 的学词机制移植过来，替换阶段 16 里不可靠的部分：

1. **采集**：以聚焦元素/光标为锚，取**有界上下文**（`before` / `after`），不再读整个输入框。
2. **触发**：**键盘事件驱动 + 每次编辑重置去抖 + Enter 计时**，替换固定 200ms 轮询。
3. **判定**：`analysisModification` 的**增/删/改计数 + large-modify 门槛**，拒绝整段重写。
4. **判定结果**：用本地「只听错」门槛（阶段 16 已改为权威），替代 Typeless 的云端决策。

## 二、逆向证据（可移植点）

- 原生库 `libContextHelper.dylib`（Swift，koffi FFI）导出：
  `setFocusedWindowEnhancedUserInterface`、`getFocusedElementInfoAsync(pid)`、
  `getFocusedElementRelatedContentAsync(pid, beforeChars, afterChars)`、
  `getFocusedVisibleTextAsync(pid, maxLength)`、`isBrowserApp`、`findWebArea`、
  `findWebInfoByTraversingUp`、`collectVisibleTexts`、`collectContentBefore/After`、
  `collectContentFromElementRecursively(direction)`、`smartJoinTexts`、
  `CaptureTimeout` / `CaptureResult`。
- 反汇编 `collectContentBefore`：读 `AXParent` → `AXChildren` → `CFEqual` 定位当前元素 →
  沿兄弟节点向前 `getElementText` 累加，直到 `targetChars` 或 `CaptureTimeout.hasExpired`。
- `CaptureResult { status, errorCode, isTimeout, truncated, contentLength, beforeLength,
  afterLength, durationMs }`。
- 浏览器白名单：Chrome / Safari / Edge / Brave / Arc / Opera / Vivaldi / Kagi / DuckDuckGo / Atlas。
- Electron 主进程：`startTrack` 记 `original_input_box` + `refined_inserted_text`；键盘事件
  重置 `setTimeout`（`[User Edit] 🔄 Edit detected, resetting timeout timer`）；Enter 记
  `lastPressEnterTime`；`analysisModification` 产出 `isLargeModify/addedCount/removedCount/
  changedCount`；大改只在 Enter 或刚开始时上报，否则不学。
- `typeless.db`：`refined_text` / `ax_text` / `edited_text` / `edited_text_status` /
  `edited_text_attempts` / `hasRevertedAI`。

## 三、范围

- `core/core/src/learning/ax/*`：有界上下文采集 + CaptureTimeout/CaptureResult +
  浏览器白名单 + 可见文本上限。
- `core/core/src/learning/watcher.rs`：键盘事件驱动 + 去抖重置 + large-modify 结算。
- `core/core/src/learning/diff.rs`：`analysis_modification`（增/删/改计数 + isLargeModify）。
- `core/core/src/learning/llm.rs`：本地门槛为准（阶段 16 已完成，本阶段不动）。

## 四、非目标

- **不做云端**：不实现 Typeless 的 `sendTrackResultToServer` / `auto_add_dictionary` 服务端、
  账号、同步、遥测。判定一律本地。
- 不做 Windows/Linux。
- 不抄 Typeless 源码（只借鉴技术路线）。
- **不做元素身份采集**：Typeless 的 `ElementInfo` / `read_focused_element_info` /
  `getFocusedElementInfoAsync` 不在本阶段范围；`WatchReport.field_id` 不承载 AX 身份。
- 不保证 TTY（Terminal）——见风险节。

---

## 五、设计

### 5.1 采集层（`learning/ax`）

新增类型：

```rust
pub struct CaptureTimeout { timeout_ms: u32, started: Instant }
impl CaptureTimeout { pub fn new(ms: u32) -> Self; pub fn has_expired(&self) -> bool; }

pub struct RelatedContent {
    pub before: String, pub after: String,
    pub before_length: usize, pub after_length: usize,
    pub truncated: bool, pub is_timeout: bool,
}
```

新增函数：

```rust
/// 读聚焦元素光标/选区两侧的有界上下文。
pub fn read_focused_related_content(
    before_chars: usize, after_chars: usize, timeout_ms: u32,
) -> Option<RelatedContent>;

/// 浏览器判定（白名单）。
fn is_browser_app(bundle_id: Option<&str>) -> bool;
```

采集顺序（按成本递增，任一成功即返回）：

1. **原生字段**：`AXValue` + `AXSelectedTextRange`（CFRange）→
   `before = value[..cursor]` 末尾 `before_chars` 个字符，`after = value[cursor..]` 开头 `after_chars` 个字符。
2. **Web 文本标记**：`AXTextMarkerRangeForUIElement` 从起点到选区、选区到终点，
   `AXStringForTextMarkerRange` 取串（Chrome/Electron 的 contenteditable）。
3. **富文本兄弟遍历**：聚焦元素是子节点时，用 `AXParent` + `AXChildren` + `CFEqual` 定位，
   沿兄弟节点向前/向后 `getElementText` 累加，直到 `targetChars` 或超时
   （移植 Typeless 的 `collectContentBefore/After`）。
4. **可见文本兜底**：`collect_visible_texts`（现有）——限制 `max_length` / `max_depth` /
   `CaptureTimeout`，并记录 `truncated`。

- 读之前对聚焦窗口设 `AXEnhancedUserInterface`，**等待 ~30ms** 再读（Chromium 暴露 AX 树的前提）。
- 所有 AX 调用带 messaging timeout；整体带 `CaptureTimeout`。
- 密码框 / 被禁 app / Secure Input 永不读（沿用现有）。

### 5.2 触发层（`learning/watcher`）

- `start_track`（粘贴后）：
  - 读一次 `read_focused_related_content` 作为 `original`（并记 bundle id）。
    > 元素身份采集（Typeless 的 `ElementInfo` / `getFocusedElementInfoAsync`）不在本阶段范围。
  - 记 `inserted_text`（我们刚粘贴的文本）。
  - `started_at`。
- **键盘监听**（复用 `handy-keys::KeyboardListener`）：任一编辑键 keyDown →
  记 `last_key_time` 并**重置去抖计时**；`Return` → 记 `last_enter_time`。
- 轮询（200ms，仅作兜底）：读 `read_focused_related_content`；与上次不同 → 重置去抖计时。
- 结算（任一命中）：
  - **去抖到期**：`now - last_edit >= EDIT_DEBOUNCE`（1.5s）→ 学。
  - **Enter + 字段清空/前台变化** → 立即学（加速）。
  - **前台 app 变化 / 连续 2s 读不到** → 有编辑就学。
  - 安全输入 / 被取代 / 设置关 → 不学。
- **large-modify 门槛**：结算前调 `analysis_modification(original, current, inserted)`；
  若 `is_large_modify`：
  - 最后按键是 Enter 或 `now - started_at < LARGE_MODIFY_GRACE` → 仍结算；
  - 否则**不学**（记录 `reason = "large modify"`）。

### 5.3 判定层（`learning/diff`）

新增纯函数：

```rust
pub struct Modification {
    pub is_large_modify: bool,
    pub added_count: usize,
    pub removed_count: usize,
    pub changed_count: usize,
}
/// 比较 original / current / inserted 的增删改字符数，判断是否整段重写。
pub fn analysis_modification(original: &str, current: &str, inserted: &str) -> Modification;
```

- 以 `inserted` 为基准，用 LCS 统计相对 `original → current` 的增/删/改。
- 阈值：改动字符数 / inserted 长度 超过比例（如 0.5）或绝对量过大 → `is_large_modify`。

### 5.4 判定结果（`learning/llm`）

- 本地「只听错」门槛为准（阶段 16 已改）。LLM 只做可选增益，不再否决。
- **无云端**。

### 5.5 落库与诊断

- `learning_attempts` 增加 `before_length` / `after_length` / `truncated`（可选列）或复用
  `pasted` / `final_text`。reason 文案新增：`large modify`、`capture timeout`、`capture truncated`。

---

## 六、数据流

```
粘贴 → start_track：读 original(before/after) + 记 inserted
  ↓ 键盘事件：编辑键 → 重置 1.5s 去抖；Enter → 记时间
  ↓ 轮询兜底：related content 变化 → 重置去抖
结算（去抖到期 / Enter+清空 / 切 app / 失焦）
  ↓ analysis_modification(original, current, inserted) → is_large_modify?
  ↓ 本地 diff + 只听错门槛（LLM 可选增益）
  ↓ learn → 写词典 + learning_attempts + 弹窗/撤销
```

---

## 七、错误处理

- 采集失败 / 超时 / truncated：静默不学，记 attempt（reason 对应）。
- Secure Input / 被禁 app / 密码框：不读、不学。
- large-modify：不学，记 attempt。
- 写词典失败：跳过该条。
- 键盘监听创建失败：退化为纯轮询去抖（仍可用）。

---

## 八、测试与验收

**单元测试**
- `analysis_modification`：小改（替换一个词）→ 非 large；整段重写 → large；增删计数正确。
- `CaptureTimeout`：到期判定。
- 采集纯逻辑：`before/after` 切片（光标位置）、`smart_join_texts`、truncated 标记（用固定片段模拟）。
- watcher 状态机：编辑重置去抖、去抖到期学、large-modify 不学、Enter+清空加速、切 app/失焦、安全输入不学。

**真机验收**
1. Chrome / 微信：听写 → 改一个词 → 停手 ~1.5s → 学到完整词 + 弹窗。
2. 整段重写（改意思/重写句子）→ 不学。
3. Terminal：能读到当前命令行（光标前）则学；读不到则静默不学（不产生垃圾词）。
4. 撤销可用；调试页能看到 before/after/truncated/reason。

**命令**
```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml
cargo fmt --manifest-path core/core/Cargo.toml --check
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
python3 scripts/check_translations.py
```

---

## 九、任务拆分

1. `diff::analysis_modification` + 单测。
2. `ax`：`CaptureTimeout` / `RelatedContent` / `read_focused_related_content`
   （原生 value+选区 → 文本标记 → 兄弟遍历 → 可见文本兜底）+ 浏览器白名单 + 30ms 等待 + 单测。
3. `watcher`：键盘事件驱动 + 去抖重置 + large-modify 结算 + 单测。
4. `learning_attempts` 诊断字段 + 设置页调试区（如需新 i18n，同步 26 语言）。
5. 全量测试 + 构建 + 真机验收。

---

## 十、风险与取舍

- **TTY（Terminal）**：终端可能不暴露光标/选区；若 `AXSelectedTextRange` 不可用，
  `before` 会退化为整缓冲。策略：对 Terminal 优先用选区切分；仍读不到则不学，**不产生垃圾词**。
- **兄弟遍历的边界**：富文本里兄弟节点可能包含非编辑文本；用 `isText` 标记 + `targetChars` 限制。
- **键盘监听与 HotkeyManager 共存**：阶段 13 已验证可共存（`KeyboardListener` 独立 CGEventTap）；
  若失败则退化为纯轮询。
- **large-modify 阈值**：过严会漏学，过松会学错；先用 0.5 比例 + 绝对上限，真机调。
- **去抖 1.5s**：中途停顿 >1.5s 仍可能学半截；撤销兜底。
- **与阶段 16 的关系**：阶段 16 的「锚定取最长」被本阶段的「光标有界上下文」取代；
  本地门槛、纯删除修复、循环 sleep 保留。
