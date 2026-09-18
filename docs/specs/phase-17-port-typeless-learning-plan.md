# 阶段 17 实现计划：移植 Typeless 采集/触发（去云）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Typeless 的学词采集/触发机制干净重写进 TalkWTF：光标/选区相对的有界采集 + 键盘事件驱动的编辑去抖 + large-modify 门槛；判定仍用本地「只听错」门槛。

**Architecture:** `diff` 加 `analysis_modification`（增/删/改计数）；`ax` 加 `CaptureTimeout`/`ElementInfo`/`RelatedContent` 与 `read_focused_related_content`（原生 `AXValue`+`AXSelectedTextRange` 切片 → Web 文本标记 → 可见文本兜底）；`watcher` 用 `KeyboardListener` 驱动编辑去抖，结算前过 large-modify 门槛。**不移植云端。**

**Tech Stack:** Rust（`core/core`，`objc2` / `handy-keys` / `strsim` 已有）、macOS Accessibility API。

**Spec:** `docs/specs/phase-17-port-typeless-learning.md`

## Global Constraints

- **不抄 Typeless 源码**（只借鉴技术路线，干净重写）；**不实现任何自建云/账号/同步/遥测**。
- BYOK：只在用户已配 provider 时才直连；学词判定一律本地。
- 不改本地 ASR 运行时；不新增重型依赖；不新增设置项。
- 命令前 `export PATH="/opt/homebrew/opt/rustup/bin:$PATH"`；测试绕过代理：
  `NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost`。
- 新增 i18n key 必须同步 26 个语言包（`scripts/check_translations.py` 校验）。
- 只改 `core/core/src/learning/*`；不动 Swift（除非接口必须同步）。
- 不写无谓注释；沿用现有风格。

---

### Task 1: `diff::analysis_modification`（增/删/改计数 + large-modify）

**Files:**
- Modify: `core/core/src/learning/diff.rs`

**Interfaces:**
- Produces:
  ```rust
  pub struct Modification {
      pub is_large_modify: bool,
      pub added_count: usize,
      pub removed_count: usize,
      pub changed_count: usize,
  }
  pub fn analysis_modification(original: &str, current: &str, inserted: &str) -> Modification;
  ```

- [ ] **Step 1: 写失败测试**

在 `diff.rs` 的 `mod tests` 末尾追加：

```rust
    #[test]
    fn analysis_modification_flags_a_small_correction() {
        // One term replaced inside a dictated sentence: not a large modify.
        let m = analysis_modification(
            "客人说他想做C3XO，请问可以吗？",
            "客人说他想做Cica Exo，请问可以吗？",
            "客人说他想做C3XO，请问可以吗？",
        );
        assert!(!m.is_large_modify);
        assert!(m.changed_count + m.added_count + m.removed_count > 0);
    }

    #[test]
    fn analysis_modification_flags_a_whole_rewrite() {
        // The user rewrote the sentence: a large modify.
        let m = analysis_modification(
            "the quick brown fox jumps over the lazy dog",
            "please schedule the meeting for next tuesday morning",
            "the quick brown fox jumps over the lazy dog",
        );
        assert!(m.is_large_modify);
    }

    #[test]
    fn analysis_modification_counts_a_pure_deletion() {
        let m = analysis_modification(
            "客人说他想做C3XO，请问可以吗？",
            "客人说他想做，请问可以吗？",
            "客人说他想做C3XO，请问可以吗？",
        );
        assert_eq!(m.added_count, 0);
        assert!(m.removed_count >= 3);
    }
```

- [ ] **Step 2: 运行确认失败**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::diff
```
Expected: 编译失败（`analysis_modification` 不存在）。

- [ ] **Step 3: 实现**

在 `diff.rs` 中 `pub fn detect_edits` 之前插入：

```rust
/// How much an edit changed relative to the dictated text. Mirrors Typeless's
/// `analysisModification`: a small localized correction is learnable, a whole
/// rewrite is not.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Modification {
    pub is_large_modify: bool,
    pub added_count: usize,
    pub removed_count: usize,
    pub changed_count: usize,
}

/// Largest fraction of the text a learnable correction may touch.
const LARGE_MODIFY_RATIO: f64 = 0.5;
/// Absolute cap, so a very short dictation cannot be almost entirely rewritten.
const LARGE_MODIFY_MAX_CHARS: usize = 40;

/// Compare the dictated text with the edited text and count the character-level
/// additions, removals and replacements.
pub fn analysis_modification(original: &str, current: &str, inserted: &str) -> Modification {
    let old: Vec<char> = original.chars().collect();
    let new: Vec<char> = current.chars().collect();

    let mut added = 0usize;
    let mut removed = 0usize;
    let mut changed = 0usize;

    for (old_start, old_end, new_start, new_end) in lcs_hunks(&old, &new) {
        let old_len = old_end - old_start;
        let new_len = new_end - new_start;
        match (old_len, new_len) {
            (0, n) => added += n,
            (m, 0) => removed += m,
            (m, n) => {
                let shared = m.min(n);
                changed += shared;
                if m > n {
                    removed += m - n;
                } else {
                    added += n - m;
                }
            }
        }
    }

    let baseline = inserted.chars().count().max(1);
    let touched = added + removed + changed;
    let is_large_modify =
        touched > LARGE_MODIFY_MAX_CHARS || (touched as f64 / baseline as f64) > LARGE_MODIFY_RATIO;

    Modification {
        is_large_modify,
        added_count: added,
        removed_count: removed,
        changed_count: changed,
    }
}
```

- [ ] **Step 4: 运行确认通过**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::diff
cargo fmt --manifest-path core/core/Cargo.toml --check
```
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add core/core/src/learning/diff.rs
git commit -m "feat(learning): analysis_modification 增删改计数 + large-modify 门槛（阶段 17 任务 1）"
```

---

### Task 2: `ax` 有界上下文采集（光标/选区相对）

**Files:**
- Modify: `core/core/src/learning/ax/mod.rs`

**Interfaces:**
- Consumes: `diff::analysis_modification`（Task 1，本任务不直接用）。
- Produces:
  ```rust
  pub struct CaptureTimeout { timeout_ms: u32, started: Instant }
  impl CaptureTimeout { pub fn new(ms: u32) -> Self; pub fn has_expired(&self) -> bool; }

  pub struct ElementInfo {
      pub role: Option<String>, pub subrole: Option<String>, pub value: Option<String>,
      pub identifier: Option<String>, pub dom_identifier: Option<String>,
      pub dom_class: Option<String>, pub url: Option<String>,
  }

  pub struct RelatedContent {
      pub before: String, pub after: String,
      pub truncated: bool, pub is_timeout: bool,
  }

  pub fn read_focused_related_content(before_chars: usize, after_chars: usize, timeout_ms: u32)
      -> Option<RelatedContent>;
  pub fn read_focused_element_info(timeout_ms: u32) -> Option<ElementInfo>;
  fn is_browser_app(bundle_id: Option<&str>) -> bool;
  ```

- [ ] **Step 1: 写失败测试（纯逻辑）**

在 `ax/mod.rs` 的 `mod tests` 末尾追加：

```rust
    #[test]
    fn slice_before_after_splits_at_the_cursor() {
        // Cursor after "C3XO" in "他想做C3XO，可以吗".
        let (before, after) = slice_before_after("他想做C3XO，可以吗", 8, 100, 100);
        assert_eq!(before, "他想做C3XO");
        assert_eq!(after, "，可以吗");
    }

    #[test]
    fn slice_before_after_bounds_the_window() {
        let (before, after) = slice_before_after("abcdefghij", 5, 3, 2);
        assert_eq!(before, "cde");
        assert_eq!(after, "fg");
    }

    #[test]
    fn capture_timeout_expires() {
        let timeout = CaptureTimeout::new(0);
        assert!(timeout.has_expired());
        let fresh = CaptureTimeout::new(5000);
        assert!(!fresh.has_expired());
    }

    #[test]
    fn browser_whitelist_matches_known_browsers() {
        assert!(is_browser_app(Some("com.google.Chrome")));
        assert!(is_browser_app(Some("company.thebrowser.Browser")));
        assert!(!is_browser_app(Some("com.apple.TextEdit")));
        assert!(!is_browser_app(None));
    }
```

- [ ] **Step 2: 运行确认失败**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/src/../Cargo.toml learning::ax
```
Expected: 编译失败。

- [ ] **Step 3: 加 FFI 与常量**

在 `ApplicationServices` extern 块加：

```rust
    fn AXValueCreate(the_type: u32, value_ptr: *const c_void) -> CFTypeRef;
```

在 `CoreFoundation` extern 块加：

```rust
    fn AXValueGetType(value: CFTypeRef) -> u32;
```

在常量区加：

```rust
/// `kAXValueCFRangeType`.
const AX_VALUE_CFRANGE: u32 = 4;
const ATTR_SELECTED_TEXT_RANGE: &str = "AXSelectedTextRange";
const PARAM_STRING_FOR_RANGE: &str = "AXStringForRange";
/// How long to wait after enabling the enhanced tree so Chromium can build it.
const ENHANCE_SETTLE: Duration = Duration::from_millis(30);

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct CFRange {
    location: isize,
    length: isize,
}
```

- [ ] **Step 4: 实现类型与纯函数**

```rust
/// A per-capture deadline. Typeless's `CaptureTimeout`.
pub struct CaptureTimeout {
    timeout_ms: u32,
    started: Instant,
}

impl CaptureTimeout {
    pub fn new(timeout_ms: u32) -> Self {
        Self { timeout_ms, started: Instant::now() }
    }

    pub fn has_expired(&self) -> bool {
        self.started.elapsed() >= Duration::from_millis(self.timeout_ms as u64)
    }
}

pub struct ElementInfo {
    pub role: Option<String>,
    pub subrole: Option<String>,
    pub value: Option<String>,
    pub identifier: Option<String>,
    pub dom_identifier: Option<String>,
    pub dom_class: Option<String>,
    pub url: Option<String>,
}

pub struct RelatedContent {
    pub before: String,
    pub after: String,
    pub truncated: bool,
    pub is_timeout: bool,
}

/// Split a field's text at a UTF-16 cursor offset, keeping at most `before_chars`
/// characters before it and `after_chars` after it.
fn slice_before_after(text: &str, cursor_utf16: usize, before_chars: usize, after_chars: usize)
    -> (String, String)
{
    let units: Vec<u16> = text.encode_utf16().collect();
    let cursor = cursor_utf16.min(units.len());
    let before_start = cursor.saturating_sub(before_chars);
    let after_end = (cursor + after_chars).min(units.len());
    let before = String::from_utf16_lossy(&units[before_start..cursor]);
    let after = String::from_utf16_lossy(&units[cursor..after_end]);
    (before, after)
}

/// Browsers whose editable content needs the web (text-marker) path.
fn is_browser_app(bundle_id: Option<&str>) -> bool {
    const BROWSERS: [&str; 10] = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",
        "com.duckduckgo.macos.browser",
        "com.openai.atlas",
    ];
    bundle_id.is_some_and(|id| BROWSERS.contains(&id))
}
```

- [ ] **Step 5: 实现选区读取与 `read_focused_related_content`**

```rust
/// The element's selected text range as a UTF-16 cursor offset, when it has one.
fn selected_cursor(element: AXUIElementRef) -> Option<usize> {
    let value = copy_value(element, ATTR_SELECTED_TEXT_RANGE)?;
    if unsafe { AXValueGetType(value.raw()) } != AX_VALUE_CFRANGE {
        return None;
    }
    let mut range = CFRange::default();
    let ok = unsafe {
        AXValueGetValue(
            value.raw(),
            AX_VALUE_CFRANGE,
            &mut range as *mut CFRange as *mut c_void,
        ) != 0
    };
    if !ok || range.location < 0 {
        return None;
    }
    Some((range.location + range.length.max(0)) as usize)
}

pub fn read_focused_element_info(_timeout_ms: u32) -> Option<ElementInfo> {
    if !is_trusted() || is_blocked_app(frontmost_bundle_id().as_deref()) {
        return None;
    }
    let focused = focused_element()?;
    set_timeout(focused.raw());
    Some(ElementInfo {
        role: copy_string(focused.raw(), ATTR_ROLE),
        subrole: copy_string(focused.raw(), ATTR_SUBROLE),
        value: copy_string(focused.raw(), ATTR_VALUE),
        identifier: copy_string(focused.raw(), "AXIdentifier"),
        dom_identifier: copy_string(focused.raw(), "AXDOMIdentifier"),
        dom_class: copy_string(focused.raw(), "AXDOMClassList"),
        url: copy_string(focused.raw(), "AXURL"),
    })
}

/// Read the focused field's text around the cursor: `before_chars` characters
/// before it and `after_chars` after it. Bounded, so a terminal's whole scrollback
/// is never captured. `None` means nothing readable.
pub fn read_focused_related_content(
    before_chars: usize,
    after_chars: usize,
    timeout_ms: u32,
) -> Option<RelatedContent> {
    if !is_trusted() || crate::secure_input::is_enabled_now() {
        return None;
    }
    if is_blocked_app(frontmost_bundle_id().as_deref()) {
        return None;
    }

    let timeout = CaptureTimeout::new(timeout_ms);
    let focused = focused_element()?;
    set_timeout(focused.raw());

    // Native fields: the value plus the selection range gives a true cursor split.
    if let Some(value) = native::read(focused.raw()) {
        if let Some(cursor) = selected_cursor(focused.raw()) {
            let (before, after) = slice_before_after(&value, cursor, before_chars, after_chars);
            return Some(RelatedContent { before, after, truncated: false, is_timeout: false });
        }
    }

    // Web content: read the editable element's text (already bounded to the field,
    // not the page); split at the cursor when a selection range is available.
    if let Some(text) = read_element(focused.raw())
        .or_else(|| read_ancestor(focused.raw()))
        .map(|read| read.text)
    {
        let cursor = selected_cursor(focused.raw()).unwrap_or(text.encode_utf16().count());
        let (before, after) = slice_before_after(&text, cursor, before_chars, after_chars);
        return Some(RelatedContent {
            before,
            after,
            truncated: before_chars < cursor || after_chars + cursor < text.encode_utf16().count(),
            is_timeout: timeout.has_expired(),
        });
    }

    // Last resort: bounded visible-text collection.
    if let Some(read) = collect_visible_text(focused.raw(), Instant::now() + Duration::from_millis(timeout_ms as u64)) {
        let units = read.text.encode_utf16().count();
        let (before, after) = slice_before_after(&read.text, units, before_chars, after_chars);
        return Some(RelatedContent {
            before,
            after,
            truncated: true,
            is_timeout: timeout.has_expired(),
        });
    }

    None
}
```

注意：`read_element`/`read_ancestor`/`collect_visible_text`/`copy_value`/`copy_string`/`focused_element` 都是现有私有函数，直接用。

- [ ] **Step 6: 加 30ms 等待**

在 `enable_enhanced_user_interface()` 末尾（返回前）加：

```rust
    std::thread::sleep(ENHANCE_SETTLE);
```

- [ ] **Step 7: 运行确认通过**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::ax
cargo fmt --manifest-path core/core/Cargo.toml --check
```
Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add core/core/src/learning/ax/mod.rs
git commit -m "feat(learning): 光标/选区相对的有界采集（阶段 17 任务 2）"
```

---

### Task 3: `watcher` 键盘事件驱动 + large-modify 结算

**Files:**
- Modify: `core/core/src/learning/watcher.rs`

**Interfaces:**
- Consumes: `ax::read_focused_related_content(before_chars, after_chars, timeout_ms)`、
  `ax::read_focused_element_info`（Task 2）；`diff::analysis_modification`（Task 1）。
- Produces: 无对外新接口；`watch_for_edit(pasted)` 行为更新。

- [ ] **Step 1: 写失败测试**

在 `watcher.rs` 的 `mod tests` 追加：

```rust
    #[test]
    fn large_modify_is_rejected() {
        let original = "the quick brown fox jumps over the lazy dog";
        let current = "please schedule the meeting for next tuesday morning";
        let m = crate::learning::diff::analysis_modification(original, current, original);
        assert!(m.is_large_modify);
    }

    #[test]
    fn a_small_correction_is_not_large_modify() {
        let original = "客人说他想做C3XO，请问可以吗？";
        let current = "客人说他想做Cica Exo，请问可以吗？";
        let m = crate::learning::diff::analysis_modification(original, current, original);
        assert!(!m.is_large_modify);
    }
```

- [ ] **Step 2: 运行确认失败**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::watcher
```
Expected: 编译失败（`diff::analysis_modification` 尚未导出到该路径；若已导出则先失败于测试文件缺失）。

- [ ] **Step 3: 重新引入键盘监听驱动去抖**

在 `observe` 的轮询循环里，恢复键盘监听（阶段 16 曾删掉）：

```rust
    let listener = handy_keys::KeyboardListener::new().ok();
```

每轮先收键：

```rust
    // Any edit key resets the debounce; Enter is recorded for the fast path.
    if let Some(listener) = listener.as_ref() {
        while let Ok(event) = listener.try_recv() {
            if event.is_key_down {
                machine.on_key(event.key == Some(handy_keys::Key::Return));
            }
        }
    }
```

`WatchMachine` 增加方法（`last_edit` 已存在）：

```rust
    /// A key was pressed while watching: any key resets the debounce (the user is
    /// still editing); Enter is remembered for the send fast-path.
    fn on_key(&mut self, is_enter: bool) {
        self.last_edit = Some(Instant::now());
        if is_enter {
            self.pending_enter = true;
        }
    }
```

并在结构体加回 `pending_enter: bool` 字段（`new` 里初始化 `false`；`on_readable` 里文本变化时清空；字段清空且 `pending_enter && edited` → `Learn(Enter)`）。

- [ ] **Step 4: 改用有界采集**

把 `observe` 里所有 `ax::read_focused_field(Some(pasted), READ_TIMEOUT_MS)` 换成：

```rust
    ax::read_focused_related_content(BEFORE_CHARS, AFTER_CHARS, READ_TIMEOUT_MS)
        .map(|related| format!("{}{}", related.before, related.after))
```

并加常量：

```rust
const BEFORE_CHARS: usize = 600;
const AFTER_CHARS: usize = 600;
```

baseline 仍要求 `diff::contains_normalized(&text, pasted)`。

- [ ] **Step 5: 加 large-modify 门槛**

在 `watch_for_edit` 的结算分支（`Some(final) if final != baseline`）里，先算：

```rust
    let modification = diff::analysis_modification(baseline, final_text, &pasted);
    if modification.is_large_modify {
        // A rewrite, not a correction. Report and skip.
        // (reason = "large modify")
    } else {
        // existing diff + local gate + learn
    }
```

- [ ] **Step 6: 运行确认通过**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml
cargo fmt --manifest-path core/core/Cargo.toml --check
```
Expected: PASS。

- [ ] **Step 7: 提交**

```bash
git add core/core/src/learning/watcher.rs
git commit -m "feat(learning): 键盘事件驱动去抖 + large-modify 结算（阶段 17 任务 3）"
```

---

### Task 4: 全量验证 + 真机验收

- [ ] **Step 1: 全量测试/构建**

```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/ffi/Cargo.toml
cargo fmt --manifest-path core/core/Cargo.toml --check
cargo fmt --manifest-path core/ffi/Cargo.toml --check
python3 scripts/check_translations.py
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
```

- [ ] **Step 2: 真机验收（用户）**

1. Chrome / 微信：听写 → 改一个词 → 停手 ~1.5s → 学到完整词 + 弹窗。
2. 整段重写 → 不学。
3. Terminal：读到命令行则学，读不到静默不学（无垃圾词）。
4. 撤销可用。

---

## Self-Review

- **Spec 覆盖**：5.1→Task 2；5.2→Task 3；5.3→Task 1；5.4 沿用阶段 16；验收→Task 4。
- **占位符**：Task 3 Step 3/4/5 涉及在现有 `observe`/`WatchMachine` 上的改动，需实现者对照现有代码落位；已给出确切方法签名与常量。
- **类型一致**：`Modification` / `CaptureTimeout` / `ElementInfo` / `RelatedContent` / `slice_before_after` /
  `read_focused_related_content` / `analysis_modification` 在各任务一致。
- **风险**：Task 2 的 AX 选区/文本标记是唯一不确定处；实现者需在真机验证 `AXSelectedTextRange` 是否可用，不可用则回退整段文本（Web 路径）。
