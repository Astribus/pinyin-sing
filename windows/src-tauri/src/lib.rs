//! Windows backend for 拼音 Sing: what's playing, lyric downloads, and saved songs.
//! The lyric logic (parsing, scoring, pinyin, karaoke) lives in the TypeScript front end.

mod media;

use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf, thread, time::Duration};
use tauri::{Emitter, Manager};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PinyinSing/0.1";

/// Downloads a lyrics web address and returns the text. Done here instead of in the window
/// because lyric sites don't allow requests from web pages on other sites.
#[tauri::command]
async fn fetch_text(url: String, referer: Option<String>) -> Result<String, String> {
    let allowed = ["https://music.163.com/", "https://lrclib.net/", "https://beta-luna.douyin.com/",
                   "https://qishui.douyin.com/", "https://music.douyin.com/"];
    if !allowed.iter().any(|a| url.starts_with(a)) {
        return Err("address not allowed".into());
    }
    let client = reqwest::Client::builder().user_agent(UA).build().map_err(|e| e.to_string())?;
    let mut req = client.get(&url);
    if let Some(r) = referer { req = req.header("Referer", r); }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    resp.text().await.map_err(|e| e.to_string())
}

/// Follows a 汽水音乐 share link to its final address (which has the track id in it).
#[tauri::command]
async fn resolve_link(url: String) -> Result<String, String> {
    let client = reqwest::Client::builder().user_agent(UA).build().map_err(|e| e.to_string())?;
    let resp = client.get(&url).send().await.map_err(|e| e.to_string())?;
    Ok(resp.url().to_string())
}

#[tauri::command]
fn media_control(action: String, seconds: Option<f64>) -> bool {
    media::control(&action, seconds.unwrap_or(0.0))
}

fn songs_dir(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?.join("Songs");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

fn file_for(dir: &PathBuf, id: &str) -> PathBuf {
    let hash: String = Sha256::digest(id.as_bytes()).iter().take(10).map(|b| format!("{b:02x}")).collect();
    dir.join(format!("{hash}.json"))
}

/// All saved songs, as JSON text (one per file).
#[tauri::command]
fn load_songs(app: tauri::AppHandle) -> Result<Vec<String>, String> {
    let dir = songs_dir(&app)?;
    let mut out = vec![];
    for entry in fs::read_dir(dir).map_err(|e| e.to_string())?.flatten() {
        if entry.path().extension().is_some_and(|e| e == "json") {
            if let Ok(text) = fs::read_to_string(entry.path()) { out.push(text); }
        }
    }
    Ok(out)
}

#[tauri::command]
fn save_song(app: tauri::AppHandle, id: String, json: String) -> Result<(), String> {
    let dir = songs_dir(&app)?;
    fs::write(file_for(&dir, &id), json).map_err(|e| e.to_string())
}

#[tauri::command]
fn delete_song(app: tauri::AppHandle, id: String) -> Result<(), String> {
    let dir = songs_dir(&app)?;
    let _ = fs::remove_file(file_for(&dir, &id));
    Ok(())
}

pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            // Reads what's playing twice a second and tells the window when anything changes.
            let handle = app.handle().clone();
            thread::spawn(move || {
                let mut last = String::new();
                loop {
                    let now = media::read();
                    let text = serde_json::to_string(&now).unwrap_or_default();
                    if text != last {
                        let _ = handle.emit("now-playing", now);
                        last = text;
                    }
                    thread::sleep(Duration::from_millis(500));
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![fetch_text, resolve_link, media_control, load_songs, save_song, delete_song])
        .run(tauri::generate_context!())
        .expect("error while running 拼音 Sing");
}
