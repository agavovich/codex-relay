#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/dist/Codex Relay.app"
ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-relay-icon.XXXXXX")"
ICONSET_DIR="$ICON_WORK_DIR/AppIcon.iconset"

trap 'rm -rf "$ICON_WORK_DIR"' EXIT

cd "$PROJECT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/.build/release/CodexRelay" "$APP_DIR/Contents/MacOS/CodexRelay"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

swift "$PROJECT_DIR/scripts/generate-app-icon.swift" "$ICONSET_DIR" >/dev/null
iconutil --convert icns "$ICONSET_DIR" \
    --output "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP_DIR"

print -r -- "$APP_DIR"
