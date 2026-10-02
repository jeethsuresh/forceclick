#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
if [[ -d "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]]; then
    swift test --disable-sandbox
else
    exec ./scripts/test-portable.sh
fi
