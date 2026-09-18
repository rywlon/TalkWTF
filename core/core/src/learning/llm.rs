//! Ask the configured provider which corrections in an edit were mishearings.
//!
//! The local gate is authoritative: it proposes the candidates and the provider
//! may only ADD to them. A provider that returns nothing — or a weak model that
//! misses a mishearing — can no longer suppress a locally-detected correction.

use log::debug;
use serde::{Deserialize, Serialize};
use specta::Type;

use super::diff::EditCandidate;
use crate::settings::{AppSettings, APPLE_INTELLIGENCE_PROVIDER_ID};

/// Most corrections one dictation may teach.
const MAX_CORRECTIONS: usize = 5;
/// Longest pattern / replacement we accept from the model.
const MAX_FIELD_CHARS: usize = 40;
/// Longest pasted / edited text we send to the provider. Mirrors the local
/// path's `MAX_PASTED_CHARS`, so a pathological dictation cannot balloon the
/// request (or leak an unbounded field read) to a third party.
const MAX_INPUT_CHARS: usize = 600;

/// Ask the active provider which terms it thinks were misheard, returning the
/// parsed candidates alongside the raw answer. `None` means the provider is
/// unavailable or failed. The caller only ADDS these to the local gate's list.
fn detect_corrections(pasted: &str, final_text: &str) -> Option<(Vec<EditCandidate>, String)> {
    if pasted.chars().count() > MAX_INPUT_CHARS || final_text.chars().count() > MAX_INPUT_CHARS {
        return None;
    }

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

    let completion =
        crate::dictation::block_on(crate::llm_client::send_chat_completion_with_schema(
            &provider,
            api_key,
            &model,
            user,
            Some(system.to_string()),
            json_schema,
            true,
        ));

    match completion {
        Ok(Some(completion)) => parse_corrections(&completion.content)
            .map(|candidates| (candidates, completion.content)),
        Ok(None) => None,
        Err(error) => {
            debug!("Edit-learning LLM request failed: {error}");
            None
        }
    }
}

/// Where a judgement came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
pub enum JudgeSource {
    Llm,
    Local,
    None,
}

/// What the edit taught, and how we know.
#[derive(Debug, Clone)]
pub struct Judgement {
    pub candidates: Vec<EditCandidate>,
    pub source: JudgeSource,
    pub llm_raw: Option<String>,
    pub reason: String,
}

/// The mishearing candidates the local gate can justify on its own. This is the
/// recall floor: the provider can only add to it, never remove from it.
fn local_candidates(pasted: &str, final_text: &str) -> Vec<EditCandidate> {
    super::diff::detect_edits(pasted, final_text)
        .into_iter()
        .filter(|candidate| {
            super::diff::is_likely_mishearing(&candidate.pattern, &candidate.replacement)
        })
        .collect()
}

/// Decide what (if anything) the edit taught. The local gate proposes the
/// candidates; the configured provider may add more (it is asked only when the
/// local gate found something). Without a provider, the local candidates stand.
pub fn judge(pasted: &str, final_text: &str) -> Judgement {
    let local = local_candidates(pasted, final_text);
    let llm = if local.is_empty() {
        None
    } else {
        detect_corrections(pasted, final_text)
    };
    judge_from(local, llm)
}

/// The decision with the local candidates and provider result supplied, so the
/// logic is testable without reading settings or making a request.
fn judge_from(local: Vec<EditCandidate>, llm: Option<(Vec<EditCandidate>, String)>) -> Judgement {
    if local.is_empty() {
        return Judgement {
            candidates: Vec::new(),
            source: JudgeSource::Local,
            llm_raw: None,
            reason: "the local gate found no mishearing".to_string(),
        };
    }

    let mut candidates = local;
    let mut llm_raw = None;
    let mut from_llm = false;

    if let Some((extra, raw)) = llm {
        llm_raw = Some(raw);
        for candidate in extra {
            if !is_valid(&candidate.pattern, &candidate.replacement) {
                continue;
            }
            let already = candidates.iter().any(|existing| {
                existing.pattern == candidate.pattern
                    && existing.replacement == candidate.replacement
            });
            if !already {
                candidates.push(candidate);
                from_llm = true;
            }
        }
    }

    let source = if from_llm {
        JudgeSource::Llm
    } else {
        JudgeSource::Local
    };
    let reason = if from_llm {
        "learned from the llm"
    } else {
        "learned from the local gate"
    };

    Judgement {
        candidates,
        source,
        llm_raw,
        reason: reason.to_string(),
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
    if provider.requires_api_key && api_key.trim().is_empty() {
        return None;
    }

    Some((provider, model, api_key))
}

/// Parse the model's answer. Accepts the structured object or a bare array, so a
/// provider that ignored the schema still works. `None` means the answer was
/// unusable.
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The decision from raw texts, computing the local candidates the way
    /// `judge` does. Keeps the tests reading like the public entry point.
    fn judge_from_text(
        pasted: &str,
        final_text: &str,
        llm: Option<(Vec<EditCandidate>, String)>,
    ) -> Judgement {
        judge_from(local_candidates(pasted, final_text), llm)
    }

    #[test]
    fn parses_a_structured_answer() {
        let parsed =
            parse_corrections(r#"{"corrections":[{"pattern":"C3XO","replacement":"Cica Exo"}]}"#);

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
    fn a_provider_that_needs_a_key_without_one_is_none() {
        let mut settings = AppSettings::default();
        settings.post_process_provider_id = "deepseek".to_string();
        settings
            .post_process_models
            .insert("deepseek".to_string(), "deepseek-chat".to_string());
        settings
            .post_process_api_keys
            .insert("deepseek".to_string(), String::new());

        assert!(provider_config(&settings).is_none());
    }

    #[test]
    fn a_configured_provider_is_some() {
        let mut settings = AppSettings::default();
        settings.post_process_provider_id = "deepseek".to_string();
        settings
            .post_process_models
            .insert("deepseek".to_string(), "deepseek-chat".to_string());
        settings
            .post_process_api_keys
            .insert("deepseek".to_string(), "sk-test".to_string());

        let (provider, model, api_key) =
            provider_config(&settings).expect("configured provider should be usable");
        assert_eq!(provider.id, "deepseek");
        assert_eq!(model, "deepseek-chat");
        assert_eq!(api_key, "sk-test");
    }

    #[test]
    fn judge_learns_from_the_local_gate_without_a_provider() {
        // No provider result: the local gate's candidate still teaches the word,
        // so a weak model can never suppress a real mishearing.
        let judgement = judge_from_text("他想做 C3XO，可以吗？", "他想做 Cica Exo，可以吗？", None);

        assert_eq!(judgement.source, JudgeSource::Local);
        assert_eq!(judgement.candidates.len(), 1);
        assert_eq!(judgement.reason, "learned from the local gate");
        assert!(judgement.llm_raw.is_none());
    }

    #[test]
    fn judge_keeps_the_local_candidate_when_the_llm_returns_nothing() {
        // The weak model answered `{"corrections":[]}`: the local candidate stays.
        let judgement = judge_from_text(
            "他想做 C3XO，可以吗？",
            "他想做 Cica Exo，可以吗？",
            Some((Vec::new(), r#"{"corrections":[]}"#.to_string())),
        );

        assert_eq!(judgement.source, JudgeSource::Local);
        assert_eq!(judgement.candidates.len(), 1);
        assert_eq!(judgement.reason, "learned from the local gate");
        assert_eq!(judgement.llm_raw.as_deref(), Some(r#"{"corrections":[]}"#));
    }

    #[test]
    fn judge_adds_a_candidate_the_llm_found() {
        // The provider adds a correction the local gate's similarity floor missed.
        let extra = vec![EditCandidate {
            pattern: "OpenType 设置".to_string(),
            replacement: "OpenTypeless".to_string(),
        }];
        let judgement = judge_from_text(
            "他想做 C3XO，可以吗？",
            "他想做 Cica Exo，可以吗？",
            Some((extra, "raw".to_string())),
        );

        assert_eq!(judgement.source, JudgeSource::Llm);
        assert_eq!(judgement.candidates.len(), 2);
        assert_eq!(judgement.reason, "learned from the llm");
    }

    #[test]
    fn judge_never_learns_when_the_local_gate_finds_nothing() {
        // No local candidate means no edit worth teaching; the provider is not
        // even consulted, so it cannot hallucinate a correction into an empty diff.
        let judgement = judge_from_text(
            "要喝牛奶",
            "想喝咖啡",
            Some((
                vec![EditCandidate {
                    pattern: "x".to_string(),
                    replacement: "y".to_string(),
                }],
                "raw".to_string(),
            )),
        );

        assert!(judgement.candidates.is_empty());
        assert_eq!(judgement.source, JudgeSource::Local);
        assert!(judgement.llm_raw.is_none());
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
