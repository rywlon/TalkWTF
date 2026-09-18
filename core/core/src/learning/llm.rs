//! Ask the configured provider which corrections in an edit were mishearings.

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

/// Ask the active provider what the user misheard, returning the parsed
/// candidates alongside the raw answer. `None` means the LLM is unavailable or
/// failed, so the caller falls back to the local diff. `Some` with an empty
/// vector means the LLM ran and found nothing worth learning — trust it.
pub fn detect_corrections(pasted: &str, final_text: &str) -> Option<(Vec<EditCandidate>, String)> {
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

/// Decide what (if anything) the edit taught, preferring the LLM and falling
/// back to the local gate. Always returns a human-readable reason.
pub fn judge(pasted: &str, final_text: &str) -> Judgement {
    judge_from(pasted, final_text, detect_corrections(pasted, final_text))
}

/// The decision with the LLM result supplied, so the fallback logic is testable
/// without reading settings or making a request.
fn judge_from(
    pasted: &str,
    final_text: &str,
    llm: Option<(Vec<EditCandidate>, String)>,
) -> Judgement {
    match llm {
        Some((candidates, raw)) => {
            let usable = candidates;
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

#[cfg(test)]
mod tests {
    use super::*;

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
    fn judge_falls_back_to_local_and_records_the_source() {
        // The LLM result is supplied as `None` directly: no request is made and
        // the local diff gate decides.
        let judgement = judge_from("他想做 C3XO，可以吗？", "他想做 Cica Exo，可以吗？", None);
        assert_eq!(judgement.source, JudgeSource::Local);
        assert_eq!(judgement.candidates.len(), 1);
        assert!(!judgement.reason.is_empty());
    }

    #[test]
    fn judge_trusts_an_empty_llm_answer_over_the_local_gate() {
        // The LLM ran and found nothing. Even though the local diff would see the
        // "C3XO" -> "Cica Exo" edit, the empty LLM answer wins: source stays Llm,
        // candidates stay empty, and the reason records the empty answer.
        let judgement = judge_from(
            "他想做 C3XO，可以吗？",
            "他想做 Cica Exo，可以吗？",
            Some((Vec::new(), "raw".to_string())),
        );

        assert_eq!(judgement.source, JudgeSource::Llm);
        assert!(judgement.candidates.is_empty());
        assert_eq!(judgement.reason, "the llm found no mishearing");
        assert_eq!(judgement.llm_raw.as_deref(), Some("raw"));
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
