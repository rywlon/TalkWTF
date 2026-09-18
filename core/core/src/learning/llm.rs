//! Ask the configured provider which corrections in an edit were mishearings.

use log::debug;

use super::diff::EditCandidate;
use crate::settings::{AppSettings, APPLE_INTELLIGENCE_PROVIDER_ID};

/// Most corrections one dictation may teach.
const MAX_CORRECTIONS: usize = 5;
/// Longest pattern / replacement we accept from the model.
const MAX_FIELD_CHARS: usize = 40;

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
