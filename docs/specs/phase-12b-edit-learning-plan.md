# 阶段 12b 实现计划：自动学词重做（发送后触发 + LLM 判定 + 弹窗修正）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让自动学词只在用户发送后触发、只学「识别听错」而非「改意思」、并把学到词的弹窗放到与录音悬浮窗相同的位置。

**Architecture:** 观察线程（`core/core/src/learning/watcher.rs`）改为只在字段清空/失焦/前台变化时结算；结算后用 LLM（复用现有 BYOK provider，新增 `learning/llm.rs`）判定听错，失败则回退到本地 `diff.rs`（新增相似度门槛）。Swift 侧只改弹窗定位与滑块下限。

**Tech Stack:** Rust（core/core，`strsim` / `serde_json` / `tokio` / `reqwest` 已有）、SwiftUI（macOS 外壳）。

**Spec:** `docs/specs/phase-12b-edit-learning-redesign.md`

## Global Constraints

- 无自建云/账号/遥测；LLM 只在用户已配 provider + key 时直连 provider（BYOK）。
- 不改本地 ASR 运行时。
- 不新增设置页；学词复用「个性化」里已选的润色 provider 与 key。
- 本项目约定：**不要 git commit，除非用户明确要求**。每个任务以「跑测试/构建通过」结束，不自动提交。
- 命令前先 `export PATH="/opt/homebrew/opt/rustup/bin:$PATH"`。
- 测试必须绕过本机代理：`NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost`。
- 新增 `.swift` 才需要在 pbxproj 四处登记；本计划只改已有 `.swift`，无需登记。
- 不要写注释（除非必要说明非显然逻辑）；沿用现有代码风格。

---

### Task 1: watcher 改为「只在发送后结算」

**Files:**
- Modify: `core/core/src/learning/watcher.rs`

**Interfaces:**
- Consumes: 无（纯重构）。
- Produces: `fn choose_final(observed: &[String], pasted: &str) -> Option<String>`（私有）；
  `fn observe(pasted: &str, bundle_id: Option<&str>, generation: u64) -> (Vec<String>, WatchReport)`（私有，返回观察到的状态而非候选）。

- [ ] **Step 1: 写失败测试**

在 `core/core/src/learning/watcher.rs` 的 `mod tests` 末尾（`a_state_with_no_edit_learns_nothing` 之后）加入：

```rust
    #[test]
    fn choose_final_prefers_the_newest_differing_state() {
        let pasted = "hello world";
        let observed = states(&[pasted, "hello there", "hello world!"]);

        assert_eq!(
            choose_final(&observed, pasted),
            Some("hello world!".to_string())
        );
    }

    #[test]
    fn choose_final_is_none_when_nothing_differs() {
        let pasted = "hello world";
        let observed = states(&[pasted, pasted]);

        assert_eq!(choose_final(&observed, pasted), None);
    }
```

- [ ] **Step 2: 运行测试确认失败**

```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml choose_final
```
Expected: 编译失败 `cannot find function choose_final`。

- [ ] **Step 3: 改常量：删 `SETTLE`，加 `FOCUS_LOST_POLLS`**

把 `watcher.rs:20-38` 的常量块替换为（`SETTLE` 删除，其余保留）：

```rust
/// Poll cadence while watching.
const POLL_INTERVAL: Duration = Duration::from_millis(200);
/// How long we keep watching after a paste.
const WATCH_WINDOW: Duration = Duration::from_secs(45);
/// Consecutive polls with no readable focus, after the field was readable, that
/// mean the user moved on (sent, submitted, or clicked away). 10 * 200ms = 2s.
const FOCUS_LOST_POLLS: u32 = 10;
/// How many observed field states we keep. Every distinct value is stored, so the
/// decision at the end can look back past an incomplete one.
const MAX_OBSERVED_STATES: usize = 40;
/// Most rules one dictation may teach.
const MAX_LEARNED_WORDS: usize = 5;
/// Only the newest dictation may watch. Without this, two dictations within the
/// watch window would run two observers, and the older one would compare the
/// field against a stale "what we pasted".
static WATCH_GENERATION: AtomicU64 = AtomicU64::new(0);
```

- [ ] **Step 4: 替换 `observe()`**

把 `watcher.rs` 中整个 `fn observe(...)`（从 `fn observe(` 到其结束的 `}`）替换为：

```rust
fn observe(
    pasted: &str,
    bundle_id: Option<&str>,
    generation: u64,
) -> (Vec<String>, WatchReport) {
    let started = Instant::now();
    let mut unreadable = 0u32;
    let mut ever_readable = false;

    // Every distinct non-empty value the field held, oldest first. The decision
    // at the end looks back through these instead of trusting the last sample.
    let mut observed: Vec<String> = Vec::new();

    let mut report = WatchReport {
        bundle_id: bundle_id.map(str::to_string),
        pasted_chars: pasted.chars().count(),
        outcome: "timeout".to_string(),
        ..Default::default()
    };

    while started.elapsed() < WATCH_WINDOW {
        std::thread::sleep(POLL_INTERVAL);
        report.polls += 1;

        if WATCH_GENERATION.load(Ordering::SeqCst) != generation {
            debug!("Stopping the edit watch: a newer dictation took over");
            report.outcome = "superseded by a newer dictation".to_string();
            return (Vec::new(), report);
        }
        if !crate::settings::current().learn_from_edits {
            report.outcome = "the setting was turned off".to_string();
            return (Vec::new(), report);
        }
        // Never read anything while the system is in a secure-input context.
        if crate::secure_input::is_enabled_now() {
            debug!("Stopping the edit watch: secure input became active");
            report.outcome = "secure input became active".to_string();
            return (Vec::new(), report);
        }
        if ax::frontmost_bundle_id().as_deref() != bundle_id {
            debug!("Stopping the edit watch: the frontmost app changed");
            report.outcome = "the frontmost app changed".to_string();
            return (observed, report);
        }

        // A read can fail transiently — the app is busy, or an input-method
        // composition window briefly owns focus. That is exactly when the user is
        // editing, so a failure must never end the watch; "the user moved on" is
        // detected by the frontmost-app check and by a sustained unreadable streak.
        let Some(focused) = ax::read_focused_text(unreadable == 0 || unreadable % 40 == 0) else {
            unreadable = unreadable.saturating_add(1);
            if ever_readable && unreadable >= FOCUS_LOST_POLLS {
                debug!("Settling the edit watch: the field lost focus");
                report.outcome = "the field lost focus".to_string();
                return (observed, report);
            }
            continue;
        };
        unreadable = 0;
        ever_readable = true;
        report.readable_polls += 1;
        report.last_field_chars = Some(focused.text.chars().count());
        report.last_field_preview = Some(focused.text.chars().take(160).collect());

        // The field emptied: the message was sent (or the draft cleared).
        if focused.text.trim().is_empty() {
            report.outcome = "the field emptied".to_string();
            return (observed, report);
        }

        if observed.last().map(String::as_str) != Some(focused.text.as_str()) {
            observed.push(focused.text.clone());
            if observed.len() > MAX_OBSERVED_STATES {
                observed.remove(0);
            }
        }
    }

    debug!("Edit watch timed out with no send");
    report.outcome = "timeout".to_string();
    (Vec::new(), report)
}
```

- [ ] **Step 5: 替换 `watch_for_edit` 里的观察线程**

把 `watcher.rs` 中 `watch_for_edit` 内 `std::thread::spawn(move || { ... });` 整个闭包替换为：

```rust
    std::thread::spawn(move || {
        let (observed, mut report) = observe(&pasted, bundle_id.as_deref(), generation);

        if let Some(final_text) = choose_final(&observed, &pasted) {
            let candidates = decide(&observed, &pasted, &mut report);

            if !candidates.is_empty() {
                report.candidate = Some(describe(&candidates));
                // Read the field's position now, while it is still focused, so the
                // notice can be placed next to it (the shell ignores this now).
                let frame = ax::focused_element_frame();
                apply(candidates, frame);
            }
        }

        if let Some(state) = crate::learning::learning_state() {
            state.set_report(report.clone());
        }

        debug!(
            "Edit watch finished: {} | polls {} ({} readable) | last field {} chars | {:?}",
            report.outcome,
            report.polls,
            report.readable_polls,
            report.last_field_chars.unwrap_or(0),
            report.candidate,
        );
    });
```

> 注意：Task 3 会把这里的 `decide(...)` 换成「LLM 优先、失败回退 `decide`」。本步先只做触发/结算重构。

- [ ] **Step 6: 加 `choose_final`**

在 `fn observe(` 之前加入：

```rust
/// The newest state the field held that differs from what we pasted. This is what
/// we compare against when deciding what the edit taught.
fn choose_final(observed: &[String], pasted: &str) -> Option<String> {
    observed
        .iter()
        .rev()
        .find(|text| text.as_str() != pasted)
        .cloned()
}
```

- [ ] **Step 7: 跑测试**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::watcher
```
Expected: PASS（含新增的两个 `choose_final` 测试与原有 `decide`/`learn` 测试）。

- [ ] **Step 8: 格式检查**

```bash
cargo fmt --manifest-path core/core/Cargo.toml --check
```
Expected: 无输出（通过）。若失败，运行 `cargo fmt --manifest-path core/core/Cargo.toml` 后重跑。

---

### Task 2: diff 加「只听错才学」门槛 + 单字 CJK 不学

**Files:**
- Modify: `core/core/src/learning/diff.rs`

**Interfaces:**
- Produces: `pub fn is_likely_mishearing(pattern: &str, replacement: &str) -> bool`
- 修改：`MIN_CJK_SPAN_CHARS` 1 → 2。

- [ ] **Step 1: 写失败测试**

在 `core/core/src/learning/diff.rs` 的 `mod tests` 末尾（`an_absurdly_long_paste_is_skipped` 之后）加入：

```rust
    #[test]
    fn gate_accepts_a_close_ascii_mishearing() {
        assert!(is_likely_mishearing("C3XO", "Cica Exo"));
    }

    #[test]
    fn gate_rejects_a_semantic_ascii_change() {
        assert!(!is_likely_mishearing("ship", "hold"));
    }

    #[test]
    fn gate_accepts_cjk_with_shared_characters() {
        assert!(is_likely_mishearing("浏览起", "浏览器"));
    }

    #[test]
    fn gate_rejects_a_semantic_cjk_change() {
        assert!(!is_likely_mishearing("要喝牛奶", "想喝咖啡"));
    }

    #[test]
    fn gate_accepts_a_cross_script_mishearing() {
        assert!(is_likely_mishearing("嗨桌飞手", "Hydra Facial"));
    }

    #[test]
    fn gate_rejects_an_identical_pair() {
        assert!(!is_likely_mishearing("hello", "hello"));
    }
```

并把已有的两个单字 CJK 测试改为断言 `None`：

```rust
    #[test]
    fn a_single_cjk_character_is_not_learned() {
        // A lone character is not a term; the LLM path handles word-level fixes.
        assert_eq!(
            candidate("今天早上我要喝牛奶", "今天晚上我要喝牛奶"),
            None
        );
    }
```

删除 `an_edit_near_the_start_still_anchors`（与 `learns_a_multi_word_term_fix` 重复；start 锚定已由
`learns_a_chinese_to_english_replacement` 覆盖）。

- [ ] **Step 2: 运行测试确认失败**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::diff
```
Expected: 编译失败 `cannot find function is_likely_mishearing`；且 `a_single_cjk_character_is_not_learned` 失败（当前会返回 `Some`）。

- [ ] **Step 3: 改 `MIN_CJK_SPAN_CHARS`**

把 `diff.rs:45`：

```rust
const MIN_CJK_SPAN_CHARS: usize = 1;
```

改为：

```rust
const MIN_CJK_SPAN_CHARS: usize = 2;
```

- [ ] **Step 4: 加门槛常量与函数**

在 `diff.rs` 的 `MIN_CJK_SPAN_CHARS` 常量块之后加入：

```rust
/// Similarity floors for the "this looks like a mishearing, not a change of mind"
/// gate. ASCII terms must be close under normalized edit distance; CJK terms must
/// share enough characters. A dictionary word biases future recognition, so a
/// semantic edit ("早" -> "晚") must never be learned.
const LEARN_SIMILARITY_THRESHOLD: f64 = 0.6;
const LEARN_CJK_OVERLAP: f64 = 0.5;
```

在 `fn has_cjk(` 之后加入：

```rust
/// Whether a correction looks like the recognizer misheard the user, rather than
/// the user changing their mind. Cross-script pairs (the recognizer wrote Chinese
/// for an English term, or vice versa) are treated as mishearings: local code
/// cannot score their pronunciation, and they are rarely a deliberate rewrite.
pub fn is_likely_mishearing(pattern: &str, replacement: &str) -> bool {
    let old_has_cjk = has_cjk(pattern);
    let new_has_cjk = has_cjk(replacement);

    if old_has_cjk != new_has_cjk {
        return true;
    }

    if old_has_cjk {
        cjk_overlap(pattern, replacement) >= LEARN_CJK_OVERLAP
    } else {
        normalized_distance(pattern, replacement) <= LEARN_SIMILARITY_THRESHOLD
    }
}

/// Normalized Levenshtein distance over alphanumeric, lowercased text.
fn normalized_distance(left: &str, right: &str) -> f64 {
    let left = match_key(left);
    let right = match_key(right);
    let max = left.chars().count().max(right.chars().count());
    if max == 0 {
        return 1.0;
    }
    strsim::levenshtein(&left, &right) as f64 / max as f64
}

fn match_key(text: &str) -> String {
    text.chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(|character| character.to_lowercase())
        .collect()
}

/// Shared-character ratio (multiset intersection over the longer side).
fn cjk_overlap(left: &str, right: &str) -> f64 {
    let mut remaining: Vec<char> = right.chars().collect();
    let mut shared = 0usize;
    for character in left.chars() {
        if let Some(index) = remaining.iter().position(|candidate| *candidate == character) {
            remaining.remove(index);
            shared += 1;
        }
    }
    let max = left.chars().count().max(right.chars().count());
    if max == 0 {
        return 0.0;
    }
    shared as f64 / max as f64
}
```

- [ ] **Step 5: 在 `decide()` 里应用门槛**

在 `watcher.rs` 的 `decide()` 中，两处 `diff::detect_edits(...)` 调用后面各加一层过滤。把：

```rust
        let candidates = diff::detect_edits(pasted, text);
```

改为：

```rust
        let candidates: Vec<diff::EditCandidate> = diff::detect_edits(pasted, text)
            .into_iter()
            .filter(|candidate| {
                diff::is_likely_mishearing(&candidate.pattern, &candidate.replacement)
            })
            .collect();
```

- [ ] **Step 6: 跑测试**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::
```
Expected: 全部 PASS。若 `falls_back_to_the_best_incomplete_state` 失败（`C3XO -> Cica` 归一化距离
0.75 > 0.6，被门槛拒绝），把该测试改为断言空：

```rust
    #[test]
    fn falls_back_to_nothing_when_the_captured_fragment_is_dissimilar() {
        let pasted = "他想做 C3XO，可以吗？";
        let observed = states(&[pasted, "他想做 Cica ，可以吗？"]);

        let mut report = WatchReport::default();
        assert!(decide(&observed, pasted, &mut report).is_empty());
    }
```

- [ ] **Step 7: 格式检查**

```bash
cargo fmt --manifest-path core/core/Cargo.toml --check
```
Expected: 通过。

---

### Task 3: 新增 LLM 听错判定并接入 watcher

**Files:**
- Create: `core/core/src/learning/llm.rs`
- Modify: `core/core/src/learning/mod.rs`
- Modify: `core/core/src/learning/watcher.rs`（观察线程改为 LLM 优先）

**Interfaces:**
- Consumes: `crate::settings::{current, AppSettings, PostProcessProvider, APPLE_INTELLIGENCE_PROVIDER_ID}`；
  `crate::llm_client::send_chat_completion_with_schema(provider, api_key, model, user_content, system_prompt, json_schema, disable_reasoning) -> Result<Option<LlmCompletion>, String>`；
  `crate::dictation::block_on`；`crate::pipeline::strip_think_block`；`super::diff::EditCandidate`。
- Produces:
  - `pub fn detect_corrections(pasted: &str, final_text: &str) -> Option<Vec<EditCandidate>>`
    （`None` = LLM 不可用/失败，调用方回退本地；`Some(vec![])` = LLM 判定无需学习）
  - `fn parse_corrections(content: &str) -> Option<Vec<EditCandidate>>`（私有、纯函数、可单测）

- [ ] **Step 1: 写失败测试**

创建 `core/core/src/learning/llm.rs`，先只放模块与测试骨架：

```rust
//! Ask the configured provider which corrections in an edit were mishearings.

use log::debug;

use crate::settings::{AppSettings, APPLE_INTELLIGENCE_PROVIDER_ID};
use super::diff::EditCandidate;

/// Most corrections one dictation may teach.
const MAX_CORRECTIONS: usize = 5;
/// Longest pattern / replacement we accept from the model.
const MAX_FIELD_CHARS: usize = 40;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_structured_answer() {
        let parsed = parse_corrections(
            r#"{"corrections":[{"pattern":"C3XO","replacement":"Cica Exo"}]}"#,
        );

        assert_eq!(
            parsed,
            Some(vec![EditCandidate {
                pattern: "C3XO".to_string(),
                replacement: "Cica Exo".to_string(),
            }])
        );
    }

    #[test]
    fn parses_a_bare_array() {
        let parsed = parse_corrections(r#"[{"pattern":"QL","replacement":"KOL"}]"#);

        assert_eq!(
            parsed,
            Some(vec![EditCandidate {
                pattern: "QL".to_string(),
                replacement: "KOL".to_string(),
            }])
        );
    }

    #[test]
    fn an_empty_answer_is_some_empty() {
        assert_eq!(parse_corrections(r#"{"corrections":[]}"#), Some(Vec::new()));
        assert_eq!(parse_corrections("[]"), Some(Vec::new()));
    }

    #[test]
    fn invalid_json_is_none() {
        assert_eq!(parse_corrections("not json"), None);
    }

    #[test]
    fn drops_invalid_entries() {
        let parsed = parse_corrections(
            r#"[{"pattern":"","replacement":"x"},{"pattern":"a","replacement":"a"},{"pattern":"a\nb","replacement":"c"}]"#,
        );

        assert_eq!(parsed, Some(Vec::new()));
    }

    #[test]
    fn strips_a_think_block_first() {
        let parsed = parse_corrections(
            "<think>hmm</think>{\"corrections\":[{\"pattern\":\"QL\",\"replacement\":\"KOL\"}]}",
        );

        assert_eq!(
            parsed,
            Some(vec![EditCandidate {
                pattern: "QL".to_string(),
                replacement: "KOL".to_string(),
            }])
        );
    }
}
```

- [ ] **Step 2: 注册模块并运行测试确认失败**

在 `core/core/src/learning/mod.rs` 的 `mod watcher;` 旁加：

```rust
#[cfg(target_os = "macos")]
mod llm;
```

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::llm
```
Expected: 编译失败 `cannot find function parse_corrections`。

- [ ] **Step 3: 实现模块**

在 `llm.rs` 的 `mod tests` 之前加入：

```rust
/// Ask the active provider what the user misheard. `None` means the LLM is
/// unavailable or failed, so the caller falls back to the local diff. `Some` with
/// an empty vector means the LLM ran and found nothing worth learning — trust it.
pub fn detect_corrections(pasted: &str, final_text: &str) -> Option<Vec<EditCandidate>> {
    let settings = crate::settings::current();
    let (provider, model, api_key) = provider_config(&settings)?;

    let schema = serde_json::json!({
        "type": "object",
        "properties": {
            "corrections": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "pattern": { "type": "string" },
                        "replacement": { "type": "string" }
                    },
                    "required": ["pattern", "replacement"],
                    "additionalProperties": false
                }
            }
        },
        "required": ["corrections"],
        "additionalProperties": false
    });

    let system = "You extract dictionary corrections from a user's edit. The user \
        dictated text, then edited it. Return ONLY words or terms the recognizer \
        misheard (the corrected word sounds like, or closely resembles, what was \
        dictated), as {\"corrections\":[{\"pattern\":\"<as dictated>\",\
        \"replacement\":\"<as corrected>\"}]}. Do NOT return edits where the user \
        changed their mind, meaning, or wording: changing \"今天早上\" to \
        \"今天晚上\" is a meaning change, not a mishearing, and must not be returned. \
        Ignore rewrites, punctuation, word order, capitalization and whitespace. \
        Return an empty list when nothing is a mishearing.";
    let user = format!("DICTATED:\n{pasted}\n\nEDITED:\n{final_text}");

    let json_schema = provider.supports_structured_output.then_some(schema);

    let completion = crate::dictation::block_on(
        crate::llm_client::send_chat_completion_with_schema(
            &provider,
            api_key,
            &model,
            user,
            Some(system.to_string()),
            json_schema,
            true,
        ),
    );

    match completion {
        Ok(Some(completion)) => parse_corrections(&completion.content),
        Ok(None) => None,
        Err(error) => {
            debug!("Edit-learning LLM request failed: {error}");
            None
        }
    }
}

/// The provider / model / key to use, or `None` when the user has not configured
/// a usable one. Apple Intelligence is a shell-side provider the core cannot run.
fn provider_config(
    settings: &AppSettings,
) -> Option<(crate::settings::PostProcessProvider, String, String)> {
    let provider = settings.active_post_process_provider()?.clone();
    if provider.id == APPLE_INTELLIGENCE_PROVIDER_ID {
        return None;
    }

    let model = settings.post_process_models.get(&provider.id)?.clone();
    if model.trim().is_empty() {
        return None;
    }

    let api_key = settings
        .post_process_api_keys
        .get(&provider.id)
        .cloned()
        .unwrap_or_default();

    Some((provider, model, api_key))
}

/// Parse the model's answer. Accepts the structured object or a bare array, so a
/// provider that ignored the schema still works. `None` means the answer was
/// unusable (fall back to the local diff).
fn parse_corrections(content: &str) -> Option<Vec<EditCandidate>> {
    let content = crate::pipeline::strip_think_block(content);
    let value: serde_json::Value = serde_json::from_str(content.trim()).ok()?;

    let items = value
        .get("corrections")
        .and_then(|corrections| corrections.as_array())
        .cloned()
        .or_else(|| value.as_array().cloned())?;

    let mut candidates = Vec::new();
    for item in items {
        let pattern = item
            .get("pattern")
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        let replacement = item
            .get("replacement")
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .trim()
            .to_string();

        if !is_valid(&pattern, &replacement) {
            continue;
        }

        candidates.push(EditCandidate {
            pattern,
            replacement,
        });
        if candidates.len() >= MAX_CORRECTIONS {
            break;
        }
    }

    Some(candidates)
}

fn is_valid(pattern: &str, replacement: &str) -> bool {
    if pattern.is_empty() || replacement.is_empty() || pattern == replacement {
        return false;
    }
    if pattern.chars().count() > MAX_FIELD_CHARS || replacement.chars().count() > MAX_FIELD_CHARS {
        return false;
    }
    !pattern.contains('\n') && !replacement.contains('\n')
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml learning::llm
```
Expected: PASS。

- [ ] **Step 5: 接入 watcher（LLM 优先，失败回退本地）**

在 `watcher.rs` 顶部模块引用处（`use super::{ax, diff};`）改为：

```rust
use super::{ax, diff, llm};
```

把 Task 1 Step 5 里线程中的这一行：

```rust
            let candidates = decide(&observed, &pasted, &mut report);
```

替换为：

```rust
            let candidates = match llm::detect_corrections(&pasted, &final_text) {
                Some(candidates) => {
                    let usable = usable_candidates(candidates);
                    report.outcome = if usable.is_empty() {
                        "the llm found no mishearing".to_string()
                    } else {
                        "learned (llm)".to_string()
                    };
                    usable
                }
                None => decide(&observed, &pasted, &mut report),
            };
```

- [ ] **Step 6: 跑全部 core 测试 + 格式**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml
cargo fmt --manifest-path core/core/Cargo.toml --check
```
Expected: 全绿、格式通过。

---

### Task 4: 学到词的弹窗用录音悬浮窗的位置

**Files:**
- Modify: `macos/TalkWTF/OverlayPanel.swift`

**Interfaces:**
- Consumes: `OverlayController.show(_ state: OverlayState, near frame: CGRect? = nil)`。
- Produces: 无新接口；`learned-overlay` 改为默认定位。

- [ ] **Step 1: 改 `handle` 的 `learned-overlay` 分支**

把 `OverlayPanel.swift:112-122`：

```swift
        case "learned-overlay":
            guard let payload = object["payload"] as? [String: Any],
                  let notice = payload["notice"] as? [String: Any] else { return }
            show(
                .learned(
                    pattern: notice["pattern"] as? String ?? "",
                    replacement: notice["replacement"] as? String ?? "",
                    count: (notice["count"] as? NSNumber)?.intValue ?? 1
                ),
                near: Self.rect(from: payload["frame"])
            )
```

改为（去掉 `near:`，与录音悬浮窗同样默认定位）：

```swift
        case "learned-overlay":
            guard let payload = object["payload"] as? [String: Any],
                  let notice = payload["notice"] as? [String: Any] else { return }
            show(
                .learned(
                    pattern: notice["pattern"] as? String ?? "",
                    replacement: notice["replacement"] as? String ?? "",
                    count: (notice["count"] as? NSNumber)?.intValue ?? 1
                )
            )
```

- [ ] **Step 2: 删掉不再使用的 `rect(from:)`**

删除 `OverlayPanel.swift` 中：

```swift
    /// AX frames are `[x, y, width, height]` in top-left screen coordinates.
    private static func rect(from value: Any?) -> CGRect? {
        guard let values = value as? [NSNumber], values.count == 4 else { return nil }
        return CGRect(
            x: values[0].doubleValue,
            y: values[1].doubleValue,
            width: values[2].doubleValue,
            height: values[3].doubleValue
        )
    }
```

- [ ] **Step 3: 构建**

```bash
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
```
Expected: `BUILD SUCCEEDED`，无「未使用函数」警告。

---

### Task 5: 阈值滑块下限 0.01

**Files:**
- Modify: `macos/TalkWTF/SettingsView.swift`

- [ ] **Step 1: 改滑块范围**

把 `SettingsView.swift:242-249` 中的：

```swift
                sliderField(
                    "word_correction_threshold",
                    "settings.debug.wordCorrectionThreshold.title",
                    description: "settings.debug.wordCorrectionThreshold.description",
                    range: 0.0...1.0,
                    step: 0.01,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                )
```

改为：

```swift
                sliderField(
                    "word_correction_threshold",
                    "settings.debug.wordCorrectionThreshold.title",
                    description: "settings.debug.wordCorrectionThreshold.description",
                    range: 0.01...1.0,
                    step: 0.01,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                )
```

- [ ] **Step 2: 构建**

```bash
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
```
Expected: `BUILD SUCCEEDED`。

---

### Task 6: 全量验证

**Files:** 无改动。

- [ ] **Step 1: 跑全部 core / ffi 测试**

```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/ffi/Cargo.toml
```
Expected: 全绿。

- [ ] **Step 2: 格式 + 翻译检查**

```bash
cargo fmt --manifest-path core/core/Cargo.toml --check
cargo fmt --manifest-path core/ffi/Cargo.toml --check
python3 scripts/check_translations.py
```
Expected: 格式通过、26 语言包 key 一致。

- [ ] **Step 3: 构建 app**

```bash
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
```
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 4: 交用户真机验收（本计划无法自动验证）**

按 spec「八、测试与验收」的手动清单：

1. 聊天输入框：听写 → 改词 → 回车发送 → 立刻弹窗，位置与录音悬浮窗一致。
2. 弹窗「撤销」→ 词消失、误听进拒绝名单。
3. 改了词但停住不发（焦点仍在）→ 不弹窗、不学习。
4. 把「今天早上我要喝牛奶」改成「今天晚上我要喝牛奶」→ 不学习（改意思）。
5. 配好 DeepSeek key 走 LLM；清空 key 走本地。
6. 阈值 0.18 下，学到的词能纠正下一次近似听错。

验收前重启 app（Rust 命令/事件改动后必须重启），并直接跑二进制看日志：

```bash
macos/build/Debug/TalkWTF.app/Contents/MacOS/TalkWTF
```

---

## Self-Review

- **Spec 覆盖**：5.1 触发 → Task 1；5.2 LLM → Task 3；5.3 门槛 → Task 2；5.4 弹窗 → Task 4；
  5.5 阈值 → Task 5；验收 → Task 6。无遗漏。
- **占位符**：无 TBD/TODO；每个代码步都给了完整代码。
- **类型一致**：`choose_final -> Option<String>`、`is_likely_mishearing -> bool`、
  `detect_corrections -> Option<Vec<EditCandidate>>`、`parse_corrections -> Option<Vec<EditCandidate>>`
  在定义与调用处一致；`observe` 返回 `(Vec<String>, WatchReport)` 在 Task 1/3 一致。
- **已知取舍**：本地门槛会漏学部分真听错（跨语言本地判不出以外的多字），已记入 spec 风险；
  无 key 用户受影响，LLM 路径为主。
