//! What's playing, from Windows' media controls (the same panel the volume flyout shows).
//! Spotify, browsers (YouTube, Spotify's web player), NetEase and most players report there.

use serde::Serialize;

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct NowPlaying {
    pub title: String,
    pub artist: String,
    /// Song length in seconds (0 if the player doesn't say).
    pub duration: f64,
    /// Position in seconds at `updated_ms`.
    pub position: f64,
    /// When the position was measured, in Unix milliseconds.
    pub updated_ms: f64,
    pub playing: bool,
    /// The player's app id, e.g. "Spotify.exe" or "Chrome".
    pub app: String,
    /// Cover art as a data URL (read once per song).
    pub art: String,
}

#[cfg(windows)]
mod imp {
    use super::NowPlaying;
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };

    // Windows file time (100 ns since 1601) → Unix milliseconds.
    fn filetime_to_unix_ms(t: i64) -> f64 {
        (t as f64 / 10_000.0) - 11_644_473_600_000.0
    }

    pub fn read() -> Option<NowPlaying> {
        let run = || -> windows::core::Result<NowPlaying> {
            let s = Manager::RequestAsync()?.join()?.GetCurrentSession()?;
            let props = s.TryGetMediaPropertiesAsync()?.join()?;
            let tl = s.GetTimelineProperties()?;
            let playing = s.GetPlaybackInfo()?.PlaybackStatus()? == Status::Playing;
            Ok(NowPlaying {
                title: props.Title()?.to_string(),
                artist: props.Artist()?.to_string(),
                duration: tl.EndTime()?.Duration as f64 / 1e7,
                position: tl.Position()?.Duration as f64 / 1e7,
                updated_ms: filetime_to_unix_ms(tl.LastUpdatedTime()?.UniversalTime),
                playing,
                app: s.SourceAppUserModelId()?.to_string(),
                art: String::new(),
            })
        };
        run().ok().filter(|n| !n.title.is_empty())
    }

    /// The cover art of what's playing, as image bytes.
    pub fn thumbnail() -> Option<Vec<u8>> {
        use windows::Storage::Streams::{DataReader, InputStreamOptions};
        let run = || -> windows::core::Result<Vec<u8>> {
            let s = Manager::RequestAsync()?.join()?.GetCurrentSession()?;
            let props = s.TryGetMediaPropertiesAsync()?.join()?;
            let stream = props.Thumbnail()?.OpenReadAsync()?.join()?;
            let size = stream.Size()? as u32;
            let reader = DataReader::CreateDataReader(&stream.GetInputStreamAt(0)?)?;
            reader.SetInputStreamOptions(InputStreamOptions::ReadAhead)?;
            reader.LoadAsync(size)?.join()?;
            let mut buf = vec![0u8; size as usize];
            reader.ReadBytes(&mut buf)?;
            Ok(buf)
        };
        run().ok().filter(|b| !b.is_empty())
    }

    pub fn control(action: &str, seconds: f64) -> bool {
        let run = || -> windows::core::Result<bool> {
            let s = Manager::RequestAsync()?.join()?.GetCurrentSession()?;
            let op = match action {
                "toggle" => s.TryTogglePlayPauseAsync()?,
                "next" => s.TrySkipNextAsync()?,
                "previous" => s.TrySkipPreviousAsync()?,
                _ => s.TryChangePlaybackPositionAsync((seconds * 1e7) as i64)?,
            };
            op.join()
        };
        run().unwrap_or(false)
    }
}

// Other systems (only used while developing on a Mac): nothing is playing.
#[cfg(not(windows))]
mod imp {
    use super::NowPlaying;
    pub fn read() -> Option<NowPlaying> { None }
    pub fn thumbnail() -> Option<Vec<u8>> { None }
    pub fn control(_action: &str, _seconds: f64) -> bool { false }
}

pub use imp::{control, read, thumbnail};
