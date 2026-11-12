#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${STUDYTIMER_BUILD_ROOT:-${TMPDIR:-/tmp}/StudyTimer-build-${UID}}"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache"
cd "$PROJECT_DIR"
TEST_FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
extra=()
if [[ -d "$TEST_FRAMEWORKS/Testing.framework" ]]; then
  extra=(-Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" -Xlinker -F -Xlinker "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib")
fi
swift test --disable-xctest --enable-swift-testing --disable-sandbox \
  --scratch-path "$BUILD_ROOT/build" --cache-path "$BUILD_ROOT/cache" \
  --config-path "$BUILD_ROOT/config" --security-path "$BUILD_ROOT/security" "${extra[@]}"
