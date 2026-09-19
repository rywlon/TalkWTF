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
if ! DEPS="$(otool -L "$BIN")"; then
  echo "ERROR: otool -L 执行失败，无法验证自包含" >&2
  exit 1
fi
BAD_DEPS="$(printf '%s\n' "$DEPS" | tail -n +2 | awk '{print $1}' | grep -vE '^(/System/|/usr/lib/)' || true)"
if [ -n "$BAD_DEPS" ]; then
  echo "ERROR: app 依赖非系统库，不可分发：" >&2
  printf '%s\n' "$BAD_DEPS" >&2
  exit 1
fi

echo "==> strip"
strip -x "$BIN" || true

echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP"

echo "==> 打 zip"
mkdir -p "$DIST"
rm -rf "$DIST/TalkWTF.app"
rm -f "$ZIP"
STAGE="$DIST/TalkWTF-${VERSION}"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/TalkWTF.app"
cp "$ROOT/INSTALL.txt" "$STAGE/INSTALL.txt"
ditto -c -k --keepParent "$STAGE" "$ZIP"
cp "$ROOT/INSTALL.txt" "$DIST/INSTALL.txt"

echo "==> 完成：$ZIP"
ls -la "$ZIP"
