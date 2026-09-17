//! Tauri command wrapper over [`talkwtf_core::dashboard`].

use talkwtf_core::dashboard::DashboardStats;

#[tauri::command]
#[specta::specta]
pub fn get_dashboard_stats() -> Result<DashboardStats, String> {
    talkwtf_core::dashboard::get_dashboard_stats()
}
