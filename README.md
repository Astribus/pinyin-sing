# 拼音 Sing

A floating lyrics window for the Mac that shows Chinese songs with pinyin under every line, so you can sing along even if you can't read the characters. Words light up in your color as they're sung.

It works with whatever is playing on your Mac: 汽水音乐, NetEase Cloud Music, Spotify, or YouTube in Chrome.

## What it does

- Lyrics island: a small floating window with the lyrics and pinyin. Drag it anywhere, resize it, keep it on top or let it act like a normal window
- Karaoke fill: each word turns from white to your color as it's sung
- Pinyin you can fix: pinyin is made automatically, and you can correct any line by hand
- Library: every song's lyrics are saved on your Mac, with albums, Liked Songs, and a page per app you listen in
- Play from the library: opens the song back in the app it came from
- Look: themes, light and dark mode, an optional spinning record

## Where lyrics come from

When a song starts, the app looks for timed lyrics in this order:

1. Songs you've already saved
2. NetEase Cloud Music's public lyrics
3. [LRCLIB](https://lrclib.net), a free, open lyrics database
4. A 汽水音乐 share link you copy (Share → Copy Link). These come with a time for every character
5. Lyrics you paste in yourself

Lyrics are fetched for the song you're playing and saved only on your Mac. This repository contains no lyrics.

## Download

Download the `PinyinSing` zip from the [latest release](https://github.com/Astribus/pinyin-sing/releases/latest), unzip it, and drag 拼音 Sing into Applications.

The app isn't signed by a paid Apple developer account, so the first time you open it, macOS says it can't check it. Click Done, then open System Settings → Privacy & Security, scroll down, and click Open Anyway next to 拼音 Sing. You only have to do this once.

## Build it yourself

Needs macOS 14.4 or later, the Xcode Command Line Tools, and [Homebrew](https://brew.sh).

```sh
brew install media-control
./build-app.sh
```

This builds the app and installs it to `~/Applications`.

## Sync words (optional)

Most lyric files only say when each line starts, so the app has to guess when each word is sung. With Sync words on, the app records a line-timed song once as it plays (only the music app's sound, never the microphone). It then separates the vocals with [Demucs](https://github.com/facebookresearch/demucs) and matches each line's pinyin to the singing with the MMS aligner in [torchaudio](https://pytorch.org/audio). Every character gets the time it's actually sung, pauses included. The times are saved with the song and the recording is deleted. Everything runs on your Mac.

It needs Python 3.12 and about 2.5 GB for the tools and the aligner model (downloaded on first use):

```sh
python3.12 -m venv ~/Library/Application\ Support/Yues\ Yinyue/sync-env
~/Library/Application\ Support/Yues\ Yinyue/sync-env/bin/pip install torch torchaudio demucs soundfile
```

Then turn on Settings → Sync words to the singing. The first time, macOS asks to let the app record the music app's audio.

## Disclaimer

This is an independent, free, open-source project for personal use. It isn't affiliated with or endorsed by NetEase, 汽水音乐 (Soda Music) or ByteDance, Spotify, YouTube or Google, or Apple. All song lyrics, titles, and album art belong to their owners. The app only displays them on your own computer while you listen, and doesn't host or share them.

If you own rights to something here and want it changed or removed, please open an issue.

## License

MIT. See [LICENSE](LICENSE). Third-party code and its licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
