//! Watch the field we just pasted into, and learn a dictionary entry from the
//! correction the user makes.
//!
//! Everything here is best-effort: unreadable fields, a switched app, secure
//! input, or an edit we cannot interpret all end in silence, never in an error.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use log::{debug, info};
use serde::{Deserialize, Serialize};
use specta::Type;

use crate::dictionary::DictionaryStore;
use crate::settings::OverlayStyle;

use super::{ax, diff};

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
    pub pasted_chars: usize,
    pub outcome: String,
    pub polls: u32,
    pub readable_polls: u32,
    pub last_field_chars: Option<usize>,
    pub last_field_preview: Option<String>,
    pub candidate: Option<String>,
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
}

/// The newest state the field held that differs from what we pasted. This is what
/// we compare against when deciding what the edit taught.
fn choose_final(observed: &[String], pasted: &str) -> Option<String> {
    observed
        .iter()
        .rev()
        .find(|text| text.as_str() != pasted)
        .cloned()
}

fn observe(pasted: &str, bundle_id: Option<&str>, generation: u64) -> (Vec<String>, WatchReport) {
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

/// Pick what to learn from every state the field was seen in.
///
/// Scans newest first: the last thing the field held before it was sent is the
/// most complete version of what the user wrote. A state whose replacement looks
/// unfinished is skipped in favour of an earlier, complete one; if nothing is
/// complete, the newest usable candidate is still better than nothing.
fn decide(observed: &[String], pasted: &str, report: &mut WatchReport) -> Vec<diff::EditCandidate> {
    let mut fallback: Option<Vec<diff::EditCandidate>> = None;

    for text in observed.iter().rev() {
        if text == pasted {
            continue;
        }

        let candidates = diff::detect_edits(pasted, text);
        if candidates.is_empty() {
            continue;
        }

        let usable = usable_candidates(candidates.clone());
        if !usable.is_empty() {
            report.outcome = "learned (decided from the captured states)".to_string();
            report.candidate = Some(describe(&usable));
            return usable;
        }

        if fallback.is_none() {
            // Last resort: the newest state still beats learning nothing, but trim
            // the half-typed tail so the stored rule is a clean term.
            fallback = Some(
                candidates
                    .into_iter()
                    .map(|mut candidate| {
                        candidate.replacement = candidate.replacement.trim_end().to_string();
                        candidate
                    })
                    .take(MAX_LEARNED_WORDS)
                    .collect(),
            );
        }
    }

    match fallback {
        Some(candidates) => {
            report.outcome = "learned (best of the captured states)".to_string();
            report.candidate = Some(describe(&candidates));
            candidates
        }
        None => Vec::new(),
    }
}

fn describe(candidates: &[diff::EditCandidate]) -> String {
    candidates
        .iter()
        .map(|candidate| format!("{} -> {}", candidate.pattern, candidate.replacement))
        .collect::<Vec<_>>()
        .join(" | ")
}

fn apply(candidates: Vec<diff::EditCandidate>, frame: Option<(f64, f64, f64, f64)>) {
    let Some(store) = crate::state::dictionary_store() else {
        return;
    };

    let applied = learn(&store, candidates);

    if applied.is_empty() {
        return;
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

    /// The `MAX_LEARNED_WORDS` cap lives in `decide()`; `learn()` stores whatever
    /// the decision handed it.
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
    fn learns_when_the_field_was_cleared_by_sending() {
        // The user fixed the term and hit send: the corrected value was only in
        // the field briefly, but it was captured.
        let pasted = "这儿有一个 KOL他想做 C3XO，可以吗？";
        let observed = states(&[
            "这儿有一个 KOL",
            pasted,
            "这儿有一个 KOL他想做 Cica Exo，可以吗？",
        ]);

        let mut report = WatchReport::default();
        let decided = decide(&observed, pasted, &mut report);

        assert_eq!(decided.len(), 1);
        assert_eq!(decided[0].pattern, "C3XO");
        assert_eq!(decided[0].replacement, "Cica Exo");
    }

    #[test]
    fn prefers_a_complete_replacement_over_a_half_typed_one() {
        let pasted = "他想做 C3XO，可以吗？";
        let observed = states(&[
            pasted,
            "他想做 Cica ，可以吗？",
            "他想做 Cica Exo，可以吗？",
        ]);

        let mut report = WatchReport::default();
        let decided = decide(&observed, pasted, &mut report);

        assert_eq!(decided.len(), 1);
        assert_eq!(decided[0].replacement, "Cica Exo");
    }

    #[test]
    fn falls_back_to_the_best_incomplete_state() {
        // Only a half-typed value was ever captured; learning it is still better
        // than learning nothing, and the user can undo it.
        let pasted = "他想做 C3XO，可以吗？";
        let observed = states(&[pasted, "他想做 Cica ，可以吗？"]);

        let mut report = WatchReport::default();
        let decided = decide(&observed, pasted, &mut report);

        assert_eq!(decided.len(), 1);
        assert_eq!(decided[0].replacement, "Cica");
    }

    #[test]
    fn learns_every_correction_in_one_state() {
        let pasted = "这儿有一个QL，他想做C3XO，请问可以吗？";
        let observed = states(&[pasted, "这儿有一个KOL，他想做Cica Exo，请问可以吗？"]);

        let mut report = WatchReport::default();
        let decided = decide(&observed, pasted, &mut report);

        let pairs: Vec<(String, String)> = decided
            .into_iter()
            .map(|candidate| (candidate.pattern, candidate.replacement))
            .collect();

        assert!(
            pairs.contains(&("QL".to_string(), "KOL".to_string())),
            "{pairs:?}"
        );
        assert!(
            pairs.contains(&("C3XO".to_string(), "Cica Exo".to_string())),
            "{pairs:?}"
        );
    }

    #[test]
    fn a_state_with_no_edit_learns_nothing() {
        let pasted = "hello world";
        let observed = states(&["hello", pasted, pasted]);

        let mut report = WatchReport::default();
        assert!(decide(&observed, pasted, &mut report).is_empty());
    }

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
}
