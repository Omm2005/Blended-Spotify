#!/bin/zsh
# Builds DesktopLyrics.app into ~/Applications and (re)launches it.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/DesktopLyrics.app"

mkdir -p "$APP/Contents/MacOS"
rm -rf "$APP/Contents/Resources/Fonts" && mkdir -p "$APP/Contents/Resources" && cp -R Fonts "$APP/Contents/Resources/Fonts"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.omshah.DesktopLyrics</string>
  <key>CFBundleName</key><string>DesktopLyrics</string>
  <key>CFBundleExecutable</key><string>DesktopLyrics</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Reads the current Spotify track and playback position to show lyrics.</string>
</dict></plist>
EOF

swiftc -O -Xcc -ivfsoverlay -Xcc "$PWD/vfs.yaml" -o "$APP/Contents/MacOS/DesktopLyrics" main.swift
codesign --force --sign - "$APP"

pkill -x DesktopLyrics || true
sleep 0.5
open "$APP"
echo "Launched $APP"
