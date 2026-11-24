//! Dashboard aggregates. Everything here is local: history rows, the dictionary
//! size, and settings. No network, no telemetry.

use serde::Serialize;
use specta::Type;

use crate::history::TokenUsage;
use crate::settings::{self, PasteMethod};

/// Characters a person types per second. Used only for the "time saved"
/// estimate; 2.0 ≈ 120 characters/minute, a deliberately conservative mixed
/// Chinese/English figure.
const TYPING_CHARS_PER_SEC: f64 = 2.0;

#[derive(Debug, Clone, Serialize, Type)]
pub struct TokenUsageSummary {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub total_tokens: u64,
    pub requests: u64,
}

impl From<TokenUsage> for TokenUsageSummary {
    fn from(usage: TokenUsage) -> Self {
        Self {
            prompt_tokens: usage.prompt_tokens,
            completion_tokens: usage.completion_tokens,
            total_tokens: usage.total_tokens,
            requests: usage.requests,
        }
    }
}

#[derive(Debug, Clone, Serialize, Type)]
pub struct DailyCount {
    pub day: String,
    pub count: u64,
}

#[derive(Debug, Clone, Serialize, Type)]
pub struct RecentActivity {
    pub id: i64,
    pub timestamp: i64,
    pub workflow: String,
    pub char_count: i64,
    pub preview: String,
}

#[derive(Debug, Clone, Serialize, Type)]
pub struct TodayStats {
    pub recordings: u64,
    pub translations: u64,
    pub dictation_ms: u64,
    pub chars: u64,
}

#[derive(Debug, Clone, Serialize, Type)]
pub struct ServiceStatus {
    /// Display name of the selected speech-recognition model.
    pub asr_model: String,
    /// A model is selected and known (downloaded).
    pub asr_ready: bool,
    pub llm_provider: Option<String>,
    pub llm_model: Option<String>,
    /// Provider + model (+ key when required) are all configured.
    pub polish_ready: bool,
    /// Paste method is not "none".
    pub paste_enabled: bool,
}

#[derive(Debug, Clone, Serialize, Type)]
pub struct PersonalizationItem {
    pub id: String,
    pub done: bool,
}

#[derive(Debug, Clone, Serialize, Type)]
pub struct Personalization {
    /// 0–100 completion score.
    pub score: u32,
    pub items: Vec<PersonalizationItem>,
}

#[derive(Debug, Clone, Serialize, Type)]
pub struct DashboardStats {
    pub total_recordings: u64,
    pub total_dictation_ms: u64,
    pub total_chars: u64,
    pub avg_chars_per_min: f64,
    /// Estimated typing time saved, clamped at zero.
    pub time_saved_ms: u64,
    pub translation_count: u64,
    pub today: TodayStats,
    pub recent: Vec<RecentActivity>,
    pub weekly: Vec<DailyCount>,
    pub services: ServiceStatus,
    pub personalization: Personalization,
    pub tokens_today: TokenUsageSummary,
    pub tokens_week: TokenUsageSummary,
}

/// Estimated typing time minus the time actually spent dictating, in ms.
fn time_saved_ms(total_chars: u64, dictation_ms: u64) -> u64 {
    let typing_ms = (total_chars as f64 / TYPING_CHARS_PER_SEC * 1000.0).round() as u64;
    typing_ms.saturating_sub(dictation_ms)
}

/// Speaking speed in characters per minute of recording.
fn avg_chars_per_min(total_chars: u64, dictation_ms: u64) -> f64 {
    if dictation_ms == 0 {
        0.0
    } else {
        total_chars as f64 / (dictation_ms as f64 / 60_000.0)
    }
}

/// Inputs to the personalization score. Weighted so the total is exactly 100.
struct PersonalizationInputs {
    dictionary_words: usize,
    custom_scenes: usize,
    translation_targets: usize,
    learn_from_edits: bool,
    polish_ready: bool,
    style_or_scene: bool,
    filler_removal: bool,
    custom_filler_words: bool,
}

fn personalization_score(input: &PersonalizationInputs) -> Personalization {
    let items = vec![
        PersonalizationItem {
            id: "dictionary".to_string(),
            done: input.dictionary_words > 0,
        },
        PersonalizationItem {
            id: "scenes".to_string(),
            done: input.custom_scenes > 0,
        },
        PersonalizationItem {
            id: "translation".to_string(),
            done: input.translation_targets > 0,
        },
        PersonalizationItem {
            id: "learning".to_string(),
            done: input.learn_from_edits,
        },
        PersonalizationItem {
            id: "polish".to_string(),
            done: input.polish_ready,
        },
        PersonalizationItem {
            id: "style".to_string(),
            done: input.style_or_scene,
        },
        PersonalizationItem {
            id: "filler".to_string(),
            done: input.filler_removal,
        },
        PersonalizationItem {
            id: "custom_filler".to_string(),
            done: input.custom_filler_words,
        },
    ];

    let score = items
        .iter()
        .map(|item| match item.id.as_str() {
            "dictionary" => 20,
            "scenes" => 15,
            "translation" => 15,
            "learning" => 15,
            "polish" => 15,
            "style" => 10,
            "filler" => 5,
            "custom_filler" => 5,
            _ => 0,
        })
        .zip(items.iter())
        .filter(|(_, item)| item.done)
        .map(|(weight, _)| weight)
        .sum();

    Personalization { score, items }
}

/// All dashboard aggregates. No shell needed: the managers come from
/// [`crate::state`].
pub fn get_dashboard_stats() -> Result<DashboardStats, String> {
    let settings = crate::settings::current();

    let snapshot = match crate::state::history_manager() {
        Some(history) => history
            .stats_snapshot()
            .map_err(|e| format!("Failed to read history stats: {e}"))?,
        None => Default::default(),
    };

    // Speech recognition service.
    let model_manager = crate::state::model_manager();
    let asr_info =
        model_manager.and_then(|manager| manager.get_model_info(&settings.selected_model));
    let asr_model = asr_info
        .as_ref()
        .map(|info| info.name.clone())
        .unwrap_or_else(|| settings.selected_model.clone());
    let asr_ready = asr_info.is_some();

    // LLM service.
    let provider = settings.active_post_process_provider();
    let llm_provider = provider.map(|provider| provider.label.clone());
    let llm_model = provider.and_then(|provider| {
        settings
            .post_process_models
            .get(&provider.id)
            .filter(|model| !model.trim().is_empty())
            .cloned()
    });
    let polish_ready = provider.is_some_and(|provider| {
        let model_ok = settings
            .post_process_models
            .get(&provider.id)
            .is_some_and(|model| !model.trim().is_empty());
        let key_ok = !provider.requires_api_key
            || settings
                .post_process_api_keys
                .get(&provider.id)
                .is_some_and(|key| !key.trim().is_empty());
        model_ok && key_ok
    });

    let paste_enabled = settings.paste_method != PasteMethod::None;

    // Personalization inputs.
    let dictionary_words = crate::state::dictionary_store()
        .and_then(|store| store.snapshot().ok())
        .map(|snapshot| snapshot.words.len())
        .unwrap_or(0);
    let custom_scenes = settings
        .scenes
        .iter()
        .filter(|scene| !settings::is_built_in_scene(scene))
        .count();
    let style_or_scene = settings.active_scene_id.is_some()
        || settings.polish_style != settings::default_polish_style();
    let custom_filler_words = settings
        .custom_filler_words
        .as_ref()
        .is_some_and(|words| !words.is_empty());

    let personalization = personalization_score(&PersonalizationInputs {
        dictionary_words,
        custom_scenes,
        translation_targets: settings.translation_targets.len(),
        learn_from_edits: settings.learn_from_edits,
        polish_ready,
        style_or_scene,
        filler_removal: settings.filler_word_removal_enabled,
        custom_filler_words,
    });

    Ok(DashboardStats {
        total_recordings: snapshot.total_recordings,
        total_dictation_ms: snapshot.total_dictation_ms,
        total_chars: snapshot.total_chars,
        avg_chars_per_min: avg_chars_per_min(snapshot.total_chars, snapshot.total_dictation_ms),
        time_saved_ms: time_saved_ms(snapshot.total_chars, snapshot.total_dictation_ms),
        translation_count: snapshot.translation_count,
        today: TodayStats {
            recordings: snapshot.today_recordings,
            translations: snapshot.today_translations,
            dictation_ms: snapshot.today_dictation_ms,
            chars: snapshot.today_chars,
        },
        recent: snapshot
            .recent
            .into_iter()
            .map(|activity| RecentActivity {
                id: activity.id,
                timestamp: activity.timestamp,
                workflow: activity.workflow,
                char_count: activity.char_count,
                preview: activity.preview,
            })
            .collect(),
        weekly: snapshot
            .weekly
            .into_iter()
            .map(|day| DailyCount {
                day: day.day,
                count: day.count,
            })
            .collect(),
        services: ServiceStatus {
            asr_model,
            asr_ready,
            llm_provider,
            llm_model,
            polish_ready,
            paste_enabled,
        },
        personalization,
        tokens_today: snapshot.tokens_today.into(),
        tokens_week: snapshot.tokens_week.into(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_saved_is_typing_time_minus_dictation_and_clamps_at_zero() {
        // 600 chars at 2/s = 300s typing; 60s of dictation → 240s saved.
        assert_eq!(time_saved_ms(600, 60_000), 240_000);
        // Speaking slower than typing is never a negative saving.
        assert_eq!(time_saved_ms(10, 600_000), 0);
        assert_eq!(time_saved_ms(0, 0), 0);
    }

    #[test]
    fn avg_chars_per_min_handles_zero_duration() {
        assert_eq!(avg_chars_per_min(0, 0), 0.0);
        assert_eq!(avg_chars_per_min(300, 60_000), 300.0);
        assert_eq!(avg_chars_per_min(150, 30_000), 300.0);
    }

    #[test]
    fn personalization_score_is_zero_when_nothing_is_configured() {
        let result = personalization_score(&PersonalizationInputs {
            dictionary_words: 0,
            custom_scenes: 0,
            translation_targets: 0,
            learn_from_edits: false,
            polish_ready: false,
            style_or_scene: false,
            filler_removal: false,
            custom_filler_words: false,
        });
        assert_eq!(result.score, 0);
        assert!(result.items.iter().all(|item| !item.done));
    }

    #[test]
    fn personalization_score_sums_to_100_when_everything_is_configured() {
        let result = personalization_score(&PersonalizationInputs {
            dictionary_words: 5,
            custom_scenes: 2,
            translation_targets: 1,
            learn_from_edits: true,
            polish_ready: true,
            style_or_scene: true,
            filler_removal: true,
            custom_filler_words: true,
        });
        assert_eq!(result.score, 100);
        assert!(result.items.iter().all(|item| item.done));
    }

    #[test]
    fn personalization_score_weights_individual_items() {
        let result = personalization_score(&PersonalizationInputs {
            dictionary_words: 3,
            custom_scenes: 0,
            translation_targets: 0,
            learn_from_edits: false,
            polish_ready: true,
            style_or_scene: false,
            filler_removal: true,
            custom_filler_words: false,
        });
        // dictionary 20 + polish 15 + filler 5
        assert_eq!(result.score, 40);
    }
}
