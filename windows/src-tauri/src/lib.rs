//! Windows backend for 拼音 Sing: what's playing, lyric downloads, and saved songs.
//! The lyric logic (parsing, scoring, pinyin, karaoke) lives in the TypeScript front end.

mod media;

use base64::Engine;
use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf, thread, time::Duration};
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Emitter, Manager, WindowEvent,
};

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
    let _ = fs::remove_file(file_for(&dir, &id).with_extension("art"));
    Ok(())
}

/// Albums (Liked Songs and the user's own), as one JSON file next to the Songs folder.
#[tauri::command]
fn load_albums(app: tauri::AppHandle) -> Result<String, String> {
    let file = songs_dir(&app)?.parent().unwrap().join("albums.json");
    Ok(fs::read_to_string(file).unwrap_or_else(|_| "[]".into()))
}

#[tauri::command]
fn save_albums(app: tauri::AppHandle, json: String) -> Result<(), String> {
    let file = songs_dir(&app)?.parent().unwrap().join("albums.json");
    fs::write(file, json).map_err(|e| e.to_string())
}

/// A song's cover art, kept as a data URL next to its lyrics.
#[tauri::command]
fn save_art(app: tauri::AppHandle, id: String, data_url: String) -> Result<(), String> {
    let dir = songs_dir(&app)?;
    fs::write(file_for(&dir, &id).with_extension("art"), data_url).map_err(|e| e.to_string())
}

#[tauri::command]
fn load_art(app: tauri::AppHandle, id: String) -> Option<String> {
    let dir = songs_dir(&app).ok()?;
    fs::read_to_string(file_for(&dir, &id).with_extension("art")).ok()
}

/// Shows or hides the lyrics island.
#[tauri::command]
fn set_island(app: tauri::AppHandle, shown: bool) {
    if let Some(w) = app.get_webview_window("island") {
        let _ = if shown { w.show() } else { w.hide() };
        let _ = app.emit("island-shown", shown);
    }
}

#[tauri::command]
fn open_dashboard(app: tauri::AppHandle) { show_dashboard(&app); }

fn show_dashboard(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("dashboard") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn data_url(bytes: &[u8]) -> String {
    let mime = if bytes.starts_with(&[0x89, b'P', b'N', b'G']) { "image/png" } else { "image/jpeg" };
    format!("data:{mime};base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes))
}

pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            // Reads what's playing twice a second and tells both windows when anything changes.
            // The cover art is read once per song.
            let handle = app.handle().clone();
            thread::spawn(move || {
                let mut last = String::new();
                let mut song = String::new();
                let mut art = String::new();
                loop {
                    let mut now = media::read();
                    if let Some(n) = now.as_mut() {
                        let key = format!("{}|{}", n.title, n.artist);
                        if key != song {
                            song = key;
                            art = media::thumbnail().map(|b| data_url(&b)).unwrap_or_default();
                        }
                        n.art = art.clone();
                    }
                    let text = serde_json::to_string(&now).unwrap_or_default();
                    if text != last {
                        let _ = handle.emit("now-playing", now);
                        last = text;
                    }
                    thread::sleep(Duration::from_millis(500));
                }
            });

            // Tray icon (Windows' version of the menu bar item).
            let toggle = MenuItem::with_id(app, "island", "Show / hide lyrics island", true, None::<&str>)?;
            let dash = MenuItem::with_id(app, "dashboard", "Open 拼音 Sing", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&dash, &toggle, &quit])?;
            TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("拼音 Sing")
                .menu(&menu)
                .on_menu_event(|app, e| match e.id.as_ref() {
                    "dashboard" => show_dashboard(app),
                    "island" => {
                        if let Some(w) = app.get_webview_window("island") {
                            let shown = !w.is_visible().unwrap_or(false);
                            set_island(app.clone(), shown);
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;
            Ok(())
        })
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        // Closing the dashboard hides it; the app keeps running in the tray.
        .on_window_event(|w, e| {
            if let WindowEvent::CloseRequested { api, .. } = e {
                if w.label() == "dashboard" {
                    api.prevent_close();
                    let _ = w.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![fetch_text, resolve_link, media_control, load_songs, save_song,
            delete_song, load_albums, save_albums, save_art, load_art, set_island, open_dashboard])
        .run(tauri::generate_context!())
        .expect("error while running 拼音 Sing");
}
