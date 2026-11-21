#!/bin/bash
# Builds "build/拼音 Sing.app" and copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

# Now Playing helper (mediaremote-adapter, BSD-3-Clause). Uses the Homebrew copy for now:
#   brew install media-control
ADAPTER="$(brew --prefix media-control 2>/dev/null || true)"
if [ ! -f "$ADAPTER/lib/media-control/mediaremote-adapter.pl" ]; then
  echo "Missing Now Playing helper. Run: brew install media-control" >&2
  exit 1
fi

swift build -c release
APP="build/拼音 Sing.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/MediaRemote"
cp .build/release/PinyinSing "$APP/Contents/MacOS/PinyinSing"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Vendor/pinyin-pro.js "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp Resources/Sync/align.py "$APP/Contents/Resources/"
cp "$ADAPTER/lib/media-control/mediaremote-adapter.pl" "$APP/Contents/Resources/MediaRemote/"
cp -R "$ADAPTER/Frameworks/MediaRemoteAdapter.framework" "$APP/Contents/Resources/MediaRemote/"
codesign --force --deep --sign - "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/拼音 Sing.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed to ~/Applications/拼音 Sing.app"
