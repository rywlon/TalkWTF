//! Import/export of the polish configuration: the custom scenes plus the active
//! scene and global style.
//!
//! Mirrors the dictionary's path-based commands — the frontend shows the native
//! dialog, Rust does the file IO. Import is a merge: it never overwrites local
//! scenes, and it never lets a file dictate local ids.

use crate::settings::{self, Scene, SCENES_MAX_COUNT};
use serde::{Deserialize, Serialize};
use specta::Type;
use tauri::AppHandle;

pub const POLISH_PROFILE_FORMAT: &str = "talkwtf_polish_profile";
pub const POLISH_PROFILE_FORMAT_VERSION: u32 = 1;

/// A scene as it appears in the file. `id` is written for readability and ignored
/// on import — imported scenes always get fresh local ids.
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct PolishProfileScene {
    #[serde(default)]
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub prompt: String,
}

/// What an exported file looks like. `format`/`version` are optional on read so a
/// hand-written file still imports, but they are always written.
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct PolishProfileFile {
    #[serde(default)]
    pub format: Option<String>,
    #[serde(default)]
    pub version: Option<u32>,
    #[serde(default, alias = "polishStyle")]
    pub polish_style: String,
    #[serde(default, alias = "activeSceneId")]
    pub active_scene_id: Option<String>,
    #[serde(default)]
    pub scenes: Vec<PolishProfileScene>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct PolishProfileImportReport {
    pub accepted: u32,
    pub skipped_duplicates: u32,
    pub skipped_invalid: u32,
}

#[tauri::command]
#[specta::specta]
pub fn export_polish_profile(app: AppHandle, path: String) -> Result<(), String> {
    let settings = settings::get_settings(&app);

    // Only the user's own scenes: shipping the built-ins would turn them into
    // custom copies on the next import.
    let scenes: Vec<_> = settings
        .scenes
        .iter()
        .filter(|scene| !settings::is_built_in_scene(scene))
        .map(|scene| {
            serde_json::json!({
                "id": scene.id,
                "name": scene.name,
                "description": scene.description,
                "prompt": scene.prompt,
            })
        })
        .collect();

    let file = serde_json::json!({
        "format": POLISH_PROFILE_FORMAT,
        "version": POLISH_PROFILE_FORMAT_VERSION,
        "polishStyle": settings.polish_style,
        "activeSceneId": settings.active_scene_id,
        "scenes": scenes,
    });

    let contents = serde_json::to_string_pretty(&file)
        .map_err(|error| format!("Failed to serialize the polish profile: {error}"))?;
    std::fs::write(&path, contents).map_err(|error| format!("Failed to write {path}: {error}"))
}

#[tauri::command]
#[specta::specta]
pub fn import_polish_profile(
    app: AppHandle,
    path: String,
) -> Result<PolishProfileImportReport, String> {
    let contents = std::fs::read_to_string(&path)
        .map_err(|error| format!("Failed to read {path}: {error}"))?;
    let file = parse_polish_profile(&contents)?;

    let mut settings = settings::get_settings(&app);
    let merged = merge_polish_profile(
        &settings.scenes,
        &settings.polish_style,
        settings.active_scene_id.as_deref(),
        file,
    );

    settings.scenes = merged.scenes;
    if let Some(style) = merged.adopted_polish_style {
        settings.polish_style = style;
    }
    if let Some(scene_id) = merged.adopted_active_scene_id {
        settings.active_scene_id = Some(scene_id);
    }
    settings::write_settings(&app, settings);

    Ok(merged.report)
}

fn parse_polish_profile(contents: &str) -> Result<PolishProfileFile, String> {
    let file: PolishProfileFile = serde_json::from_str(contents)
        .map_err(|error| format!("That file is not a polish profile: {error}"))?;

    if let Some(format) = file.format.as_deref() {
        if format != POLISH_PROFILE_FORMAT {
            return Err(format!("Unsupported polish profile format {format}"));
        }
    }
    if let Some(version) = file.version {
        if version != POLISH_PROFILE_FORMAT_VERSION {
            return Err(format!("Unsupported polish profile version {version}"));
        }
    }

    Ok(file)
}

/// What a merge decided, so the caller only writes settings once.
struct MergedProfile {
    scenes: Vec<Scene>,
    adopted_polish_style: Option<String>,
    adopted_active_scene_id: Option<String>,
    report: PolishProfileImportReport,
}

/// Merge a parsed file into the local scenes.
///
/// Duplicates and invalid rows are counted, never fatal, so a partly-bad file
/// still imports what it can. The style and the active scene are adopted only
/// when the local settings have no choice of their own: restoring a backup on a
/// fresh install brings everything back, while importing on a configured install
/// never silently changes what the user picked.
fn merge_polish_profile(
    existing: &[Scene],
    local_polish_style: &str,
    local_active_scene_id: Option<&str>,
    file: PolishProfileFile,
) -> MergedProfile {
    let mut report = PolishProfileImportReport {
        accepted: 0,
        skipped_duplicates: 0,
        skipped_invalid: 0,
    };

    // The file's active scene has to be matched by name: its ids are not ours.
    let file_active_name = file.active_scene_id.as_deref().and_then(|active| {
        file.scenes
            .iter()
            .find(|scene| scene.id == active)
            .map(|scene| scene.name.trim().to_lowercase())
    });
    let file_style = file.polish_style.clone();

    let mut scenes = existing.to_vec();
    let mut imported_names: Vec<(String, String)> = Vec::new(); // (name, new id)

    for entry in file.scenes {
        let Ok((name, description, prompt)) =
            settings::prepare_scene_input(&entry.name, &entry.description, &entry.prompt)
        else {
            report.skipped_invalid += 1;
            continue;
        };

        let identity = name.to_lowercase();
        if scenes
            .iter()
            .any(|scene| scene.name.trim().to_lowercase() == identity)
        {
            report.skipped_duplicates += 1;
            continue;
        }

        if scenes.len() >= SCENES_MAX_COUNT {
            report.skipped_invalid += 1;
            continue;
        }

        let now = chrono::Utc::now().to_rfc3339();
        let scene = Scene {
            id: fresh_scene_id(&scenes),
            name: name.clone(),
            description,
            prompt,
            created_at: now.clone(),
            updated_at: now,
        };
        imported_names.push((name, scene.id.clone()));
        scenes.push(scene);
        report.accepted += 1;
    }

    let adopted_polish_style = if local_polish_style == settings::default_polish_style()
        && settings::is_known_polish_style(&file_style)
    {
        Some(file_style)
    } else {
        None
    };

    let adopted_active_scene_id = if local_active_scene_id.is_none() {
        file_active_name.and_then(|wanted| {
            imported_names
                .iter()
                .find(|(name, _)| name.trim().to_lowercase() == wanted)
                .map(|(_, id)| id.clone())
        })
    } else {
        None
    };

    MergedProfile {
        scenes,
        adopted_polish_style,
        adopted_active_scene_id,
        report,
    }
}

/// A local id for an imported scene, following the same scheme as `add_scene`.
fn fresh_scene_id(existing: &[Scene]) -> String {
    let base = chrono::Utc::now().timestamp_millis();
    let mut suffix = 0;

    loop {
        let id = if suffix == 0 {
            format!("scene_{base}")
        } else {
            format!("scene_{base}_{suffix}")
        };
        if !existing.iter().any(|scene| scene.id == id) {
            return id;
        }
        suffix += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scene(id: &str, name: &str, prompt: &str) -> Scene {
        Scene {
            id: id.to_string(),
            name: name.to_string(),
            description: String::new(),
            prompt: prompt.to_string(),
            created_at: String::new(),
            updated_at: String::new(),
        }
    }

    fn file(
        scenes: Vec<PolishProfileScene>,
        style: &str,
        active: Option<&str>,
    ) -> PolishProfileFile {
        PolishProfileFile {
            format: Some(POLISH_PROFILE_FORMAT.to_string()),
            version: Some(POLISH_PROFILE_FORMAT_VERSION),
            polish_style: style.to_string(),
            active_scene_id: active.map(|id| id.to_string()),
            scenes,
        }
    }

    fn entry(id: &str, name: &str, prompt: &str) -> PolishProfileScene {
        PolishProfileScene {
            id: id.to_string(),
            name: name.to_string(),
            description: String::new(),
            prompt: prompt.to_string(),
        }
    }

    #[test]
    fn imports_scenes_with_fresh_ids_and_adopts_an_empty_install() {
        let file = file(
            vec![
                entry("scene_1", "邮件", "写邮件"),
                entry("scene_2", "笔记", "写笔记"),
            ],
            "structured",
            Some("scene_1"),
        );

        let merged = merge_polish_profile(&[], &settings::default_polish_style(), None, file);

        assert_eq!(merged.report.accepted, 2);
        assert_eq!(merged.scenes.len(), 2);
        assert!(merged.scenes.iter().all(|scene| scene.id != "scene_1"));
        // The file's active scene is followed by name, onto the fresh id.
        assert_eq!(
            merged.adopted_active_scene_id.as_deref(),
            Some(merged.scenes[0].id.as_str())
        );
        assert_eq!(merged.adopted_polish_style.as_deref(), Some("structured"));
    }

    #[test]
    fn skips_scenes_that_already_exist_by_name() {
        let existing = vec![scene("scene_local", "邮件", "本地版本")];
        let file = file(
            vec![
                entry("scene_1", " 邮件 ", "导入版本"),
                entry("scene_2", "笔记", "写笔记"),
            ],
            "clean",
            None,
        );

        let merged = merge_polish_profile(&existing, &settings::default_polish_style(), None, file);

        assert_eq!(merged.report.accepted, 1);
        assert_eq!(merged.report.skipped_duplicates, 1);
        // The local scene wins: its prompt is untouched.
        assert_eq!(merged.scenes[0].prompt, "本地版本");
    }

    #[test]
    fn counts_invalid_rows_instead_of_failing() {
        let file = file(
            vec![
                entry("scene_1", "", "没有名字"),
                entry("scene_2", "笔记", ""),
            ],
            "clean",
            None,
        );

        let merged = merge_polish_profile(&[], &settings::default_polish_style(), None, file);

        assert_eq!(merged.report.accepted, 0);
        assert_eq!(merged.report.skipped_invalid, 2);
        assert!(merged.scenes.is_empty());
    }

    #[test]
    fn never_overrides_a_style_or_active_scene_the_user_already_chose() {
        let existing = vec![scene("scene_local", "邮件", "本地版本")];
        let file = file(
            vec![entry("scene_1", "笔记", "写笔记")],
            "professional",
            Some("scene_1"),
        );

        let merged = merge_polish_profile(&existing, "minimal", Some("scene_local"), file);

        assert_eq!(merged.report.accepted, 1);
        assert_eq!(merged.adopted_polish_style, None);
        assert_eq!(merged.adopted_active_scene_id, None);
    }

    #[test]
    fn rejects_a_foreign_format_or_version() {
        let mut wrong_format = file(vec![], "clean", None);
        wrong_format.format = Some("something_else".to_string());
        assert!(parse_polish_profile(&serde_json::to_string(&wrong_format).unwrap()).is_err());

        let mut wrong_version = file(vec![], "clean", None);
        wrong_version.version = Some(POLISH_PROFILE_FORMAT_VERSION + 1);
        assert!(parse_polish_profile(&serde_json::to_string(&wrong_version).unwrap()).is_err());

        let plain = file(vec![entry("scene_1", "笔记", "写笔记")], "clean", None);
        let parsed = parse_polish_profile(&serde_json::to_string(&plain).unwrap()).unwrap();
        assert_eq!(parsed.scenes.len(), 1);
    }
}
