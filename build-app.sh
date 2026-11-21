#!/bin/bash
# Builds "build/Yue's 音乐.app" and copies it to ~/Applications.
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
APP="build/Yue's 音乐.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/MediaRemote"
cp .build/release/YuesYinyue "$APP/Contents/MacOS/YuesYinyue"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Vendor/pinyin-pro.js "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp "$ADAPTER/lib/media-control/mediaremote-adapter.pl" "$APP/Contents/Resources/MediaRemote/"
cp -R "$ADAPTER/Frameworks/MediaRemoteAdapter.framework" "$APP/Contents/Resources/MediaRemote/"
codesign --force --deep --sign - "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Yue's 音乐.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed to ~/Applications/Yue's 音乐.app"
