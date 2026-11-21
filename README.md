# Yue's 音乐

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

## Build

Needs macOS 14.4 or later, the Xcode Command Line Tools, and [Homebrew](https://brew.sh).

```sh
brew install media-control
./build-app.sh
```

This builds the app and installs it to `~/Applications`. The app isn't signed by a registered Apple developer, so the first time, right-click it and choose Open.

## Disclaimer

This is an independent, free, open-source project for personal use. It isn't affiliated with or endorsed by NetEase, 汽水音乐 (Soda Music) or ByteDance, Spotify, YouTube or Google, or Apple. All song lyrics, titles, and album art belong to their owners. The app only displays them on your own computer while you listen, and doesn't host or share them.

If you own rights to something here and want it changed or removed, please open an issue.

## License

MIT. See [LICENSE](LICENSE). Third-party code and its licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
