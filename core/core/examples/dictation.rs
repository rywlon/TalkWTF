//! Headless dictation smoke test: the exact path the Swift app's hotkey uses
//! (`start` → record → `stop` → transcript), minus the hotkey and paste.
//!
//! ```sh
//! NO_PROXY=127.0.0.1,localhost cargo run --example dictation -- 4
//! ```
//!
//! Records for N seconds (default 3) from the default microphone.

use std::path::PathBuf;
use std::time::Duration;

use talkwtf_core::events::EventSink;
use talkwtf_core::pipeline::ProcessingMode;
use talkwtf_core::{dictation, engine, events, settings};

/// Prints the overlay state machine so the run doubles as a state trace.
struct PrintSink;

impl EventSink for PrintSink {
    fn emit(&self, event: &str, payload: serde_json::Value) {
        if event == "overlay-state" {
            println!(
                "  [overlay] {}",
                serde_json::to_string(&payload).unwrap_or_default()
            );
        }
    }
}

fn main() {
    let seconds: u64 = std::env::args()
        .nth(1)
        .and_then(|value| value.parse().ok())
        .unwrap_or(3);

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

    settings::init(data_dir);
    settings::set_resource_dir(resource_dir);

    events::set_sink(Box::new(PrintSink));

    if let Err(e) = engine::init() {
        eprintln!("engine init failed: {e}");
        std::process::exit(1);
    }
    println!("engine ready");

    println!("--- start (records {seconds}s) ---");
    if let Err(e) = dictation::start(ProcessingMode::Polish) {
        eprintln!("start failed: {e}");
        std::process::exit(1);
    }
    println!("recording…");

    std::thread::sleep(Duration::from_secs(seconds));

    println!("--- stop ---");
    match dictation::stop(ProcessingMode::Polish) {
        Ok(text) => {
            println!("transcript: {text}");
            println!("\nOK");
        }
        Err(e) => {
            eprintln!("stop failed: {e}");
            std::process::exit(1);
        }
    }
}
