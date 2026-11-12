#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
VERSION="${1:-$APP_VERSION}"
VERSION="${VERSION#v}"
if [[ "$VERSION" != "$APP_VERSION" ]]; then
  print -u2 "版本不一致：发布 $VERSION，应用 $APP_VERSION"
  exit 1
fi
export STUDYTIMER_BUILD_ROOT="${STUDYTIMER_BUILD_ROOT:-${TMPDIR:-/tmp}/StudyTimer-build-${UID}}"
OUTPUT_DIR="${STUDYTIMER_RELEASE_DIR:-$PROJECT_DIR/dist}"
"$PROJECT_DIR/scripts/build-app.sh"
APP="$STUDYTIMER_BUILD_ROOT/StudyTimer.app"
mkdir -p "$OUTPUT_DIR"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/StudyTimer-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$APP" "$STAGING/StudyTimer.app"
ln -s /Applications "$STAGING/Applications"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/StudyTimer-macOS-arm64.zip"
/usr/bin/hdiutil create -volname "StudyTimer $VERSION" -srcfolder "$STAGING" -format UDZO -ov "$OUTPUT_DIR/StudyTimer-macOS-arm64.dmg"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 StudyTimer-macOS-arm64.dmg StudyTimer-macOS-arm64.zip > SHA256SUMS.txt
)
python3 "$PROJECT_DIR/scripts/verify-release.py" "$OUTPUT_DIR" --version "$VERSION"
printf '发布包已生成：%s\n' "$OUTPUT_DIR"
