//! Watch the field we just pasted into, and learn a dictionary entry from the
//! correction the user makes.
//!
//! Everything here is best-effort: unreadable fields, a switched app, secure
//! input, or an edit we cannot interpret all end in silence, never in an error.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use handy_keys::{Key, KeyEvent, KeyboardListener};
use log::{debug, info};
use serde::{Deserialize, Serialize};
use specta::Type;

use crate::dictionary::DictionaryStore;
use crate::settings::OverlayStyle;

use super::{ax, diff, llm};

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
/// How many observed field states we keep. Every distinct value is stored, so the
/// decision at the end can look back past an incomplete one.
const MAX_OBSERVED_STATES: usize = 40;
/// Most rules one dictation may teach.
const MAX_LEARNED_WORDS: usize = 5;
/// Only the newest dictation may watch. Without this, two dictations within the
/// watch window would run two observers, and the older one would compare the
/// field against a stale "what we pasted".
static WATCH_GENERATION: AtomicU64 = AtomicU64::new(0);

/// Emitted when a correction was learned, so the overlay can offer an undo.
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct LearnedCorrection {
    pub pattern: String,
    pub replacement: String,
    /// How many rules this dictation taught. The notice shows the pair when it is
    /// one, and a count when a single message carried several corrections.
    pub count: u32,
}

/// What the last dictation's watch session saw. This is what the settings-page
/// diagnostic reports: the live focused element is useless there, because by the
/// time a button is clicked the focus is on our own window.
#[derive(Default, Clone, serde::Serialize)]
pub struct WatchReport {
    pub bundle_id: Option<String>,
    /// The AX identity of the watched field, when it has a stable one.
    pub field_id: Option<String>,
    pub pasted_chars: usize,
    pub outcome: String,
    pub polls: u32,
    pub readable_polls: u32,
    pub last_field_chars: Option<usize>,
    pub last_field_preview: Option<String>,
    pub candidate: Option<String>,
    /// Which AX read path produced the last readable field (diagnostics).
    pub strategy: Option<String>,
}

/// The last correction we applied, so undo knows exactly what to take back.
#[derive(Default)]
pub struct LearningState {
    applied: Mutex<Vec<AppliedLearning>>,
    last_report: Mutex<Option<WatchReport>>,
}

#[derive(Clone)]
struct AppliedLearning {
    /// The corrected term, added to the dictionary as a recognition hint. Learning
    /// deliberately stops here: turning the edit into a global replacement rule
    /// would also rewrite the same text wherever the user meant it
    /// ("浏览器" → "乒乓球" is right once, wrong the next time).
    word: String,
    pattern: String,
    replacement: String,
}

impl LearningState {
    fn remember(&self, applied: Vec<AppliedLearning>) {
        if let Ok(mut slot) = self.applied.lock() {
            *slot = applied;
        }
    }

    fn set_report(&self, report: WatchReport) {
        if let Ok(mut slot) = self.last_report.lock() {
            *slot = Some(report);
        }
    }

    pub fn report(&self) -> Option<WatchReport> {
        self.last_report.lock().ok().and_then(|slot| slot.clone())
    }

    /// Consumes the pending undo, so a second click cannot remove something else.
    /// Returns every `(word, misheard text)` pair the last session taught.
    pub fn take(&self) -> Vec<(String, String)> {
        self.applied
            .lock()
            .map(|mut slot| std::mem::take(&mut *slot))
            .unwrap_or_default()
            .into_iter()
            .map(|applied| (applied.word, applied.pattern))
            .collect()
    }
}

/// Start watching, if the feature is on and the platform supports it.
pub fn watch_for_edit(pasted_text: &str) {
    let settings = crate::settings::current();
    if !settings.learn_from_edits
        // The capsule is the only surface for the undo affordance.
        || settings.overlay_style == OverlayStyle::None
        || pasted_text.trim().is_empty()
    {
        return;
    }
    if !ax::is_trusted() {
        debug!("Learn-from-edits is on but Accessibility permission is missing");
        return;
    }

    let pasted = pasted_text.to_string();
    // Captured now: if the user switches apps, we stop watching.
    let bundle_id = ax::frontmost_bundle_id();
    let generation = WATCH_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;

    if let Some(state) = crate::learning::learning_state() {
        state.set_report(WatchReport {
            bundle_id: bundle_id.clone(),
            pasted_chars: pasted.chars().count(),
            outcome: "watching".to_string(),
            ..Default::default()
        });
    }

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

                        let (outcome, reason) =
                            attempt_outcome(!applied.is_empty(), found, source, &judgement.reason);
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
}

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

        if self.edited()
            && self
                .last_edit
                .is_some_and(|at| at.elapsed() >= EDIT_DEBOUNCE)
        {
            return (WatchStep::Learn, Some(StopReason::Settled));
        }
        (WatchStep::Continue, None)
    }
}

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

/// The newest non-empty state the field held. When the field clears on send, the
/// last empty state is skipped so the text that was actually sent is recovered.
fn settled_text(observed: &[String]) -> Option<String> {
    observed
        .iter()
        .rev()
        .find(|text| !text.trim().is_empty())
        .cloned()
}

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

/// The AX budget for one read. Chromium answers slowly while it builds its
/// accessibility tree, so this is per-call, not the poll cadence.
const READ_TIMEOUT_MS: u32 = 300;

/// Update the report's field diagnostics from a successful read.
fn record_field(report: &mut WatchReport, field: &ax::FocusedField) {
    report.readable_polls += 1;
    report.last_field_chars = Some(field.text.chars().count());
    report.last_field_preview = Some(field.text.chars().take(160).collect());
    report.strategy = Some(field.strategy.to_string());
    if !field.identity.key.is_empty() {
        report.field_id = Some(field.identity.key.clone());
    }
}

/// Classify a readable field. The field identity is intentionally not compared:
/// Chromium re-renders its contenteditable and the identifier changes while the
/// user is still in the same field, and the whole-box diff already rejects an
/// unrelated final text.
fn field_poll(field: &ax::FocusedField) -> Poll {
    if field.text.trim().is_empty() {
        Poll::Readable(String::new())
    } else {
        Poll::Readable(field.text.clone())
    }
}

/// Wait up to `budget` for key events and report whether a Return keyDown
/// arrived. Drains anything queued behind the first event so a burst of typing
/// cannot hide the Enter.
fn wait_for_enter(listener: Option<&KeyboardListener>, budget: Duration) -> bool {
    let Some(listener) = listener else {
        std::thread::sleep(budget);
        return false;
    };

    let deadline = Instant::now() + budget;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return false;
        }
        match listener.recv_timeout(remaining) {
            Ok(event) => {
                if is_return_keydown(&event) {
                    return true;
                }
                while let Some(queued) = listener.try_recv() {
                    if is_return_keydown(&queued) {
                        return true;
                    }
                }
            }
            Err(_) => return false,
        }
    }
}

fn is_return_keydown(event: &KeyEvent) -> bool {
    event.is_key_down && event.key == Some(Key::Return)
}

/// Drop candidates that are clearly half-finished.
///
/// A replacement ending in whitespace means the user was mid-word when the field
/// was sampled ("Cica " on the way to "Cica Exo"); storing that would teach half a
/// term. Only used for the "prefer a complete one" pass — the fallback keeps them.
fn usable_candidates(candidates: Vec<diff::EditCandidate>) -> Vec<diff::EditCandidate> {
    candidates
        .into_iter()
        .filter(|candidate| !candidate.replacement.ends_with(char::is_whitespace))
        .take(MAX_LEARNED_WORDS)
        .collect()
}

fn describe(candidates: &[diff::EditCandidate]) -> String {
    candidates
        .iter()
        .map(|candidate| format!("{} -> {}", candidate.pattern, candidate.replacement))
        .collect::<Vec<_>>()
        .join(" | ")
}

fn apply(
    candidates: Vec<diff::EditCandidate>,
    frame: Option<(f64, f64, f64, f64)>,
) -> Vec<AppliedLearning> {
    let Some(store) = crate::state::dictionary_store() else {
        return Vec::new();
    };

    let applied = learn(&store, candidates);

    if applied.is_empty() {
        return applied;
    }

    info!(
        "Learned {} dictionary correction(s) from an edit: {}",
        applied.len(),
        applied
            .iter()
            .map(|entry| format!("{:?} -> {:?}", entry.pattern, entry.replacement))
            .collect::<Vec<_>>()
            .join(", ")
    );

    if let Some(state) = crate::learning::learning_state() {
        state.remember(applied.clone());
    }

    let first = &applied[0];
    let payload = LearnedCorrection {
        pattern: first.pattern.clone(),
        replacement: first.replacement.clone(),
        count: applied.len() as u32,
    };
    // The settings page listens to this and refreshes its lists.
    crate::events::emit("learned-correction", &payload);
    // The shell shows the notice itself (the overlay is shell-owned); it gets
    // the same payload plus the field frame to place it next to.
    crate::events::emit(
        "learned-overlay",
        serde_json::json!({ "notice": payload, "frame": frame }),
    );

    applied
}

/// The `(outcome, reason)` stored for one learning attempt.
///
/// Pure, and the only place the pair is built, so `outcome` and `reason` can
/// never contradict: a row that says `skipped` never claims a word was learned,
/// and a row that says `learned` always names the source.
///
/// * `applied` — at least one candidate was written to the dictionary.
/// * `found` — the active path produced a candidate, whether or not it was
///   written. Separates "no mishearing" from "already known or rejected".
/// * `source` — which path judged the edit.
/// * `local_outcome` — the local gate's own outcome, used when it found nothing.
fn attempt_outcome(
    applied: bool,
    found: bool,
    source: llm::JudgeSource,
    local_outcome: &str,
) -> (String, String) {
    if applied {
        let reason = match source {
            llm::JudgeSource::Llm => "learned from the llm",
            llm::JudgeSource::Local | llm::JudgeSource::None => "learned from the local gate",
        };
        return ("learned".to_string(), reason.to_string());
    }

    let reason = if found {
        // The path saw a mishearing but the store already knew the word, the
        // user rejected this mishearing before, or the store was unavailable.
        "the correction was already known or rejected".to_string()
    } else {
        match source {
            llm::JudgeSource::Llm => "the llm found no mishearing".to_string(),
            llm::JudgeSource::Local | llm::JudgeSource::None => local_outcome.to_string(),
        }
    };
    ("skipped".to_string(), reason)
}

/// The judge source as it is stored in the attempts table.
fn judge_source_str(source: llm::JudgeSource) -> &'static str {
    match source {
        llm::JudgeSource::Llm => "llm",
        llm::JudgeSource::Local => "local",
        llm::JudgeSource::None => "none",
    }
}

/// Serialize what was actually learned as `[{pattern, replacement}]`, or `None`
/// when nothing was added.
fn learned_json(applied: &[AppliedLearning]) -> Option<String> {
    if applied.is_empty() {
        return None;
    }
    let pairs: Vec<serde_json::Value> = applied
        .iter()
        .map(|entry| {
            serde_json::json!({
                "pattern": entry.pattern,
                "replacement": entry.replacement,
            })
        })
        .collect();
    serde_json::to_string(&pairs).ok()
}

/// Persist one learning attempt. Best-effort: a write failure is logged and
/// never interrupts the watch.
#[allow(clippy::too_many_arguments)]
fn record_attempt(
    pasted: &str,
    final_text: &str,
    bundle_id: Option<&str>,
    field_id: Option<&str>,
    source: &str,
    llm_raw: Option<String>,
    outcome: &str,
    reason: &str,
    learned_json: Option<String>,
    strategy: Option<String>,
) {
    let Some(store) = crate::state::dictionary_store() else {
        return;
    };

    let attempt = crate::dictionary::NewLearningAttempt {
        bundle_id: bundle_id.map(str::to_string),
        field_id: field_id.map(str::to_string),
        pasted: pasted.to_string(),
        final_text: final_text.to_string(),
        source: source.to_string(),
        llm_raw,
        outcome: outcome.to_string(),
        reason: reason.to_string(),
        learned_json,
        strategy,
    };

    if let Err(error) = store.add_learning_attempt(&attempt) {
        debug!("Failed to record learning attempt: {error}");
    }
}

/// Store what the edit taught. The corrected term goes in as a dictionary word —
/// a recognition hint — and nothing else: a global replacement rule would also
/// rewrite text the user meant as typed ("浏览器" → "乒乓球" is right once and
/// wrong the next time). Returns only what this run actually added.
fn learn(store: &DictionaryStore, candidates: Vec<diff::EditCandidate>) -> Vec<AppliedLearning> {
    let mut applied = Vec::new();

    for candidate in candidates {
        // On a read error, treat it as "already known" and write nothing.
        if store.has_word(&candidate.replacement).unwrap_or(true) {
            continue;
        }
        if store
            .is_learning_rejected(&candidate.pattern)
            .unwrap_or(true)
        {
            continue;
        }

        let Ok(added) = store.add_word(&candidate.replacement) else {
            continue;
        };

        applied.push(AppliedLearning {
            word: added.word,
            pattern: candidate.pattern,
            replacement: candidate.replacement,
        });
    }

    applied
}

#[cfg(test)]
mod tests {
    use super::*;

    fn states(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    fn store() -> (DictionaryStore, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("temp dir");
        let store =
            DictionaryStore::at_for_tests(dir.path().join("dictionary.db")).expect("open store");
        (store, dir)
    }

    fn edit(pattern: &str, replacement: &str) -> diff::EditCandidate {
        diff::EditCandidate {
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
        }
    }

    #[test]
    fn learning_adds_the_word_and_never_a_replacement_rule() {
        // The user corrected "浏览器" to "乒乓球". The word is worth knowing; a
        // global rule would rewrite every future "浏览器" the user really meant.
        let (store, _dir) = store();

        let applied = learn(&store, vec![edit("浏览器", "乒乓球")]);

        assert_eq!(applied.len(), 1);
        assert_eq!(applied[0].word, "乒乓球");
        assert_eq!(store.list_words().unwrap().len(), 1);
        assert!(
            store.list_rules().unwrap().is_empty(),
            "learning must not create replacement rules"
        );
    }

    #[test]
    fn learning_skips_words_that_are_already_known() {
        let (store, _dir) = store();
        store.add_word("Hydra Facial").unwrap();

        let applied = learn(&store, vec![edit("hydro fish", "Hydra Facial")]);

        assert!(applied.is_empty());
        assert_eq!(store.list_words().unwrap().len(), 1);
    }

    #[test]
    fn learning_skips_a_rejected_mishearing_only() {
        let (store, _dir) = store();
        store.remember_learning_rejection("浏览器").unwrap();

        // The undone mishearing stays undone...
        assert!(learn(&store, vec![edit("浏览器", "乒乓球")]).is_empty());
        assert!(store.list_words().unwrap().is_empty());

        // ...but the same word taught by a different mishearing still gets in.
        let applied = learn(&store, vec![edit("乒乓求", "乒乓球")]);
        assert_eq!(applied.len(), 1);
        assert_eq!(store.list_words().unwrap()[0].word, "乒乓球");
    }

    /// The `MAX_LEARNED_WORDS` cap lives in `usable_candidates()`; `learn()`
    /// stores whatever the decision handed it.
    #[test]
    fn learning_adds_every_candidate_it_is_given() {
        let (store, _dir) = store();
        let candidates = (0..MAX_LEARNED_WORDS + 3)
            .map(|index| edit("wrong", &format!("word {index}")))
            .collect::<Vec<_>>();

        let applied = learn(&store, candidates);

        assert_eq!(applied.len(), MAX_LEARNED_WORDS + 3);
    }

    #[test]
    fn learned_json_is_none_until_something_was_added() {
        assert_eq!(learned_json(&[]), None);

        let applied = vec![AppliedLearning {
            word: "Cica Exo".to_string(),
            pattern: "C3XO".to_string(),
            replacement: "Cica Exo".to_string(),
        }];
        let json = learned_json(&applied).expect("non-empty applied serializes");
        assert!(json.contains("\"pattern\":\"C3XO\""), "{json}");
        assert!(json.contains("\"replacement\":\"Cica Exo\""), "{json}");
    }

    #[test]
    fn judge_source_strings_match_the_stored_values() {
        assert_eq!(judge_source_str(llm::JudgeSource::Llm), "llm");
        assert_eq!(judge_source_str(llm::JudgeSource::Local), "local");
        assert_eq!(judge_source_str(llm::JudgeSource::None), "none");
    }

    #[test]
    fn attempt_outcome_pairs_the_outcome_with_a_matching_reason() {
        // Applied: the reason names the source that produced the candidates.
        assert_eq!(
            attempt_outcome(true, true, llm::JudgeSource::Llm, "ignored"),
            ("learned".to_string(), "learned from the llm".to_string())
        );
        assert_eq!(
            attempt_outcome(true, true, llm::JudgeSource::Local, "ignored"),
            (
                "learned".to_string(),
                "learned from the local gate".to_string()
            )
        );

        // The LLM ran but produced nothing usable (or every candidate was
        // filtered as half-typed): skipped with a no-mishearing reason, never
        // "learned from the llm".
        assert_eq!(
            attempt_outcome(false, false, llm::JudgeSource::Llm, "ignored"),
            (
                "skipped".to_string(),
                "the llm found no mishearing".to_string()
            )
        );

        // The local gate found nothing: the reason is the gate's own outcome.
        assert_eq!(
            attempt_outcome(
                false,
                false,
                llm::JudgeSource::Local,
                "the enter key was pressed"
            ),
            (
                "skipped".to_string(),
                "the enter key was pressed".to_string()
            )
        );

        // A candidate was found but not written: the row must not claim it
        // learned anything, even though `decide` reported a candidate.
        assert_eq!(
            attempt_outcome(
                false,
                true,
                llm::JudgeSource::Local,
                "learned (decided from the captured states)"
            ),
            (
                "skipped".to_string(),
                "the correction was already known or rejected".to_string()
            )
        );
    }

    #[test]
    fn attempt_outcome_is_never_self_contradictory() {
        for source in [
            llm::JudgeSource::Llm,
            llm::JudgeSource::Local,
            llm::JudgeSource::None,
        ] {
            for applied in [true, false] {
                for found in [true, false] {
                    let (outcome, reason) =
                        attempt_outcome(applied, found, source, "the local outcome");
                    assert_eq!(outcome == "learned", applied, "{source:?}");
                    if !applied {
                        assert!(
                            !reason.contains("learned"),
                            "a skipped row must not claim learning: {reason:?}"
                        );
                    }
                }
            }
        }
    }

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

    /// Recorded evidence for the dual-tap assumption in `observe`: a second
    /// `CGEventTap` (a `KeyboardListener`) can be created and used while the
    /// app's blocking `HotkeyManager` is alive, and still receives Return.
    ///
    /// Ignored by default: it needs Accessibility permission and a real
    /// synthesized key event, which a headless/CI run cannot provide.
    ///
    /// Manual procedure:
    /// 1. Grant the test binary Accessibility permission.
    /// 2. `cargo test -p talkwtf-core --lib -- --ignored dual_tap`
    /// 3. While both are alive, post a Return keyDown with
    ///    `CGEventCreateKeyboardEvent(None, 36, true)` + `CGEventPost`, and
    ///    confirm the listener's `recv_timeout` yields `Key::Return` (the
    ///    manager, which registered no hotkey for it, must not swallow it).
    #[test]
    #[ignore = "needs Accessibility permission and a synthesized Return CGEvent"]
    fn dual_tap_hotkey_manager_and_listener_coexist() {
        use handy_keys::HotkeyManager;

        let manager = HotkeyManager::new_with_blocking().expect("blocking hotkey manager");
        let listener = KeyboardListener::new().expect("second keyboard listener");

        assert!(manager.try_recv().is_none());

        drop(listener);
        drop(manager);
    }
}
