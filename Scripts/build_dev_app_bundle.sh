#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/debug"
APP_NAME="Speechflow.app"
APP_DIR="$ROOT_DIR/dist/$APP_NAME"
EXECUTABLE_NAME="SpeechflowApp"

cd "$ROOT_DIR"
swift build

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ROOT_DIR/Sources/SpeechflowApp/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Built $APP_DIR"
