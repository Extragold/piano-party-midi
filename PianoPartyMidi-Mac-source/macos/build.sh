#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="../dist/macos/Piano Party MIDI.app"
mkdir -p "$app/Contents/MacOS"
build_tmp="$(mktemp -d)"
trap 'rm -rf "$build_tmp"' EXIT
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -target "$arch-apple-macosx12.0" main.swift -framework Cocoa -framework CoreMIDI -framework CoreGraphics -o "$build_tmp/PianoPartyMidi-$arch"
done
xcrun lipo -create "$build_tmp/PianoPartyMidi-arm64" "$build_tmp/PianoPartyMidi-x86_64" -output "$app/Contents/MacOS/PianoPartyMidi"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PianoPartyMidi</string>
<key>CFBundleIdentifier</key><string>com.pianoparty.midicompanion</string>
<key>CFBundleName</key><string>Piano Party MIDI</string>
<key>CFBundleVersion</key><string>0.1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --strict "$app"
xcrun lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/PianoPartyMidi"
printf 'Built: %s\n' "$app"
