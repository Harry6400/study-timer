#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${STUDYTIMER_BUILD_ROOT:-${TMPDIR:-/tmp}/StudyTimer-build-${UID}}"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache"
cd "$PROJECT_DIR"
swift build --configuration release --arch arm64 --disable-sandbox \
  --scratch-path "$BUILD_ROOT/build" --cache-path "$BUILD_ROOT/cache" \
  --config-path "$BUILD_ROOT/config" --security-path "$BUILD_ROOT/security"
APP="$BUILD_ROOT/StudyTimer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_ROOT/build/release/StudyTimer" "$APP/Contents/MacOS/StudyTimer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
swift -module-cache-path "$BUILD_ROOT/module-cache" scripts/make-icon.swift "$BUILD_ROOT/AppIcon.iconset"
iconutil -c icns "$BUILD_ROOT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.harry64.studytimer "$APP"
codesign --verify --strict "$APP"
printf '已构建：%s\n' "$APP"
if [[ "${1:-}" == "--install" ]]; then
  ditto "$APP" /Applications/StudyTimer.app
  REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  "$REGISTER" -u "$APP" || true
  "$REGISTER" -f /Applications/StudyTimer.app
  printf '已安装：/Applications/StudyTimer.app\n'
fi
