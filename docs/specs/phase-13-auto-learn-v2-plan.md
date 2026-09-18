# 阶段 13 实现计划：自动学词 v2（完整采集 + Enter 触发 + 可解释）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让学词在 Chrome/微信/原生输入框都能读到、以 Enter 为发送信号、并且每次尝试都可解释。

**Architecture:** 分四层：`capture`（AX 增强 + 三级读取 + 字段身份）→ `trigger`（Enter 为主 + 轮询兜底，扩展已有 `WatchMachine`）→ `judge`（LLM 只听错 + 本地门槛，记录原始返回与原因）→ `learn`（写词典 + 写 `learning_attempts` + 事件）。

**Tech Stack:** Rust（core/core，`handy-keys` / `rusqlite` / `objc2` 已有）、SwiftUI（macOS 外壳）。

**Spec:** `docs/specs/phase-13-auto-learn-v2.md`

## Global Constraints

- 无自建云/账号/遥测；BYOK：只用用户已配的 active polish provider + key 直连。
- 不改本地 ASR 运行时；不新增重型依赖。
- 分支 `phase-13-learn-v2` 上允许提交；每个任务跑测试/构建通过再收。
- 命令前 `export PATH="/opt/homebrew/opt/rustup/bin:$PATH"`；测试绕过代理：
  `NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost`。
- 新增 Swift 文件才需在 pbxproj 四处登记；本计划只改已有 `.swift`（除必要新建时说明）。
- 新增 i18n key 必须同步 26 个语言包（`scripts/check_translations.py` 会校验 key 一致）。
- 不要写无谓注释；沿用现有风格。

---

### Task 1: 采集层——AX 增强 + 三级读取 + 字段身份

**Files:**
- Modify: `core/core/src/learning/ax/mod.rs`

**Interfaces:**
- Produces:
  - `pub struct FieldIdentity { pub pid: i32, pub key: String }`
  - `pub struct FocusedField { pub text: String, pub identity: FieldIdentity, pub strategy: &'static str }`
  - `pub fn read_focused_field(timeout_ms: u32) -> Option<FocusedField>`
  - 保留 `read_focused_text`（watcher 之外的调用方不受影响）。

- [ ] **Step 1: 写失败测试（纯逻辑）**

在 `ax/mod.rs` 末尾加 `#[cfg(test)] mod tests`（若已有则追加）：

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joins_collected_fragments_in_order() {
        let fragments = vec!["hello".to_string(), "world".to_string()];
        assert_eq!(smart_join(&fragments), "hello world");
    }

    #[test]
    fn smart_join_does_not_double_space() {
        let fragments = vec!["hello ".to_string(), " world".to_string()];
        assert_eq!(smart_join(&fragments), "hello  world");
    }

    #[test]
    fn smart_join_inserts_space_between_cjk_and_latin() {
        let fragments = vec!["你好".to_string(), "world".to_string()];
        assert_eq!(smart_join(&fragments), "你好 world");
    }

    #[test]
    fn identity_key_prefers_identifier_over_frame() {
        assert_eq!(
            identity_key(Some("field-1".into()), Some("dom-9".into()), Some("1,2,3,4".into())),
            "field-1"
        );
        assert_eq!(
            identity_key(None, Some("dom-9".into()), Some("1,2,3,4".into())),
            "dom-9"
        );
        assert_eq!(identity_key(None, None, Some("1,2,3,4".into())), "1,2,3,4");
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::ax
```
Expected: 编译失败（`smart_join` / `identity_key` 不存在）。

- [ ] **Step 3: 加 FFI 声明**

在 `ApplicationServices` extern 块加：

```rust
    fn AXUIElementGetPid(element: AXUIElementRef, pid: *mut i32) -> AXError;
    fn AXUIElementSetAttributeValue(
        element: AXUIElementRef,
        attribute: CFTypeRef,
        value: CFTypeRef,
    ) -> AXError;
```

在 `CoreFoundation` extern 块加：

```rust
    static kCFBooleanTrue: CFTypeRef;
    static kCFBooleanFalse: CFTypeRef;
    fn CFBooleanGetValue(boolean: CFTypeRef) -> Boolean;
    fn CFBooleanGetTypeID() -> usize;
```

- [ ] **Step 4: 加常量、类型与纯函数**

在 `MAX_CHILDREN` 常量附近加：

```rust
/// Visible-text walk bounds: a browser page can be enormous.
const MAX_CAPTURE_CHARS: usize = 4000;
const MAX_CAPTURE_NODES: usize = 2000;
const MAX_CAPTURE_DEPTH: usize = 20;

/// What identifies the field we pasted into, so a later poll can tell it is still
/// the same field (and stop when the user moved to another one).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldIdentity {
    pub pid: i32,
    pub key: String,
}

pub struct FocusedField {
    pub text: String,
    pub identity: FieldIdentity,
    pub strategy: &'static str,
}

/// Pick the most stable identifier we have for a field.
fn identity_key(identifier: Option<String>, dom: Option<String>, frame: Option<String>) -> String {
    identifier
        .filter(|value| !value.is_empty())
        .or_else(|| dom.filter(|value| !value.is_empty()))
        .or(frame)
        .unwrap_or_default()
}

/// Join collected text fragments the way Typeless's `smartJoinTexts` does: a
/// space between fragments, but never a space between two CJK fragments.
fn smart_join(fragments: &[String]) -> String {
    let mut out = String::new();
    for fragment in fragments {
        if fragment.is_empty() {
            continue;
        }
        if !out.is_empty() && needs_separator(out.chars().last(), fragment.chars().next()) {
            out.push(' ');
        }
        out.push_str(fragment);
    }
    out
}

fn needs_separator(left: Option<char>, right: Option<char>) -> bool {
    match (left, right) {
        (Some(left), Some(right)) => !is_cjk_char(left) && !is_cjk_char(right)
            && !left.is_whitespace()
            && !right.is_whitespace(),
        _ => false,
    }
}

fn is_cjk_char(character: char) -> bool {
    let code = character as u32;
    (0x3040..=0x30FF).contains(&code)
        || (0x3400..=0x4DBF).contains(&code)
        || (0x4E00..=0x9FFF).contains(&code)
        || (0xF900..=0xFAFF).contains(&code)
}
```

- [ ] **Step 5: 加 AX 增强 guard**

```rust
/// Sets `AXEnhancedUserInterface` on the focused window so Chromium-based apps
/// expose their accessibility tree, and restores the previous value on drop.
struct EnhancedUserInterface {
    window: AxElement,
    previous: Option<bool>,
}

impl EnhancedUserInterface {
    fn enable(focused: AXUIElementRef) -> Option<Self> {
        let window = copy_element(focused, "AXWindow")?;
        set_timeout(window.raw());

        let previous = copy_value(window.raw(), "AXEnhancedUserInterface")
            .and_then(|value| cf_boolean(value.raw()));

        let attribute = attribute("AXEnhancedUserInterface");
        unsafe {
            AXUIElementSetAttributeValue(
                window.raw(),
                Retained::as_ptr(&attribute) as CFTypeRef,
                kCFBooleanTrue,
            );
        }

        Some(Self { window, previous })
    }
}

impl Drop for EnhancedUserInterface {
    fn drop(&mut self) {
        let value = match self.previous {
            Some(true) => unsafe { kCFBooleanTrue },
            Some(false) => unsafe { kCFBooleanFalse },
            None => return,
        };
        let attribute = attribute("AXEnhancedUserInterface");
        unsafe {
            AXUIElementSetAttributeValue(
                self.window.raw(),
                Retained::as_ptr(&attribute) as CFTypeRef,
                value,
            );
        }
    }
}

fn cf_boolean(value: CFTypeRef) -> Option<bool> {
    if unsafe { CFGetTypeID(value) != CFBooleanGetTypeID() } {
        return None;
    }
    Some(unsafe { CFBooleanGetValue(value) } != 0)
}
```

- [ ] **Step 6: 加可见文本收集与身份读取**

```rust
/// Walk the focused element's subtree, collecting the text of text-bearing
/// elements in AXChildren order. This is the fallback for web content whose
/// editable region has no `AXValue` and no text markers.
fn collect_visible_text(element: AXUIElementRef) -> Option<FocusedText> {
    let mut fragments: Vec<String> = Vec::new();
    let mut nodes = 0usize;
    collect_into(element, 0, &mut nodes, &mut fragments);

    let text = smart_join(&fragments);
    if text.trim().is_empty() {
        return None;
    }

    Some(FocusedText {
        text,
        source: TextSource::Web,
        strategy: "visible text collection",
    })
}

fn collect_into(element: AXUIElementRef, depth: usize, nodes: &mut usize, out: &mut Vec<String>) {
    if depth > MAX_CAPTURE_DEPTH || *nodes >= MAX_CAPTURE_NODES {
        return;
    }
    *nodes += 1;

    if let Some(role) = copy_string(element, ATTR_ROLE) {
        if is_text_bearing_role(&role) {
            if let Some(text) = native::read(element) {
                if out.iter().map(String::len).sum::<usize>() < MAX_CAPTURE_CHARS {
                    out.push(text);
                }
            }
        }
    }

    let Some(children) = copy_array(element, ATTR_CHILDREN) else {
        return;
    };
    let count = unsafe { CFArrayGetCount(children.raw()) };
    for index in 0..count {
        if *nodes >= MAX_CAPTURE_NODES {
            return;
        }
        let child = unsafe { CFArrayGetValueAtIndex(children.raw(), index) } as AXUIElementRef;
        if child.is_null() {
            continue;
        }
        set_timeout(child);
        collect_into(child, depth + 1, nodes, out);
    }
}

fn is_text_bearing_role(role: &str) -> bool {
    matches!(
        role,
        "AXStaticText" | "AXTextArea" | "AXTextField" | "AXHeading" | "AXLink"
    )
}

fn field_identity(element: AXUIElementRef) -> FieldIdentity {
    let mut pid: i32 = 0;
    unsafe { AXUIElementGetPid(element, &mut pid) };

    let frame = focused_element_frame()
        .map(|(x, y, width, height)| format!("{x:.0},{y:.0},{width:.0},{height:.0}"));

    let key = identity_key(
        copy_string(element, "AXIdentifier"),
        copy_string(element, "AXDOMIdentifier"),
        frame,
    );

    FieldIdentity { pid, key }
}
```

- [ ] **Step 7: 加 `read_focused_field`**

```rust
/// Read the focused field with the enhancement + three-tier strategy. `None`
/// means "nothing readable here" — never an error.
pub fn read_focused_field(_timeout_ms: u32) -> Option<FocusedField> {
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

    let _enhance = EnhancedUserInterface::enable(focused.raw());
    let identity = field_identity(focused.raw());

    let read = read_element(focused.raw())
        .or_else(|| read_ancestor(focused.raw()))
        .or_else(|| read_child(focused.raw()))
        .or_else(|| collect_visible_text(focused.raw()))?;

    Some(FocusedField {
        text: read.text,
        identity,
        strategy: read.strategy,
    })
}
```

- [ ] **Step 8: 跑测试 + fmt**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::ax
cargo fmt --manifest-path core/core/Cargo.toml --check
```
Expected: PASS。

- [ ] **Step 9: 提交**

```bash
git add core/core/src/learning/ax/mod.rs
git commit -m "feat(learning): AX 采集增强 + 三级读取 + 字段身份（阶段 13 任务 1）"
```

---

### Task 2: 触发层——Enter 为主 + 身份变化

**Files:**
- Modify: `core/core/src/hotkeys.rs`
- Modify: `core/core/src/learning/watcher.rs`

**Interfaces:**
- Consumes: `ax::read_focused_field`（Task 1）、`hotkeys` 的 Return 转发。
- Produces:
  - `hotkeys::start_enter_watch()` / `hotkeys::stop_enter_watch()` 或等价的事件通道
    （最终实现择一，但 watcher 必须能在观察期间收到 Enter keyDown）。
  - `WatchMachine` 新增 `Poll::Enter`、`Poll::IdentityChanged` 与 `StopReason::Enter`、`StopReason::IdentityChanged`。

- [ ] **Step 1: 先验证 `handy-keys` 两个监听能否共存**

写一个临时 example 或单测，创建 `HotkeyManager::new_with_blocking()` 的同时再建一个
`KeyboardListener::new()`，确认不 panic 且能收到 `Key::Return`。
- 若能共存：在 `watcher.rs` 观察期间创建 `KeyboardListener`，用 `recv_timeout(POLL_INTERVAL)`
  在轮询间隙收 Return。
- 若冲突：改在 `hotkeys.rs` 的监听线程里，把未命中任何绑定、且 `key == Some(Key::Return)`
  的 keyDown 事件通过一个 `OnceLock<Mutex<Option<Sender<()>>>>` 转发给当前观察者。

（在报告里写明选了哪条路与证据。）

- [ ] **Step 2: 写失败测试（状态机）**

在 `watcher.rs` 的 `mod tests` 追加：

```rust
    #[test]
    fn machine_learns_on_enter() {
        let mut machine = WatchMachine::new();
        machine.on(Poll::Readable("hello".into()));
        assert_eq!(
            machine.on(Poll::Enter),
            (WatchStep::Learn, Some(StopReason::Enter))
        );
    }

    #[test]
    fn machine_stops_when_the_field_identity_changes() {
        let mut machine = WatchMachine::new();
        machine.on(Poll::Readable("hello".into()));
        assert_eq!(
            machine.on(Poll::IdentityChanged),
            (WatchStep::Ignore, Some(StopReason::IdentityChanged))
        );
    }
```

- [ ] **Step 3: 运行确认失败**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::watcher
```
Expected: 编译失败（`Poll::Enter` / `StopReason::Enter` 不存在）。

- [ ] **Step 4: 扩展状态机**

在 `enum Poll` 加 `Enter`、`IdentityChanged`；在 `enum StopReason` 加 `Enter`、`IdentityChanged`；
在 `WatchMachine::on` 加分支：

```rust
            Poll::Enter => (WatchStep::Learn, Some(StopReason::Enter)),
            Poll::IdentityChanged => (WatchStep::Ignore, Some(StopReason::IdentityChanged)),
```

在 `stop_outcome` 加：

```rust
        StopReason::Enter => "the enter key was pressed",
        StopReason::IdentityChanged => "the focused field changed",
```

- [ ] **Step 5: 接入 Enter 与身份变化**

`observe` 改为：
- 起始用 `ax::read_focused_field(300)` 读一次，记下 `identity` 与文本；读不到则记 `Poll::Unreadable`。
- 每轮：先尝试收 Enter（`recv_timeout` 或转发通道）→ 若收到 `Poll::Enter`；
  否则读字段：
  - `read_focused_field` 返回 `None` → `Poll::Unreadable`；
  - `Some(field)` 且 `field.identity != start_identity` → `Poll::IdentityChanged`；
  - `Some(field)` 且 `field.text.trim().is_empty()` → `Poll::Readable(String::new())`；
  - 否则 `Poll::Readable(field.text)`。
- 其余（generation/setting/secure/frontmost）分支不变。
- `report` 增加 `strategy`（可选）用于诊断。

（保持 `observe` 的返回契约 `(Vec<String>, WatchReport)` 不变。）

- [ ] **Step 6: 跑测试 + fmt**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::watcher
cargo fmt --manifest-path core/core/Cargo.toml --check
```
Expected: PASS。

- [ ] **Step 7: 提交**

```bash
git add core/core/src/hotkeys.rs core/core/src/learning/watcher.rs
git commit -m "feat(learning): Enter 触发 + 字段身份变化停止（阶段 13 任务 2）"
```

---

### Task 3: 判定层——记录 llm_raw 与原因

**Files:**
- Modify: `core/core/src/learning/llm.rs`
- Modify: `core/core/src/learning/watcher.rs`

**Interfaces:**
- Produces:
  ```rust
  pub enum JudgeSource { Llm, Local, None }
  pub struct Judgement {
      pub candidates: Vec<EditCandidate>,
      pub source: JudgeSource,
      pub llm_raw: Option<String>,
      pub reason: String,
  }
  pub fn judge(pasted: &str, final_text: &str) -> Judgement;
  ```
- `detect_corrections` 保留（`judge` 内部用），或改为返回 `(Option<Vec<..>>, Option<String> raw)`。

- [ ] **Step 1: 写失败测试**

在 `llm.rs` 的 `tests` 追加：

```rust
    #[test]
    fn judge_falls_back_to_local_and_records_the_source() {
        // No provider configured in tests → LLM unavailable → local path.
        let judgement = judge("c3xo", "cica exo");
        assert_eq!(judgement.source, JudgeSource::Local);
        assert_eq!(judgement.candidates.len(), 1);
        assert!(!judgement.reason.is_empty());
    }
```

（若 `judge` 在无 provider 时因 `settings::current()` 读不到而 panic，测试里先
`crate::settings::init_for_tests()`（若存在）；否则把纯逻辑拆成 `judge_from(pasted, final, llm: Option<...>)` 再测。）

- [ ] **Step 2: 运行确认失败**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::llm
```

- [ ] **Step 3: 实现 `judge`**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
pub enum JudgeSource { Llm, Local, None }

#[derive(Debug, Clone)]
pub struct Judgement {
    pub candidates: Vec<EditCandidate>,
    pub source: JudgeSource,
    pub llm_raw: Option<String>,
    pub reason: String,
}

/// Decide what (if anything) the edit taught, preferring the LLM and falling
/// back to the local gate. Always returns a human-readable reason.
pub fn judge(pasted: &str, final_text: &str) -> Judgement {
    match detect_corrections(pasted, final_text) {
        Some((candidates, raw)) => {
            let usable = candidates; // validation already done in parse
            if usable.is_empty() {
                Judgement {
                    candidates: Vec::new(),
                    source: JudgeSource::Llm,
                    llm_raw: Some(raw),
                    reason: "the llm found no mishearing".to_string(),
                }
            } else {
                Judgement {
                    candidates: usable,
                    source: JudgeSource::Llm,
                    llm_raw: Some(raw),
                    reason: "learned from the llm".to_string(),
                }
            }
        }
        None => {
            let candidates: Vec<EditCandidate> = super::diff::detect_edits(pasted, final_text)
                .into_iter()
                .filter(|candidate| {
                    super::diff::is_likely_mishearing(&candidate.pattern, &candidate.replacement)
                })
                .collect();
            let reason = if candidates.is_empty() {
                "the local gate found no mishearing".to_string()
            } else {
                "learned from the local gate".to_string()
            };
            Judgement {
                candidates,
                source: JudgeSource::Local,
                llm_raw: None,
                reason,
            }
        }
    }
}
```

把 `detect_corrections` 的返回改为 `Option<(Vec<EditCandidate>, String)>`（`String` 是原始
content），并在 watcher 里改用 `judge`。

- [ ] **Step 4: 跑测试 + fmt**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::
cargo fmt --manifest-path core/core/Cargo.toml --check
```

- [ ] **Step 5: 提交**

```bash
git add core/core/src/learning/llm.rs core/core/src/learning/watcher.rs
git commit -m "feat(learning): judge 记录来源/原始返回/原因（阶段 13 任务 3）"
```

---

### Task 4: `learning_attempts` 表 + FFI + 调试页

**Files:**
- Modify: `core/core/src/dictionary.rs`（迁移 + 读写）
- Modify: `core/core/src/learning/watcher.rs`（写入 attempt）
- Modify: `core/ffi/src/lib.rs`
- Modify: `macos/TalkWTF/CoreClient.swift`、`macos/TalkWTF/SettingsView.swift`
- Modify: `resources/locales/*/translation.json`（26 个）

**Interfaces:**
- Produces:
  - `dictionary::LearningAttempt`（字段见下）
  - `DictionaryStore::add_learning_attempt(&self, attempt: &NewLearningAttempt) -> Result<()>`
  - `DictionaryStore::list_learning_attempts(&self, limit: usize) -> Result<Vec<LearningAttempt>>`
  - `DictionaryStore::clear_learning_attempts(&self) -> Result<()>`
  - FFI：`list_learning_attempts`、`clear_learning_attempts`

- [ ] **Step 1: 写失败测试**

在 `dictionary.rs` 的 `tests` 追加：

```rust
    #[test]
    fn learning_attempts_round_trip_and_trim() {
        let (store, _dir) = store();
        for index in 0..205 {
            store
                .add_learning_attempt(&NewLearningAttempt {
                    bundle_id: Some("com.test".into()),
                    field_id: Some("field-1".into()),
                    pasted: format!("wrong {index}"),
                    final_text: format!("right {index}"),
                    source: "local".into(),
                    llm_raw: None,
                    outcome: "learned".into(),
                    reason: "learned from the local gate".into(),
                    learned_json: Some("[]".into()),
                })
                .unwrap();
        }
        let attempts = store.list_learning_attempts(500).unwrap();
        assert_eq!(attempts.len(), 200);
        assert_eq!(attempts[0].pasted, "wrong 5");

        store.clear_learning_attempts().unwrap();
        assert!(store.list_learning_attempts(10).unwrap().is_empty());
    }
```

- [ ] **Step 2: 运行确认失败**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning_attempts
```

- [ ] **Step 3: 加迁移与类型**

在 `MIGRATIONS` 加第二个 `M::up`：

```rust
static MIGRATIONS: &[M] = &[
    M::up(
        "CREATE TABLE dictionary ( ... 原样 ... );",
    ),
    M::up(
        "CREATE TABLE learning_attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            bundle_id TEXT,
            field_id TEXT,
            pasted TEXT NOT NULL,
            final_text TEXT NOT NULL,
            source TEXT NOT NULL,
            llm_raw TEXT,
            outcome TEXT NOT NULL,
            reason TEXT NOT NULL,
            learned_json TEXT
        );",
    ),
];
```

类型：

```rust
pub const LEARNING_ATTEMPT_LIMIT: usize = 200;

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct NewLearningAttempt {
    pub bundle_id: Option<String>,
    pub field_id: Option<String>,
    pub pasted: String,
    pub final_text: String,
    pub source: String,
    pub llm_raw: Option<String>,
    pub outcome: String,
    pub reason: String,
    pub learned_json: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct LearningAttempt {
    pub id: i64,
    pub created_at: String,
    pub bundle_id: Option<String>,
    pub field_id: Option<String>,
    pub pasted: String,
    pub final_text: String,
    pub source: String,
    pub llm_raw: Option<String>,
    pub outcome: String,
    pub reason: String,
    pub learned_json: Option<String>,
}
```

- [ ] **Step 4: 实现读写（含 200 条裁剪）**

```rust
    pub fn add_learning_attempt(&self, attempt: &NewLearningAttempt) -> Result<()> {
        let conn = self.get_connection()?;
        let created_at = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO learning_attempts
                (created_at, bundle_id, field_id, pasted, final_text, source, llm_raw, outcome, reason, learned_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                created_at, attempt.bundle_id, attempt.field_id, attempt.pasted,
                attempt.final_text, attempt.source, attempt.llm_raw, attempt.outcome,
                attempt.reason, attempt.learned_json,
            ],
        )?;
        conn.execute(
            "DELETE FROM learning_attempts WHERE id NOT IN (
                SELECT id FROM learning_attempts ORDER BY id DESC LIMIT ?1
             )",
            params![LEARNING_ATTEMPT_LIMIT as i64],
        )?;
        Ok(())
    }

    pub fn list_learning_attempts(&self, limit: usize) -> Result<Vec<LearningAttempt>> {
        let conn = self.get_connection()?;
        let mut stmt = conn.prepare(
            "SELECT id, created_at, bundle_id, field_id, pasted, final_text, source,
                    llm_raw, outcome, reason, learned_json
             FROM learning_attempts ORDER BY id DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit as i64], |row| {
            Ok(LearningAttempt {
                id: row.get(0)?,
                created_at: row.get(1)?,
                bundle_id: row.get(2)?,
                field_id: row.get(3)?,
                pasted: row.get(4)?,
                final_text: row.get(5)?,
                source: row.get(6)?,
                llm_raw: row.get(7)?,
                outcome: row.get(8)?,
                reason: row.get(9)?,
                learned_json: row.get(10)?,
            })
        })?;
        rows.collect()
    }

    pub fn clear_learning_attempts(&self) -> Result<()> {
        let conn = self.get_connection()?;
        conn.execute("DELETE FROM learning_attempts", [])?;
        Ok(())
    }
```

（`chrono` 若未依赖，用 `std::time::SystemTime` + 现有时间格式，或复用项目已有的时间来源。）

- [ ] **Step 5: watcher 写入 attempt**

在 `apply()`（或结算处）组装 `NewLearningAttempt`：
- `source` = `judgement.source` 的字符串（`llm`/`local`/`none`）
- `outcome` = `learned` 或 `skipped`
- `reason` = `judgement.reason`
- `learned_json` = 学到的词对 JSON（无则 `None`）
- 无候选时也要写一条（`skipped`），便于诊断。

- [ ] **Step 6: FFI**

在 `core/ffi/src/lib.rs` 的 `invoke` 加：

```rust
        "list_learning_attempts" => {
            let limit = args.get("limit").and_then(|v| v.as_u64()).unwrap_or(50) as usize;
            let store = talkwtf_core::state::dictionary_store()
                .ok_or_else(|| "dictionary store is not initialized".to_string())?;
            json_of(store.list_learning_attempts(limit).map_err(|e| e.to_string())?)
        }
        "clear_learning_attempts" => {
            let store = talkwtf_core::state::dictionary_store()
                .ok_or_else(|| "dictionary store is not initialized".to_string())?;
            store.clear_learning_attempts().map_err(|e| e.to_string())?;
            json_of(serde_json::json!({ "ok": true }))
        }
```

- [ ] **Step 7: Swift 解码 + 调试页**

- `CoreClient.swift`：加 `LearningAttempt` 结构（字段同名）与 `listLearningAttempts(limit:)` /
  `clearLearningAttempts()`。
- `SettingsView.swift` 调试区加 Section「学词记录」：列出最近 50 条
  （`pasted → final`、`source`、`reason`、时间），带「清空」按钮，`.task` 时加载。
- 新增 i18n key（en 写好，其余 25 个语言包补同 key，可用英文兜底）：
  `settings.debug.learningAttempts.title`、`settings.debug.learningAttempts.empty`、
  `settings.debug.learningAttempts.clear`。

- [ ] **Step 8: 构建 + 测试 + 翻译检查**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/ffi/Cargo.toml
python3 scripts/check_translations.py
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
```
Expected: 全绿 + 构建成功。

- [ ] **Step 9: 提交**

```bash
git add -A
git commit -m "feat(learning): learning_attempts 本地记录 + FFI + 调试页（阶段 13 任务 4）"
```

---

### Task 5: 全量验证 + 真机验收

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

按 spec 第八节：Chrome contenteditable / 微信 / TextEdit 各测一遍；改意思不学；
调试页能看到每次尝试；撤销可用；未配 key 走本地。

---

## Self-Review

- **Spec 覆盖**：5.2→Task 1；5.3→Task 2；5.4→Task 3；5.5→Task 4；验收→Task 5。
- **占位符**：Task 2 Step 1 保留「择一实现」是刻意的可行性判定步骤，报告须写明选择与证据；
  其余步骤均有具体代码/命令。
- **类型一致**：`FieldIdentity` / `FocusedField` / `JudgeSource` / `Judgement` /
  `NewLearningAttempt` / `LearningAttempt` 在定义与调用处一致。
- **风险**：Task 1 的 AX FFI 与 Task 2 的 Enter 共存是本计划最不确定处，故各自第一步先验证。
