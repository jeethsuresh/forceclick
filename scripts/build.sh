#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --build-system native -c release -debug-info-format none
app="$PWD/build/ForceClick.app"
stamp="$PWD/build/release-input-hash.txt"
input_hash=$(/usr/bin/shasum -a 256 .build/release/ForceClick Info.plist | /usr/bin/awk '{printf "%s:", $1}')
if [[ -n "${FORCECLICK_SIGNING_IDENTITY:-}" ]]; then
    signing_id="$FORCECLICK_SIGNING_IDENTITY"
else
    ./scripts/local-signing.sh
    signing_id=$(< "$PWD/.signing/identity-sha1")
fi
input_hash="$input_hash:$signing_id"
if [[ -f "$stamp" && -f "$app/Contents/MacOS/ForceClick" ]] && \
   [[ "$(< "$stamp")" == "$input_hash" ]] && \
   codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
    echo "Build unchanged; kept the existing app signature and Accessibility identity."
    exit 0
fi
mkdir -p "$app/Contents/MacOS"
cp .build/release/ForceClick "$app/Contents/MacOS/ForceClick"
cp Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ForceClickBuild string ${input_hash[1,12]}" "$app/Contents/Info.plist"
if [[ -n "${FORCECLICK_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --sign "$FORCECLICK_SIGNING_IDENTITY" --identifier dev.local.forceclick "$app"
else
    ./scripts/local-signing.sh --sign "$app"
fi
codesign --verify --deep --strict "$app"
print -r -- "$input_hash" > "$stamp"
echo "Built $app"
