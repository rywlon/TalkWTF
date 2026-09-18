# 阶段 16 实现计划：自动学词 v3（整框去抖 + 输入框采集）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「听写后改词 → 自动学进词典」在 Chrome / 微信 / 原生输入框稳定触发、学到完整词、不污染词典。

**Architecture:** 分四层：`capture`（按粘贴文本锚定输入框，取 baseline 整框）→ `trigger`（编辑一变重置 1.5s 去抖，静默即结算）→ `judge`（整框 `diff(baseline,final)` + 只听错，LLM 只看改动附近有界上下文）→ `learn`（写词典 + attempts + 弹窗/撤销）。

**Tech Stack:** Rust（`core/core`，`handy-keys` / `rusqlite` / `objc2` 已有）、SwiftUI（仅同步调用签名，若有）。

**Spec:** `docs/specs/phase-16-auto-learn-v3.md`

## Global Constraints

- 无自建云/账号/遥测；BYOK：只用用户已配的 active polish provider + key 直连。
- 不改本地 ASR 运行时；不新增重型依赖；不新增设置项。
- 分支 `phase-15-overlay-trigger` 上允许提交；每个任务跑测试/构建通过再收。
- 命令前 `export PATH="/opt/homebrew/opt/rustup/bin:$PATH"`；测试绕过代理：
  `NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost`。
- 本计划只改已有 `.swift`（若 `read_focused_field` 签名变化导致 Swift 侧无需改动，则不动 Swift）。
- 不新增 i18n key；不写无谓注释；沿用现有风格。

---

### Task 1: `diff` 纯辅助函数（锚定 + 有界上下文）

**Files:**
- Modify: `core/core/src/learning/diff.rs`

**Interfaces:**
- Produces:
  - `pub fn contains_normalized(haystack: &str, needle: &str) -> bool`
  - `pub fn relation_score(pasted: &str, current: &str) -> usize`
  - `pub fn bounded_context(baseline: &str, final_text: &str, radius: usize) -> (String, String)`
  - `is_related` 改为复用 `relation_score`，行为不变。

- [ ] **Step 1: 写失败测试**

在 `diff.rs` 的 `mod tests` 末尾追加：

```rust
    #[test]
    fn contains_normalized_ignores_case_and_punctuation() {
        assert!(contains_normalized("Hello, World!", "hello world"));
        assert!(contains_normalized("abc123", "ABC"));
        assert!(!contains_normalized("hello", "world"));
        assert!(!contains_normalized("hello", ""));
    }

    #[test]
    fn relation_score_counts_shared_prefix_and_suffix() {
        // Shared prefix "hello " (6); the differing middles share no suffix.
        assert_eq!(relation_score("hello world", "hello there"), 6);
        // Shared prefix "abc" (3) + shared suffix "def" (3).
        assert_eq!(relation_score("abcXYZdef", "abcQQQdef"), 6);
    }

    #[test]
    fn bounded_context_widens_the_difference() {
        let (old, new) = bounded_context("we should ship it today", "we should hold it today", 0);
        assert_eq!(old, "ship");
        assert_eq!(new, "hold");

        let (old, new) = bounded_context("we should ship it today", "we should hold it today", 3);
        assert_eq!(old, "ld ship it");
        assert_eq!(new, "ld hold it");
    }

    #[test]
    fn bounded_context_is_safe_on_identical_text() {
        let (old, new) = bounded_context("same", "same", 4);
        // Nothing differs: the returned context is empty (or the whole text).
        assert!(old.len() <= "same".len());
        assert!(new.len() <= "same".len());
    }
```

- [ ] **Step 2: 运行确认失败**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::diff
```
Expected: 编译失败（`contains_normalized` / `relation_score` / `bounded_context` 不存在）。

- [ ] **Step 3: 实现三个函数并让 `is_related` 复用 `relation_score`**

在 `diff.rs` 中 `pub fn is_related` 之前插入：

```rust
/// Whether `needle` appears in `haystack` after normalizing both to lowercase
/// alphanumerics. Used to anchor a read to the text we just pasted.
pub fn contains_normalized(haystack: &str, needle: &str) -> bool {
    let needle = match_key(needle);
    if needle.is_empty() {
        return false;
    }
    match_key(haystack).contains(&needle)
}

/// Common prefix + suffix length between two texts, case-insensitive. The
/// "how much of the pasted text is still there" score.
pub fn relation_score(pasted: &str, current: &str) -> usize {
    let pasted: Vec<char> = pasted.chars().collect();
    let current: Vec<char> = current.chars().collect();
    let (prefix, suffix) = unchanged_span(&pasted, &current);
    prefix + suffix
}

/// The differing middle of `baseline` / `final_text`, widened by `radius`
/// characters on both sides. Used to send only the edit's neighbourhood to the
/// LLM, never the whole input box.
pub fn bounded_context(baseline: &str, final_text: &str, radius: usize) -> (String, String) {
    let old: Vec<char> = baseline.chars().collect();
    let new: Vec<char> = final_text.chars().collect();
    let (prefix, suffix) = unchanged_span(&old, &new);

    let start = prefix.saturating_sub(radius);
    let old_end = old.len().saturating_sub(suffix).saturating_add(radius).min(old.len());
    let new_end = new.len().saturating_sub(suffix).saturating_add(radius).min(new.len());

    let old_start = start.min(old_end);
    let new_start = start.min(new_end);
    (
        old[old_start..old_end].iter().collect(),
        new[new_start..new_end].iter().collect(),
    )
}
```

把 `is_related` 的函数体替换为：

```rust
pub fn is_related(pasted: &str, current: &str) -> bool {
    if pasted.is_empty() || current.is_empty() {
        return false;
    }
    let required = (pasted.chars().count() / 2).max(2);
    relation_score(pasted, current) >= required
}
```

- [ ] **Step 4: 运行确认通过**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::diff
cargo fmt --manifest-path core/core/Cargo.toml --check
```
Expected: PASS（含原有 `is_related` 测试）。

- [ ] **Step 5: 提交**

```bash
git add core/core/src/learning/diff.rs
git commit -m "feat(learning): diff 加锚定/有界上下文辅助（阶段 16 任务 1）"
```

---

### Task 2: `ax` 候选选择（读对输入框，不再取最长）

**Files:**
- Modify: `core/core/src/learning/ax/mod.rs`
- Modify: `core/core/src/learning/watcher.rs`（仅改 3 处 `read_focused_field` 调用签名）

**Interfaces:**
- Consumes: `diff::contains_normalized`、`diff::is_related`、`diff::relation_score`（Task 1）。
- Produces:
  - `fn select_candidate(candidates: Vec<FocusedText>, pasted: Option<&str>) -> Option<FocusedText>`
  - `pub fn read_focused_field(pasted: Option<&str>, timeout_ms: u32) -> Option<FocusedField>`

- [ ] **Step 1: 让 `FocusedText` 可克隆**

把 `ax/mod.rs` 中：

```rust
pub struct FocusedText {
    pub text: String,
    pub source: TextSource,
    /// Which step of the search produced this text, for diagnostics.
    pub strategy: &'static str,
}
```

改为：

```rust
#[derive(Clone)]
pub struct FocusedText {
    pub text: String,
    pub source: TextSource,
    /// Which step of the search produced this text, for diagnostics.
    pub strategy: &'static str,
}
```

- [ ] **Step 2: 写失败测试**

在 `ax/mod.rs` 的 `mod tests` 末尾追加：

```rust
    fn text(value: &str) -> FocusedText {
        FocusedText {
            text: value.to_string(),
            source: TextSource::Native,
            strategy: "test",
        }
    }

    #[test]
    fn select_candidate_prefers_the_shortest_containing_read() {
        // The whole window and the input box both contain the paste; the input
        // box is shorter, so it wins even though the window is "longer".
        let candidates = vec![
            text("页面上其他文字 hello world 更多页面文字"),
            text("hello world"),
        ];
        let chosen = select_candidate(candidates, Some("hello world")).unwrap();
        assert_eq!(chosen.text, "hello world");
    }

    #[test]
    fn select_candidate_falls_back_to_the_most_related() {
        // Nothing contains the paste verbatim (the read is stale), but one read
        // still shares most of it.
        let candidates = vec![text("unrelated page text"), text("hello world!")];
        let chosen = select_candidate(candidates, Some("hello world")).unwrap();
        assert_eq!(chosen.text, "hello world!");
    }

    #[test]
    fn select_candidate_returns_none_when_nothing_is_related() {
        let candidates = vec![text("completely different text")];
        assert!(select_candidate(candidates, Some("hello world")).is_none());
    }

    #[test]
    fn select_candidate_without_a_paste_takes_the_first() {
        let candidates = vec![text("first"), text("second")];
        assert_eq!(
            select_candidate(candidates, None).unwrap().text,
            "first"
        );
    }
```

- [ ] **Step 3: 运行确认失败**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::ax
```
Expected: 编译失败（`select_candidate` 不存在）。

- [ ] **Step 4: 实现 `select_candidate`**

在 `ax/mod.rs` 中 `read_focused_field` 之前插入：

```rust
/// Pick the read that is the user's input box, using the pasted text as an
/// anchor. The whole window and the input box both contain the paste; the input
/// box is shorter, so "shortest containing" wins. When nothing contains the
/// paste (a stale or partial read), fall back to the most related read. When
/// nothing is related at all, return `None` rather than guess.
fn select_candidate(candidates: Vec<FocusedText>, pasted: Option<&str>) -> Option<FocusedText> {
    let Some(pasted) = pasted.filter(|value| !value.trim().is_empty()) else {
        return candidates.into_iter().next();
    };

    let mut containing: Vec<FocusedText> = candidates
        .iter()
        .filter(|candidate| diff::contains_normalized(&candidate.text, pasted))
        .cloned()
        .collect();
    if !containing.is_empty() {
        containing.sort_by_key(|candidate| candidate.text.chars().count());
        return containing.into_iter().next();
    }

    candidates
        .into_iter()
        .filter(|candidate| diff::is_related(pasted, &candidate.text))
        .max_by_key(|candidate| diff::relation_score(pasted, &candidate.text))
}
```

在文件顶部 `use` 区加（若未有）：

```rust
use super::super::diff;
```

注意：`ax/mod.rs` 属于 `learning` 模块，`diff` 是同级的 `crate::learning::diff`。用
`use crate::learning::diff;` 更稳。

- [ ] **Step 5: 改 `read_focused_field` 签名与选择逻辑**

把 `read_focused_field` 的签名与结尾替换：

```rust
pub fn read_focused_field(pasted: Option<&str>, timeout_ms: u32) -> Option<FocusedField> {
    if !is_trusted() {
        debug!("Accessibility permission is not granted");
        return None;
    }
    if crate::secure_input::is_enabled_now() {
        return None;
    }
    if is_blocked_app(frontmost_bundle_id().as_deref()) {
        return None;
    }

    let focused = focused_element()?;
    set_timeout(focused.raw());

    let deadline = Instant::now() + Duration::from_millis(timeout_ms as u64);
    let identity = field_identity(focused.raw());

    // Run every strategy, then let the anchor pick the input box instead of the
    // longest read (which is the whole window in Terminal/browsers).
    let candidates: Vec<FocusedText> = [
        read_element(focused.raw()),
        read_ancestor(focused.raw()),
        read_child(focused.raw()),
        collect_visible_text(focused.raw(), deadline),
    ]
    .into_iter()
    .flatten()
    .collect();

    let read = select_candidate(candidates, pasted)?;

    Some(FocusedField {
        text: read.text,
        identity,
        strategy: read.strategy,
    })
}
```

- [ ] **Step 6: 更新 watcher 的 3 处调用（保持编译通过）**

`watcher.rs` 中三处 `ax::read_focused_field(READ_TIMEOUT_MS)` 改为
`ax::read_focused_field(Some(pasted), READ_TIMEOUT_MS)`（`observe` 的 `pasted` 在作用域内）。
三处分别在 `observe` 的起始读、Enter 后补读、主轮询读。

- [ ] **Step 7: 运行确认通过**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::
cargo fmt --manifest-path core/core/Cargo.toml --check
```
Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add core/core/src/learning/ax/mod.rs core/core/src/learning/watcher.rs
git commit -m "feat(learning): 采集按粘贴文本锚定输入框（阶段 16 任务 2）"
```

---

### Task 3: `watcher` 去抖结算重写

**Files:**
- Modify: `core/core/src/learning/watcher.rs`

**Interfaces:**
- Consumes: `diff::contains_normalized`、`diff::bounded_context`（Task 1）；`ax::read_focused_field(pasted, timeout)`（Task 2）。
- Produces（本任务内部）：
  - `struct WatchMachine { baseline, observed, last_edit, ever_readable, unreadable, pending_enter }`
  - `fn settled_text(observed: &[String]) -> Option<String>`
  - `enum StopReason { Settled, Enter, FieldEmptied, FocusLost, AppChanged, Superseded, SettingOff, SecureInput, NoEdit }`
- 删除：`choose_final()`、`decide()`、`SEND_CONFIRM_WINDOW`、`SEND_SETTLE`、`WatchStep` 不变。

- [ ] **Step 1: 替换常量块**

把：

```rust
/// Poll cadence while watching.
const POLL_INTERVAL: Duration = Duration::from_millis(200);
/// How long we keep watching after a paste.
const WATCH_WINDOW: Duration = Duration::from_secs(45);
/// Consecutive polls with no readable focus, after the field was readable, that
/// mean the user moved on (sent, submitted, or clicked away). 10 * 200ms = 2s.
const FOCUS_LOST_POLLS: u32 = 10;
/// After Enter, how long we wait for the field to clear (or the app to navigate)
/// to confirm the key really sent. An input-method commit keeps the text and
/// grows it instead, so it is not a send.
const SEND_CONFIRM_WINDOW: Duration = Duration::from_millis(2000);
/// After Enter, the field being unchanged for this long confirms the send even
/// when the app does not clear the field. An input-method commit changes the
/// text immediately, so it cancels instead.
const SEND_SETTLE: Duration = Duration::from_millis(600);
```

改为：

```rust
/// Poll cadence while watching.
const POLL_INTERVAL: Duration = Duration::from_millis(200);
/// How long we wait for the paste to show up in the field before giving up.
const BASELINE_TIMEOUT: Duration = Duration::from_millis(2000);
/// How long the field must stop changing before the edit is considered done.
const EDIT_DEBOUNCE: Duration = Duration::from_millis(1500);
/// How long we keep watching after a paste.
const WATCH_WINDOW: Duration = Duration::from_secs(45);
/// If no edit is made within this window, stop watching.
const NO_EDIT_WINDOW: Duration = Duration::from_secs(15);
/// Consecutive polls with no readable focus, after the field was readable, that
/// mean the user moved on. 10 * 200ms = 2s.
const FOCUS_LOST_POLLS: u32 = 10;
/// Characters of context around an edit sent to the LLM.
const LLM_CONTEXT_RADIUS: usize = 80;
```

- [ ] **Step 2: 替换 `Poll` / `StopReason` / `WatchMachine`**

把 `enum Poll` 到 `impl WatchMachine { ... }` 结束（`stop_outcome` 之前）整段替换为：

```rust
/// What one poll of the watch saw (or why it must stop).
#[derive(Debug, Clone, PartialEq, Eq)]
enum Poll {
    /// The focused field was readable, holding this text.
    Readable(String),
    /// Nothing readable was focused this poll.
    Unreadable,
    /// The user pressed Enter (an accelerator, not a requirement).
    Enter,
    Superseded,
    SettingOff,
    SecureInput,
    AppChanged,
}

#[derive(Debug, PartialEq, Eq)]
enum WatchStep {
    Continue,
    Learn,
    Ignore,
}

#[derive(Debug, PartialEq, Eq)]
enum StopReason {
    /// The edit stopped changing for `EDIT_DEBOUNCE`.
    Settled,
    /// Enter was pressed and the field cleared.
    Enter,
    /// The field emptied without Enter.
    FieldEmptied,
    FocusLost,
    AppChanged,
    Superseded,
    SettingOff,
    SecureInput,
    /// The watch ended without any edit.
    NoEdit,
}

/// The watch's settle logic, with the accessibility reads left outside so the
/// timing rules are unit-testable.
struct WatchMachine {
    baseline: String,
    /// Every distinct field value seen, baseline first.
    observed: Vec<String>,
    /// When the field last changed to a new value.
    last_edit: Option<Instant>,
    ever_readable: bool,
    unreadable: u32,
    /// Set by Enter; cleared by any text change. Lets a cleared field settle
    /// immediately instead of waiting out the debounce.
    pending_enter: bool,
}

impl WatchMachine {
    fn new(baseline: String) -> Self {
        Self {
            observed: vec![baseline.clone()],
            baseline,
            last_edit: None,
            ever_readable: false,
            unreadable: 0,
            pending_enter: false,
        }
    }

    /// Whether the field ever held something other than the baseline.
    fn edited(&self) -> bool {
        self.observed
            .iter()
            .any(|text| text != &self.baseline && !text.trim().is_empty())
    }

    fn settle(&self, reason: StopReason) -> (WatchStep, Option<StopReason>) {
        if self.edited() {
            (WatchStep::Learn, Some(reason))
        } else {
            (WatchStep::Ignore, Some(reason))
        }
    }

    fn on(&mut self, poll: Poll) -> (WatchStep, Option<StopReason>) {
        match poll {
            Poll::Superseded => (WatchStep::Ignore, Some(StopReason::Superseded)),
            Poll::SettingOff => (WatchStep::Ignore, Some(StopReason::SettingOff)),
            Poll::SecureInput => (WatchStep::Ignore, Some(StopReason::SecureInput)),
            Poll::AppChanged => self.settle(StopReason::AppChanged),
            Poll::Enter => {
                self.pending_enter = true;
                (WatchStep::Continue, None)
            }
            Poll::Unreadable => {
                self.unreadable = self.unreadable.saturating_add(1);
                if self.ever_readable && self.unreadable >= FOCUS_LOST_POLLS {
                    self.settle(StopReason::FocusLost)
                } else {
                    (WatchStep::Continue, None)
                }
            }
            Poll::Readable(text) => self.on_readable(text),
        }
    }

    fn on_readable(&mut self, text: String) -> (WatchStep, Option<StopReason>) {
        self.unreadable = 0;
        self.ever_readable = true;

        if self.observed.last() != Some(&text) {
            let pending = self.pending_enter;
            let emptied = text.trim().is_empty();
            self.pending_enter = false;
            self.observed.push(text);
            if self.observed.len() > MAX_OBSERVED_STATES {
                self.observed.remove(0);
            }

            if emptied {
                return if self.edited() {
                    let reason = if pending {
                        StopReason::Enter
                    } else {
                        StopReason::FieldEmptied
                    };
                    (WatchStep::Learn, Some(reason))
                } else {
                    (WatchStep::Ignore, Some(StopReason::NoEdit))
                };
            }

            if self.edited() {
                self.last_edit = Some(Instant::now());
            }
            return (WatchStep::Continue, None);
        }

        if self.edited() && self.last_edit.is_some_and(|at| at.elapsed() >= EDIT_DEBOUNCE) {
            return (WatchStep::Learn, Some(StopReason::Settled));
        }
        (WatchStep::Continue, None)
    }
}
```

- [ ] **Step 3: 替换 `stop_outcome` 并删除 `choose_final` / `decide`**

把 `fn stop_outcome` 的 match 替换为：

```rust
fn stop_outcome(reason: StopReason) -> &'static str {
    match reason {
        StopReason::Settled => "the edit settled",
        StopReason::Enter => "the enter key was pressed and the field cleared",
        StopReason::FieldEmptied => "the field emptied",
        StopReason::FocusLost => "the field lost focus",
        StopReason::AppChanged => "the frontmost app changed",
        StopReason::Superseded => "superseded by a newer dictation",
        StopReason::SettingOff => "the setting was turned off",
        StopReason::SecureInput => "secure input became active",
        StopReason::NoEdit => "no edit was made",
    }
}
```

删除整段 `fn choose_final(...)`，并新增：

```rust
/// The newest non-empty state the field held. When the field clears on send, the
/// last empty state is skipped so the text that was actually sent is recovered.
fn settled_text(observed: &[String]) -> Option<String> {
    observed
        .iter()
        .rev()
        .find(|text| !text.trim().is_empty())
        .cloned()
}
```

删除整段 `fn decide(...)`。保留 `describe`、`usable_candidates`、`apply`、`learn`、
`attempt_outcome`、`judge_source_str`、`learned_json`、`record_attempt`、`record_field`、`field_poll`。

- [ ] **Step 4: 重写 `observe`**

把 `fn observe` 整段替换为：

```rust
fn observe(pasted: &str, bundle_id: Option<&str>, generation: u64) -> (Vec<String>, WatchReport) {
    let started = Instant::now();

    let mut report = WatchReport {
        bundle_id: bundle_id.map(str::to_string),
        pasted_chars: pasted.chars().count(),
        outcome: "watching".to_string(),
        ..Default::default()
    };

    // A second CGEventTap coexists with the app's blocking `HotkeyManager`; the
    // listener lives only for this watch. Enter is only an accelerator now.
    let listener = KeyboardListener::new().ok();
    if listener.is_none() {
        debug!("Enter watch unavailable; falling back to field polling only");
    }

    // Enable the enhanced tree once for the whole watch; the guard restores it.
    let _enhance = ax::enable_enhanced_user_interface();

    // Wait until the paste shows up in the input box. Chromium answers the very
    // first read with no value, so this retries instead of trusting one read.
    let baseline = loop {
        if started.elapsed() >= BASELINE_TIMEOUT {
            break None;
        }
        match ax::read_focused_field(Some(pasted), READ_TIMEOUT_MS) {
            Some(field) if diff::contains_normalized(&field.text, pasted) => break Some(field),
            _ => std::thread::sleep(POLL_INTERVAL),
        }
    };

    let Some(baseline) = baseline else {
        report.outcome = "the input box could not be read".to_string();
        return (Vec::new(), report);
    };
    record_field(&mut report, &baseline);
    let mut machine = WatchMachine::new(baseline.text.clone());

    while started.elapsed() < WATCH_WINDOW {
        report.polls += 1;
        let entered = wait_for_enter(listener.as_ref(), POLL_INTERVAL);
        if entered {
            let _ = machine.on(Poll::Enter);
        }

        let poll = if WATCH_GENERATION.load(Ordering::SeqCst) != generation {
            Poll::Superseded
        } else if !crate::settings::current().learn_from_edits {
            Poll::SettingOff
        } else if crate::secure_input::is_enabled_now() {
            Poll::SecureInput
        } else if ax::frontmost_bundle_id().as_deref() != bundle_id {
            Poll::AppChanged
        } else {
            match ax::read_focused_field(Some(pasted), READ_TIMEOUT_MS) {
                Some(field) => {
                    record_field(&mut report, &field);
                    field_poll(&field)
                }
                None => Poll::Unreadable,
            }
        };

        match machine.on(poll) {
            (WatchStep::Continue, _) => {
                if !machine.edited() && started.elapsed() >= NO_EDIT_WINDOW {
                    report.outcome = "no edit was made".to_string();
                    return (Vec::new(), report);
                }
            }
            (WatchStep::Learn, reason) => {
                report.outcome = stop_outcome(reason.expect("learn has a reason")).to_string();
                return (machine.observed, report);
            }
            (WatchStep::Ignore, reason) => {
                report.outcome = stop_outcome(reason.expect("ignore has a reason")).to_string();
                return (Vec::new(), report);
            }
        }
    }

    debug!("Edit watch timed out with no settle");
    report.outcome = "timeout".to_string();
    (Vec::new(), report)
}
```

- [ ] **Step 5: 重写 `watch_for_edit` 的结算段**

把 `watch_for_edit` 中 `std::thread::spawn(move || { ... })` 的内容替换为：

```rust
    std::thread::spawn(move || {
        let (observed, mut report) = observe(&pasted, bundle_id.as_deref(), generation);

        let baseline = observed.first().cloned();
        let final_text = settled_text(&observed);

        let (outcome, reason, applied, source, llm_raw) =
            match (baseline.as_deref(), final_text.as_deref()) {
                (Some(baseline), Some(final_text)) if final_text != baseline => {
                    // Whole-box diff first: same source before/after, so the
                    // localized correction is reliable.
                    let raw = diff::detect_edits(baseline, final_text);
                    if raw.is_empty() {
                        (
                            "skipped".to_string(),
                            "the edit was not a local correction".to_string(),
                            Vec::new(),
                            llm::JudgeSource::None,
                            None,
                        )
                    } else {
                        // Only the edit's neighbourhood goes to the provider.
                        let (pasted_ctx, final_ctx) =
                            diff::bounded_context(baseline, final_text, LLM_CONTEXT_RADIUS);
                        let judgement = llm::judge(&pasted_ctx, &final_ctx);
                        let source = judgement.source;
                        let llm_raw = judgement.llm_raw.clone();
                        let candidates = usable_candidates(judgement.candidates);
                        let found = !candidates.is_empty();

                        let applied = if found {
                            report.candidate = Some(describe(&candidates));
                            let frame = ax::focused_element_frame();
                            apply(candidates, frame)
                        } else {
                            Vec::new()
                        };

                        let (outcome, reason) = attempt_outcome(
                            !applied.is_empty(),
                            found,
                            source,
                            &judgement.reason,
                        );
                        (outcome, reason, applied, source, llm_raw)
                    }
                }
                _ => {
                    let (outcome, reason) =
                        attempt_outcome(false, false, llm::JudgeSource::None, &report.outcome);
                    (outcome, reason, Vec::new(), llm::JudgeSource::None, None)
                }
            };

        report.outcome = reason.clone();

        let recorded_final = final_text
            .clone()
            .or_else(|| report.last_field_preview.clone())
            .unwrap_or_default();
        record_attempt(
            &pasted,
            &recorded_final,
            report.bundle_id.as_deref(),
            report.field_id.as_deref(),
            judge_source_str(source),
            llm_raw,
            &outcome,
            &reason,
            learned_json(&applied),
            report.strategy.clone(),
        );

        if let Some(state) = crate::learning::learning_state() {
            state.set_report(report.clone());
        }

        debug!(
            "Edit watch finished: {} | pasted into {:?} | polls {} ({} readable) | last field {} chars via {:?} | {:?}",
            report.outcome,
            report.bundle_id,
            report.polls,
            report.readable_polls,
            report.last_field_chars.unwrap_or(0),
            report.strategy,
            report.candidate,
        );
    });
```

注意：`report.polls` 需要继续自增。在 `observe` 的 `while` 循环开头加 `report.polls += 1;`。

- [ ] **Step 6: 重写/删除 watcher 单测**

删除以下测试（引用已删除的函数/旧行为）：
`choose_final_prefers_the_newest_differing_state`、`choose_final_is_none_when_nothing_differs`、
`choose_final_prefers_a_complete_state_over_a_trailing_space`、
`choose_final_is_none_when_the_newest_state_is_unrelated`、
`learns_when_the_field_was_cleared_by_sending`、`prefers_a_complete_replacement_over_a_half_typed_one`、
`falls_back_to_nothing_when_the_captured_fragment_is_dissimilar`、
`the_gate_drops_a_dissimilar_correction_in_one_state`、`a_state_with_no_edit_learns_nothing`。

把旧 machine 测试替换为：

```rust
    #[test]
    fn machine_learns_after_the_edit_settles() {
        let mut machine = WatchMachine::new("hello world".to_string());
        assert_eq!(
            machine.on(Poll::Readable("hello there".into())),
            (WatchStep::Continue, None)
        );
        std::thread::sleep(EDIT_DEBOUNCE + Duration::from_millis(50));
        assert_eq!(
            machine.on(Poll::Readable("hello there".into())),
            (WatchStep::Learn, Some(StopReason::Settled))
        );
    }

    #[test]
    fn machine_does_not_settle_while_the_edit_keeps_changing() {
        let mut machine = WatchMachine::new("hello world".to_string());
        machine.on(Poll::Readable("hello the".into()));
        machine.on(Poll::Readable("hello there".into()));
        std::thread::sleep(EDIT_DEBOUNCE + Duration::from_millis(50));
        // A newer change resets the timer, so this is still not settled.
        machine.on(Poll::Readable("hello there!".into()));
        assert_eq!(
            machine.on(Poll::Readable("hello there!".into())),
            (WatchStep::Continue, None)
        );
    }

    #[test]
    fn machine_never_learns_without_an_edit() {
        let mut machine = WatchMachine::new("hello world".to_string());
        for _ in 0..200 {
            assert_eq!(
                machine.on(Poll::Readable("hello world".into())),
                (WatchStep::Continue, None)
            );
        }
    }

    #[test]
    fn machine_learns_when_an_edited_field_clears() {
        let mut machine = WatchMachine::new("hello world".to_string());
        machine.on(Poll::Readable("hello there".into()));
        assert_eq!(
            machine.on(Poll::Readable(String::new())),
            (WatchStep::Learn, Some(StopReason::FieldEmptied))
        );
    }

    #[test]
    fn machine_ignores_a_cleared_field_without_an_edit() {
        let mut machine = WatchMachine::new("hello world".to_string());
        assert_eq!(
            machine.on(Poll::Readable(String::new())),
            (WatchStep::Ignore, Some(StopReason::NoEdit))
        );
    }

    #[test]
    fn machine_settles_on_enter_cleared() {
        let mut machine = WatchMachine::new("hello world".to_string());
        machine.on(Poll::Readable("hello there".into()));
        machine.on(Poll::Enter);
        assert_eq!(
            machine.on(Poll::Readable(String::new())),
            (WatchStep::Learn, Some(StopReason::Enter))
        );
    }

    #[test]
    fn machine_ignores_focus_loss_without_an_edit() {
        let mut machine = WatchMachine::new("hello world".to_string());
        machine.on(Poll::Readable("hello world".into()));
        for _ in 0..(FOCUS_LOST_POLLS - 1) {
            assert_eq!(machine.on(Poll::Unreadable).0, WatchStep::Continue);
        }
        assert_eq!(
            machine.on(Poll::Unreadable),
            (WatchStep::Ignore, Some(StopReason::FocusLost))
        );
    }

    #[test]
    fn machine_learns_on_focus_loss_after_an_edit() {
        let mut machine = WatchMachine::new("hello world".to_string());
        machine.on(Poll::Readable("hello there".into()));
        for _ in 0..(FOCUS_LOST_POLLS - 1) {
            assert_eq!(machine.on(Poll::Unreadable).0, WatchStep::Continue);
        }
        assert_eq!(
            machine.on(Poll::Unreadable),
            (WatchStep::Learn, Some(StopReason::FocusLost))
        );
    }

    #[test]
    fn machine_learns_on_app_change_after_an_edit() {
        let mut machine = WatchMachine::new("hello world".to_string());
        machine.on(Poll::Readable("hello there".into()));
        assert_eq!(
            machine.on(Poll::AppChanged),
            (WatchStep::Learn, Some(StopReason::AppChanged))
        );
    }

    #[test]
    fn machine_ignores_an_app_change_without_an_edit() {
        let mut machine = WatchMachine::new("hello world".to_string());
        machine.on(Poll::Readable("hello world".into()));
        assert_eq!(
            machine.on(Poll::AppChanged),
            (WatchStep::Ignore, Some(StopReason::AppChanged))
        );
    }

    #[test]
    fn machine_ignores_supersede_setting_and_secure_input() {
        for poll in [Poll::Superseded, Poll::SettingOff, Poll::SecureInput] {
            let mut machine = WatchMachine::new("hello world".to_string());
            machine.on(Poll::Readable("hello there".into()));
            assert_eq!(machine.on(poll).0, WatchStep::Ignore);
        }
    }

    #[test]
    fn machine_never_settles_on_unreadable_before_reading_once() {
        let mut machine = WatchMachine::new("hello world".to_string());
        for _ in 0..100 {
            assert_eq!(machine.on(Poll::Unreadable).0, WatchStep::Continue);
        }
    }

    #[test]
    fn machine_caps_the_observed_states() {
        let mut machine = WatchMachine::new("baseline".to_string());
        for index in 0..(MAX_OBSERVED_STATES + 5) {
            machine.on(Poll::Readable(format!("value {index}")));
        }
        assert_eq!(machine.observed.len(), MAX_OBSERVED_STATES);
    }

    #[test]
    fn settled_text_skips_a_trailing_empty_state() {
        let observed = states(&["hello world", "hello there", ""]);
        assert_eq!(settled_text(&observed), Some("hello there".to_string()));
    }
```

- [ ] **Step 7: 运行确认通过**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::watcher
cargo fmt --manifest-path core/core/Cargo.toml --check
```
Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add core/core/src/learning/watcher.rs
git commit -m "feat(learning): 去抖结算 + 整框 diff + 有界上下文判定（阶段 16 任务 3）"
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
Expected: 全绿 + 构建成功。

- [ ] **Step 2: 真机验收（用户）**

按 spec 第八节：
1. Chrome / 微信 / TextEdit：听写 → 改词 → 停手 1.5s → 弹窗 + 词典加词。
2. 输入法提交候选的中途停顿不学半截词。
3. 改意思（早→晚）不学。
4. 弹窗撤销 → 词消失、误听进拒绝名单。
5. 调试页能看到每次尝试的 baseline/final/来源/原因。

- [ ] **Step 3: 提交（若验收后有微调）**

```bash
git add -A
git commit -m "fix(learning): 阶段 16 真机验收微调"
```

---

## Self-Review

- **Spec 覆盖**：5.2→Task 2；5.3→Task 3；5.4→Task 1（`bounded_context`）+ Task 3（`llm::judge` 接入）；
  5.5 学词/事件不变；验收→Task 4。
- **占位符**：无 TBD/TODO；每个代码步骤都有完整代码与命令。
- **类型一致**：`read_focused_field(pasted, timeout)`、`select_candidate`、`contains_normalized`、
  `relation_score`、`bounded_context`、`settled_text`、`WatchMachine::new(baseline)` 在各任务一致。
- **风险**：Task 3 改动最大，故先替换纯状态机与常量，再重写 `observe`/结算；每步可独立编译。
