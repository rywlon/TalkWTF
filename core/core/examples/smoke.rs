//! Headless engine smoke test: init → list models → transcribe a real WAV →
//! polish it. Run with:
//!
//! ```sh
//! NO_PROXY=127.0.0.1,localhost cargo run --example smoke
//! ```

use std::path::PathBuf;

use talkwtf_core::pipeline::ProcessingMode;
use talkwtf_core::{audio_toolkit, dictation, engine, settings};

fn main() {
    let data_dir = PathBuf::from(std::env::var("HOME").unwrap())
        .join("Library/Application Support/com.pais.handy");
    // The core resolves bundled paths as `<resource_dir>/resources/...`, so this
    // is the repo root, not the `resources` directory itself.
    let resource_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();

    println!("data dir:      {}", data_dir.display());
    println!("resource dir:  {}", resource_dir.display());

    settings::init(data_dir.clone());
    settings::set_resource_dir(resource_dir);

    println!("\n--- init ---");
    if let Err(e) = engine::init() {
        eprintln!("engine init failed: {e}");
        std::process::exit(1);
    }
    println!("engine ready");

    let settings = settings::current();
    println!("\n--- settings ---");
    println!("selected_model:    {}", settings.selected_model);
    println!("polish_style:      {}", settings.polish_style);
    println!("active_scene_id:   {:?}", settings.active_scene_id);
    println!("provider:          {}", settings.post_process_provider_id);
    println!(
        "model:             {:?}",
        settings
            .post_process_models
            .get(&settings.post_process_provider_id)
    );

    println!("\n--- models ---");
    if let Some(manager) = talkwtf_core::state::model_manager() {
        let models = manager.get_available_models();
        println!("{} model(s)", models.len());
        for model in models.iter().take(5) {
            println!(
                "  {} ({}) downloaded={}",
                model.name, model.id, model.is_downloaded
            );
        }
    }

    // Pick the newest recording and run the full pipeline on it.
    let recordings = data_dir.join("recordings");
    let wav = std::fs::read_dir(&recordings).ok().and_then(|dir| {
        let mut files: Vec<PathBuf> = dir
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "wav"))
            .collect();
        files.sort();
        files.pop()
    });

    let Some(wav) = wav else {
        eprintln!("\nno WAV found in {}", recordings.display());
        std::process::exit(1);
    };
    println!("\n--- transcribe {} ---", wav.display());

    let samples = match audio_toolkit::read_wav_samples(&wav) {
        Ok(samples) => samples,
        Err(e) => {
            eprintln!("failed to read WAV: {e}");
            std::process::exit(1);
        }
    };
    println!(
        "{} samples ({:.1}s)",
        samples.len(),
        samples.len() as f32 / 16_000.0
    );

    let transcription = match talkwtf_core::state::transcription_manager() {
        Some(manager) => {
            let settings = settings::current();
            if let Err(e) = manager.load_model(&settings.selected_model) {
                eprintln!("failed to load model: {e}");
                std::process::exit(1);
            }
            match manager.transcribe(samples) {
                Ok(text) => text,
                Err(e) => {
                    eprintln!("transcription failed: {e}");
                    std::process::exit(1);
                }
            }
        }
        None => {
            eprintln!("no transcription manager");
            std::process::exit(1);
        }
    };
    println!("raw:      {transcription}");

    let processed = dictation::block_on(talkwtf_core::pipeline::process_transcription_output(
        &transcription,
        ProcessingMode::Polish,
    ));
    println!("polished: {}", processed.final_text);
    println!("failed:   {}", processed.translation_failed);

    println!("\nOK");
}
