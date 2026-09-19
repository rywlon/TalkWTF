#!/bin/bash
# 打出自包含、可分发的 TalkWTF.app（arm64，未公证）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="/opt/homebrew/opt/rustup/bin:$PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' macos/TalkWTF/Info.plist)"
APP="macos/build/Release/TalkWTF.app"
BIN="$APP/Contents/MacOS/TalkWTF"
DIST="$ROOT/dist"
ZIP="$DIST/TalkWTF-${VERSION}-arm64.zip"

echo "==> 构建 Release"
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Release build

echo "==> 断言自包含"
if otool -L "$BIN" | grep -E '/Users/|libtalkwtf_ffi\.dylib'; then
  echo "ERROR: app 仍依赖构建目录里的库，不可分发" >&2
  exit 1
fi

echo "==> strip"
strip -x "$BIN" || true

echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP"

echo "==> 打 zip"
mkdir -p "$DIST"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
cp "$ROOT/INSTALL.txt" "$DIST/INSTALL.txt"

echo "==> 完成：$ZIP"
ls -la "$ZIP"
